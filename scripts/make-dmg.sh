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
# hdiutil occasionally fails with "Resource busy" on CI machines; retry.
for attempt in 1 2 3 4; do
  if hdiutil create -volname "XT NTFS $VERSION" -srcfolder "$STAGE" -fs HFS+ \
       -format UDZO -imagekey zlib-level=9 -ov "$DMG"; then
    break
  fi
  [ "$attempt" = 4 ] && exit 1
  echo "hdiutil create failed (attempt $attempt); retrying" >&2
  sleep $((attempt * 5))
done
hdiutil verify "$DMG"
shasum -a 256 "$DMG"
