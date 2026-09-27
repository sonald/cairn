#!/usr/bin/env bash
# Invoke only after the parent CI/benchmark run ends; this intentionally opens native windows.
set -euo pipefail
base="$(cd "$(dirname "$0")" && pwd)"
fixture="${1:?provide the frozen text fixture path}"
out="${2:?provide an empty output directory}"
[[ ! -e "$out" ]] || { echo "refusing to overwrite existing evidence: $out" >&2; exit 2; }
mkdir -p "$out"
for mode in ordinary chunked; do
  /usr/bin/time -l "$base/chunked-content-probe" --mode "$mode" --fixture "$fixture" \
    --out "$out/$mode.json" --chunk-units 4096 2> "$out/$mode.stderr.txt"
done
python3 "$base/compare.py" "$out/ordinary.json" "$out/chunked.json" > "$out/comparison.json"
