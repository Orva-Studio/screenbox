#!/bin/bash
# Builds ScreenBox.app into ./build/
set -euo pipefail

cd "$(dirname "$0")"
APP="build/ScreenBox.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O \
  -framework Cocoa -framework Carbon \
  -o "$APP/Contents/MacOS/ScreenBox" \
  Sources/Prefs.swift Sources/main.swift

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>ScreenBox</string>
	<key>CFBundleIdentifier</key>
	<string>local.screenbox</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleExecutable</key>
	<string>ScreenBox</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

echo "Built $APP"
