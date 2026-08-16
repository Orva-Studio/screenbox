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
mkdir -p "$STAGE/.background"
cp design/dmg-background.tiff "$STAGE/.background/background.tiff"

# Two passes: a writable image the Finder can lay out, then a compressed
# read-only one to ship. Going straight to UDZO would leave the window
# unstyled, since there'd be nothing to write the .DS_Store into.
VOLUME="ScreenBox $VERSION"
RW="build/ScreenBox-rw.dmg"
rm -f "$RW"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -format UDRW -ov -quiet "$RW"
MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -nobrowse | grep -o '/Volumes/.*' | head -1)

# Best effort: CI has no Finder to script, and the automation prompt can be
# declined. A plain-looking DMG beats a failed release.
osascript <<APPLESCRIPT || echo "note: skipped Finder window styling" >&2
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 150, 840, 550}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set background picture of opts to file ".background:background.tiff"
    set position of item "ScreenBox.app" of container window to {160, 190}
    set position of item "Applications" of container window to {480, 190}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$RW" -format UDZO -ov -quiet -o "$DMG"
rm -f "$RW"

rm -rf "$STAGE"

echo "Built $DMG"
