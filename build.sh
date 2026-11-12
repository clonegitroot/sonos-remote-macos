#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")"

export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p build
app="$PWD/build/Sonos Remote.app"
ext="$app/Contents/PlugIns/Sonos Widget.appex"
mkdir -p "$app/Contents/"{MacOS,Resources} "$ext/Contents/MacOS"
cp Info.plist "$app/Contents/Info.plist"
cp Widget-Info.plist "$ext/Contents/Info.plist"
cp Remote.icns "$app/Contents/Resources/Remote.icns"

swiftc -parse-as-library -O -module-cache-path "$PWD/build/cache" Sonos.swift Favorites.swift Setup.swift \
  -o "$app/Contents/MacOS/SonosRemote"
# Start through Foundation's extension bootstrap while keeping Swift's WidgetBundle main.
swiftc -parse-as-library -application-extension -O -module-cache-path "$PWD/build/cache" Widget.swift Favorites.swift \
  -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -u -Xlinker _main \
  -o "$ext/Contents/MacOS/SonosWidget"

identity="${SIGN_IDENTITY:--}"
codesign --force --sign "$identity" --timestamp=none --entitlements widget.entitlements "$ext"
codesign --force --sign "$identity" --timestamp=none --entitlements host.entitlements "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --norsrc --keepParent "$app" "$PWD/build/Sonos Remote.zip"
