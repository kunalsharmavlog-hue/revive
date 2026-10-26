#!/bin/zsh
# Builds Revive.app (universal: Apple silicon + Intel) with the Xcode Command Line Tools.
# Optional: SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh
set -e
cd "${0:A:h}"
VERSION="1.0"
APP="build/Revive.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macos14 -o build/Revive-arm64 Sources/*.swift
swiftc -O -target x86_64-apple-macos14 -o build/Revive-x86_64 Sources/*.swift
lipo -create build/Revive-arm64 build/Revive-x86_64 -output "$APP/Contents/MacOS/Revive"
rm build/Revive-arm64 build/Revive-x86_64

[ -f Icon/Revive.icns ] || { swift Icon/make-icon.swift Icon/icon_1024.png; }
cp Icon/Revive.icns "$APP/Contents/Resources/Revive.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Revive</string>
  <key>CFBundleDisplayName</key><string>Revive</string>
  <key>CFBundleIdentifier</key><string>app.revive.recovery</string>
  <key>CFBundleExecutable</key><string>Revive</string>
  <key>CFBundleIconFile</key><string>Revive</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Kunal (lutly.video@gmail.com). MIT License.</string>
  <key>NSAppleEventsUsageDescription</key><string>Revive asks for your administrator password to read damaged drives.</string>
</dict></plist>
EOF

if [ -n "$SIGN_ID" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi
(cd build && rm -f "Revive-$VERSION.zip" && ditto -c -k --keepParent Revive.app "Revive-$VERSION.zip")
echo "Built: $PWD/$APP and build/Revive-$VERSION.zip"
