#!/bin/bash
#
# Builds, signs, notarizes and staples a distributable MagicPlus.app, then packages it as a
# zip (for Sparkle) and a styled DMG (for the download button).
#
# Requirements, none of which can be scripted around:
#   - A "Developer ID Application" certificate in the login keychain
#   - A notarytool keychain profile:
#       xcrun notarytool store-credentials tabmenu-notary \
#         --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
#     Override the profile name with NOTARY_PROFILE=...
#   - Your Team ID in Config/Local.xcconfig (copy Config/Local.example.xcconfig)
#
# Usage: Scripts/release.sh [version]

set -euo pipefail

PROJECT="tabmenu.xcodeproj"
SCHEME="tabmenu"
NOTARY_PROFILE="${NOTARY_PROFILE:-tabmenu-notary}"
BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/tabmenu.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
VERSION="${1:-}"

cd "$(dirname "$0")/.."

if [[ -n "$VERSION" ]]; then
  echo "==> Setting marketing version to $VERSION"
  xcrun agvtool new-marketing-version "$VERSION" >/dev/null
fi

echo "==> Running tests"
xcodebuild test -project "$PROJECT" -scheme "$SCHEME" -destination 'platform=macOS' -quiet

echo "==> Archiving"
rm -rf "$BUILD_DIR"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'platform=macOS' \
  -quiet

echo "==> Exporting a Developer ID build"
cat > "$BUILD_DIR/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -quiet

APP="$EXPORT_DIR/MagicPlus.app"
ZIP="$BUILD_DIR/MagicPlus.zip"
DMG="$BUILD_DIR/MagicPlus.dmg"

echo "==> Verifying signature and entitlements"
codesign --verify --deep --strict --verbose=1 "$APP"
codesign -d --entitlements - "$APP" | grep -E "camera|calendars|apple-events" || {
  echo "!! Expected entitlements are missing — camera, calendar and AppleScript features will fail silently."
  exit 1
}

echo "==> Verifying Sparkle is configured"
# Without SUPublicEDKey, Sparkle falls back to Apple code-signing checks only, which accept
# any same-team build served by whoever controls the feed host. Never ship that.
EDKEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true)
if [[ -z "$EDKEY" ]]; then
  echo "!! SUPublicEDKey is missing from Info.plist — run Sparkle's generate_keys and add the public key before releasing."
  exit 1
fi

echo "==> Notarizing (this waits for Apple)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Building the styled DMG"
"$(dirname "$0")/package-dmg.sh" "$APP" "$DMG"

echo "==> Signing and notarizing the DMG"
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [[ -z "$IDENTITY" ]]; then
  echo "!! No Developer ID Application identity in the keychain; the DMG is unsigned."
else
  codesign --sign "$IDENTITY" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

echo
echo "Done:"
echo "  $DMG   ← upload this next to your site's download button"
echo "  $ZIP   ← feed this to Sparkle's generate_appcast, upload with appcast.xml"
echo
echo "Sparkle release steps (after generate_keys is done once):"
echo "  generate_appcast --download-url-prefix https://YOUR-DOMAIN/magicplus/ $BUILD_DIR"
echo "  then upload appcast.xml + the zip, and verify SUFeedURL matches."
echo
echo "Gatekeeper check: spctl -a -vvv -t install \"$APP\""
