#!/bin/zsh
# Build "IP Tipster.app" (universal, ad-hoc signed) into dist/.  --install also copies it to /Applications.
set -e
cd "${0:A:h}"
VER=$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' main.swift)
rm -rf dist; mkdir -p "dist/IP Tipster.app"/Contents/{MacOS,Resources}
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $arch-apple-macos12 main.swift -o dist/IPTipster-$arch
done
lipo -create dist/IPTipster-arm64 dist/IPTipster-x86_64 -output "dist/IP Tipster.app"/Contents/MacOS/IPTipster
rm dist/IPTipster-arm64 dist/IPTipster-x86_64
cp AppIcon.icns "dist/IP Tipster.app"/Contents/Resources/AppIcon.icns
cat > "dist/IP Tipster.app"/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>IP Tipster</string>
<key>CFBundleDisplayName</key><string>IP Tipster</string>
<key>CFBundleIdentifier</key><string>com.timmccoy.iptipster</string>
<key>CFBundleExecutable</key><string>IPTipster</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VER</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHumanReadableCopyright</key><string>Personal utility</string>
</dict></plist>
PL
codesign --force --deep -s - "dist/IP Tipster.app"
echo "built IP Tipster $VER"
if [[ "$1" == "--install" ]]; then
    pkill -x IPTipster 2>/dev/null || true
    rm -rf "/Applications/IP Tipster.app"
    ditto "dist/IP Tipster.app" "/Applications/IP Tipster.app"
    echo "installed /Applications/IP Tipster.app"
fi
