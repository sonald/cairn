# Vendored Zstandard (decode only)

- Upstream: https://github.com/facebook/zstd
- Release: `v1.5.7`, archive `https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz`
- Archive SHA-256: `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3` (checked by `scripts/vendor-zstd.sh`)
- Vendored date: 2026-11-24, by `scripts/vendor-zstd.sh`
- License: Zstandard is dual-licensed BSD or GPLv2; Cairn uses it under the
  BSD license in `LICENSE`.

Kept: `lib/zstd.h`, `lib/zstd_errors.h`, the headers of `lib/common`, the
common sources decompression needs (no `pool.c`/`threading.c`) and all of
`lib/decompress` except `huf_decompress_amd64.S`; the target defines
`ZSTD_DISABLE_ASM`. Used to decompress remote project captures made with
`zstd -3 --long=27`, which needs `ZSTD_d_windowLogMax` raised to 27.
