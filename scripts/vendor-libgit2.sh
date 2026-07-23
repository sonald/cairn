#!/usr/bin/env bash

set -euo pipefail

LIBGIT2_TAG="v1.9.6"
LIBGIT2_SHA256="a88a42a4ea9bdab7aa8686eead3bf7d9c6dd74529caca16ab22eaa92433d31d9"
LIBGIT2_URL="https://github.com/libgit2/libgit2/archive/refs/tags/${LIBGIT2_TAG}.tar.gz"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/Vendor/libgit2"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cairn-libgit2.XXXXXX")"
VENDORED_DATE="$(date +%F)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for tool in cmake curl shasum tar; do
    command -v "$tool" >/dev/null || {
        echo "vendor-libgit2: missing required tool: $tool" >&2
        exit 1
    }
done

# Offline path: CAIRN_LIBGIT2_SRC may point at a pre-fetched source tarball
# (same tag), so vendoring works without network access.
if [[ -n "${CAIRN_LIBGIT2_SRC:-}" ]]; then
    cp "$CAIRN_LIBGIT2_SRC" "$WORK_DIR/libgit2.tar.gz"
else
    curl -fL --retry 3 -o "$WORK_DIR/libgit2.tar.gz" "$LIBGIT2_URL"
fi
echo "$LIBGIT2_SHA256  $WORK_DIR/libgit2.tar.gz" | shasum -a 256 -c -
tar -xzf "$WORK_DIR/libgit2.tar.gz" -C "$WORK_DIR"

SOURCE="$WORK_DIR/libgit2-${LIBGIT2_TAG#v}"
BUILD="$WORK_DIR/build"
STAGE="$WORK_DIR/stage"

cmake -S "$SOURCE" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$STAGE" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF \
    -DBUILD_CLI=OFF \
    -DBUILD_EXAMPLES=OFF \
    -DUSE_SSH=OFF \
    -DUSE_HTTPS=OFF \
    -DUSE_NTLMCLIENT=OFF \
    -DUSE_GSSAPI=OFF \
    -DUSE_BUNDLED_ZLIB=ON \
    -DREGEX_BACKEND=builtin
cmake --build "$BUILD" --parallel
cmake --install "$BUILD"

test -f "$STAGE/lib/libgit2.a"
test -f "$STAGE/include/git2.h"

rm -rf "$TARGET"
mkdir -p "$TARGET"
cp -R "$STAGE/include" "$TARGET/include"
mkdir -p "$TARGET/lib"
cp "$STAGE/lib/libgit2.a" "$TARGET/lib/libgit2.a"
cp "$SOURCE/COPYING" "$TARGET/LICENSE"

cat > "$TARGET/VENDORED.md" <<EOF
# Vendored libgit2

- Upstream: https://github.com/libgit2/libgit2
- Release tag: \`$LIBGIT2_TAG\`
- Download URL: $LIBGIT2_URL
- SHA-256: \`$LIBGIT2_SHA256\`
- Vendored date: $VENDORED_DATE
- Vendoring method: downloaded and statically built by \`scripts/vendor-libgit2.sh\`
- License: GPL-2.0 with linking exception; see \`LICENSE\`.
- Deployment target: macOS \`${MACOSX_DEPLOYMENT_TARGET:-14.0}\`

The build disables SSH, HTTP(S), NTLM, and GSSAPI transports. Cairn only reads
local Git object databases.
EOF

echo "vendored libgit2 ${LIBGIT2_TAG} -> $TARGET/lib/libgit2.a"
