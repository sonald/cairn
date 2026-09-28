import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightReaderUI

/// Frozen from the three-way sweep in `RenderingAttributesCoordinator.style`
/// at `82e0ef2`, before decorations became layers.
private func legacyStyledRanges(
    syntaxRanges: [(range: NSRange, kind: HighlightKind)],
    visibleOccurrences: [NSRange],
    referenceRanges: [(range: NSRange, isParameter: Bool)]
) -> [(range: NSRange, kind: HighlightKind?, occurrence: Bool, isParameterReference: Bool?)] {
    var styledRanges: [(range: NSRange, kind: HighlightKind?, occurrence: Bool, isParameterReference: Bool?)] = []
    var spanIndex = 0
    var occurrenceIndex = 0
    var referenceIndex = 0
    var location = min(
        syntaxRanges.first?.range.location ?? Int.max,
        visibleOccurrences.first?.location ?? Int.max,
        referenceRanges.first?.range.location ?? Int.max
    )
    while location != Int.max {
        while spanIndex < syntaxRanges.count,
              NSMaxRange(syntaxRanges[spanIndex].range) <= location
        {
            spanIndex += 1
        }
        while occurrenceIndex < visibleOccurrences.count,
              NSMaxRange(visibleOccurrences[occurrenceIndex]) <= location
        {
            occurrenceIndex += 1
        }
        while referenceIndex < referenceRanges.count,
              NSMaxRange(referenceRanges[referenceIndex].range) <= location
        {
            referenceIndex += 1
        }
        let syntax = syntaxRanges.indices.contains(spanIndex) ? syntaxRanges[spanIndex] : nil
        let occurrence = visibleOccurrences.indices.contains(occurrenceIndex)
            ? visibleOccurrences[occurrenceIndex] : nil
        let reference = referenceRanges.indices.contains(referenceIndex)
            ? referenceRanges[referenceIndex] : nil
        let kind = syntax.flatMap { $0.range.location <= location ? $0.kind : nil }
        let isOccurrence = occurrence.map { $0.location <= location } ?? false
        let isParameterReference = reference.flatMap {
            $0.range.location <= location ? $0.isParameter : nil
        }
        let nextSyntaxBoundary = syntax.map {
            kind == nil ? $0.range.location : NSMaxRange($0.range)
        } ?? Int.max
        let nextOccurrenceBoundary = occurrence.map {
            isOccurrence ? NSMaxRange($0) : $0.location
        } ?? Int.max
        let nextReferenceBoundary = reference.map {
            isParameterReference == nil ? $0.range.location : NSMaxRange($0.range)
        } ?? Int.max
        let next = min(nextSyntaxBoundary, nextOccurrenceBoundary, nextReferenceBoundary)
        guard next > location else { break }
        if kind != nil || isOccurrence || isParameterReference != nil {
            styledRanges.append((
                NSRange(location: location, length: next - location),
                kind,
                isOccurrence,
                isParameterReference
            ))
        }
        location = next
    }
    return styledRanges
}

private struct SplitMix64 {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(bound))
    }
}

/// Sorted by location; ranges may overlap, as nested highlight spans can.
private func randomRanges(_ random: inout SplitMix64, length: Int) -> [NSRange] {
    var ranges: [NSRange] = []
    var location = random.next(8)
    while location < length, ranges.count < 40 {
        ranges.append(NSRange(location: location, length: 1 + random.next(12)))
        location += random.next(10)
    }
    return ranges
}

@Test
func decorationComposerMatchesTheLegacyThreeWaySweep() {
    var random = SplitMix64(state: 0x5EED)
    for _ in 0..<2_000 {
        let length = 1 + random.next(200)
        let syntax = randomRanges(&random, length: length).map {
            ($0, HighlightKind(rawValue: UInt8(random.next(16)))!)
        }
        let occurrences = random.next(3) == 0 ? [] : randomRanges(&random, length: length)
        let references = randomRanges(&random, length: length).map {
            ($0, random.next(2) == 0)
        }

        let expected = legacyStyledRanges(
            syntaxRanges: syntax,
            visibleOccurrences: occurrences,
            referenceRanges: references
        )
        let composed = DecorationComposer.compose([
            DecorationLayer(ranges: syntax.map(\.0)) { index, run in run.syntax = syntax[index].1 },
            DecorationLayer(ranges: occurrences) { _, run in run.occurrence = true },
            DecorationLayer(ranges: references.map(\.0)) { index, run in
                run.parameterReference = references[index].1
            },
        ])

        #expect(composed.count == expected.count)
        for (run, legacy) in zip(composed, expected) {
            #expect(run.range == legacy.range)
            #expect(run.syntax == legacy.kind)
            #expect(run.occurrence == legacy.occurrence)
            #expect(run.parameterReference == legacy.isParameterReference)
        }
    }
}
