import Darwin
import Foundation
import Testing
@testable import CodeInsightCore

/// Deterministic generator so a failing seed reproduces.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Reference built on decoded scalars instead of byte walking: the hit's
/// neighbors are the scalars that end at its start and begin at its end.
private func referenceWholeWordRanges(pattern: String, in text: String, allowsDollar: Bool) -> [ByteRange] {
    let bytes = Array(text.utf8)
    let needle = Array(pattern.utf8)
    var scalarStartingAt: [Int: Unicode.Scalar] = [:]
    var scalarEndingAt: [Int: Unicode.Scalar] = [:]
    var offset = 0
    for scalar in text.unicodeScalars {
        let width = String(scalar).utf8.count
        scalarStartingAt[offset] = scalar
        scalarEndingAt[offset + width] = scalar
        offset += width
    }
    func isIdentifier(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar else { return false }
        return scalar == "_" || (allowsDollar && scalar == "$") || scalar.properties.isXIDContinue
    }
    var result: [ByteRange] = []
    var index = 0
    while !needle.isEmpty, index + needle.count <= bytes.count {
        if Array(bytes[index..<index + needle.count]) == needle,
           !isIdentifier(scalarEndingAt[index]),
           !isIdentifier(scalarStartingAt[index + needle.count]) {
            result.append(ByteRange(lowerBound: UInt32(index), upperBound: UInt32(index + needle.count)))
            index += needle.count
        } else {
            index += 1
        }
    }
    return result
}

@Test
func wholeWordLiteralSearchMatchesScalarReferenceOnRandomUnicodeText() throws {
    let pieces = ["a", "b", "é", "中", "_", "$", " ", ".", "1", "🚀", "ab", "a\u{301}"]
    for seed in UInt64(1)...400 {
        var random = SplitMix64(state: seed)
        let text = (0..<Int.random(in: 0...40, using: &random))
            .map { _ in pieces.randomElement(using: &random)! }.joined()
        let pattern = (1...Int.random(in: 1...2, using: &random))
            .map { _ in ["a", "b", "ab", "中", "é"].randomElement(using: &random)! }.joined()
        for allowsDollar in [false, true] {
            let actual = try literalRanges(
                Array(pattern.utf8), in: Array(text.utf8), caseSensitive: true,
                wordBoundary: WordBoundary(allowsDollar: allowsDollar)
            )
            let expected = referenceWholeWordRanges(pattern: pattern, in: text, allowsDollar: allowsDollar)
            #expect(actual == expected, "seed \(seed): \(pattern) in \(text)")
        }
    }
}

@Test
func wholeWordHandlesLineEdgesAndCombiningMarks() throws {
    let boundary = WordBoundary(allowsDollar: false)
    func hits(_ pattern: String, _ text: String) throws -> Int {
        try literalRanges(Array(pattern.utf8), in: Array(text.utf8), caseSensitive: false,
                          wordBoundary: boundary).count
    }
    #expect(try hits("value", "value") == 1)
    #expect(try hits("value", "value\nvalue") == 2)
    #expect(try hits("cafe", "cafe\u{301} cafe") == 1, "a combining mark continues the word")
    #expect(try hits("VALUE", "value_ value") == 1, "case folding still applies")
}

/// Independent reference over path components with `fnmatch`: an anchored
/// pattern matches some leading run of components, an unanchored one
/// (no `/`) matches some single component; anything below a match counts.
private func referenceGlobMatches(_ pattern: String, _ path: String) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    if pattern.contains("/") {
        return (1...components.count).contains { count in
            fnmatch(pattern, components.prefix(count).joined(separator: "/"), FNM_PATHNAME) == 0
        }
    }
    return components.contains { fnmatch(pattern, $0, FNM_PATHNAME) == 0 }
}

@Test
func pathGlobMatchesFnmatchReferenceForStarAndQuestionPatterns() {
    let componentPieces = ["a", "b", "ab", "x.rs", "a.ts"]
    let patternPieces = ["a", "b", "*", "?", ".rs", "/"]
    for seed in UInt64(1)...500 {
        var random = SplitMix64(state: seed)
        let path = (1...Int.random(in: 1...4, using: &random))
            .map { _ in componentPieces.randomElement(using: &random)! }.joined(separator: "/")
        var pattern = (1...Int.random(in: 1...4, using: &random))
            .map { _ in patternPieces.randomElement(using: &random)! }.joined()
        while pattern.hasPrefix("/") || pattern.hasSuffix("/") || pattern.contains("//") {
            pattern = pattern.replacingOccurrences(of: "//", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard !pattern.isEmpty, let glob = PathGlob(pattern) else { continue }
        #expect(glob.matches(path) == referenceGlobMatches(pattern, path), "seed \(seed): \(pattern) vs \(path)")
    }
}

@Test
func pathGlobSupportsGlobstarAlternativesAndDirectoryPatterns() throws {
    func matches(_ pattern: String, _ path: String) throws -> Bool {
        try #require(PathGlob(pattern)).matches(path)
    }
    #expect(try matches("**/tests/**", "src/sync/tests/a.rs"))
    #expect(try matches("**/tests/**", "tests/a.rs"))
    #expect(try !matches("**/tests/**", "src/testsuite/a.rs"))
    #expect(try matches("src/**/*.rs", "src/a.rs"))
    #expect(try matches("src/**/*.rs", "src/x/y/a.rs"))
    #expect(try matches("*.{rs,ts}", "web/pool.ts"))
    #expect(try !matches("*.{rs,ts}", "web/pool.tsx"))
    #expect(try matches("vendor/", "vendor/dep/lib.rs"))
    #expect(try !matches("vendor/", "vendor"), "a directory pattern needs something below it")
    #expect(try matches("/build", "build/out.rs"))
    #expect(try !matches("/build", "src/build/out.rs"), "a leading slash anchors at the root")
    #expect(try matches("a{b", "x/a{b"), "an unclosed brace is literal")
    #expect(PathGlob("   ") == nil)
    #expect(PathGlob.list("src/**, *.{rs,ts} ,, ").map(\.pattern) == ["src/**", "*.{rs,ts}"])
}
