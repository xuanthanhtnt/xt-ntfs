#!/usr/bin/env bash
# Extracts macFUSE's headers and libfuse from the official installer into
# <prefix> without installing anything on the build machine.
#
#   engine/fetch-macfuse-sdk.sh <prefix>
#
# Afterwards: MACFUSE_PREFIX=<prefix> engine/build-ntfs3g.sh ...
# The resulting ntfs-3g references /usr/local/lib/libfuse.2.dylib, which is
# where macFUSE installs it on users' Macs.
set -euo pipefail

PREFIX="${1:?usage: fetch-macfuse-sdk.sh <prefix>}"
mkdir -p "$PREFIX"
PREFIX="$(cd "$PREFIX" && pwd)"
WORK="$(mktemp -d)"
trap 'hdiutil detach -quiet "$WORK/mnt" 2>/dev/null || true; rm -rf "$WORK"' EXIT

api="https://api.github.com/repos/macfuse/macfuse/releases?per_page=20"
auth=()
if [ -n "${GITHUB_TOKEN:-}" ]; then auth=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
url="$(curl -fsSL "${auth[@]}" "$api" | python3 -c '
import json, sys
for rel in json.load(sys.stdin):
    if rel.get("prerelease") or rel.get("draft"):
        continue
    for a in rel.get("assets", []):
        if a["name"].endswith(".dmg"):
            print(a["browser_download_url"]); sys.exit(0)
sys.exit(1)')"
echo "macFUSE installer: $url"
curl -fsSL -o "$WORK/macfuse.dmg" "$url"
mkdir -p "$WORK/mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$WORK/mnt" "$WORK/macfuse.dmg"
pkg="$(find "$WORK/mnt" -maxdepth 2 -name '*.pkg' | head -1)"
[ -n "$pkg" ] || { echo "no .pkg in macFUSE dmg" >&2; exit 1; }
pkgutil --expand-full "$pkg" "$WORK/pkg"

hdr="$(find "$WORK/pkg" -path '*/usr/local/include/fuse' -type d | head -1)"
lib="$(find "$WORK/pkg" -path '*/usr/local/lib/libfuse.2.dylib' | head -1)"
[ -n "$hdr" ] && [ -n "$lib" ] || { echo "headers/libfuse not found in package" >&2; find "$WORK/pkg" -maxdepth 6 | head -50; exit 1; }
mkdir -p "$PREFIX/include" "$PREFIX/lib"
cp -R "$hdr" "$PREFIX/include/"
libdir="$(dirname "$lib")"
cp -P "$libdir"/libfuse.2*.dylib "$libdir"/libfuse.dylib "$PREFIX/lib/" 2>/dev/null || cp "$lib" "$PREFIX/lib/"
[ -e "$PREFIX/lib/libfuse.dylib" ] || ln -s libfuse.2.dylib "$PREFIX/lib/libfuse.dylib"
echo "macFUSE SDK ready in $PREFIX"
ls -l "$PREFIX/lib"
otool -D "$PREFIX/lib/libfuse.2.dylib" || true
