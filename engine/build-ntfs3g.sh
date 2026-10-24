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
make -j"$JOBS" >"$WORK/make.log" 2>&1 || { grep -iE 'error|warning: implicit' "$WORK/make.log" | tail -40; exit 1; }
grep -E 'xt_rawio|unix_io' "$WORK/make.log" | grep -iE 'warning' || true

log "Collecting binaries"
STAGE="$WORK/stage"
make install DESTDIR="$STAGE" >"$WORK/install.log" 2>&1 || { tail -40 "$WORK/install.log"; exit 1; }
mkdir -p "$OUT/bin"
for p in ntfs-3g lowntfs-3g ntfs-3g.probe mkntfs ntfsfix ntfslabel ntfsinfo ntfsls ntfscat ntfscp ntfscluster ntfsresize; do
  f="$(find "$STAGE" -type f -name "$p" -perm -u+x | head -1)"
  if [[ -n "$f" ]]; then
    cp "$f" "$OUT/bin/$p"
    strip "$OUT/bin/$p" 2>/dev/null || true
  fi
done
echo "$VERSION" > "$OUT/bin/NTFS3G_VERSION"
ls -l "$OUT/bin"
if [[ "$(uname -s)" == Darwin ]]; then
  lipo -info "$OUT/bin/ntfs-3g" || true
  otool -L "$OUT/bin/ntfs-3g" || true
fi
log "Engine ready in $OUT/bin"
