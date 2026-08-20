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

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN_DIR/Switchboard" "$APP/Contents/MacOS/Switchboard"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/Switchboard/Resources/ModuleManifest.json" "$APP/Contents/Resources/ModuleManifest.json"
cp "$ROOT/Sources/Switchboard/Resources/WarmCornersMigrationContract.json" "$APP/Contents/Resources/WarmCornersMigrationContract.json"
cp "$ROOT/Sources/Switchboard/Resources/InventoryBaseline.json" "$APP/Contents/Resources/InventoryBaseline.json"
cp "$ROOT/Sources/Switchboard/Resources/RuntimeManifest.json" "$APP/Contents/Resources/RuntimeManifest.json"
cp "$ROOT/Resources/com.ivogundlach.switchboard.agent.plist" "$APP/Contents/Library/LaunchAgents/com.ivogundlach.switchboard.agent.plist"
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
plutil -lint "$APP/Contents/Library/LaunchAgents/com.ivogundlach.switchboard.agent.plist" >/dev/null
codesign --force --sign "$REQUIRED_CERTIFICATE_SHA1" --identifier com.ivo.mail-assistant --options runtime --timestamp=none "$MAIL_HELPER"
codesign --force --sign "$REQUIRED_CERTIFICATE_SHA1" --identifier com.ivogundlach.quit-on-close --options runtime --timestamp=none "$APP/Contents/Resources/Helpers/quit-on-close"
codesign --force --sign "$REQUIRED_CERTIFICATE_SHA1" --identifier com.ivogundlach.switchboard.updater --options runtime --timestamp=none "$APP/Contents/Resources/Helpers/switchboard-updater"
codesign --force --sign "$REQUIRED_CERTIFICATE_SHA1" --options runtime --timestamp=none "$APP"
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
