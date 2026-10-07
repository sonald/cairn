@preconcurrency import AppKit
import CodeInsightCore
import CodeInsightReaderCore

@MainActor
public final class RenderingAttributesCoordinator {
    public private(set) var styledFragmentCount = 0
    public private(set) var referenceStyledFragmentCount = 0
    public private(set) var referenceAttributeRunCount = 0
    /// 引用查询实际扫描到的候选数（工作量，非输出量）。
    /// 输出计数会被 fragment 交集过滤，测不出 viewport 门控是否失效。
    public private(set) var referenceScannedCount = 0

    private var cachedRuns: [NSRange: [DecorationRun]] = [:]
    private var cachedRunCount = 0
    package private(set) var rangeCalculationCount = 0
    package private(set) var rangeCacheHitCount = 0

    /// Fragments that received this generation's attributes. TextKit may call
    /// the validator for a fragment outside the buffered viewport; `style`
    /// skips it there, so scrolling must style it once it becomes visible.
    private let styledFragments = NSHashTable<NSTextLayoutFragment>(
        options: [.weakMemory, .objectPointerPersonality]
    )

    private func clearRangeCache() {
        cachedRuns.removeAll(keepingCapacity: true)
        cachedRunCount = 0
        styledFragments.removeAllObjects()
    }

    func needsStyle(_ fragment: NSTextLayoutFragment) -> Bool {
        !styledFragments.contains(fragment)
    }

    private var spans: [HighlightSpan] = []
    private var occurrenceRanges: [NSRange] = []
    /// Highlighted-name source ranges, sorted, with their color slots.
    private var highlightRanges: [ByteRange] = []
    private var highlightSlots: [UInt8] = []
    private var highlightContentID: ContentID?
    /// The clicked token; the background pass draws it, so no layer may fill it.
    private var primaryDisplayRange: NSRange?
    private var document: ReaderDocument?
    private var map: DisplayMap?
    private var theme = ReaderTheme(settings: ReaderSettings())

    public init() {}

    public func update(document: ReaderDocument, theme: ReaderTheme) {
        guard let map = DisplayMap(document: document, renderedFoldIDs: []) else {
            clear()
            return
        }
        update(document: document, map: map, theme: theme)
    }

    func update(document: ReaderDocument, map: DisplayMap, theme: ReaderTheme) {
        clearRangeCache()
        if highlightContentID != document.contentID {
            highlightRanges = []
            highlightSlots = []
            highlightContentID = nil
        }
        spans = document.highlightSpans
        self.document = document
        self.map = map
        self.theme = theme
        styledFragmentCount = 0
        referenceStyledFragmentCount = 0
        referenceAttributeRunCount = 0
        referenceScannedCount = 0
    }

    var hasRenderingAttributes: Bool { document != nil }

    /// Display ranges of the current click occurrence or find matches.
    var occurrenceDisplayRanges: [NSRange] { occurrenceRanges }

    func setHighlights(_ ranges: [(range: ByteRange, slot: UInt8)], contentID: ContentID?) {
        clearRangeCache()
        let sorted = ranges.sorted { $0.range.lowerBound < $1.range.lowerBound }
        highlightRanges = sorted.map(\.range)
        highlightSlots = sorted.map(\.slot)
        highlightContentID = contentID
    }

    func setOccurrences(_ ranges: [NSRange], primary: NSRange? = nil) {
        clearRangeCache()
        occurrenceRanges = ranges
        primaryDisplayRange = primary
        styledFragmentCount = 0
        referenceStyledFragmentCount = 0
        referenceAttributeRunCount = 0
        referenceScannedCount = 0
    }

    func clear() {
        clearRangeCache()
        spans = []
        occurrenceRanges = []
        highlightRanges = []
        highlightSlots = []
        highlightContentID = nil
        document = nil
        map = nil
        styledFragmentCount = 0
        referenceStyledFragmentCount = 0
        referenceAttributeRunCount = 0
        referenceScannedCount = 0
    }

    public func style(
        fragment: NSTextLayoutFragment,
        in manager: NSTextLayoutManager
    ) {
        let bounds = manager.textViewportLayoutController.viewportBounds
        let bufferedViewport = bounds.insetBy(dx: 0, dy: -bounds.height * 2)
        guard fragment.layoutFragmentFrame.intersects(bufferedViewport) else { return }
        guard let map, let content = manager.textContentManager else { return }

        let fragmentRange = fragment.rangeInElement
        let start = content.offset(
            from: content.documentRange.location,
            to: fragmentRange.location
        )
        let end = content.offset(
            from: content.documentRange.location,
            to: fragmentRange.endLocation
        )
        guard
            start != NSNotFound,
            end != NSNotFound,
            start <= end,
            let sourceRanges = map.visibleSourceRanges(
                forDisplay: NSRange(location: start, length: end - start)
            )
        else { return }

        let fragmentNSRange = NSRange(location: start, length: end - start)
        if let runs = cachedRuns[fragmentNSRange] {
            rangeCacheHitCount += 1
            submit(runs, for: fragmentNSRange, in: manager, content: content)
            styledFragments.add(fragment)
            return
        }
        rangeCalculationCount += 1
        var visibleSpans: [HighlightSpan] = []
        for sourceRange in sourceRanges {
            visibleSpans.append(contentsOf: ViewportGating.spans(
                spans,
                intersectingBytes: sourceRange.lowerBound..<sourceRange.upperBound,
                buffer: 0
            ))
        }
        var syntaxRanges: [(range: NSRange, kind: HighlightKind)] = []
        syntaxRanges.reserveCapacity(visibleSpans.count)
        for span in visibleSpans {
            guard let projected = map.project(byteRange: span.range) else { continue }
            for globalRange in projected.visible {
                let intersection = NSIntersectionRange(globalRange, fragmentNSRange)
                guard intersection.length > 0 else { continue }
                syntaxRanges.append((intersection, span.kind))
            }
        }
        var referenceRanges: [(range: NSRange, isParameter: Bool)] = []
        if theme.syntaxFormatting, let document {
            for sourceRange in sourceRanges {
                let references = document.localReferences(
                    intersectingBytes: sourceRange.lowerBound..<sourceRange.upperBound
                )
                referenceScannedCount += references.count
                referenceRanges.reserveCapacity(referenceRanges.count + references.count)
                for reference in references {
                    let isParameter: Bool
                    switch reference.kind {
                    case .param:
                        isParameter = true
                    case .letBinding:
                        isParameter = false
                    default:
                        continue
                    }
                    guard let projected = map.project(byteRange: reference.range)
                    else { continue }
                    for globalRange in projected.visible {
                        let intersection = NSIntersectionRange(
                            globalRange,
                            fragmentNSRange
                        )
                        guard intersection.length > 0 else { continue }
                        referenceRanges.append((intersection, isParameter))
                    }
                }
            }
        }
        var low = 0
        var high = occurrenceRanges.count
        while low < high {
            let middle = low + (high - low) / 2
            if NSMaxRange(occurrenceRanges[middle]) <= fragmentNSRange.location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var visibleOccurrences: [NSRange] = []
        for range in occurrenceRanges[low...] {
            guard range.location < NSMaxRange(fragmentNSRange) else { break }
            let intersection = NSIntersectionRange(range, fragmentNSRange)
            guard intersection.length > 0 else { continue }
            visibleOccurrences.append(intersection)
        }

        var visibleHighlights: [(range: NSRange, slot: UInt8)] = []
        for sourceRange in sourceRanges where !highlightRanges.isEmpty {
            var first = 0
            var last = highlightRanges.count
            while first < last {
                let middle = first + (last - first) / 2
                if highlightRanges[middle].upperBound <= sourceRange.lowerBound {
                    first = middle + 1
                } else {
                    last = middle
                }
            }
            for index in first..<highlightRanges.count {
                let range = highlightRanges[index]
                guard range.lowerBound < sourceRange.upperBound else { break }
                guard let projected = map.project(byteRange: range) else { continue }
                for globalRange in projected.visible where globalRange != primaryDisplayRange {
                    let intersection = NSIntersectionRange(globalRange, fragmentNSRange)
                    guard intersection.length > 0 else { continue }
                    visibleHighlights.append((intersection, highlightSlots[index]))
                }
            }
        }
        visibleHighlights.sort { $0.range.location < $1.range.location }

        let styledRanges = DecorationComposer.compose([
            DecorationLayer(ranges: syntaxRanges.map(\.range)) { index, run in
                run.syntax = syntaxRanges[index].kind
            },
            DecorationLayer(ranges: visibleOccurrences) { _, run in
                run.occurrence = true
            },
            DecorationLayer(ranges: visibleHighlights.map(\.range)) { index, run in
                run.highlightSlot = visibleHighlights[index].slot
            },
            DecorationLayer(ranges: referenceRanges.map(\.range)) { index, run in
                run.parameterReference = referenceRanges[index].isParameter
            },
        ])

        if styledRanges.count <= 8_192 {
            if cachedRuns.count >= 128 || cachedRunCount + styledRanges.count > 8_192 {
                // Capacity eviction only; published fragments stay valid.
                cachedRuns.removeAll(keepingCapacity: true)
                cachedRunCount = 0
            }
            cachedRuns[fragmentNSRange] = styledRanges
            cachedRunCount += styledRanges.count
        }
        submit(styledRanges, for: fragmentNSRange, in: manager, content: content)
        styledFragments.add(fragment)
    }

    private func submit(
        _ styledRanges: [DecorationRun], for fragmentRange: NSRange,
        in manager: NSTextLayoutManager, content: NSTextContentManager
    ) {
        // Validator callbacks must always republish: TextKit may have discarded
        // its attributes even when our pure range calculations are unchanged.
        if let textRange = textRange(fragmentRange, in: content) {
            ReaderWorkCounters.record(\.renderingAttributeUpdatedUTF16Units, fragmentRange.length)
            manager.setRenderingAttributes([.foregroundColor: theme.foregroundColor], for: textRange)
        }
        var wroteAttributes = false
        var wroteReferenceAttributes = false
        for styled in styledRanges {
            guard let textRange = textRange(styled.range, in: content) else {
                continue
            }
            var foregroundColor = styled.syntax.map {
                theme.color(for: $0)
            } ?? theme.foregroundColor
            if styled.parameterReference == true {
                foregroundColor = foregroundColor.withAlphaComponent(
                    theme.parameterReferenceAlpha
                )
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: foregroundColor,
            ]
            if let slot = styled.highlightSlot {
                if !styled.occurrence {
                    attributes[.backgroundColor] = theme.highlightColor(slot: slot)
                }
            } else if styled.occurrence {
                attributes[.backgroundColor] = theme.occurrenceColor
            }
            ReaderWorkCounters.record(\.renderingAttributeUpdatedUTF16Units, styled.range.length)
            manager.setRenderingAttributes(attributes, for: textRange)
            wroteAttributes = true
            if styled.parameterReference != nil {
                referenceAttributeRunCount += 1
                wroteReferenceAttributes = true
            }
        }
        if wroteAttributes { styledFragmentCount += 1 }
        if wroteReferenceAttributes { referenceStyledFragmentCount += 1 }
    }

    private func textRange(
        _ range: NSRange,
        in content: NSTextContentManager
    ) -> NSTextRange? {
        guard
            let lower = content.location(
                content.documentRange.location,
                offsetBy: range.location
            ),
            let upper = content.location(lower, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: lower, end: upper)
    }
}
