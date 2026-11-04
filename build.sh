#!/bin/bash
# Bygger "WilderLoader.app" utan Xcode. Koden ligger kvar under namnet Kortkoll, som appen hette förut.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="build/WilderLoader.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/Kortkoll "$APP/Contents/MacOS/WilderLoader"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WilderLoader</string>
  <key>CFBundleDisplayName</key><string>WilderLoader</string>
  <key>CFBundleExecutable</key><string>WilderLoader</string>
  <key>CFBundleIdentifier</key><string>com.wildermark.wilderloader</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict></plist>
EOF
codesign --force -s - "$APP"
echo "Klar: $APP"
