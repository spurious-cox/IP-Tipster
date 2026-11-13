#!/bin/zsh
# Sign with Developer ID, make a DMG, notarize and staple it.  Output: dist/IP-Tipster-<version>.dmg
# One-time setup for notarization (stores an app-specific password in the keychain):
#   xcrun notarytool store-credentials notary --apple-id <apple id> --team-id RUDN8D7ZN9
set -e
cd "${0:A:h}"
SIGN_ID="4208ABA3EC12F24C1F09C7BB624EFF68B44259DB"     # Developer ID Application
PROFILE="${NOTARY_PROFILE:-notary}"
./build.sh
VER=$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' main.swift)
APP="dist/IP Tipster.app"
codesign --force --deep --timestamp --options runtime --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
DMG="dist/IP-Tipster-$VER.dmg"
rm -f "$DMG"
# Build the image by hand: `hdiutil create -srcfolder` fails with "Resource busy" on this Mac.
TMPD=$(mktemp -d)
hdiutil create -volname "IP Tipster" -size 40m -fs HFS+ -type SPARSE "$TMPD/rw" >/dev/null
MNT=$(hdiutil attach "$TMPD/rw.sparseimage" -nobrowse -noverify | awk -F'\t' '/\/Volumes\//{print $NF}')
ditto "$APP" "$MNT/IP Tipster.app"
ln -s /Applications "$MNT/Applications"
sync; sleep 3; hdiutil detach "$MNT" >/dev/null 2>&1 || { sleep 5; hdiutil detach "$MNT" -force >/dev/null; }
hdiutil convert "$TMPD/rw.sparseimage" -format UDZO -o "$TMPD/img.dmg" >/dev/null
mv "$TMPD/img.dmg" "$DMG"; rm -rf "$TMPD"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
echo "signed $DMG"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "No notarization profile '$PROFILE'. Run the store-credentials command at the top of this script, then run it again."
    exit 2
fi
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "release ready: $DMG"
