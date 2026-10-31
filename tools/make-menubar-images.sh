#!/usr/bin/env bash
# Regenerates docs/menubar.png and docs/menubar-long.png from StatusIcon. Run it
# when the menu bar drawing changes. The menu screenshot (docs/menu-claude.png) is a
# real screenshot of the open menu and has to be retaken by hand.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

WORK="$(mktemp -d)"
# Top-level code is only allowed in a file called main.swift.
cp "$ROOT/tools/menubar-images.swift" "$WORK/main.swift"
swiftc -target arm64-apple-macos14.0 -o "$WORK/menubar-images" \
  "$WORK/main.swift" \
  "$ROOT/Sources/AgentTray/StatusIcon.swift" \
  "$ROOT/Sources/AgentTray/Usage.swift" \
  "$ROOT/Sources/AgentTray/Palette.swift" \
  "$ROOT/Sources/AgentTray/RobotMark.swift" \
  -framework AppKit -framework SwiftUI
"$WORK/menubar-images" "$ROOT/docs"
rm -rf "$WORK"
