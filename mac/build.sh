#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP="QoderCoo.app"
BIN="$APP/Contents/MacOS/QoderCoo"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns assets/coo_head.png "$APP/Contents/Resources/"
cp LICENSE-Coopanion.txt THIRD-PARTY-NOTICE.md "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/web"
cp -R web "$APP/Contents/Resources/web"

swiftc -O main.swift -o "$BIN"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

if [ "${1:-}" = "--install" ]; then
  pkill -f "/Applications/QoderCoo.app/Contents/MacOS/QoderCoo" 2>/dev/null || true
  sleep 1
  ditto "$APP" "/Applications/QoderCoo.app"
  codesign --force --deep --sign - "/Applications/QoderCoo.app" >/dev/null 2>&1 || true
  echo "installed /Applications/QoderCoo.app"
fi

echo "built $PWD/$APP"