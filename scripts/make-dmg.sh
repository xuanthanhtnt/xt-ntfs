#!/usr/bin/env bash
# Packs "XT NTFS.app" into a compressed DMG with an /Applications link.
#   scripts/make-dmg.sh <path to XT NTFS.app> <output.dmg>
set -euo pipefail

APP="${1:?app}"
DMG="${2:?output dmg}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/XT NTFS.app"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/docs/READ-ME-FIRST.txt" "$STAGE/READ ME FIRST - Đọc trước.txt"

rm -f "$DMG"
hdiutil create -volname "XT NTFS $VERSION" -srcfolder "$STAGE" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$DMG"
hdiutil verify "$DMG"
shasum -a 256 "$DMG"
