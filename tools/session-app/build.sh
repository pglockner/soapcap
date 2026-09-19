#!/usr/bin/env bash
# Builds build/Soapcap.app (SwiftUI window front end for the soapcap CLI).
# Signs ad hoc by default. Set SOAPCAP_SIGN_IDENTITY to a stable local code
# signing identity to keep macOS privacy grants across rebuilds.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$here"

swift build -c release
app="$here/build/Soapcap.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Soapcap" "$app/Contents/MacOS/Soapcap"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Soapcap</string>
  <key>CFBundleIdentifier</key><string>local.soapcap.session</string>
  <key>CFBundleExecutable</key><string>Soapcap</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Soapcap transcribes your microphone on-device during a session.</string>
</dict></plist>
PLIST
codesign --force --sign "${SOAPCAP_SIGN_IDENTITY:--}" --identifier local.soapcap.session "$app"
echo "Built $app"
echo "Run: open \"$app\""
