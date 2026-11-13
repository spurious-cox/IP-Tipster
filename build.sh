#!/bin/zsh
# Build DNSUpdater.app (universal, ad-hoc signed) into dist/.  --install also copies it to /Applications.
set -e
cd "${0:A:h}"
VER=$(sed -n 's/^let appVersion = "\(.*\)"/\1/p' main.swift)
rm -rf dist; mkdir -p dist/DNSUpdater.app/Contents/{MacOS,Resources}
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $arch-apple-macos12 main.swift -o dist/DNSUpdater-$arch
done
lipo -create dist/DNSUpdater-arm64 dist/DNSUpdater-x86_64 -output dist/DNSUpdater.app/Contents/MacOS/DNSUpdater
rm dist/DNSUpdater-arm64 dist/DNSUpdater-x86_64
cp AppIcon.icns dist/DNSUpdater.app/Contents/Resources/AppIcon.icns
cat > dist/DNSUpdater.app/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>DNSUpdater</string>
<key>CFBundleDisplayName</key><string>DNSUpdater</string>
<key>CFBundleIdentifier</key><string>com.timmccoy.dnsupdater</string>
<key>CFBundleExecutable</key><string>DNSUpdater</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VER</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHumanReadableCopyright</key><string>Personal utility</string>
</dict></plist>
PL
codesign --force --deep -s - dist/DNSUpdater.app
echo "built DNSUpdater $VER"
if [[ "$1" == "--install" ]]; then
    pkill -x DNSUpdater 2>/dev/null || true
    rm -rf /Applications/DNSUpdater.app
    ditto dist/DNSUpdater.app /Applications/DNSUpdater.app
    echo "installed /Applications/DNSUpdater.app"
fi
