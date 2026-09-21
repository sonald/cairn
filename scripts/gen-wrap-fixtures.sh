#!/usr/bin/env bash
# Generate and verify the reader soft-wrap performance fixtures (F1–F5,
# docs/plans/2026-09-19-reader-wrap-design.md §7.4.3).
#
# Usage:
#   bash scripts/gen-wrap-fixtures.sh                          # generate into fixtures/wrap/
#   bash scripts/gen-wrap-fixtures.sh --verify                 # verify only, no generation
#
# Fixtures are deterministic (fixed seeds baked into the loops below) and are
# committed together with fixtures/wrap/wrap_perf.manifest.json, which pins
# SHA-256, byte counts, logical line counts, and the longest logical line in
# bytes for every fixture.

set -euo pipefail

fixture_dir="fixtures/wrap"
manifest="$fixture_dir/wrap_perf.manifest.json"
verify_only=false
[[ "${1:-}" == "--verify" ]] && verify_only=true

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

# ---------- helpers ----------

max_line_bytes() {
    LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$1"
}

write_manifest_entry() {
    # write_manifest_entry <file> <kind> <extra-json>
    local file="$1" kind="$2" extra="${3:-}"
    local sha bytes lines maxline name
    name="$(basename "$file")"
    sha="$(shasum -a 256 "$file" | awk '{print $1}')"
    bytes="$(wc -c < "$file" | tr -d ' ')"
    lines="$(wc -l < "$file" | tr -d ' ')"
    maxline="$(max_line_bytes "$file")"
    if [[ -n "$extra" ]]; then
        jq -n \
            --arg name "$name" --arg kind "$kind" --arg sha "$sha" \
            --argjson bytes "$bytes" --argjson lines "$lines" \
            --argjson maxLineUTF8Bytes "$maxline" \
            --argjson extra "$extra" \
            '$extra + {name: $name, kind: $kind, sha256: $sha,
                       byteCount: $bytes, lineCount: $lines,
                       maxLineUTF8Bytes: $maxLineUTF8Bytes}'
    else
        jq -n \
            --arg name "$name" --arg kind "$kind" --arg sha "$sha" \
            --argjson bytes "$bytes" --argjson lines "$lines" \
            --argjson maxLineUTF8Bytes "$maxline" \
            '{name: $name, kind: $kind, sha256: $sha,
              byteCount: $bytes, lineCount: $lines,
              maxLineUTF8Bytes: $maxLineUTF8Bytes}'
    fi
}

# ---------- F1 ordinary large file (~3 MiB) ----------
# Short function bodies with a deterministic sprinkle of long lines, so the
# ordinary toggle/resize budget exercises both common layout shapes.

gen_f1() {
    local out="$1"
    local module item filler
    for ((module = 0; module < 300; module++)); do
        printf 'mod wrap_f1_%03d {\n' "$module" >> "$out"
        printf '    use crate::alpha;\n' >> "$out"
        printf '    use crate::beta;\n' >> "$out"
        for ((item = 0; item < 16; item++)); do
            printf '    pub fn f1_%03d_%02d(input: usize) -> usize {\n' "$module" "$item" >> "$out"
            printf '        let base = input + %d;\n' "$((module * 16 + item))" >> "$out"
            printf '        let doubled = base * 2;\n' >> "$out"
            if (( (module * 16 + item) % 8 == 0 )); then
                # Long line: ~120 repetitions of a 24-char fragment.
                printf '        let payload = vec!["wrap-f1-payload-0123456789", ' >> "$out"
                for ((filler = 0; filler < 120; filler++)); do
                    printf '"wrap-f1-payload-0123456789", ' >> "$out"
                done
                printf '];\n' >> "$out"
            else
                printf '        let payload = vec![base, doubled];\n' >> "$out"
            fi
            printf '        doubled + payload.len()\n' >> "$out"
            printf '    }\n' >> "$out"
        done
        printf '}\n' >> "$out"
    done
}

# ---------- F2 one mega logical line (>= 512 KiB) ----------
# Normal short context before and after a single 512 KiB string literal so the
# mid-line anchor and paragraph-level layout cost can be measured in isolation.

gen_f2() {
    local out="$1"
    local i
    printf 'fn wrap_f2_context_before() {\n' >> "$out"
    for ((i = 0; i < 100; i++)); do
        printf '    let context_%03d = %d; // ordinary context line\n' "$i" "$i" >> "$out"
    done
    printf '}\n\n' >> "$out"
    printf 'fn wrap_f2_mega() -> String {\n' >> "$out"
    printf '    // The literal below is one logical line of at least 524288 bytes.\n' >> "$out"
    printf '    let blob = "' >> "$out"
    for ((i = 0; i < 32768; i++)); do
        printf 'wrapf2megablob0123456789abcdef' >> "$out"
    done
    printf '";\n' >> "$out"
    printf '    blob\n' >> "$out"
    printf '}\n\n' >> "$out"
    printf 'fn wrap_f2_context_after() {\n' >> "$out"
    for ((i = 0; i < 100; i++)); do
        printf '    let tail_%03d = %d; // ordinary context line\n' "$i" "$i" >> "$out"
    done
    printf '}\n' >> "$out"
}

# ---------- F3 unbroken 1 MiB string ----------
# A single logical line with no whitespace at all, reported separately: it
# stresses unbreakable-run layout, memory, and main-thread blocking.

gen_f3() {
    local out="$1"
    local i
    printf 'const WRAP_F3_WALL: &str = "' >> "$out"
    for ((i = 0; i < 65536; i++)); do
        printf 'wrapf3unbrokenwall0123456789' >> "$out"
    done
    printf '";\n' >> "$out"
}

# ---------- F4 combined text ----------
# Tabs, deep space indentation (beyond the 24-column clamp), Chinese, emoji,
# CRLF sections, comments, and foldable Rust structure on one file.

gen_f4() {
    local out="$1"
    printf 'mod wrap_f4_combined {\n' >> "$out"
    printf '\tfn tab_indented() {\n' >> "$out"
    printf '\t\tlet a = 1;\n' >> "$out"
    printf '\t\tlet b = 2;\n' >> "$out"
    printf '\t}\n' >> "$out"
    printf '    fn deep_indent() {\n' >> "$out"
    printf '        let deeply_indented_line = "this line starts with more than twenty-four columns of leading spaces so the hanging indent clamp engages";\n' >> "$out"
    printf '        let wrapped_follow_on = 1;\n' >> "$out"
    printf '    }\n' >> "$out"
    printf '    fn unicode() {\n' >> "$out"
    printf '        // 中文注释：软换行必须保留字符位置的 UTF-8／UTF-16 对应。\n' >> "$out"
    printf '        let emoji = "🚀🚀🚀 rocket fleet with family 👨‍👩‍👧‍👦 emoji and combining é accents";\n' >> "$out"
    printf '        let cjk = "中文长行没有空格因此只能按字符断行中文长行没有空格因此只能按字符断行";\n' >> "$out"
    printf '    }\n' >> "$out"
    printf '    fn crlf_section() {\r\n' >> "$out"
    printf '        let crlf_line = "this function uses CRLF line endings";\r\n' >> "$out"
    printf '        let another_crlf_line = 42;\r\n' >> "$out"
    printf '    }\r\n' >> "$out"
    printf '    fn comments() {\n' >> "$out"
    printf '        // A long comment line that wraps across visual rows and exercises the proportional comment font path when enabled.\n' >> "$out"
    printf '        /* block comment */ let value = 1;\n' >> "$out"
    printf '    }\n' >> "$out"
    printf '}\n' >> "$out"
}

# ---------- F5 Reading Set excerpts (30 cards × 20 lines + omission card) ----------
# Cards are separated by "### card <index>" headers. Every card carries two
# ~2 KiB long lines. The final card exercises omitted-line ("…") rows that get
# no line-number label. The wrap perf runner parses this file into excerpt
# models (S2b); the manifest pins its digest in the meantime.

gen_f5() {
    local out="$1"
    local card line chunk
    for ((card = 0; card < 30; card++)); do
        printf '### card %03d\n' "$card" >> "$out"
        printf 'fn f5_card_%03d(input: usize) -> usize {\n' "$card" >> "$out"
        for ((line = 0; line < 8; line++)); do
            printf '    let step_%02d = input + %d; // ordinary card line\n' "$line" "$line" >> "$out"
        done
        printf '    let long_a = "' >> "$out"
        for ((chunk = 0; chunk < 42; chunk++)); do
            printf 'wrap-f5-card-long-line-fragment-0123456789abcdef' >> "$out"
        done
        printf '";\n' >> "$out"
        for ((line = 8; line < 16; line++)); do
            printf '    let step_%02d = input * %d;\n' "$line" "$line" >> "$out"
        done
        printf '    let long_b = "' >> "$out"
        for ((chunk = 0; chunk < 42; chunk++)); do
            printf 'wrap-f5-card-long-line-fragment-fedcba9876543210' >> "$out"
        done
        printf '";\n' >> "$out"
        printf '    step_00 + long_a.len() + long_b.len()\n' >> "$out"
        printf '}\n' >> "$out"
    done
    printf '### card 030\n' >> "$out"
    printf 'fn f5_card_with_omissions() {\n' >> "$out"
    printf 'let visible_head = 1;\n' >> "$out"
    printf '…\n' >> "$out"
    printf 'let visible_tail = 2;\n' >> "$out"
    printf '}\n' >> "$out"
}

# ---------- verify ----------

verify_manifest() {
    jq -e '
        .schemaVersion == 1 and
        .seed == "reader-wrap-v2" and
        (.fixtures | length == 5) and
        ([.fixtures[].name] == ["f1-ordinary.rs", "f2-mega-line.rs",
                                "f3-no-whitespace.rs", "f4-combined.rs",
                                "f5-reading-set.txt"]) and
        (.fixtures[0].byteCount >= 2097152) and
        (.fixtures[1].maxLineUTF8Bytes >= 524288) and
        (.fixtures[2].byteCount >= 1048576 and .fixtures[2].lineCount == 1)
    ' "$manifest" >/dev/null || { echo "FAIL  wrap fixture manifest shape" >&2; return 1; }
    local entry file path
    for entry in $(jq -r '.fixtures | to_entries[] | "\(.value.name)"' "$manifest"); do
        file="$fixture_dir/$entry"
        local sha bytes lines
        sha="$(shasum -a 256 "$file" | awk '{print $1}')"
        bytes="$(wc -c < "$file" | tr -d ' ')"
        lines="$(wc -l < "$file" | tr -d ' ')"
        jq -e --arg name "$entry" --arg sha "$sha" \
            --argjson bytes "$bytes" --argjson lines "$lines" '
            .fixtures[] | select(.name == $name) |
            .sha256 == $sha and .byteCount == $bytes and .lineCount == $lines
        ' "$manifest" >/dev/null || {
            echo "FAIL  wrap fixture drift: $entry" >&2
            return 1
        }
    done
    echo "  ok  wrap fixtures: $(jq -r '.fixtures | length' "$manifest") files verified against $manifest"
}

# ---------- run ----------

if [[ "$verify_only" == true ]]; then
    [[ -f "$manifest" ]] || { echo "manifest missing: $manifest" >&2; exit 1; }
    verify_manifest
    exit 0
fi

mkdir -p "$fixture_dir"

f1="$fixture_dir/f1-ordinary.rs"
f2="$fixture_dir/f2-mega-line.rs"
f3="$fixture_dir/f3-no-whitespace.rs"
f4="$fixture_dir/f4-combined.rs"
f5="$fixture_dir/f5-reading-set.txt"
for f in "$f1" "$f2" "$f3" "$f4" "$f5"; do
    rm -f "$f"
done

gen_f1 "$f1"
gen_f2 "$f2"
gen_f3 "$f3"
gen_f4 "$f4"
gen_f5 "$f5"

entries="$(
    write_manifest_entry "$f1" "ordinary" '{"minBytes": 2097152}'
    write_manifest_entry "$f2" "mega-line" '{"minMegaLineBytes": 524288}'
    write_manifest_entry "$f3" "no-whitespace" '{"minBytes": 1048576}'
    write_manifest_entry "$f4" "combined" '{}'
    write_manifest_entry "$f5" "reading-set" '{"cards": 31}'
)"

# Each write_manifest_entry call prints one JSON object; slurp them into an
# array before assembling the manifest.
jq -n \
    --arg seed "reader-wrap-v2" \
    --argjson fixtures "$(printf '%s\n' "$entries" | jq -s -c '.')" \
    '{schemaVersion: 1, seed: $seed, fixtures: $fixtures}' > "$manifest"

verify_manifest
