#!/usr/bin/env bash
# Builds AgentTray.app — a self-contained menu bar app, no Xcode project needed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/AgentTray.app"
TARGET="${MACOS_TARGET:-arm64-apple-macos14.0}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target "$TARGET" \
  -o "$APP/Contents/MacOS/AgentTray" \
  "$ROOT"/Sources/AgentTray/*.swift \
  -framework AppKit -framework SwiftUI -framework ServiceManagement

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AgentTray</string>
  <key>CFBundleDisplayName</key><string>AgentTray</string>
  <key>CFBundleExecutable</key><string>AgentTray</string>
  <key>CFBundleIdentifier</key><string>com.lestex.agenttray</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature keeps the Keychain prompt to a one-time "Always Allow"
# (per build — a rebuild changes the signature and asks again).
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed; Keychain may prompt on every launch"

echo "built $APP"
