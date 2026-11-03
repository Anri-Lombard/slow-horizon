#!/bin/zsh
# Builds Slow Horizon.app and installs it to ~/Applications, where Spotlight finds it.
set -euo pipefail
cd "${0:a:h}"

APP="build/Slow Horizon.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc -O main.swift Renderer.swift Sky.swift Sound.swift ClaudeFM.swift -o "$APP/Contents/MacOS/SlowHorizon"
cp Shaders.metal "$APP/Contents/Resources/"
[[ -f AppIcon.icns ]] && cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Slow Horizon</string>
  <key>CFBundleDisplayName</key><string>Slow Horizon</string>
  <key>CFBundleIdentifier</key><string>com.anrilombard.slowhorizon</string>
  <key>CFBundleExecutable</key><string>SlowHorizon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/"Slow Horizon.app"
cp -R "$APP" ~/Applications/
echo "Installed to ~/Applications/Slow Horizon.app"
