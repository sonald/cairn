import CodeInsightCore
import Foundation
import Testing
@testable import CodeInsightReaderCore

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

private let openers: [UInt8] = Array("([{".utf8)
private let closers: [UInt8] = Array(")]}".utf8)

@Test
func bracketPairsAreSymmetricNestedAndSkipExcludedRanges() {
    for seed in UInt64(1)...300 {
        var random = SplitMix64(state: seed)
        let alphabet = Array("()[]{}ab \n".utf8)
        let bytes = (0..<Int.random(in: 0...160, using: &random)).map { _ in
            alphabet.randomElement(using: &random)!
        }
        // Random disjoint excluded ranges stand in for strings and comments.
        var excluded: [ByteRange] = []
        var cursor = 0
        while cursor < bytes.count {
            let start = cursor + Int.random(in: 0...12, using: &random)
            let end = min(bytes.count, start + Int.random(in: 1...8, using: &random))
            guard start < end else { break }
            excluded.append(ByteRange(lowerBound: UInt32(start), upperBound: UInt32(end)))
            cursor = end + 1
        }
        let pairs = BracketPairs(bytes: bytes, excluded: excluded)

        let expectedOffsets = bytes.indices.filter { index in
            (openers + closers).contains(bytes[index])
                && !excluded.contains { $0.contains(UInt32(index)) }
        }.map(UInt32.init)
        #expect(pairs.offsets == expectedOffsets, "seed \(seed)")

        var spans: [(UInt32, UInt32)] = []
        for (index, partner) in pairs.partners.enumerated() where partner >= 0 {
            let partner = Int(partner)
            #expect(Int(pairs.partners[partner]) == index, "seed \(seed): partner is mutual")
            guard index < partner else { continue }
            let open = bytes[Int(pairs.offsets[index])]
            let close = bytes[Int(pairs.offsets[partner])]
            #expect(openers.firstIndex(of: open) == closers.firstIndex(of: close), "seed \(seed): shapes match")
            spans.append((pairs.offsets[index], pairs.offsets[partner]))
        }
        for a in spans {
            for b in spans where a.0 < b.0 {
                #expect(!(b.0 < a.1 && a.1 < b.1), "seed \(seed): pairs never cross")
            }
        }
    }
}

@Test
func balancedBracketsAllMatchAndEnclosingPairWidensOneLevelAtATime() {
    let source = Array("f(a[b{c}d]e)".utf8)
    let pairs = BracketPairs(bytes: source, excluded: [])
    #expect(pairs.partners.allSatisfy { $0 >= 0 })
    #expect(pairs.bracket(at: 1)?.partner == 11)
    #expect(pairs.bracket(at: 2) == nil)

    let caret: UInt32 = 6 // inside {c}
    let inner = pairs.enclosingPair(lower: caret, upper: caret)
    #expect(inner.map { [$0.open, $0.close] } == [5, 7])
    let middle = inner.flatMap { pairs.enclosingPair(lower: $0.open + 1, upper: $0.close) }
    #expect(middle.map { [$0.open, $0.close] } == [3, 9])
    let outer = middle.flatMap { pairs.enclosingPair(lower: $0.open + 1, upper: $0.close) }
    #expect(outer.map { [$0.open, $0.close] } == [1, 11])
    #expect(outer.flatMap { pairs.enclosingPair(lower: $0.open + 1, upper: $0.close) } == nil)
}

@Test
func strayAndTruncatedBracketsStayUnmatchedWithoutBreakingNeighbors() {
    // A stray `]` and an unclosed `{` at the end of a truncated file.
    let source = Array("(a]) { (b)".utf8)
    let pairs = BracketPairs(bytes: source, excluded: [])
    #expect(pairs.bracket(at: 0)?.partner == 3)
    #expect(pairs.bracket(at: 2).map { $0.partner == nil } == true)
    #expect(pairs.bracket(at: 5).map { $0.partner == nil } == true)
    #expect(pairs.bracket(at: 7)?.partner == 9)
}

@Test
func identifierIndexIgnoresBracketsInsideStringsAndComments() throws {
    let source = "fn f() { let s = \"(\"; // )\n g(s) }"
    let document = try DocumentLoader(source: { _ in Array(source.utf8) })
        .load(file: URL(fileURLWithPath: "/brackets.rs"), languageMode: .init(language: .rust)).document
    let index = try IdentifierIndex(document: document)
    let bytes = Array(source.utf8)
    let open = UInt32(bytes.firstIndex(of: UInt8(ascii: "{"))!)
    let close = UInt32(bytes.lastIndex(of: UInt8(ascii: "}"))!)
    #expect(index.brackets.bracket(at: open)?.partner == close)
    let quoted = UInt32(source.utf8.count - source.drop { $0 != "\"" }.utf8.count + 1)
    #expect(index.brackets.bracket(at: quoted) == nil)
}
