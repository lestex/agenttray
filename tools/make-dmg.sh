#!/usr/bin/env bash
# Packs build/AgentTray.app into a drag-to-Applications disk image.
# Usage: tools/make-dmg.sh [output.dmg]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/AgentTray.app"
DMG="${1:-$ROOT/build/AgentTray.dmg}"

[ -d "$APP" ] || { echo "no bundle at $APP — run ./build.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)/AgentTray"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # the drag target

rm -f "$DMG"
hdiutil create -volname AgentTray -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$(dirname "$STAGE")"

echo "built $DMG ($(du -h "$DMG" | cut -f1))"
