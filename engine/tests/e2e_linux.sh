#!/usr/bin/env bash
# End-to-end test of the XT NTFS engine on Linux (needs root and /dev/fuse).
#
#   engine/tests/e2e_linux.sh <xt-bin-dir> [stock-bin-dir]
#
# Formats an image with the XT build in simulated raw mode (O_DIRECT,
# sector-aligned I/O enforced), mounts it through FUSE, runs a mixed file
# workload, unmounts, then checks the volume with ntfsfix and re-reads every
# file with a stock (unpatched) ntfs-3g build when one is given.
set -euo pipefail

XT="${1:?xt bin dir}"
STOCK="${2:-}"
WORK="${E2E_WORK:-$(mktemp -d)}"
IMG="$WORK/vol.img"
MNT="$WORK/mnt"
DATA="$WORK/data"
SIZE_MB="${E2E_SIZE_MB:-1024}"
SECTOR="${E2E_SECTOR:-512}"
mkdir -p "$MNT" "$DATA"

export XTNTFS_SIMULATE_RAW="$SECTOR"
export XTNTFS_SIMULATE_ODIRECT=1
export XTNTFS_FLUSH_MS="${XTNTFS_FLUSH_MS:-200}"

step() { printf '\n\033[1;32m## %s\033[0m\n' "$*"; }

step "create ${SIZE_MB} MiB image, sector $SECTOR"
truncate -s "${SIZE_MB}M" "$IMG"
"$XT/mkntfs" -F -f -s "$SECTOR" -L "XT E2E" "$IMG" >/dev/null

step "generate test data"
python3 - "$DATA" <<'EOF'
import os, sys, random
root = sys.argv[1]
rnd = random.Random(1234)
os.makedirs(os.path.join(root, "small"), exist_ok=True)
for i in range(3000):                       # many small files
    d = os.path.join(root, "small", f"d{i % 37}")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, f"f{i}.bin"), "wb") as f:
        f.write(rnd.randbytes(rnd.choice([0, 1, 17, 700, 1023, 1025, 4096, 5000, 40000])))
for i, sz in enumerate([1 << 20, 7_777_777, 64 << 20, 150 << 20]):  # big files
    with open(os.path.join(root, f"big{i}.bin"), "wb") as f:
        f.write(rnd.randbytes(sz))
names = ["Tiếng Việt có dấu.txt", "日本語ファイル.txt", "emoji 😀.txt", "spaces  and.dots...txt"]
for n in names:
    with open(os.path.join(root, n), "w", encoding="utf-8") as f:
        f.write(n * 100)
EOF
(cd "$DATA" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$WORK/expected.sha"
echo "files: $(wc -l < "$WORK/expected.sha")"

step "mount with XT engine"
"$XT/ntfs-3g" "$IMG" "$MNT" -o noatime,big_writes,windows_names
t0=$(date +%s.%N)
cp -a "$DATA/." "$MNT/"
sync
t1=$(date +%s.%N)
echo "copy-in: $(python3 -c "print(round($t1-$t0,2))") s"

step "mixed operations"
mv "$MNT/small/d1" "$MNT/small/d1-renamed"
rm -rf "$MNT/small/d2"
dd if=/dev/urandom of="$MNT/overwrite.bin" bs=1M count=20 status=none
dd if=/dev/urandom of="$MNT/overwrite.bin" bs=4096 count=3 seek=7 conv=notrunc status=none
truncate -s 5M "$MNT/overwrite.bin"
truncate -s 9M "$MNT/overwrite.bin"
python3 - "$MNT" <<'EOF'
import os, sys, random
p = os.path.join(sys.argv[1], "random-io.bin")
rnd = random.Random(99)
with open(p, "wb") as f:
    f.write(b"\0" * (8 << 20))
with open(p, "r+b") as f:
    for _ in range(2000):
        off = rnd.randrange(0, 8 << 20)
        f.seek(off)
        f.write(rnd.randbytes(rnd.choice([1, 100, 511, 513, 4096, 70000])))
EOF
(cd "$MNT" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$WORK/mounted.sha"
umount "$MNT" 2>/dev/null || fusermount -u "$MNT"
sleep 1

step "verify volume consistency (ntfsfix --no-action)"
"$XT/ntfsfix" -n "$IMG"

step "re-mount and compare checksums (XT engine)"
"$XT/ntfs-3g" "$IMG" "$MNT" -o ro
(cd "$MNT" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$WORK/remount.sha"
umount "$MNT" 2>/dev/null || fusermount -u "$MNT"
diff "$WORK/mounted.sha" "$WORK/remount.sha"
echo "XT re-read: identical ($(wc -l < "$WORK/remount.sha") files)"

# Files untouched by the mixed operations must equal the source data.
grep -v -E ' \./(small/d1/|small/d2/|small/d1-renamed/|overwrite.bin|random-io.bin)' "$WORK/expected.sha" > "$WORK/expected-kept.sha"
grep -F -f <(cut -c67- "$WORK/expected-kept.sha") "$WORK/remount.sha" | sort > "$WORK/kept-now.sha" || true
sort "$WORK/expected-kept.sha" > "$WORK/expected-kept.sorted"
diff "$WORK/expected-kept.sorted" "$WORK/kept-now.sha"
echo "source data preserved"

if [[ -n "$STOCK" ]]; then
  step "cross-check with stock ntfs-3g (no XT layer)"
  unset XTNTFS_SIMULATE_RAW XTNTFS_SIMULATE_ODIRECT
  "$STOCK/ntfsfix" -n "$IMG"
  "$STOCK/ntfs-3g" "$IMG" "$MNT" -o ro
  (cd "$MNT" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$WORK/stock.sha"
  umount "$MNT" 2>/dev/null || fusermount -u "$MNT"
  diff "$WORK/mounted.sha" "$WORK/stock.sha"
  echo "stock re-read: identical"
fi

step "PASS"
