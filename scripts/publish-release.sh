#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="ivogundlach/Switchboard"
BUNDLE_ID="com.ivogundlach.switchboard"
TEAM_ID="Q2X7X86GYR"
IDENTITY_PREFIX="Developer ID Application:"

usage() {
  printf '%s\n' \
    "Usage: scripts/publish-release.sh --version X.Y.Z --notary-profile NAME [--output-dir DIR] [--publish]" \
    "" \
    "Builds, Developer ID-signs, notarizes, audits, and publishes one immutable" \
    "notarized Switchboard-X.Y.Z-macOS.dmg and Switchboard-update.json artifacts." \
    "Without --publish, --output-dir is required and no GitHub state changes." \
    "The source checkout must be clean and exactly tagged vX.Y.Z."
}

version=""
notary_profile=""
publish=0
output_dir=""
while (($#)); do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --notary-profile) notary_profile="${2:-}"; shift 2 ;;
    --output-dir) output_dir="${2:-}"; shift 2 ;;
    --publish) publish=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Version must use X.Y.Z semantic-version format.\n' >&2
  exit 2
fi
if [[ -z "$notary_profile" ]]; then
  printf 'A notarytool keychain profile is required.\n' >&2
  exit 2
fi
if ((publish != 1)) && [[ -z "$output_dir" ]]; then
  printf 'A local preparation requires --output-dir; GitHub publishing additionally requires --publish.\n' >&2
  exit 2
fi

identity_line="$(security find-identity -v -p codesigning | rg -m1 "${IDENTITY_PREFIX}.*\(${TEAM_ID}\)" || true)"
if [[ -z "$identity_line" ]]; then
  printf 'No Apple-issued Developer ID Application certificate for Team %s is installed.\n' "$TEAM_ID" >&2
  exit 3
fi
identity_hash="$(awk '{print $2}' <<<"$identity_line")"
if [[ ! "$identity_hash" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  printf 'Could not resolve the Developer ID certificate fingerprint.\n' >&2
  exit 3
fi

for command in swift codesign hdiutil xcrun jq shasum ditto plutil; do
  command -v "$command" >/dev/null || { printf 'Required command is missing: %s\n' "$command" >&2; exit 4; }
done
if ((publish == 1)); then
  command -v gh >/dev/null || { printf 'Required command is missing: gh\n' >&2; exit 4; }
  gh auth status >/dev/null
fi
if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet \
  || [[ -n "$(git -C "$ROOT" ls-files --others --exclude-standard)" ]]; then
  printf 'Release checkout must be clean; build from the exact committed tag.\n' >&2
  exit 5
fi
exact_tag="$(git -C "$ROOT" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ "$exact_tag" != "v$version" ]]; then
  printf 'Release checkout must be exactly tagged v%s.\n' "$version" >&2
  exit 5
fi
if ((publish == 1)) && gh release view "v$version" --repo "$REPOSITORY" >/dev/null 2>&1; then
  printf 'Release v%s already exists; refusing to replace an immutable release.\n' "$version" >&2
  exit 5
fi

"$ROOT/build.sh"

release_root="$(mktemp -d "${TMPDIR:-/tmp}/switchboard-release.XXXXXX")"
cleanup() {
  if [[ -n "${mounted_device:-}" ]]; then
    hdiutil detach "$mounted_device" >/dev/null 2>&1 || true
  fi
  rm -rf "$release_root"
}
trap cleanup EXIT

app="$release_root/Switchboard.app"
ditto "$ROOT/build/Switchboard.app" "$app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${version//./}" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SwitchboardUpdateTeamIdentifier $TEAM_ID" "$app/Contents/Info.plist"

while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | rg -q 'Mach-O'; then
    codesign --force --sign "$identity_hash" --options runtime --timestamp \
      --preserve-metadata=identifier,entitlements "$candidate"
  fi
done < <(find "$app/Contents" -type f -print0)

while IFS= read -r -d '' candidate; do
  codesign --force --sign "$identity_hash" --options runtime --timestamp \
    --preserve-metadata=identifier,entitlements "$candidate"
done < <(find "$app/Contents" -depth \( -name '*.app' -o -name '*.appex' -o -name '*.xpc' -o -name '*.framework' \) -print0)

codesign --force --sign "$identity_hash" --options runtime --timestamp \
  --preserve-metadata=identifier,entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"

team="$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$team" == "$TEAM_ID" ]] || { printf 'Signed app Team ID mismatch.\n' >&2; exit 6; }
identifier="$(codesign -dv --verbose=4 "$app" 2>&1 | sed -n 's/^Identifier=//p')"
[[ "$identifier" == "$BUNDLE_ID" ]] || { printf 'Signed app bundle identifier mismatch.\n' >&2; exit 6; }

stage="$release_root/dmg-root"
mkdir -p "$stage"
ditto "$app" "$stage/Switchboard.app"
# The updater accepts exactly one app and rejects every symbolic link on the
# mounted image, including the conventional Applications shortcut.
dmg_name="Switchboard-$version-macOS.dmg"
dmg="$release_root/$dmg_name"
hdiutil create -volname Switchboard -srcfolder "$stage" -format UDZO -ov "$dmg" >/dev/null
codesign --force --sign "$identity_hash" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
hdiutil verify "$dmg" >/dev/null

attach_plist="$release_root/attach.plist"
hdiutil attach -readonly -nobrowse -plist "$dmg" >"$attach_plist"
mounted_device="$(plutil -extract system-entities xml1 -o - "$attach_plist" | plutil -convert json -o - -- - | jq -r '.[] | select(."mount-point" != null) | ."dev-entry"' | head -1)"
mount_point="$(plutil -extract system-entities xml1 -o - "$attach_plist" | plutil -convert json -o - -- - | jq -r '.[] | select(."mount-point" != null) | ."mount-point"' | head -1)"
[[ -n "$mounted_device" && -d "$mount_point/Switchboard.app" ]] || { printf 'Notarized DMG mount verification failed.\n' >&2; exit 7; }
codesign --verify --deep --strict --verbose=2 "$mount_point/Switchboard.app"
spctl --assess --type execute --verbose=4 "$mount_point/Switchboard.app"
hdiutil detach "$mounted_device" >/dev/null
mounted_device=""

sha256="$(shasum -a 256 "$dmg" | awk '{print $1}')"
manifest="$release_root/Switchboard-update.json"
jq -n \
  --arg version "$version" \
  --arg dmg_url "https://github.com/$REPOSITORY/releases/download/v$version/$dmg_name" \
  --arg sha "$sha256" \
  --arg bundle "$BUNDLE_ID" \
  --arg team "$TEAM_ID" \
  '{schemaVersion:1,version:$version,minimumSystemVersion:"26.0",architectures:["arm64"],dmgURL:$dmg_url,dmgSHA256:$sha,bundleIdentifier:$bundle,teamIdentifier:$team}' \
  >"$manifest"
jq -e '.schemaVersion == 1 and (.dmgSHA256 | test("^[0-9a-f]{64}$"))' "$manifest" >/dev/null

notes="$release_root/release-notes.md"
printf '# Switchboard %s\n\nSigned with Apple Developer ID, notarized, and verified for Apple silicon on macOS 26 or later. This update automatically imports detected standalone utilities, settings, commands, Services, and background jobs when their exact permissions are ready. Old owners are retired only after the bundled replacement passes its operational health check; permission blockers are brought directly into view during onboarding.\n' "$version" >"$notes"

if [[ -n "$output_dir" ]]; then
  mkdir -p "$output_dir"
  output_dir="$(cd "$output_dir" && pwd -P)"
  ditto "$dmg" "$output_dir/$dmg_name"
  ditto "$manifest" "$output_dir/Switchboard-update.json"
  ditto "$notes" "$output_dir/release-notes.md"
fi

if ((publish != 1)); then
  printf 'Prepared notarized release artifacts in %s\n' "$output_dir"
  exit 0
fi

# Keep an incomplete release hidden from update discovery. Publish only after
# GitHub reports the exact immutable asset pair on the draft.
gh release create "v$version" --repo "$REPOSITORY" \
  --title "Switchboard $version" --notes-file "$notes" --draft
gh release upload "v$version" "$dmg" "$manifest" --repo "$REPOSITORY"
release_json="$(gh release view "v$version" --repo "$REPOSITORY" --json isDraft,tagName,assets)"
jq -e --arg tag "v$version" --arg dmg "$dmg_name" '
  .isDraft == true and .tagName == $tag and
  ([.assets[].name] | sort) == ([$dmg, "Switchboard-update.json"] | sort)
' <<<"$release_json" >/dev/null || {
  printf 'Draft asset verification failed; the draft remains hidden for inspection.\n' >&2
  exit 8
}
gh release edit "v$version" --repo "$REPOSITORY" --draft=false --latest

printf 'Published https://github.com/%s/releases/tag/v%s\n' "$REPOSITORY" "$version"
