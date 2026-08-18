#!/bin/bash
# Builds ScreenBox.app into ./build/
#
# The version comes from the latest git tag (`v1.2.0` -> `1.2.0`), so tagging a
# release is the only thing that changes it. Set VERSION= to override.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/ScreenBox.app"

# Marketing version: the tag without its leading v. Untagged builds are marked
# as such rather than borrowing a release number they aren't.
if [ -z "${VERSION:-}" ]; then
  if TAG=$(git describe --tags --abbrev=0 2>/dev/null); then
    VERSION="${TAG#v}"
    git describe --tags --exact-match >/dev/null 2>&1 || VERSION="$VERSION-dev"
  else
    VERSION="0.0.0-dev"
  fi
fi

# Build number: commit count, which only ever goes up. Falls back to 1 outside
# a checkout (a source tarball, say).
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The icon is checked in prebuilt: iconutil needs a whole .iconset directory,
# and regenerating it on every build would only ever produce the same file.
cp design/ScreenBox.icns "$APP/Contents/Resources/ScreenBox.icns"

# Universal binary. CI runs on Apple Silicon, so building for the host alone
# would ship releases that Intel Macs refuse to launch ("bad CPU type").
SOURCES=(Sources/Prefs.swift Sources/Tool.swift Sources/Toolbar.swift Sources/main.swift)
SLICES=()
for ARCH in arm64 x86_64; do
  SLICE="build/$ARCH-ScreenBox"
  swiftc -O \
    -target "$ARCH-apple-macos13.0" \
    -framework Cocoa -framework Carbon \
    -o "$SLICE" \
    "${SOURCES[@]}"
  SLICES+=("$SLICE")
done

lipo -create -output "$APP/Contents/MacOS/ScreenBox" "${SLICES[@]}"
rm -f "${SLICES[@]}"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>ScreenBox</string>
	<key>CFBundleIdentifier</key>
	<string>local.screenbox</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleExecutable</key>
	<string>ScreenBox</string>
	<key>CFBundleIconFile</key>
	<string>ScreenBox</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>MIT licence. Copyright © 2026 Orva Studio.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

echo "Built $APP ($VERSION, build $BUILD)"
