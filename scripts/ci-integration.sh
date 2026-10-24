#!/bin/bash
# macOS integration test for CI runners (no FUSE mount is possible there):
#   - installs the helper and engine from the built app and talks to the
#     helper over its socket,
#   - formats, verifies, renames and erases an NTFS volume on a RAM disk
#     through the helper,
#   - measures the engine's write speed through /dev/disk (stock ntfs-3g
#     path) and /dev/rdisk (XT raw I/O layer) and checks the data,
#   - takes screenshots of the app showing the NTFS volume.
#
#   scripts/ci-integration.sh "<path to XT NTFS.app>" <output-dir>
# Writes <output-dir>/report.md; exits non-zero if a check failed.
set -uo pipefail

APP="$(cd "$1" && pwd)"
OUT="$2"
mkdir -p "$OUT"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="/Library/Application Support/XTNTFS/engine"
REPORT="$OUT/report.md"
XTCTL=(python3 "$ROOT/scripts/xtctl.py")
failures=0

: > "$REPORT"
note() { echo "$*" | tee -a "$REPORT"; }
check() {
  local name="$1"; shift
  if "$@" >>"$OUT/commands.log" 2>&1; then
    note "- PASS $name"
  else
    note "- FAIL $name"
    failures=$((failures + 1))
  fi
}
ctl() { "${XTCTL[@]}" "$1" > "$OUT/last-reply.json" 2>&1; local rc=$?; cat "$OUT/last-reply.json" >> "$OUT/commands.log"; return $rc; }
reply_has() { grep -q "$1" "$OUT/last-reply.json"; }
now() { python3 -c 'import time; print(time.time())'; }

note "# XT NTFS integration test"
note ""
note "macOS $(sw_vers -productVersion) ($(uname -m)), $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
note ""
note "## Helper"

check "install-engine.sh" sudo bash "$APP/Contents/Resources/scripts/install-engine.sh" "$APP"
for _ in $(seq 1 40); do [ -S /var/run/com.xuanthanhtnt.xtntfs.sock ] && break; sleep 0.5; done
check "helper socket exists" test -S /var/run/com.xuanthanhtnt.xtntfs.sock
check "status request" ctl status
check "status reports engine version" reply_has '"engineVersion": "ntfs-3g'
check "engine binaries installed" test -x "$ENGINE/ntfs-3g" -a -x "$ENGINE/lowntfs-3g" -a -x "$ENGINE/mkntfs"
invalid_rejected() { ! "${XTCTL[@]}" '{"command":"mount","bsdName":"disk1; rm -rf /"}'; }
check "invalid disk name is rejected" invalid_rejected
check "ntfs-3g runs" bash -c "'$ENGINE/ntfs-3g' --version 2>&1 | grep -qi ntfs-3g"

note ""
note "## RAM disk"
DEV="$(hdiutil attach -nomount ram://1572864 | awk '{print $1}')"   # 768 MiB
BSD="${DEV#/dev/}"
note "RAM disk: $DEV"
check "partition (MBR)" diskutil partitionDisk "$DEV" MBR "MS-DOS FAT32" XTTEST 100%
PART="${BSD}s1"
diskutil unmount "/dev/$PART" >/dev/null 2>&1 || true
check "mkntfs" sudo "$ENGINE/mkntfs" --fast --force --label XTTEST "/dev/$PART"
diskutil unmount "/dev/$PART" >/dev/null 2>&1 || true
check "ntfs-3g.probe (read-write)" sudo "$ENGINE/ntfs-3g.probe" --readwrite "/dev/$PART"
check "ntfsfix --no-action" sudo "$ENGINE/ntfsfix" --no-action "/dev/$PART"

note ""
note "## Engine throughput (ntfscp, 512 MiB file, no FUSE)"
SRC="${RUNNER_TEMP:-/tmp}/xt-src.bin"
dd if=/dev/urandom of="$SRC" bs=1048576 count=512 2>/dev/null
SUM="$(shasum -a 256 "$SRC" | awk '{print $1}')"
for mode in block raw; do
  diskutil unmount "/dev/$PART" >/dev/null 2>&1 || true
  if [ "$mode" = block ]; then d="/dev/$PART"; else d="/dev/r$PART"; fi
  t0="$(now)"
  if sudo env XTNTFS_CACHE_MB=64 "$ENGINE/ntfscp" -f "$d" "$SRC" "/copy-$mode.bin" >>"$OUT/commands.log" 2>&1; then
    t1="$(now)"
    rate="$(python3 -c "print(f'{512/($t1-$t0):.0f}')")"
    note "- $mode device ($d): $(python3 -c "print(f'{$t1-$t0:.2f}')") s, ${rate} MB/s"
  else
    note "- FAIL ntfscp via $mode device"
    failures=$((failures + 1))
  fi
  diskutil unmount "/dev/$PART" >/dev/null 2>&1 || true
  got="$(sudo "$ENGINE/ntfscat" "/dev/r$PART" "/copy-$mode.bin" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
  check "data written via $mode device reads back intact" test "$got" = "$SUM"
done
diskutil unmount "/dev/$PART" >/dev/null 2>&1 || true
check "volume consistent after writes (ntfsfix)" sudo "$ENGINE/ntfsfix" --no-action "/dev/r$PART"

note ""
note "## Helper operations"
check "verify through helper" ctl "{\"command\":\"verify\",\"bsdName\":\"$PART\"}"
check "rename through helper" ctl "{\"command\":\"rename\",\"bsdName\":\"$PART\",\"label\":\"XT Data\"}"
diskutil unmount "/dev/$PART" >/dev/null 2>&1 || true
check "new label written" bash -c "sudo '$ENGINE/ntfslabel' --no-action /dev/$PART | grep -q 'XT Data'"
check "erase to ExFAT through helper" ctl "{\"command\":\"erase\",\"bsdName\":\"$PART\",\"format\":\"exfat\",\"label\":\"XTEXFAT\"}"
check "erase back to NTFS through helper" ctl "{\"command\":\"erase\",\"bsdName\":\"$PART\",\"format\":\"ntfs\",\"label\":\"XT NTFS\"}"
diskutil unmount "/dev/$PART" >/dev/null 2>&1 || true
check "fresh NTFS volume is valid" sudo "$ENGINE/ntfs-3g.probe" --readwrite "/dev/$PART"
ctl status >/dev/null 2>&1
note ""
note "Recent helper events:"
python3 - "$OUT/last-reply.json" <<'EOF' | tee -a "$REPORT"
import json, sys
try:
    st = json.load(open(sys.argv[1])).get("status") or {}
except Exception:
    st = {}
for e in (st.get("events") or [])[-12:]:
    print(f"- {e.get('kind')}: {e.get('volumeName') or e.get('bsdName')}: {e.get('message')}")
EOF

note ""
note "## App"
open "$APP"
sleep 12
osascript -e 'tell application "System Events" to set frontmost of process "XTNTFS" to true' >/dev/null 2>&1 || true
sleep 2
screencapture -x "$OUT/ntfs-volume.png" || true
pkill -f "XT NTFS.app/Contents/MacOS/XTNTFS" || true

check "uninstall-engine.sh" sudo bash "$APP/Contents/Resources/scripts/uninstall-engine.sh"
check "helper removed" test ! -e /Library/LaunchDaemons/com.xuanthanhtnt.xtntfs.helper.plist
hdiutil detach "$DEV" -force >/dev/null 2>&1 || true
sudo cp /Library/Logs/XTNTFS.log "$OUT/helper.log" 2>/dev/null || true
sudo chmod 644 "$OUT/helper.log" 2>/dev/null || true

note ""
note "Failures: $failures"
exit $((failures > 0))
