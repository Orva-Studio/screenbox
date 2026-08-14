#!/bin/bash
# Packages build/ScreenBox.app into a drag-to-install disk image.
#
#   ./scripts/make-dmg.sh            # version read from the built app
#   ./scripts/make-dmg.sh 1.0.1      # explicit
#
# Run ./build.sh first — this only packages what's already there, so the DMG
# can't disagree with the app it contains.
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/ScreenBox.app"
if [ ! -d "$APP" ]; then
  echo "$APP not found — run ./build.sh first" >&2
  exit 1
fi

VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")}"
DMG="build/ScreenBox-$VERSION.dmg"

# A staging folder is what ends up as the mounted volume: the app, plus a
# symlink to /Applications so the window is a drag-and-drop install.
STAGE="build/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/ScreenBox.app" # ditto, not cp: keeps the code signature intact
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "ScreenBox $VERSION" \
  -srcfolder "$STAGE" \
  -format UDZO \
  -ov -quiet \
  "$DMG"

rm -rf "$STAGE"

echo "Built $DMG"
