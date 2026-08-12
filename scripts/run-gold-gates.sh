#!/usr/bin/env bash
# Run gold-set evaluations with pre-flight corpus validation.
#
# Usage:
#   bash scripts/run-gold-gates.sh                  # both corpora
#   bash scripts/run-gold-gates.sh --tokio-only      # tokio only
#   bash scripts/run-gold-gates.sh --ripgrep-only     # ripgrep only
#   bash scripts/run-gold-gates.sh --corpus-root DIR  # override root
#   bash scripts/run-gold-gates.sh --python-corpus DIR --python-revision SHA
#
# Reads corpus root from: --corpus-root, $CAIRN_CORPUS_ROOT, or ~/.cache/cairn-corpora
# Exits non-zero with a specific diagnostic when a corpus is missing or degraded.

set -euo pipefail

cd "$(dirname "$0")/.."

fixed_python_revision="f55831ee798cd4d7bafab4d50d6dba46e6fce387"
root="${CAIRN_CORPUS_ROOT:-$HOME/.cache/cairn-corpora}"
run_tokio=true
run_ripgrep=true
run_python=false
persist_flag=""
python_corpus=""
python_revision=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --corpus-root) root="$2"; shift 2 ;;
        --tokio-only)  run_ripgrep=false; shift ;;
        --ripgrep-only) run_tokio=false; shift ;;
        --python-corpus) python_corpus="$2"; run_python=true; shift 2 ;;
        --python-revision) python_revision="$2"; shift 2 ;;
        --persist)     persist_flag="--persist"; shift ;;
        --help|-h)
            head -15 "$0" | tail -13 | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "unknown option: $1" >&2
            exit 2 ;;
    esac
done

# ---------- pre-flight checks ----------

preflight_ok=true
python_snapshot_before=""

check_python_corpus_snapshot() {
    check_python_corpus_state | shasum -a 256 | awk '{ print $1 }'
}

check_python_corpus_state() {
    git -C "$python_corpus" rev-parse HEAD
    git -C "$python_corpus" status --porcelain
    git -C "$python_corpus" ls-files -s '*.py' pyproject.toml uv.lock
}

check_python_corpus() {
    if ! $run_python; then
        return 0
    fi

    if [[ "$python_corpus" != /* ]]; then
        echo "ERROR: --python-corpus must be an absolute path: $python_corpus" >&2
        preflight_ok=false
        return 1
    fi

    if [[ -z "$python_revision" ]]; then
        echo "ERROR: --python-corpus requires --python-revision" >&2
        preflight_ok=false
        return 1
    fi

    if [[ "$python_revision" != "$fixed_python_revision" ]]; then
        echo "ERROR: python corpus revision must be fixed $fixed_python_revision" >&2
        preflight_ok=false
        return 1
    fi

    if [[ ! -d "$python_corpus/.git" ]]; then
        echo "ERROR: python corpus has no .git directory: $python_corpus" >&2
        preflight_ok=false
        return 1
    fi

    local head status py_count
    head="$(git -C "$python_corpus" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$head" != "$python_revision" ]]; then
        echo "ERROR: python corpus HEAD mismatch: want $python_revision got $head" >&2
        preflight_ok=false
        return 1
    fi

    status="$(git -C "$python_corpus" status --porcelain)"
    if [[ -n "$status" ]]; then
        echo "ERROR: python corpus is not clean:" >&2
        echo "$status" >&2
        preflight_ok=false
        return 1
    fi

    py_count="$(git -C "$python_corpus" ls-files '*.py' | wc -l | tr -d ' ')"
    if [[ "$py_count" -ne 204 ]]; then
        echo "ERROR: python corpus tracked .py count: want 204 got $py_count" >&2
        preflight_ok=false
        return 1
    fi

    if [[ ! -f "$python_corpus/pyproject.toml" || ! -f "$python_corpus/uv.lock" ]]; then
        echo "ERROR: python corpus missing pyproject.toml or uv.lock" >&2
        preflight_ok=false
        return 1
    fi

    python_snapshot_before="$(check_python_corpus_snapshot)"
    echo "  ok  python corpus frozen: $head"
}

assert_python_corpus_unchanged() {
    local after
    after="$(check_python_corpus_snapshot)"
    if [[ "$after" != "$python_snapshot_before" ]]; then
        echo "ERROR: python corpus changed during gold gate" >&2
        return 1
    fi
}

check_corpus() {
    local dir="$1" label="$2"

    if [[ ! -d "$dir" ]]; then
        echo "ERROR: $label corpus directory does not exist: $dir" >&2
        echo "       Run: bash scripts/provision-corpora.sh" >&2
        preflight_ok=false
        return 1
    fi

    if [[ ! -d "$dir/.git" ]]; then
        echo "ERROR: $label corpus has no .git directory: $dir" >&2
        echo "       The directory exists but .git is missing — it may have been" >&2
        echo "       destroyed by the macOS temp-file cleaner or an incomplete clone." >&2
        echo "       Run: bash scripts/provision-corpora.sh" >&2
        preflight_ok=false
        return 1
    fi

    if ! git -C "$dir" rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1; then
        echo "ERROR: $label corpus .git is corrupted (no commits): $dir" >&2
        echo "       Remove and re-provision:" >&2
        echo "         rm -rf '$dir'" >&2
        echo "         bash scripts/provision-corpora.sh" >&2
        preflight_ok=false
        return 1
    fi

    local rs_count
    rs_count="$(find "$dir" -name '*.rs' -type f | wc -l | tr -d ' ')"
    if [[ "$rs_count" -eq 0 ]]; then
        echo "ERROR: $label corpus has 0 .rs files (destroyed?): $dir" >&2
        echo "       The .git directory exists but source files are gone." >&2
        echo "       Remove and re-provision:" >&2
        echo "         rm -rf '$dir'" >&2
        echo "         bash scripts/provision-corpora.sh" >&2
        preflight_ok=false
        return 1
    fi

    if ! cargo metadata --manifest-path "$dir/Cargo.toml" --offline \
         --format-version 1 --no-deps >/dev/null 2>&1; then
        echo "ERROR: $label corpus: cargo metadata --offline failed: $dir" >&2
        echo "       Dependencies may be missing from the local cargo cache." >&2
        echo "       Run: cargo fetch --manifest-path '$dir/Cargo.toml'" >&2
        preflight_ok=false
        return 1
    fi

    echo "  ok  $label: $(git -C "$dir" rev-parse --short HEAD), $rs_count .rs files"
}

echo "corpus root: $root"
$run_tokio   && check_corpus "$root/tokio-tokio-1.47.1" "tokio"   || true
$run_ripgrep && check_corpus "$root/ripgrep-14.1.1"     "ripgrep" || true
$run_python  && check_python_corpus || true

if ! $preflight_ok; then
    echo "" >&2
    echo "Gold gates aborted: one or more corpora are not usable." >&2
    echo "Set CAIRN_CORPUS_ROOT or pass --corpus-root if corpora are elsewhere." >&2
    exit 1
fi

# ---------- build ----------

if reader_map_hits=$(rg -n 'ByteUTF16Map|byteUTF16Map' \
    Sources/CodeInsightReaderUI/ \
    --glob '!Sources/CodeInsightReaderUI/DisplayMap.swift' 2>&1); then
    echo "$reader_map_hits"
    echo "FAIL: 发现禁用 ByteUTF16Map 引用" >&2
    exit 1
else
    reader_map_rc=$?
    if [[ $reader_map_rc -eq 1 ]]; then
        echo "PASS: ReaderUI ByteUTF16Map 引用仅限 DisplayMap.swift"
    else
        echo "FAIL: rg 基础设施错误 rc=$reader_map_rc" >&2
        exit 1
    fi
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/swift-module-cache}"

swift_options=()
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
    swift_options=(
        --disable-sandbox
        --cache-path .build/cache
        --config-path .build/config
        --security-path .build/security
        --manifest-cache local
    )
fi

swift build ${swift_options[@]+"${swift_options[@]}"}
binary="$PWD/.build/debug/codeinsight"
"$PWD/.build/debug/codeinsight-app" --self-test-projector
"$PWD/.build/debug/codeinsight-app" --self-test-fold
bash scripts/provision-corpora.sh \
    --verify-fold-fixture fixtures/fold_perf.rs \
    --manifest fixtures/fold_perf.manifest.json
swift build -c release ${swift_options[@]+"${swift_options[@]}"} \
    --product codeinsight-app
bash scripts/run-fold-perf.sh \
    --app-bin .build/release/codeinsight-app \
    --fixture fixtures/fold_perf.rs \
    --manifest fixtures/fold_perf.manifest.json

# ---------- run gold gates ----------

failures=0

run_gold() {
    local gold_file="$1" corpus="$2" label="$3" language=""
    echo ""
    echo "--- $label ---"
    if [[ $# -gt 3 ]]; then language="$4"; fi
    if "$binary" goldset "$gold_file" --corpus "$corpus" $persist_flag \
        ${language:+--language "$language"}; then
        echo "PASS  $label"
    else
        echo "FAIL  $label" >&2
        failures=$((failures + 1))
    fi
}

$run_tokio   && run_gold goldset/tokio.gold   "$root/tokio-tokio-1.47.1" "tokio gold"
$run_ripgrep && run_gold goldset/ripgrep.gold "$root/ripgrep-14.1.1"     "ripgrep gold"
if $run_python; then
    run_gold goldset/mcp-python-sdk.gold "$python_corpus" "mcp-python-sdk gold" "python"
    assert_python_corpus_unchanged || failures=$((failures + 1))
fi

echo ""
if [[ $failures -ne 0 ]]; then
    echo "FAILED: $failures gold gate(s) failed." >&2
    exit 1
fi
echo "All gold gates passed."
