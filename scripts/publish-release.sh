#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY="ivogundlach/Switchboard"
BUNDLE_ID="com.ivogundlach.switchboard"
TEAM_ID="Q2X7X86GYR"
IDENTITY_PREFIX="Developer ID Application:"

usage() {
  printf '%s\n' \
    "Usage: scripts/publish-release.sh --version X.Y.Z --notary-profile NAME --publish" \
    "" \
    "Builds, Developer ID-signs, notarizes, audits, and publishes one immutable" \
    "GitHub release containing Switchboard-X.Y.Z-macOS.dmg and Switchboard-update.json."
}

version=""
notary_profile=""
publish=0
while (($#)); do
  case "$1" in
    --version) version="${2:-}"; shift 2 ;;
    --notary-profile) notary_profile="${2:-}"; shift 2 ;;
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
if ((publish != 1)); then
  printf 'Publishing is external and irreversible; rerun with --publish after reviewing the exact version.\n' >&2
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

for command in swift codesign hdiutil xcrun gh jq shasum ditto plutil; do
  command -v "$command" >/dev/null || { printf 'Required command is missing: %s\n' "$command" >&2; exit 4; }
done
gh auth status >/dev/null
if gh release view "v$version" --repo "$REPOSITORY" >/dev/null 2>&1; then
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
ln -s /Applications "$stage/Applications"
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
printf '# Switchboard %s\n\nSigned with Apple Developer ID, notarized, and verified for Apple silicon on macOS 26 or later.\n' "$version" >"$notes"
gh release create "v$version" "$dmg" "$manifest" \
  --repo "$REPOSITORY" --title "Switchboard $version" --notes-file "$notes" --latest

printf 'Published https://github.com/%s/releases/tag/v%s\n' "$REPOSITORY" "$version"
