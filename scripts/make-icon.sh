#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_ROOT="$ROOT/Icon"
ICONSET="$ICON_ROOT/AppIcon.iconset"
SOURCE="$ICON_ROOT/AppIcon.svg"
MASTER="$ICON_ROOT/AppIcon-1024.png"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -s format png "$SOURCE" --out "$MASTER" >/dev/null

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$ICON_ROOT/AppIcon.icns"
echo "$ICON_ROOT/AppIcon.icns"
