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

# Fail here rather than after a notarization wait if the signing tools cannot be had.
"$(dirname "$0")/fetch-sparkle-tools.sh"

# Everything this release needs and cannot create for itself, checked before the first long step.
# Without this, a missing certificate is discovered by `-exportArchive` — after the tests and the
# archive, six minutes in — and a missing notary profile only after that.
echo "==> Preflight"
MISSING=0

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "!! No \"Developer ID Application\" certificate in the keychain."
  echo "   Xcode → Settings → Accounts → your Apple ID → Manage Certificates → + → Developer ID Application."
  echo "   (Requires Apple Developer Program membership.)"
  MISSING=1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "!! No notarytool profile named \"$NOTARY_PROFILE\"."
  echo "   xcrun notarytool store-credentials $NOTARY_PROFILE \\"
  echo "     --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD"
  MISSING=1
fi

# The one thing that cannot be replaced if it is lost: every existing install only accepts updates
# signed with this key.
if ! security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1; then
  echo "!! The Sparkle private key is not in this keychain, so the appcast cannot be signed."
  echo "   If this is a new machine, import your backup; do not generate a new key — installs"
  echo "   already out there will refuse anything signed by a different one."
  MISSING=1
fi

if [[ "$MISSING" == "1" ]]; then
  echo
  echo "Nothing was built. Fix the above and run this again."
  exit 1
fi
echo "Signing identity, notary profile and update key are all present."

if [[ -n "$VERSION" ]]; then
  echo "==> Setting marketing version to $VERSION"
  # Edited in the project file rather than through `agvtool`, which is the wrong tool here: this
  # project carries its version as a build setting and lets Xcode generate the plist key, while
  # agvtool goes looking for `Info.plist` files to patch. It announced success, wrote nothing that
  # lasted, failed with `Cannot find ".../YES"`, and — because its output went to /dev/null — the
  # release carried on and shipped 1.3.0 labelled 1.2.0.
  /usr/bin/sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g" "$PROJECT/project.pbxproj"

  if ! grep -q "MARKETING_VERSION = $VERSION;" "$PROJECT/project.pbxproj"; then
    echo "!! The version could not be set in $PROJECT/project.pbxproj."
    exit 1
  fi

  # And the build number with it, because that is the number Sparkle actually compares.
  #
  # 1.3.0 was first built with the build number 1.2.0 had shipped with. Everything looked right — a
  # notarized 1.3.0, a correctly named zip, a valid feed — and it was undeliverable: Sparkle sees the
  # same build number as the one installed and offers nothing. Worse, `generate_appcast` keys its
  # cached item metadata on the build number, so the new item came out carrying the *old* release's
  # title: a feed announcing 1.2.0 and handing over 1.3.0.
  BUILD=$(grep -m1 -oE "CURRENT_PROJECT_VERSION = [0-9]+" "$PROJECT/project.pbxproj" | grep -oE "[0-9]+")
  NEXT_BUILD=$((BUILD + 1))
  echo "==> Bumping the build number to $NEXT_BUILD"
  /usr/bin/sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = $NEXT_BUILD;/g" "$PROJECT/project.pbxproj"

  if ! grep -q "CURRENT_PROJECT_VERSION = $NEXT_BUILD;" "$PROJECT/project.pbxproj"; then
    echo "!! The build number could not be set."
    exit 1
  fi
fi

echo "==> Checking Turkish translations"
# A release that ships English text to a Turkish user is a release nobody proofread.
"$(dirname "$0")/check-localization.sh" tr

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

echo "==> Verifying the privileged helper shipped with the app"
# SMAppService looks for both halves by path. If either is missing the charge limit cannot be
# installed at all, and the app finds out only on the user's machine.
HELPER="$APP/Contents/MacOS/MagicPlusHelper"
DAEMON_PLIST="$APP/Contents/Library/LaunchDaemons/com.tabmenu.helper.plist"
for path in "$HELPER" "$DAEMON_PLIST"; do
  if [[ ! -f "$path" ]]; then
    echo "!! Missing $path — the battery charge limit will not install."
    exit 1
  fi
done
codesign --verify --strict --verbose=1 "$HELPER"

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

# The appcast is generated from every release archive kept here, not just this one: Sparkle reads
# the whole feed, and a directory holding one build produces a feed that has forgotten every
# earlier version — along with its release notes and any delta it could have built against it.
# This directory therefore outlives the build directory, which is wiped on every run.
#
# The archive is named after its version for the same reason. `MagicPlus.zip` would overwrite the
# previous release every time, leaving a feed whose older entries point at a file that is now a
# different build — and Sparkle would hand a user the wrong bytes for the version it promised.
RELEASES="build/releases"
SHIPPED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

# Checked against what was asked for, and this check is the point: a version that silently stayed
# behind produces a package named after the *previous* release, which overwrites it on the site and
# leaves everyone already on that version never offered the update. Nothing about that looks wrong
# until somebody asks why the update never arrived.
if [[ -n "$VERSION" && "$SHIPPED_VERSION" != "$VERSION" ]]; then
  echo "!! Asked for $VERSION but the built app says $SHIPPED_VERSION. Nothing has been staged."
  exit 1
fi

# The build number has to be new as well, or the feed is valid and the update is invisible.
SHIPPED_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
if [[ -f "$RELEASES/appcast.xml" ]]; then
  NEWEST_PUBLISHED=$(grep -oE "<sparkle:version>[0-9]+" "$RELEASES/appcast.xml" \
    | grep -oE "[0-9]+" | sort -n | tail -1)
  if [[ -n "$NEWEST_PUBLISHED" && "$SHIPPED_BUILD" -le "$NEWEST_PUBLISHED" ]]; then
    echo "!! Build $SHIPPED_BUILD is not newer than the $NEWEST_PUBLISHED already in the feed."
    echo "   Sparkle would offer this to nobody. Nothing has been staged."
    exit 1
  fi
fi
VERSIONED_ZIP="$RELEASES/MagicPlus-$SHIPPED_VERSION.zip"
mkdir -p "$RELEASES"
cp "$ZIP" "$VERSIONED_ZIP"

echo "==> Generating the appcast"
# The private key comes from the login keychain; the URL prefix must match where the zips are
# actually served from, or Sparkle downloads a 404 and reports it as a failed update.
DOWNLOAD_PREFIX="${DOWNLOAD_PREFIX:-https://magicplus.emreramazanoglu.com.tr/}"
Tools/sparkle/bin/generate_appcast \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "https://magicplus.emreramazanoglu.com.tr/" \
  "$RELEASES"

# generate_appcast omits the EdDSA signature — silently, with a success message — when the app
# inside the archive has no SUPublicEDKey to verify it with. The result is a feed every install
# refuses, discovered only by a user whose update fails. Never ship one unsigned.
if ! grep -q "edSignature" "$RELEASES/"*.xml; then
  echo "!! The generated appcast carries no edSignature. The archived app is missing SUPublicEDKey,"
  echo "   or the private key is not in this keychain (Sparkle's generate_keys puts it there)."
  exit 1
fi

# What the app will actually ask for, checked against what was produced — a feed at a URL the app
# does not read is the failure mode that looks like everything worked.
FEED=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist")
FEED_NAME="${FEED##*/}"
if [[ ! -f "$RELEASES/$FEED_NAME" ]]; then
  echo "!! SUFeedURL is $FEED but generate_appcast wrote $(ls "$RELEASES"/*.xml 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
  echo "   Rename the generated file to $FEED_NAME when uploading, or point SUFeedURL at it."
  exit 1
fi

# Straight into the site's own static folder rather than a pile of files to upload by hand: the
# feed and the download button are part of the site, and a release that is not on the site is not
# a release. `npm run build` in website/ copies public/ into out/ untouched.
echo "==> Staging into the site"
SITE="website/public"
cp "$RELEASES/$FEED_NAME" "$SITE/$FEED_NAME"
cp "$VERSIONED_ZIP" "$SITE/"
cp "$DMG" "$SITE/MagicPlus.dmg"

echo
echo "Done. $SHIPPED_VERSION is staged in $SITE:"
echo "  MagicPlus.dmg                       ← what the site's download button points at"
echo "  $(basename "$VERSIONED_ZIP")                ← what Sparkle downloads, per the appcast"
echo "  $FEED_NAME                        ← the feed the app reads at $FEED"
echo
echo "Publish it:"
echo "  cd website && npm run build     # copies public/ into out/"
echo "  upload out/ to the site root"
echo
echo "The zips and the DMG are deliberately not committed. A git-driven deploy (Vercel/Netlify)"
echo "will not carry them, so upload out/ yourself, or host the binaries elsewhere and set"
echo "DOWNLOAD_PREFIX to match."
echo
echo "Gatekeeper check: spctl -a -vvv -t install \"$APP\""
