#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from RobotMark. Only needed when the mark changes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SET="$ROOT/Resources/AppIcon.iconset"

rm -rf "$SET" && mkdir -p "$SET"
BIN="$(mktemp -d)/makeicon"
swiftc -target arm64-apple-macos14.0 -o "$BIN" \
  "$ROOT/tools/main.swift" "$ROOT/Sources/AgentTray/RobotMark.swift" \
  -framework AppKit -framework SwiftUI
"$BIN" "$SET"
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
rm -rf "$SET"
echo "built $ROOT/Resources/AppIcon.icns"
