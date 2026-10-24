#!/usr/bin/env bash
# Build the XT NTFS engine: upstream ntfs-3g + the XT raw I/O layer.
#
# Usage: engine/build-ntfs3g.sh <output-dir>
#
# Environment:
#   NTFS3G_VERSION   upstream tag (default below)
#   NTFS3G_SRC       use this existing source tree instead of downloading
#   XT_ARCHS         macOS architectures (default: "arm64 x86_64")
#   XT_MACOS_MIN     macOS deployment target (default: 12.0)
#
# On macOS the result links against macFUSE's libfuse (installed by the
# macFUSE package in /usr/local/lib). On Linux (used for testing) ntfs-3g's
# bundled fuse-lite is used.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:?usage: build-ntfs3g.sh <output-dir>}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
VERSION="${NTFS3G_VERSION:-$(cat "$HERE/NTFS3G_VERSION")}"
WORK="${XT_WORK:-$OUT/.work}"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

rm -rf "$WORK"
mkdir -p "$WORK"
if [[ -n "${NTFS3G_SRC:-}" ]]; then
  log "Using source tree $NTFS3G_SRC"
  cp -R "$NTFS3G_SRC" "$WORK/src"
else
  log "Fetching ntfs-3g $VERSION"
  git clone --quiet --depth 1 --branch "$VERSION" \
    https://github.com/tuxera/ntfs-3g.git "$WORK/src"
fi
SRC="$WORK/src"
rm -rf "$SRC/.git"

log "Applying XT NTFS overlay"
cp -R "$HERE/overlay/." "$SRC/"
# Compile the raw I/O layer together with the unix device operations.
sed -i.bak 's/^libntfs_3g_la_SOURCES += unix_io.c$/libntfs_3g_la_SOURCES += unix_io.c xt_rawio.c/' \
  "$SRC/libntfs-3g/Makefile.am"
grep -q 'unix_io.c xt_rawio.c' "$SRC/libntfs-3g/Makefile.am" || {
  echo "failed to patch libntfs-3g/Makefile.am" >&2; exit 1; }
# Hold back the raw I/O layer's threads until FUSE has mounted the volume:
# macFUSE's libfuse forks to run its mount helper and a forked threaded
# process may deadlock. Threads start from the FUSE init callback.
for f in "$SRC/src/ntfs-3g.c" "$SRC/src/lowntfs-3g.c"; do
  perl -0pi -e 's/(#include "ntfs-3g_common.h"\n)/$1#include "xt_rawio.h"\n/' "$f"
  perl -0pi -e 's/(\n\terr = ntfs_open\(opts\.device\);\n)/\n\txt_raw_defer_threads(1);$1/' "$f"
  perl -0pi -e 's/(static void \*?ntfs_init\([^{]*?\)\n\{\n)/$1\txt_raw_defer_threads(0);\n/' "$f"
  for want in '#include "xt_rawio.h"' 'xt_raw_defer_threads(1);' 'xt_raw_defer_threads(0);'; do
    [[ "$(grep -cF "$want" "$f")" == 1 ]] || { echo "failed to patch $f ($want)" >&2; exit 1; }
  done
done
# Volume icon: macFUSE implements the volicon option as a libfuse module
# that only fuse_main() sets up; ntfs-3g mounts with fuse_mount() and
# fuse_new(), so Finder showed macFUSE's generic "FUSE" icon. Load the
# module in fuse_new() when the helper names an icon in XTNTFS_VOLICON.
perl -0pi -e 's/(\n\tif \(fuse_opt_add_arg\(&args, ""\) == -1\)\n\t\tgoto err;\n)/$1\tif (xt_volicon_args(&args))\n\t\tgoto err;\n/' "$SRC/src/ntfs-3g.c"
perl -0pi -e 's/(\nstatic struct fuse \*mount_fuse\(char \*parsed_options\)\n)/\n\/* XT NTFS: "-omodules=volicon,iconpath=PATH" for the volume icon. *\/\nstatic int xt_volicon_args(struct fuse_args *args)\n{\n\tconst char *icon = getenv("XTNTFS_VOLICON");\n\tchar *arg;\n\tsize_t n;\n\tint ret;\n\n\tif (!icon || !*icon || strchr(icon, \x27,\x27))\n\t\treturn 0;\n\tn = strlen(icon) + 32;\n\targ = malloc(n);\n\tif (!arg)\n\t\treturn -1;\n\tsnprintf(arg, n, "-omodules=volicon,iconpath=%s", icon);\n\tret = fuse_opt_add_arg(args, arg);\n\tfree(arg);\n\treturn ret == -1 ? -1 : 0;\n}\n$1/' "$SRC/src/ntfs-3g.c"
[[ "$(grep -c 'xt_volicon_args' "$SRC/src/ntfs-3g.c")" == 2 ]] || { echo "failed to add the volume icon to ntfs-3g.c" >&2; exit 1; }
# Install programs into bin/ and sbin/ under the prefix (not /sbin).
sed -i.bak 's#\$(DESTDIR)/sbin/#$(DESTDIR)$(sbindir)/#g' \
  "$SRC/ntfsprogs/Makefile.am" "$SRC/src/Makefile.am"
# Allow configuring without libgcrypt's m4 macros (crypto is disabled).
if ! aclocal --print-ac-dir >/dev/null 2>&1 || \
   ! ls "$(aclocal --print-ac-dir)"/libgcrypt*.m4 >/dev/null 2>&1; then
  if ! grep -rqs AM_PATH_LIBGCRYPT /opt/homebrew/share/aclocal /usr/local/share/aclocal 2>/dev/null; then
    cat > "$SRC/m4/xt-libgcrypt-stub.m4" <<'EOF'
AC_DEFUN([AM_PATH_LIBGCRYPT], [ifelse([$3], , :, [$3])])
EOF
  fi
fi

cd "$SRC"
log "autogen"
./autogen.sh >"$WORK/autogen.log" 2>&1 || { tail -40 "$WORK/autogen.log"; exit 1; }

CONF=(
  --prefix=/
  --exec-prefix=/
  --disable-shared
  --enable-static
  --disable-ldconfig
  --disable-mtab
  --disable-crypto
  --disable-dependency-tracking
  --enable-extras
)

case "$(uname -s)" in
  Darwin)
    ARCHS="${XT_ARCHS:-arm64 x86_64}"
    MIN="${XT_MACOS_MIN:-12.0}"
    ARCHFLAGS=""
    for a in $ARCHS; do ARCHFLAGS="$ARCHFLAGS -arch $a"; done
    FUSE_PREFIX="${MACFUSE_PREFIX:-/usr/local}"
    export CFLAGS="-O2 $ARCHFLAGS -mmacosx-version-min=$MIN"
    export LDFLAGS="$ARCHFLAGS -mmacosx-version-min=$MIN"
    export FUSE_MODULE_CFLAGS="-I$FUSE_PREFIX/include/fuse -D_FILE_OFFSET_BITS=64 -D_DARWIN_USE_64_BIT_INODE"
    export FUSE_MODULE_LIBS="-L$FUSE_PREFIX/lib -lfuse"
    CONF+=(--with-fuse=external)
    ;;
  *)
    export CFLAGS="${CFLAGS:--O2 -g}"
    CONF+=(--with-fuse=internal)
    ;;
esac

log "configure ${CONF[*]}"
./configure "${CONF[@]}" >"$WORK/configure.log" 2>&1 || { tail -60 "$WORK/configure.log"; exit 1; }
log "make -j$JOBS"
make -j"$JOBS" >"$WORK/make.log" 2>&1 || { grep -iE -B2 -A3 'error' "$WORK/make.log" | tail -120; exit 1; }
grep -E 'xt_rawio|unix_io' "$WORK/make.log" | grep -iE 'warning' || true

log "Collecting binaries"
# Programs are taken straight from the build tree: `make install` is not
# needed (libntfs-3g is static) and its install hooks assume a Linux
# root layout (/lib, /sbin) that does not exist on macOS.
mkdir -p "$OUT/bin"
is_binary() {
  # A real executable, not a libtool wrapper script.
  [[ -f "$1" && -x "$1" ]] && ! head -c 2 "$1" | grep -q '#!'
}
REQUIRED=(ntfs-3g lowntfs-3g ntfs-3g.probe mkntfs ntfsfix ntfslabel)
OPTIONAL=(ntfsinfo ntfsls ntfscat ntfscp ntfscluster ntfsresize)
for p in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do
  f=""
  for dir in "$SRC/src" "$SRC/ntfsprogs"; do
    if is_binary "$dir/$p"; then f="$dir/$p"; break; fi
    if is_binary "$dir/.libs/$p"; then f="$dir/.libs/$p"; break; fi
  done
  if [[ -n "$f" ]]; then
    cp "$f" "$OUT/bin/$p"
    strip "$OUT/bin/$p" 2>/dev/null || true
  elif [[ " ${REQUIRED[*]} " == *" $p "* ]]; then
    echo "required program $p was not built" >&2
    exit 1
  fi
done
echo "$VERSION" > "$OUT/bin/NTFS3G_VERSION"
ls -l "$OUT/bin"
if [[ "$(uname -s)" == Darwin ]]; then
  lipo -info "$OUT/bin/ntfs-3g" || true
  otool -L "$OUT/bin/ntfs-3g" || true
fi
log "Engine ready in $OUT/bin"
