import CodeInsightCore
import CodeInsightReaderCore
import Testing

/// Each fold as `header line → last hidden line`, 0-based.
private func foldLines(_ format: TextFormat?, _ text: String) -> [String] {
    let document = TextFormat.previewDocument(bytes: Array(text.utf8), format: format)
    return document.foldRegions.map { region in
        let header = document.lineTable.lineColumn(at: region.headerRange.lowerBound)!.line
        let last = document.lineTable.lineColumn(at: region.bodyRange.upperBound)!.line
        return "\(header - 1)→\(last - 1)"
    }
}

@Test
func textPreviewFoldsFollowEachFormatFamily() {
    // Indentation; YAML items fold under a flush key; blank lines stay in the body.
    #expect(foldLines(.yaml, "a:\n  b: 1\n\n  c:\n  - x\n  - y\nd:\n- 1\n- 2\n") == ["0→5", "3→5", "6→8"])
    #expect(foldLines(.json, "{\n  \"a\": [\n    1\n  ]\n}\n") == ["0→3", "1→2"])
    // Sections own everything up to the next header, not trailing blanks.
    #expect(foldLines(.toml, "x = 1\n[a]\nb = 1\n\n[c]\nd = 2\n\n") == ["1→2", "4→5"])
    #expect(foldLines(.diff, "diff --git a b\n--- a\n@@ -1 +1 @@\n-x\n+y\n@@ -9 +9 @@\n z\n")
        == ["0→6", "2→4", "5→6"])
    #expect(foldLines(.jinja(host: .toml), "[a]\nb = {{ v }}\n") == ["0→1"])
    #expect(foldLines(nil, "plain\n\tnested\n") == ["0→1"])
    // Bundled grammars keep their syntax folds.
    #expect(foldLines(.javascript, "function f() {\n  return 1;\n}\n") == ["0→2"])
}

@Test
func textPreviewFoldsStayValidOnGeneratedIndentation() {
    var generator = SplitMix64(seed: 0x5EED_F01D)
    let pieces = ["", " ", "  ", "\t", "    ", "- ", "  - "]
    let words = ["key:", "[sec]", "@@ h", "diff x", "é😀", "-", "x\r"]
    for _ in 0..<300 {
        let text = (0..<Int(generator.next() % 30)).map { _ in
            pieces[Int(generator.next() % UInt64(pieces.count))] + words[Int(generator.next() % UInt64(words.count))]
        }.joined(separator: generator.next() % 2 == 0 ? "\n" : "\r\n")
        for format: TextFormat? in [.yaml, .toml, .diff, .json, nil] {
            let document = TextFormat.previewDocument(bytes: Array(text.utf8), format: format)
            #expect(document.foldTopology != nil, "\(String(describing: format)): \(text.debugDescription)")
            for region in document.foldRegions {
                // Bodies start at the header's line end and end at a line end,
                // so placeholders never split a line or a CRLF.
                #expect(region.headerRange.upperBound == region.bodyRange.lowerBound)
                let end = Int(region.bodyRange.upperBound)
                #expect(end == document.bytes.count || document.bytes[end] == 0x0A || document.bytes[end] == 0x0D)
            }
        }
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
