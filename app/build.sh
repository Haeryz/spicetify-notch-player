#!/bin/bash
# Builds "Notch Player.app" (universal) into ./build
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Notch Player.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target $arch-apple-macos13.0 -o build/NotchPlayer-$arch NotchPlayer.swift
done
lipo -create build/NotchPlayer-arm64 build/NotchPlayer-x86_64 -output "$APP/Contents/MacOS/NotchPlayer"
rm build/NotchPlayer-*
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Notch Player</string>
  <key>CFBundleDisplayName</key><string>Notch Player</string>
  <key>CFBundleIdentifier</key><string>io.github.haeryz.notchplayer</string>
  <key>CFBundleExecutable</key><string>NotchPlayer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>Notch Player listens to Spotify's audio output to drive the visualizer. Nothing is recorded or stored.</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
echo "Built $APP"
