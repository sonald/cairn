#!/usr/bin/env bash
# Re-vendor the decode-only part of Zstandard into Sources/CZstd (network required).
#
# Usage: bash scripts/vendor-zstd.sh
#
# Remote project capture compresses with `zstd -3 --long=27` on the remote host;
# Cairn only needs to decompress, so only lib/common (minus the multithreading
# pool) and lib/decompress are kept. The amd64 Huffman assembly is left out and
# the target builds with ZSTD_DISABLE_ASM. Running this rewrites Sources/CZstd/lib,
# LICENSE and VENDORED.md; include/CZstd.h is kept.

set -euo pipefail

ZSTD_VERSION="1.5.7"
ZSTD_URL="https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz"
ZSTD_SHA256="eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$REPO_ROOT/Sources/CZstd"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codeinsight-vendor-zstd.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

curl -fL --retry 3 -o "$WORK_DIR/zstd.tar.gz" "$ZSTD_URL"
echo "$ZSTD_SHA256  $WORK_DIR/zstd.tar.gz" | shasum -a 256 -c -
tar -xzf "$WORK_DIR/zstd.tar.gz" -C "$WORK_DIR"
SOURCE="$WORK_DIR/zstd-$ZSTD_VERSION/lib"

rm -rf "$TARGET/lib"
mkdir -p "$TARGET/lib/common" "$TARGET/lib/decompress" "$TARGET/include"
cp "$SOURCE/zstd.h" "$SOURCE/zstd_errors.h" "$TARGET/lib/"
cp "$SOURCE/common/"*.h "$TARGET/lib/common/"
for file in debug.c entropy_common.c error_private.c fse_decompress.c xxhash.c zstd_common.c; do
    cp "$SOURCE/common/$file" "$TARGET/lib/common/"
done
cp "$SOURCE/decompress/"*.c "$SOURCE/decompress/"*.h "$TARGET/lib/decompress/"
cp "$WORK_DIR/zstd-$ZSTD_VERSION/LICENSE" "$TARGET/LICENSE"

cat > "$TARGET/VENDORED.md" <<EOF
# Vendored Zstandard (decode only)

- Upstream: https://github.com/facebook/zstd
- Release: \`v$ZSTD_VERSION\`, archive \`$ZSTD_URL\`
- Archive SHA-256: \`$ZSTD_SHA256\` (checked by \`scripts/vendor-zstd.sh\`)
- Vendored date: $(date +%F), by \`scripts/vendor-zstd.sh\`
- License: Zstandard is dual-licensed BSD or GPLv2; Cairn uses it under the
  BSD license in \`LICENSE\`.

Kept: \`lib/zstd.h\`, \`lib/zstd_errors.h\`, the headers of \`lib/common\`, the
common sources decompression needs (no \`pool.c\`/\`threading.c\`) and all of
\`lib/decompress\` except \`huf_decompress_amd64.S\`; the target defines
\`ZSTD_DISABLE_ASM\`. Used to decompress remote project captures made with
\`zstd -3 --long=27\`, which needs \`ZSTD_d_windowLogMax\` raised to 27.
EOF
echo "Vendored zstd $ZSTD_VERSION into $TARGET"
