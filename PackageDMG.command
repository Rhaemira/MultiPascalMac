#!/bin/zsh
# Created by Amirali Yazdani on 10/16/26.
set -euo pipefail
cd "${0:A:h}"

APP_NAME="Multi-Pascal Mac.app"
VERSION="1.1"
AUTHOR_SLUG="Amirali-Yazdani"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
OUTPUT_DIR="${OUTPUT_DIR:-$PWD/dist}"
WORK="$(mktemp -d)"
STAGING="$WORK/DMGRoot"
mkdir -p "$STAGING"
trap 'rm -rf "$WORK"' EXIT

if [[ -n "$NOTARY_PROFILE" && -z "$SIGNING_IDENTITY" ]]; then
  print -u2 "ERROR: NOTARY_PROFILE requires SIGNING_IDENTITY (Developer ID Application)."
  exit 2
fi

"$PWD/BuildMacApp.command"
APP="$PWD/$APP_NAME"
mkdir -p "$OUTPUT_DIR"

if [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "Signing app with: $SIGNING_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "NOTICE: Building an unsigned development DMG. Gatekeeper may warn when users open it."
fi

# If notarization credentials were supplied, notarize and staple the app itself
# before placing it in the disk image. This lets the copied app retain its ticket.
if [[ -n "$NOTARY_PROFILE" ]]; then
  APP_ZIP="$WORK/Multi-Pascal-Mac-app-for-notarization.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# Standard Mac drag-to-Applications DMG layout.
ditto "$APP" "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/Read Me - Installation.txt" <<'INSTALL'
MULTI-PASCAL MAC
Created by Amirali Yazdani · Version 1.1

Install:
1. Drag "Multi-Pascal Mac.app" onto the Applications shortcut in this window.
2. Eject this disk image.
3. Open Multi-Pascal Mac from your Applications folder.

Use Compile to check source, Run to execute a program, and Activity to inspect
simulated processor work. The timing display models MPWin-like virtual costs;
it is not a native CPU benchmark.

For support, source code, and release information, consult the project README.
INSTALL
DMG="$OUTPUT_DIR/Multi-Pascal-Mac-$VERSION-$AUTHOR_SLUG.dmg"
rm -f "$DMG"
hdiutil create \
  -volname "Multi-Pascal Mac" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG"

if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --force --timestamp --identifier "org.multipascal.mac.disk-image" --sign "$SIGNING_IDENTITY" "$DMG"
  codesign --verify --verbose=2 "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  echo "Notarized and stapled app + disk image."
elif [[ -n "$SIGNING_IDENTITY" ]]; then
  echo "Signed app + DMG created. Notarization was not requested."
fi

echo
echo "Created: $DMG"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "For public distribution, sign with Developer ID and notarize; see docs/DISTRIBUTION.md."
fi
