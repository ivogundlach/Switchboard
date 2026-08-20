#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Switchboard.app"
REQUIRED_SIGNING_IDENTITY="Ivo Market Dev"
REQUIRED_CERTIFICATE_SHA1="12F05E96DC78DEF756913A2D574FF98F6C5BD485"
if [[ -n "${SIGNING_IDENTITY+x}" && "$SIGNING_IDENTITY" != "$REQUIRED_SIGNING_IDENTITY" ]]; then
  echo "Switchboard local builds require exactly: $REQUIRED_SIGNING_IDENTITY" >&2
  exit 2
fi
SIGNING_IDENTITY="$REQUIRED_SIGNING_IDENTITY"

if ! security find-identity -v -p codesigning | grep -Fq "$REQUIRED_CERTIFICATE_SHA1"; then
  echo "Required signing identity is unavailable: $SIGNING_IDENTITY" >&2
  exit 2
fi

swift build --package-path "$ROOT" -c release
BIN_DIR="$(swift build --package-path "$ROOT" -c release --show-bin-path)"

# Build the vendored Kinetics companion for the same Apple-silicon/macOS target
# as Switchboard. Its source intentionally contains only the main app; the old
# SMAppService LoginLauncher target is not part of this bundle.
KINETICS_SCRATCH="$ROOT/.build/kinetics"
swift build --package-path "$ROOT/Vendor/Kinetics" --scratch-path "$KINETICS_SCRATCH" \
  -c release --triple arm64-apple-macosx26.0
KINETICS_BIN_DIR="$(swift build --package-path "$ROOT/Vendor/Kinetics" --scratch-path "$KINETICS_SCRATCH" \
  -c release --triple arm64-apple-macosx26.0 --show-bin-path)"
KINETICS_BIN="$KINETICS_BIN_DIR/Kinetics"
[[ -x "$KINETICS_BIN" ]] || { echo "Vendored Kinetics binary is missing." >&2; exit 6; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents" \
  "$APP/Contents/PlugIns/CopyPathFinderExt.appex/Contents/MacOS" \
  "$APP/Contents/PlugIns/CopyPathFinderExt.appex/Contents/Resources" \
  "$APP/Contents/Library/LoginItems/Kinetics Login Launcher.app/Contents/MacOS" \
  "$APP/Contents/Resources/Companions/Kinetics.app/Contents/MacOS" \
  "$APP/Contents/Resources/Companions/Kinetics.app/Contents/Resources"
cp "$BIN_DIR/Switchboard" "$APP/Contents/MacOS/Switchboard"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/Switchboard/Resources/ModuleManifest.json" "$APP/Contents/Resources/ModuleManifest.json"
cp "$ROOT/Sources/Switchboard/Resources/WarmCornersMigrationContract.json" "$APP/Contents/Resources/WarmCornersMigrationContract.json"
cp "$ROOT/Sources/Switchboard/Resources/InventoryBaseline.json" "$APP/Contents/Resources/InventoryBaseline.json"
cp "$ROOT/Sources/Switchboard/Resources/RuntimeManifest.json" "$APP/Contents/Resources/RuntimeManifest.json"
cp "$ROOT/Resources/com.ivogundlach.switchboard.agent.plist" "$APP/Contents/Library/LaunchAgents/com.ivogundlach.switchboard.agent.plist"
KINETICS_HELPER_APP="$APP/Contents/Library/LoginItems/Kinetics Login Launcher.app"
KINETICS_HELPER_EXECUTABLE="$KINETICS_HELPER_APP/Contents/MacOS/Kinetics Login Launcher"
cp "$ROOT/Resources/KineticsLegacyLoginLauncher-Info.plist" "$KINETICS_HELPER_APP/Contents/Info.plist"
xcrun swiftc -O -swift-version 6 -parse-as-library -target arm64-apple-macosx26.0 \
  "$ROOT/Sources/Switchboard/Helpers/KineticsLegacyLoginLauncher/main.swift" \
  -o "$KINETICS_HELPER_EXECUTABLE"
chmod 0755 "$KINETICS_HELPER_EXECUTABLE"
if strings "$KINETICS_HELPER_EXECUTABLE" | grep -Eiq 'NSWorkspace|SMAppService|register|open'; then
  echo "Kinetics migration helper contains forbidden launch or registration behavior." >&2
  exit 7
fi
KINETICS_APP="$APP/Contents/Resources/Companions/Kinetics.app"
cp "$KINETICS_BIN" "$KINETICS_APP/Contents/MacOS/Kinetics"
cp "$ROOT/Vendor/Kinetics/Resources/Info.plist" "$KINETICS_APP/Contents/Info.plist"
cp "$ROOT/Vendor/Kinetics/Resources/AppIcon.icns" "$KINETICS_APP/Contents/Resources/AppIcon.icns"
chmod 0755 "$KINETICS_APP/Contents/MacOS/Kinetics"
COPY_PATH_APPEX="$APP/Contents/PlugIns/CopyPathFinderExt.appex"
cp "$ROOT/Resources/CopyPathFinderExt-Info.plist" "$COPY_PATH_APPEX/Contents/Info.plist"
cp "$ROOT/Resources/CopyPathFinderExt.entitlements" "$COPY_PATH_APPEX/Contents/Resources/CopyPathFinderExt.entitlements"
xcrun swiftc -O -swift-version 6 -target arm64-apple-macosx26.0 \
  -application-extension -parse-as-library -module-name CopyPathFinderExt \
  -D COPY_PATH_FINDER_EXTENSION \
  "$ROOT/Sources/Switchboard/Modules/CopyPath/FinderSync.swift" \
  -Xlinker -e -Xlinker _NSExtensionMain -framework FinderSync -framework Cocoa \
  -o "$COPY_PATH_APPEX/Contents/MacOS/CopyPathFinderExt"
mkdir -p "$APP/Contents/Resources/Modules" "$APP/Contents/Resources/Services" "$APP/Contents/Resources/Helpers"
cp -R "$ROOT/Payloads/Modules/." "$APP/Contents/Resources/Modules/"
cp -R "$ROOT/Payloads/Services/." "$APP/Contents/Resources/Services/"
find "$APP/Contents/Resources/Modules" -type f -path '*/bin/*' -exec chmod 0755 {} +

MAIL_HELPER="$APP/Contents/Resources/Helpers/MailAssistant.app"
mkdir -p "$MAIL_HELPER/Contents/MacOS" "$MAIL_HELPER/Contents/Resources"
cp "$ROOT/Helpers/MailAssistant-Info.plist" "$MAIL_HELPER/Contents/Info.plist"
clang -O2 -o "$MAIL_HELPER/Contents/MacOS/mail-assistant-runner" "$ROOT/Helpers/MailAssistantStub.c"
cp "$ROOT/Helpers/mail-assistant-runner.sh" "$MAIL_HELPER/Contents/Resources/runner.sh"
chmod 0755 "$MAIL_HELPER/Contents/Resources/runner.sh"

xcrun swiftc -O -swift-version 6 \
  "$ROOT/Sources/Switchboard/Modules/Desktop/QuitOnCloseController.swift" \
  "$ROOT/Helpers/QuitOnCloseMain.swift" \
  -o "$APP/Contents/Resources/Helpers/quit-on-close"

xcrun swiftc -O -swift-version 6 \
  "$ROOT/Sources/Switchboard/Services/UpdateInstaller.swift" \
  "$ROOT/Helpers/UpdaterMain.swift" \
  -o "$APP/Contents/Resources/Helpers/switchboard-updater"

if [[ ! -s "$ROOT/Icon/AppIcon.icns" || "$ROOT/Icon/AppIcon.svg" -nt "$ROOT/Icon/AppIcon.icns" ]]; then
  "$ROOT/scripts/make-icon.sh" >/dev/null
fi
cp "$ROOT/Icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

chmod 0755 "$APP/Contents/MacOS/Switchboard"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
plutil -lint "$KINETICS_HELPER_APP/Contents/Info.plist" >/dev/null
plutil -lint "$KINETICS_APP/Contents/Info.plist" >/dev/null
plutil -lint "$APP/Contents/Library/LaunchAgents/com.ivogundlach.switchboard.agent.plist" >/dev/null
plutil -lint "$COPY_PATH_APPEX/Contents/Info.plist" >/dev/null
plutil -lint "$COPY_PATH_APPEX/Contents/Resources/CopyPathFinderExt.entitlements" >/dev/null
codesign --force --sign "$REQUIRED_CERTIFICATE_SHA1" --entitlements "$ROOT/Resources/CopyPathFinderExt.entitlements" --identifier com.ivo.CopyPath.FinderExt --options runtime --timestamp=none "$COPY_PATH_APPEX"
codesign --force --sign "$REQUIRED_CERTIFICATE_SHA1" --identifier com.ivo.mail-assistant --options runtime --timestamp=none "$MAIL_HELPER"
codesign --force --sign "$REQUIRED_CERTIFICATE_SHA1" --identifier com.ivogundlach.quit-on-close --options runtime --timestamp=none "$APP/Contents/Resources/Helpers/quit-on-close"
codesign --force --sign "$REQUIRED_CERTIFICATE_SHA1" --identifier com.ivogundlach.switchboard.updater --options runtime --timestamp=none "$APP/Contents/Resources/Helpers/switchboard-updater"
codesign --force --sign "$REQUIRED_CERTIFICATE_SHA1" --identifier com.ivogundlach.Kinetics.LoginLauncher --options runtime --timestamp=none "$KINETICS_HELPER_APP"
codesign --force --sign "$REQUIRED_CERTIFICATE_SHA1" --identifier com.ivogundlach.Kinetics --options runtime --timestamp=none "$KINETICS_APP"
codesign --verify --deep --strict --verbose=2 "$KINETICS_HELPER_APP"
codesign --verify --deep --strict --verbose=2 "$KINETICS_APP"
codesign --force --sign "$REQUIRED_CERTIFICATE_SHA1" --options runtime --timestamp=none "$APP"
codesign --verify --deep --strict --verbose=2 "$COPY_PATH_APPEX"
codesign --verify --deep --strict --verbose=2 "$APP"
requirement="$(codesign -d -r- "$APP" 2>&1 | tr '[:upper:]' '[:lower:]')"
expected_leaf="$(printf '%s' "$REQUIRED_CERTIFICATE_SHA1" | tr '[:upper:]' '[:lower:]')"
if [[ "$requirement" != *"certificate leaf = h\"$expected_leaf\""* ]]; then
  echo "Built app does not match the pinned local certificate." >&2
  exit 5
fi

if [[ "${INSTALL:-0}" == "1" ]]; then
  if [[ "$APP" != "$ROOT/build/Switchboard.app" ]]; then
    echo "Unexpected build path; refusing installation." >&2
    exit 3
  fi
  echo "INSTALL=1 is intentionally blocked until the Warm Corners production migration gate is approved." >&2
  exit 4
fi

echo "Built locally without installation: $APP"
