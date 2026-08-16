#!/bin/bash
#
# Packages an .app into a styled drag-to-install DMG: branded background, positioned icons,
# fixed window. The layout constants here must match Scripts/dmg-assets/background.png,
# which is generated with the app icon's design language.
#
# Usage: package-dmg.sh <path/to/MagicPlus.app> <output.dmg>

set -euo pipefail

APP="$1"
OUT="$2"
VOLNAME="MagicPlus"
ASSETS="$(cd "$(dirname "$0")" && pwd)/dmg-assets"

STAGE=$(mktemp -d)
TMPDMG="$(mktemp -u).dmg"
MOUNTPOINT="/Volumes/$VOLNAME"
cleanup() {
  hdiutil detach "/Volumes/$VOLNAME" -quiet 2>/dev/null || true
  rm -rf "$STAGE" "$TMPDMG"
}
trap cleanup EXIT

# A volume left over from an interrupted run would hijack Finder's "tell disk" below.
for stale in /Volumes/MagicPlus*; do
  [ -d "$stale" ] && hdiutil detach "$stale" -quiet 2>/dev/null || true
done

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp "$ASSETS/background.png" "$STAGE/.background/background.png"

# Read-write image first: Finder writes the layout into its .DS_Store.
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDRW -quiet "$TMPDMG"
# Default /Volumes mount: Finder only sees disks mounted there.
hdiutil attach -readwrite -noverify -noautoopen "$TMPDMG" -quiet
MOUNT="/Volumes/$VOLNAME"
[ -d "$MOUNT" ] || { echo "!! expected mount at $MOUNT" >&2; exit 1; }

osascript <<OSA
set backgroundFile to POSIX file "$MOUNT/.background/background.png" as alias
tell application "Finder"
	tell disk "$VOLNAME"
		open
		delay 1
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 120, 860, 548}
		set viewOptions to the icon view options of container window
		set arrangement of viewOptions to not arranged
		set icon size of viewOptions to 112
		set text size of viewOptions to 12
		set background picture of viewOptions to backgroundFile
		set position of item "MagicPlus.app" of container window to {170, 210}
		set position of item "Applications" of container window to {490, 210}
		close
		open
		update without registering applications
		delay 1
		close
	end tell
end tell
OSA

sync
# The layout only exists if Finder managed to write it; fail loudly rather than ship a
# default-looking DMG.
if [ ! -f "$MOUNT/.DS_Store" ]; then
  echo "!! Finder did not persist the window layout (.DS_Store missing)" >&2
  exit 1
fi
hdiutil detach "$MOUNT" -quiet

# Compressed, read-only image for distribution.
rm -f "$OUT"
hdiutil convert "$TMPDMG" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet

echo "styled DMG: $OUT"
