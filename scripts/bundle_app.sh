#!/bin/bash
# Builds a release binary and wraps it in a minimal Airtraffic.app bundle.
# No Xcode required — works with Command Line Tools alone.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/Airtraffic.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/Airtraffic "$APP/Contents/MacOS/Airtraffic"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Airtraffic</string>
    <key>CFBundleIdentifier</key>
    <string>com.airtraffic.app</string>
    <key>CFBundleName</key>
    <string>Airtraffic</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper allows local execution
codesign --force --sign - "$APP"

echo "Built: $APP"
echo "起動するには: open $APP"
