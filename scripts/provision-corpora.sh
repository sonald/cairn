#!/usr/bin/env bash
# Provision and verify test corpora for gold gates and relation-timing measurements.
#
# Usage:
#   bash scripts/provision-corpora.sh              # provision to default root
#   bash scripts/provision-corpora.sh --check      # verify only, no downloads
#   bash scripts/provision-corpora.sh --root DIR   # override root
#   bash scripts/provision-corpora.sh --gen-fold-fixture FILE --manifest JSON
#
# Default root: $CAIRN_CORPUS_ROOT or ~/.cache/cairn-corpora
#
# Each corpus requires:
#   1. A .git directory with at least one commit (rust-analyzer readiness)
#   2. `cargo metadata --offline` exit 0 (dependency resolution without network)
#
# Corpora:
#   tokio-tokio-1.47.1/  – full workspace clone of tokio-rs/tokio at tag tokio-1.47.1
#   ripgrep-14.1.1/      – full clone of BurntSushi/ripgrep at tag 14.1.1

set -euo pipefail

readonly TOKIO_TAG="tokio-1.47.1"
readonly TOKIO_DIR="tokio-tokio-1.47.1"
readonly TOKIO_REPO="https://github.com/tokio-rs/tokio.git"

readonly RIPGREP_TAG="14.1.1"
readonly RIPGREP_DIR="ripgrep-14.1.1"
readonly RIPGREP_REPO="https://github.com/BurntSushi/ripgrep.git"

check_only=false
root="${CAIRN_CORPUS_ROOT:-$HOME/.cache/cairn-corpora}"
fold_fixture=""
fold_manifest=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)   check_only=true; shift ;;
        --root)    root="$2"; shift 2 ;;
        --gen-fold-fixture) fold_fixture="$2"; shift 2 ;;
        --manifest) fold_manifest="$2"; shift 2 ;;
        --help|-h)
            head -14 "$0" | tail -12 | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "unknown option: $1" >&2
            exit 2 ;;
    esac
done

errors=0

# ---------- deterministic M11 fold fixture ----------

validate_fold_fixture() {
    local fixture="$1" manifest="$2"
    local actual_sha actual_bytes actual_newlines
    actual_sha="$(shasum -a 256 "$fixture" | awk '{print $1}')"
    actual_bytes="$(wc -c < "$fixture" | tr -d ' ')"
    actual_newlines="$(wc -l < "$fixture" | tr -d ' ')"

    jq -e \
        --arg sha "$actual_sha" \
        --argjson bytes "$actual_bytes" \
        --argjson newlines "$actual_newlines" \
        '
        .schemaVersion == 1 and
        .seed == "m11-fold-perf-v1" and
        .fixtureSHA256 == $sha and
        .byteCount == $bytes and
        .newlineCount == $newlines and
        .newlineCount == 50000 and
        .lineCount == 50001 and
        .candidateCount == 8400 and
        .acceptedFoldCount == 8400 and
        .kindCounts == {
            "cfgTest": 0,
            "container": 200,
            "declaration": 4000,
            "block": 4000,
            "comment": 0,
            "imports": 200,
            "attributes": 0
        } and
        .depthCounts == {"0": 200, "1": 4200, "2": 4000} and
        .presets.structure == {"logical": 4200, "rendered": 4200} and
        .presets.overview == {"logical": 4400, "rendered": 200} and
        .perfPreset == "Overview"
        ' "$manifest" >/dev/null
    [[ "$actual_bytes" -ge 2097152 ]] || {
        echo "FAIL  fold fixture: $actual_bytes bytes, expected at least 2097152" >&2
        return 1
    }
    echo "  ok  fold fixture: sha=$actual_sha bytes=$actual_bytes newlines=$actual_newlines"
}

generate_fold_fixture() {
    local fixture="$1" manifest="$2"
    local fixture_dir manifest_dir fixture_tmp manifest_tmp
    fixture_dir="$(dirname "$fixture")"
    manifest_dir="$(dirname "$manifest")"
    mkdir -p "$fixture_dir" "$manifest_dir"
    fixture_tmp="$(mktemp "$fixture_dir/.fold_perf.rs.XXXXXX")"
    manifest_tmp="$(mktemp "$manifest_dir/.fold_perf.manifest.XXXXXX")"
    trap 'rm -f "$fixture_tmp" "$manifest_tmp"' RETURN

    local module item filler ordinal
    ordinal=0
    for ((module = 0; module < 200; module++)); do
        printf 'mod module_%03d {\n' "$module" >> "$fixture_tmp"
        printf '    use crate::alpha;\n' >> "$fixture_tmp"
        printf '    use crate::beta;\n' >> "$fixture_tmp"
        printf '    use crate::gamma;\n' >> "$fixture_tmp"
        for ((item = 0; item < 20; item++)); do
            printf '    fn item_%03d_%02d() {\n' "$module" "$item" >> "$fixture_tmp"
            printf '        if true {\n' >> "$fixture_tmp"
            printf '            let payload_0 = "m11-fold-perf-v1 deterministic payload 0123456789abcdef";\n' >> "$fixture_tmp"
            for ((filler = 1; filler <= 7; filler++)); do
                printf '            let payload_%d = "m11-fold-perf-v1 deterministic payload 0123456789abcdef";\n' \
                    "$filler" >> "$fixture_tmp"
            done
            if [[ "$ordinal" -lt 1000 ]]; then
                printf '            let payload_8 = "m11-fold-perf-v1 deterministic payload 0123456789abcdef";\n' >> "$fixture_tmp"
            fi
            printf '        }\n' >> "$fixture_tmp"
            printf '    }\n' >> "$fixture_tmp"
            ordinal=$((ordinal + 1))
        done
        printf '}\n' >> "$fixture_tmp"
    done

    local sha bytes newlines
    sha="$(shasum -a 256 "$fixture_tmp" | awk '{print $1}')"
    bytes="$(wc -c < "$fixture_tmp" | tr -d ' ')"
    newlines="$(wc -l < "$fixture_tmp" | tr -d ' ')"
    cat > "$manifest_tmp" <<JSON
{
  "schemaVersion": 1,
  "seed": "m11-fold-perf-v1",
  "fixtureSHA256": "$sha",
  "byteCount": $bytes,
  "newlineCount": $newlines,
  "lineCount": 50001,
  "candidateCount": 8400,
  "acceptedFoldCount": 8400,
  "kindCounts": {
    "cfgTest": 0,
    "container": 200,
    "declaration": 4000,
    "block": 4000,
    "comment": 0,
    "imports": 200,
    "attributes": 0
  },
  "depthCounts": {"0": 200, "1": 4200, "2": 4000},
  "presets": {
    "structure": {"logical": 4200, "rendered": 4200},
    "overview": {"logical": 4400, "rendered": 200}
  },
  "perfPreset": "Overview"
}
JSON
    mv "$fixture_tmp" "$fixture"
    mv "$manifest_tmp" "$manifest"
    trap - RETURN
    validate_fold_fixture "$fixture" "$manifest"
}

if [[ -n "$fold_fixture" || -n "$fold_manifest" ]]; then
    if [[ -z "$fold_fixture" || -z "$fold_manifest" || "$check_only" == true ]]; then
        echo "--gen-fold-fixture FILE requires --manifest JSON and cannot combine with --check" >&2
        exit 2
    fi
    generate_fold_fixture "$fold_fixture" "$fold_manifest"
    exit 0
fi

# ---------- validation helpers ----------

validate_git() {
    local dir="$1" label="$2"
    if [[ ! -d "$dir/.git" ]]; then
        echo "FAIL  $label: no .git directory" >&2
        return 1
    fi
    if ! git -C "$dir" rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1; then
        echo "FAIL  $label: .git exists but has no commits (corrupted?)" >&2
        return 1
    fi
    local commit
    commit="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"
    echo "  ok  $label: git HEAD = $commit"
}

validate_cargo() {
    local dir="$1" label="$2"
    if ! cargo metadata --manifest-path "$dir/Cargo.toml" --offline \
         --format-version 1 --no-deps >/dev/null 2>&1; then
        echo "FAIL  $label: cargo metadata --offline failed" >&2
        echo "      Dependencies may be missing from the local cargo cache." >&2
        echo "      Run: cargo fetch --manifest-path '$dir/Cargo.toml'" >&2
        return 1
    fi
    echo "  ok  $label: cargo metadata --offline"
}

validate_files() {
    local dir="$1" label="$2" min_count="$3"
    local count
    count="$(find "$dir" -name '*.rs' -type f | wc -l | tr -d ' ')"
    if [[ "$count" -lt "$min_count" ]]; then
        echo "FAIL  $label: found $count .rs files (expected >= $min_count)" >&2
        return 1
    fi
    echo "  ok  $label: $count .rs files"
}

validate_corpus() {
    local dir="$1" label="$2" min_rs="$3"
    local ok=true
    if [[ ! -d "$dir" ]]; then
        echo "FAIL  $label: directory does not exist: $dir" >&2
        return 1
    fi
    validate_git   "$dir" "$label" || ok=false
    validate_cargo "$dir" "$label" || ok=false
    validate_files "$dir" "$label" "$min_rs" || ok=false
    $ok
}

# ---------- provisioning ----------

clone_corpus() {
    local repo="$1" tag="$2" dest="$3" label="$4"
    if [[ -d "$dest" ]]; then
        echo "skip  $label: already exists at $dest"
        return 0
    fi
    echo "clone $label: $repo @ $tag -> $dest"
    if ! git clone --depth 1 --branch "$tag" "$repo" "$dest" 2>&1; then
        echo "FAIL  $label: git clone failed (network unavailable?)" >&2
        return 1
    fi
    echo "  ok  $label: cloned"
}

fetch_cargo_deps() {
    local dir="$1" label="$2"
    if cargo metadata --manifest-path "$dir/Cargo.toml" --offline \
       --format-version 1 --no-deps >/dev/null 2>&1; then
        return 0
    fi
    echo "fetch $label: running cargo fetch (needs network)"
    if ! cargo fetch --manifest-path "$dir/Cargo.toml" 2>&1; then
        echo "FAIL  $label: cargo fetch failed" >&2
        return 1
    fi
}

# ---------- main ----------

echo "corpus root: $root"
echo ""

if $check_only; then
    echo "--- checking tokio ---"
    validate_corpus "$root/$TOKIO_DIR" "tokio" 300 || errors=$((errors + 1))
    echo ""
    echo "--- checking ripgrep ---"
    validate_corpus "$root/$RIPGREP_DIR" "ripgrep" 50 || errors=$((errors + 1))
else
    mkdir -p "$root"

    echo "--- tokio ---"
    clone_corpus "$TOKIO_REPO" "$TOKIO_TAG" "$root/$TOKIO_DIR" "tokio" \
        || errors=$((errors + 1))
    if [[ -d "$root/$TOKIO_DIR" ]]; then
        fetch_cargo_deps "$root/$TOKIO_DIR" "tokio" || errors=$((errors + 1))
    fi
    echo ""

    echo "--- ripgrep ---"
    clone_corpus "$RIPGREP_REPO" "$RIPGREP_TAG" "$root/$RIPGREP_DIR" "ripgrep" \
        || errors=$((errors + 1))
    if [[ -d "$root/$RIPGREP_DIR" ]]; then
        fetch_cargo_deps "$root/$RIPGREP_DIR" "ripgrep" || errors=$((errors + 1))
    fi
    echo ""

    echo "--- verifying ---"
    validate_corpus "$root/$TOKIO_DIR" "tokio" 300 || errors=$((errors + 1))
    echo ""
    validate_corpus "$root/$RIPGREP_DIR" "ripgrep" 50 || errors=$((errors + 1))
fi

echo ""
if [[ $errors -ne 0 ]]; then
    echo "FAILED: $errors corpus/corpora not usable." >&2
    exit 1
fi
echo "All corpora verified."
echo ""
echo "Export for use:"
echo "  export CAIRN_CORPUS_ROOT='$root'"
