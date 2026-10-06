@preconcurrency import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import os

private func readerDynamicColor(
    value: @escaping @Sendable (Bool) -> UInt32,
    alpha: @escaping @Sendable (Bool) -> CGFloat
) -> NSColor {
    NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let rgb = value(isDark)
        return NSColor(
            red: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: alpha(isDark)
        )
    }
}

@MainActor
public extension ReaderTheme {
    func color(for kind: HighlightKind) -> NSColor {
        dynamicColor { isDark in rgb(for: kind, isDark: isDark) }
    }

    func color(for kind: DiffCore.MarkerKind) -> NSColor {
        dynamicColor { isDark in diffRGB(for: kind, isDark: isDark) }
    }

    var backgroundColor: NSColor {
        dynamicColor(backgroundRGB(isDark:))
    }

    var foregroundColor: NSColor {
        dynamicColor(foregroundRGB(isDark:))
    }

    var lineNumberColor: NSColor {
        dynamicColor(lineNumberRGB(isDark:))
    }

    var currentLineColor: NSColor {
        dynamicColor(currentLineRGB(isDark:))
    }

    var occurrenceColor: NSColor {
        dynamicColor(occurrenceRGB(isDark:))
    }

    func highlightColor(slot: UInt8) -> NSColor {
        dynamicColor { isDark in highlightRGB(slot: slot, isDark: isDark) }
    }

    /// Project-search condition color; drawn as an underline, never a fill.
    func queryConditionColor(index: Int) -> NSColor {
        dynamicColor { isDark in queryConditionRGB(index: index, isDark: isDark) }
    }

    func overviewHighlightColor(slot: UInt8) -> NSColor {
        dynamicColor { isDark in overviewHighlightRGB(slot: slot, isDark: isDark) }
    }

    var overviewOccurrenceColor: NSColor {
        dynamicColor(overviewOccurrenceRGB(isDark:))
    }

    var chromeColor: NSColor {
        dynamicColor(chromeRGB(isDark:))
    }

    var chromeHeaderColor: NSColor {
        dynamicColor(chromeHeaderRGB(isDark:))
    }

    var chromeDividerColor: NSColor {
        dynamicColor(chromeDividerRGB(isDark:))
    }

    var chromeSelectionColor: NSColor {
        // Custom rows keep their normal foreground, so use the matching
        // subdued theme fill rather than AppKit's white-text selection fill.
        dynamicColor(chromeSelectionRGB(isDark:))
    }

    var accentColor: NSColor {
        dynamicColor(accentRGB(isDark:))
    }

    var chromeSecondaryColor: NSColor {
        dynamicColor(chromeSecondaryRGB(isDark:))
    }

    var chromeTertiaryColor: NSColor {
        dynamicColor(chromeTertiaryRGB(isDark:))
    }

    var verifiedColor: NSColor {
        dynamicColor(verifiedRGB(isDark:))
    }

    var verifiedBackgroundColor: NSColor {
        dynamicColor(
            verifiedRGB(isDark:),
            alpha: { CGFloat(verifiedFillAlpha(isDark: $0)) }
        )
    }

    var inferredColor: NSColor {
        dynamicColor(inferredRGB(isDark:))
    }

    var inferredBackgroundColor: NSColor {
        dynamicColor(
            inferredRGB(isDark:),
            alpha: { CGFloat(inferredFillAlpha(isDark: $0)) }
        )
    }

    var unresolvedColor: NSColor {
        dynamicColor(unresolvedRGB(isDark:))
    }

    var unresolvedBorderColor: NSColor {
        dynamicColor(unresolvedBorderRGB(isDark:))
    }

    var warningColor: NSColor {
        dynamicColor(warningRGB(isDark:))
    }

    var warningBackgroundColor: NSColor {
        dynamicColor(
            warningRGB(isDark:),
            alpha: { CGFloat(warningFillAlpha(isDark: $0)) }
        )
    }

    var warningBorderColor: NSColor {
        dynamicColor(warningBorderRGB(isDark:))
    }

    var chipBackgroundColor: NSColor {
        dynamicColor(chipBackgroundRGB(isDark:))
    }

    var chipForegroundColor: NSColor {
        dynamicColor(chipForegroundRGB(isDark:))
    }

    var primarySelectionFillColor: NSColor {
        dynamicColor(
            accentRGB(isDark:),
            alpha: { CGFloat(primarySelectionFillAlpha(isDark: $0)) }
        )
    }

    private func dynamicColor(
        _ value: @escaping @Sendable (Bool) -> UInt32
    ) -> NSColor {
        dynamicColor(value, alpha: { _ in 1 })
    }

    private func dynamicColor(
        _ value: @escaping @Sendable (Bool) -> UInt32,
        alpha: @escaping @Sendable (Bool) -> CGFloat
    ) -> NSColor {
        readerDynamicColor(value: value, alpha: alpha)
    }
}

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

extension ReadingHeightLevel {
    package var title: String {
        switch self {
        case .full: localized("reader.height.full")
        case .structure: localized("reader.height.structure")
        case .overview: localized("reader.height.overview")
        }
    }
}

/// An identifier under the pointer and where it sits on screen.
public struct ReaderHoverTarget: Equatable {
    public let byteRange: ByteRange
    public let screenRect: NSRect
}

@MainActor
public final class ReaderTextView {
    private struct FoldScopeKey: Hashable {
        let file: URL
        let contentID: ContentID
    }

    private struct FocusState {
        let readingHeightLevel: ReadingHeightLevel
        let foldOverridesByScope: [FoldScopeKey: FoldOverrides]
        var followsExplicitNavigation = true
        var focusedFoldID: FoldID
        var byteOffset: UInt32
    }

    private struct LatentFoldAnchor {
        let byteOffset: UInt32
        let foldID: FoldID
    }

    public let view: NSTextView
    public let renderingCoordinator = RenderingAttributesCoordinator()
    public var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    public var onContextMenu: ((Int) -> Void)?
    /// The identifier under the pointer, or `nil` over anything else.
    public var onHover: ((ReaderHoverTarget?) -> Void)?
    /// Scrolling or Escape: the hover card must close.
    public var onHoverDismiss: (() -> Void)?
    /// Escape goes to an open hover card first; returns whether it closed one.
    public var onHoverEscape: (() -> Bool)?
    private var lastHoverTarget: ReaderHoverTarget?
    public var onViewportChange: (() -> Void)?
    package var onCaretChange: ((UInt32) -> Void)?
    /// R4 (P3): fires only for USER caret moves — mouse selection and
    /// keyboard navigation — not for programmatic reveals/restores.
    package var onUserCaretChange: ((UInt32) -> Void)?
    private let backingTextStorage: NSTextStorage
    private var displayMap: DisplayMap? {
        didSet { invalidateOverview() }
    }
    private var displayedDocument: ReaderDocument?
    private var theme: ReaderTheme
    private var typographyKey: ReaderTypographyKey
    private var fontEnvironmentRevision: UInt64
    private var isDrawingRuler = false
    package var usesPreparedDecorations = ProcessInfo.processInfo.environment["CAIRN_READONLY_DECORATION_CACHE"] != "0"
    private var diffMarkers: [Int: DiffCore.MarkerKind] = [:]
    private var bookmarkMarkers: [Int: [String]] = [:]
    private var declarationKindsByLine: [Int: OutlineKind] = [:]
    private weak var scrollView: NSScrollView?
    private weak var ruler: NSRulerView?
    private var lineNumbers = true
    private var wrapLines: Bool
    private var isValidatingVisibleRenderingAttributes = false
    private let derivedDataStore: ReaderDerivedDataStore
    private var derivedDataTask: Task<Void, Never>?
    private var derivedDataSubscription: ReaderDerivedDataStore.Subscription?
    private var derivedDataGeneration = 0
    private var identifierIndex: IdentifierIndex?
    private var preparedAnalysisKey: ReaderAnalysisKey?
    private var pendingOccurrenceActivation: UInt32?
    package var onIdentifierPreparationChanged: ((ReaderIdentifierState) -> Void)?
    package private(set) var identifierPreparationState: ReaderIdentifierState = .notRequested {
        didSet {
            if oldValue != identifierPreparationState {
                onIdentifierPreparationChanged?(identifierPreparationState)
            }
        }
    }
    private var occurrenceSelectionByteOffset: UInt32?
    /// Highlighted names and their color slots, shared by the project window.
    private var highlightedNames: [String: UInt8] = [:]
    private var queryHits: (hits: [(range: ByteRange, condition: Int)], contentID: ContentID?) = ([], nil)
    private var overviewRulerView: OverviewRulerView?
    private var overviewCache: (content: OverviewContent, lines: ProjectedLines)?
    private var overviewGeneration = 0
    /// The bracket beside the caret and its partner, as source byte offsets.
    private var bracketMatch: (bracket: UInt32, partner: UInt32?)?
    private var caretByteOffset: UInt32?
    private var blockEndAnnotations: [BlockEndAnnotation] = []
    /// Label rects from the last background pass, for click and hover hits.
    private var drawnBlockEndAnnotations: [(rect: NSRect, annotation: BlockEndAnnotation)] = []
    /// Activating a block-end label: the header's byte offset. The host
    /// records the jump so Back returns to the brace.
    package var onBlockEndAnnotationActivate: ((UInt32) -> Void)?
    private var findMatchByteRanges: [ByteRange]?
    private var findSelectionIndex: Int?
    private var foldOverridesByScope: [FoldScopeKey: FoldOverrides] = [:]
    private var activeFoldScope: FoldScopeKey?
    package private(set) var readingHeightLevel: ReadingHeightLevel = .full
    private var baselineFoldIDs: Set<FoldID> = []
    private var logicalFoldIDs: Set<FoldID> = []
    private var renderedFoldIDs: Set<FoldID> = []
    private var foldAttachments: [FoldID: FoldAttachment] = [:]
    private var focusState: FocusState?
    private var visibleFoldRegionsCache: [FoldRegion] = []
    private var renderedFoldRegionsCache: [FoldRegion] = []
    private var visibleFoldsByLine: [Int: FoldRegion] = [:]
    private var foldedDiffCache: [FoldID: DiffCore.MarkerKind] = [:]
    private var foldedDiffByLine: [Int: DiffCore.MarkerKind] = [:]
    private var visibleBookmarksByLine: [Int: [String]] = [:]
    private var projectionSelectionUsesPrimaryStyle = false
    private var latentProjectionSelection: (sourceRanges: [ByteRange], displayRanges: [NSRange])?
    private var isCommittingProjection = false
    package var localProjectionUpdatesEnabled = ProcessInfo.processInfo.environment["CAIRN_READONLY_LOCAL_REPLACEMENT"] != "0"
    package var forceProjectionPreflightFailureForTesting = false
    package private(set) var partialProjectionCommitCount = 0
    package private(set) var projectionFallbackCount = 0
    package private(set) var projectionFallbackReason: String?
    package private(set) var projectionCommitRejectionReason: String?
    package private(set) var projectionRejectedCount = 0
    package var projectionPreflightHookForTesting: (() -> Void)?
    private var latentSelectionAnchor: LatentFoldAnchor?
    private var latentViewportAnchor: LatentFoldAnchor?
    /// The fold whose handle is currently hovered, identified by FoldID so
    /// the hover matches the row the pointer actually hits (C4/D2.3), never
    /// a whole-column state.
    private var foldGutterHoveredID: FoldID?
    private var navigationLandingLine: Int?
    private var navigationMarkerGeneration = 0
    private var nativeSelectedTextAttributes: [NSAttributedString.Key: Any] = [:]
    /// Wrap performance probes (§7.4.2): full projection commits into the
    /// backing storage, and real background draw passes observed by the
    /// renderer. Both only count; they never gate rendering.
    package private(set) var typographyAttributeUpdateMilliseconds = 0.0
    package private(set) var typographyAttributeUpdateCount = 0
    package private(set) var projectionInstallCount = 0
    private let paragraphLayout = ReaderParagraphLayout()
    private var lastParagraphIndentLimit: CGFloat?
    private var paragraphWidthUpdatePending = false
    package private(set) var paragraphUpdateCount = 0
    package private(set) var backgroundDrawCount = 0
    /// Viewport restore diagnostics (§7.4.2): post-restore correction passes
    /// actually executed, and the anchor offset error of the last restore.
    package private(set) var viewportRestorePassCount = 0
    package private(set) var lastViewportAnchorErrorPt: CGFloat?
    package private(set) var lastViewportRestoreWasLimited = false
    /// Width-reflow diagnostics (§7.4.2): total frame notifications seen and
    /// how many were merged into an already-pending reflow.
    package private(set) var widthReflowNotificationCount = 0
    package private(set) var mergedWidthReflowCount = 0
    /// Bumped whenever the fold projection is rebuilt; viewport states carry
    /// the revision they were captured under so display offsets from another
    /// projection are never restored verbatim (D3.1).
    private var projectionRevision = 0
    /// Layout-transaction generation: bumped at the start of every reflow
    /// transaction and every user-facing content/geometry change. Pending
    /// async restores validate against it and die when it moves (D3.6).
    private var viewportStateGeneration = 0
    private let reflowPolicy: ReaderReflowPolicy
    private let usesCostAwareReflow = ProcessInfo.processInfo.environment["CAIRN_READONLY_REFLOW"] != "0"
    private var readerWorkStopped = false
    package private(set) var lastViewportRestoreLimitation: String?
    package private(set) var viewportGeometryCaptureCount = 0
    private var requiresViewportOnlyLayout: Bool {
        guard let cost = displayedDocument?.cost else { return true }
        return reflowPolicy.requiresViewportOnlyLayout(for: cost)
    }
    /// True while a reflow transaction is restoring selection/scroll; view
    /// and selection callbacks must not treat this as user interaction.
    private var isRestoringViewport = false
    /// Stable viewport state reused across one consecutive pure-reflow
    /// sequence (wrap/font/width changes). Cleared by user interaction,
    /// navigation, fold changes, and content replacement (D3.5/E3).
    private var pendingReflowState: ReaderViewportState?
    // No source/pixel anchor is fabricated when precision is cost-limited.
    private var pendingHorizontalState: ReaderViewportState.HorizontalState?
    /// Coalescing flag for width-change-driven reflows (D3.7): one merged
    /// restore per runloop turn no matter how many tile/frame notifications
    /// AppKit delivers for a single resize.
    private var hasScheduledWidthReflow = false
    /// Viewport state captured at the first width change of the current
    /// resize; cleared once the merged reflow runs.
    private var widthReflowCapturedState: ReaderViewportState?
    /// Deferred restore work, drained on the main queue in the running app
    /// and flushable synchronously in tests (where the test runner owns the
    /// main thread and main-queue blocks only run after the test returns).
    private var pendingViewportCorrection: (
        state: ReaderViewportState,
        generation: Int,
        remaining: Int,
        staleAttempts: Int,
        targetWidth: CGFloat,
        targetTypography: ReaderTypographyKey,
        targetFontEnvironment: UInt64
    )?
    private var pendingWidthReflowGeneration: Int?
    package var reflowDiagnostics: (generation: Int, widthCapture: Bool, widthPending: Bool, correctionPending: Bool, stopped: Bool) {
        (viewportStateGeneration, widthReflowCapturedState != nil, pendingWidthReflowGeneration != nil,
         pendingViewportCorrection != nil, readerWorkStopped)
    }
    public private(set) var currentLineNumber: Int?
    public private(set) var occurrenceCount = 0
    public private(set) var primarySelectionRange: NSRange?
    public private(set) var visibleLineNumbers: [Int] = []
    public private(set) var visibleCurrentLineNumbers: [Int] = []
    public private(set) var visibleDeclarationMarkerLines: [Int] = []

    public convenience init(settings: ReaderSettings = ReaderSettings()) {
        self.init(settings: settings, derivedDataStore: ReaderDerivedDataStore())
    }

    package init(settings: ReaderSettings = ReaderSettings(), derivedDataStore: ReaderDerivedDataStore,
                 reflowPolicy: ReaderReflowPolicy = ReaderReflowPolicy()) {
        self.reflowPolicy = reflowPolicy
        self.derivedDataStore = derivedDataStore
        theme = ReaderTheme(settings: settings)
        typographyKey = ReaderTypographyKey(settings: settings)
        fontEnvironmentRevision = ReaderFontResolver.shared.fontEnvironmentRevision
        lineNumbers = settings.lineNumbers
        wrapLines = settings.wrapLines
        let textView = ClickTextView(usingTextLayoutManager: true)
        view = textView
        backingTextStorage = NSTextStorage()
        view.textContentStorage?.textStorage = backingTextStorage
        configure()
        nativeSelectedTextAttributes = view.selectedTextAttributes
        applyThemeColors()
        textView.clickHandler = { [weak self] index, modifiers in
            self?.clearProjectionSelection()
            self?.activate(atCharacterIndex: index)
            self?.onClick?(index, modifiers)
        }
        textView.sourceCopyHandler = { [weak self] in
            self?.sourceTextForCurrentSelections()
        }
        textView.contextMenuHandler = { [weak self] index in
            self?.onContextMenu?(index)
        }
        textView.selectionHandler = { [weak self] index in
            guard let self, !self.isCommittingProjection else { return }
            clearProjectionSelection()
            pendingOccurrenceActivation = nil
            // Programmatic restores set the selection themselves; only real
            // user interaction ends a pure-reflow sequence (D3.5).
            invalidateReflowSequence()
            if let byteOffset = byteOffset(forCharacterIndex: index) {
                updateCurrentLine(byteOffset: byteOffset)
                onUserCaretChange?(byteOffset)
            }
            // A native gesture can select the same symbol range as activation.
            // It still needs the native selection background and anchor semantics.
            if primarySelectionRange != nil {
                self.primarySelectionRange = nil
                view.selectedTextAttributes = nativeSelectedTextAttributes
                if let document = displayedDocument,
                   let occurrenceSelectionByteOffset
                {
                    setOccurrences(occurrenceNSRanges(
                        in: document,
                        at: occurrenceSelectionByteOffset
                    ))
                }
            }
        }
        textView.hoverHandler = { [weak self] point in
            guard let self else { return }
            let annotation = point.flatMap { self.blockEndAnnotation(at: $0) }
            let tip = annotation?.header
            if self.view.toolTip != tip { self.view.toolTip = tip }
            self.handleHover(at: annotation == nil ? point : nil)
        }
        textView.escapeHandler = { [weak self] in
            guard let self else { return false }
            if onHoverEscape?() == true { return true }
            if isFocusMode { return exitFocusMode() }
            guard occurrenceCount > 0 || pendingOccurrenceActivation != nil else { return false }
            clearOccurrences()
            return true
        }
        textView.backgroundHandler = { [weak self, weak textView] rect in
            guard let self, let textView, !self.isCommittingProjection else { return }
            self.backgroundDrawCount += 1
            self.drawCurrentLineBackground(in: textView, dirtyRect: rect)
            self.drawPrimarySelection(in: textView, dirtyRect: rect)
            self.drawHighlightRings(in: textView, dirtyRect: rect)
            self.drawQueryHitUnderlines(in: textView, dirtyRect: rect)
            self.drawBracketMatch(in: textView, dirtyRect: rect)
            self.drawBlockEndAnnotations(in: textView, dirtyRect: rect)
        }
        textView.annotationClickHandler = { [weak self] point in
            guard let self, let hit = self.blockEndAnnotation(at: point) else { return false }
            self.onBlockEndAnnotationActivate?(hit.headerOffset)
            return true
        }
        textView.layoutCompleted = { [weak self] in
            // A scroll notifies before TextKit lays out the new viewport; the
            // ruler's band reads that layout, so draw it again afterwards.
            self?.overviewRulerView?.needsDisplay = true
            guard let self, !self.readerWorkStopped, !self.isCommittingProjection, !self.isRestoringViewport,
                  self.renderingCoordinator.hasRenderingAttributes,
                  let manager = self.view.textLayoutManager else { return }
            self.styleUnstyledVisibleFragments(in: manager)
            self.processPendingViewportCorrection()
        }
        textView.userScrollHandler = { [weak self] in
            self?.lastHoverTarget = nil
            self?.onHoverDismiss?()
            guard let self, !self.readerWorkStopped else { return }
            self.invalidateReflowSequence()
            self.focusState?.followsExplicitNavigation = false
        }
        textView.viewportChanged = { [weak self] in
            guard let self, !self.readerWorkStopped, !self.isCommittingProjection,
                  let layoutManager = self.view.textLayoutManager
            else { return }
            self.foldGutterHoveredID = nil
            // Scrolls issued by a reflow restore are programmatic and each
            // one must not re-run viewport validation: right after a
            // container-width change that validation costs a full layout
            // (seconds on the 30k-line fixture). The owning transaction
            // validates and publishes once at its end (D3.4).
            if self.isRestoringViewport { return }
            // Bounds changes may come from TextKit layout. Only explicit user
            // input clears the anchor. Scrolling does not change style data:
            // style only fragments that lack this generation's attributes.
            self.styleUnstyledVisibleFragments(in: layoutManager, updateLayout: true)
            self.ruler?.needsDisplay = true
            self.onViewportChange?()
        }
        // Width changes: capture the old stable state before the frame
        // actually changes, then merge all tile/frame notifications of one
        // resize into a single reflow restore (D3.7).
        textView.widthWillChange = { [weak self] oldWidth in
            self?.captureStateForWidthChange(previousViewportWidth: oldWidth)
        }
        textView.widthDidChange = { [weak self] _ in
            self?.scheduleWidthReflow()
        }
    }

    deinit {
        derivedDataTask?.cancel()
        if let subscription = derivedDataSubscription {
            let store = derivedDataStore
            Task { await store.cancel(subscription) }
        }
    }

    /// Terminal host teardown; identifier refresh itself must not cancel reflow.
    /// Preserve text/selection for the host's final reading-position checkpoint.
    package func stopPendingReaderWork() {
        readerWorkStopped = true
        invalidateReflowSequence()
        paragraphWidthUpdatePending = false
        cancelDerivedDataSubscription()
    }

    package func cancelDerivedDataSubscription() {
        derivedDataGeneration += 1
        derivedDataTask?.cancel()
        derivedDataTask = nil
        if let subscription = derivedDataSubscription {
            let store = derivedDataStore
            Task { await store.cancel(subscription) }
        }
        derivedDataSubscription = nil
        identifierIndex = nil
        preparedAnalysisKey = nil
        pendingOccurrenceActivation = nil
        identifierPreparationState = .notRequested
    }

    private func prepareIdentifiers(for document: ReaderDocument) {
        let previousSubscription = derivedDataSubscription
        let pending = pendingOccurrenceActivation
        cancelDerivedDataSubscription()
        pendingOccurrenceActivation = pending
        identifierPreparationState = .building
        let generation = derivedDataGeneration
        let key = document.analysisKey
        let store = derivedDataStore
        // Register/build independently of synchronous first-screen AppKit work.
        // This task owns its token until the matching Reader accepts the result.
        derivedDataTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard !Task.isCancelled else { return }
            if let previousSubscription { await store.cancel(previousSubscription) }
            let subscription = await store.subscribe(key: key, document: document)
            let published = await withTaskCancellationHandler {
                do {
                    let index = try await store.value(for: subscription)
                    return await MainActor.run { [weak self] in
                        guard !Task.isCancelled, let self,
                              self.derivedDataGeneration == generation,
                              self.displayedDocument?.analysisKey == key else { return false }
                        self.derivedDataSubscription = subscription
                        self.identifierIndex = index
                        self.preparedAnalysisKey = key
                        self.identifierPreparationState = .ready
                        self.refreshHighlights()
                        self.refreshBracketMatch()
                        if let pending = self.pendingOccurrenceActivation,
                           pending == self.occurrenceSelectionByteOffset {
                            self.pendingOccurrenceActivation = nil
                            self.finishOccurrenceActivation(at: pending)
                        } else if self.occurrenceSelectionByteOffset != nil {
                            self.refreshOccurrenceRendering()
                        }
                        return true
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard !Task.isCancelled, let self,
                              self.derivedDataGeneration == generation,
                              self.displayedDocument?.analysisKey == key else { return }
                        self.identifierPreparationState = .unavailable(String(describing: error))
                    }
                    return false
                }
            } onCancel: {
                Task { await store.cancel(subscription) }
            }
            if !published { await store.cancel(subscription) }
        }
    }

    package func waitForIdentifierPreparation() async {
        await derivedDataTask?.value
    }

    private func preparedOccurrences(in document: ReaderDocument, at offset: UInt32) -> ArraySlice<ByteRange> {
        guard preparedAnalysisKey == document.analysisKey, let identifierIndex else { return [] }
        return identifierIndex.occurrences(at: offset)
    }

    /// The identifier index for the displayed document, once prepared.
    private var preparedIdentifierIndex: IdentifierIndex? {
        guard let document = displayedDocument, preparedAnalysisKey == document.analysisKey else { return nil }
        return identifierIndex
    }

    // MARK: Overview ruler

    /// The strip of whole-file marks; the host places it beside the scroll view.
    public var overviewRuler: NSView {
        if let overviewRulerView { return overviewRulerView }
        let ruler = OverviewRulerView(reader: self)
        overviewRulerView = ruler
        return ruler
    }

    public static let overviewRulerWidth = OverviewRulerView.width

    var overviewTheme: ReaderTheme { theme }

    private func invalidateOverview() {
        overviewCache = nil
        overviewGeneration += 1
        overviewRulerView?.needsDisplay = true
    }

    /// Marks by display line; rebuilt lazily after any source of marks changes.
    func overviewContent() -> (content: OverviewContent, generation: Int) {
        if let overviewCache { return (overviewCache.content, overviewGeneration) }
        guard !isCommittingProjection, let document = displayedDocument, let map = displayMap
        else { return (OverviewContent(), overviewGeneration) }
        let lines = ProjectedLines(projection: map.projection, lineStarts: document.lineTable.lineStarts)
        let lineStarts = document.lineTable.lineStarts
        var content = OverviewContent(lineCount: lines.count)
        func add(_ kind: OverviewContent.Kind, _ byte: UInt32, _ label: String) {
            let position = lines.displayLine(ofByte: byte)
            content.marks.append(.init(kind: kind, line: position.line, folded: position.folded, byteOffset: byte, label: label))
        }
        for (line, kind) in diffMarkers where lineStarts.indices.contains(line - 1) {
            let label = switch kind {
            case .added: localized("reader.overview.added")
            case .removed: localized("reader.overview.removed")
            case .changed: localized("reader.overview.changed")
            }
            add(.diff(kind), lineStarts[line - 1], label)
        }
        if let findMatchByteRanges {
            let label = localized("reader.overview.find")
            for range in findMatchByteRanges { add(.occurrence, range.lowerBound, label) }
        } else if let offset = occurrenceSelectionByteOffset, let index = preparedIdentifierIndex {
            let label = index.name(at: offset) ?? ""
            for range in preparedOccurrences(in: document, at: offset) { add(.occurrence, range.lowerBound, label) }
        }
        if let index = preparedIdentifierIndex {
            for (name, slot) in highlightedNames {
                for range in index.occurrences(named: name) { add(.highlight(slot), range.lowerBound, name) }
            }
        }
        for (line, labels) in bookmarkMarkers where lineStarts.indices.contains(line - 1) {
            add(.bookmark, lineStarts[line - 1], localizedFormat("reader.bookmarks", labels.joined(separator: ", ")))
        }
        overviewCache = (content, lines)
        return (content, overviewGeneration)
    }

    /// Display lines in view and the caret's display line.
    func overviewViewport() -> (lines: Range<Int>?, caret: Int?) {
        _ = overviewContent()
        guard let lines = overviewCache?.lines, let document = displayedDocument
        else { return (nil, nil) }
        let caret = currentLineNumber.flatMap { line in
            document.lineTable.lineStarts.indices.contains(line - 1)
                ? lines.displayLine(ofByte: document.lineTable.lineStarts[line - 1]).line : nil
        }
        guard let manager = view.textLayoutManager, let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange
        else { return (nil, caret) }
        // The viewport range includes overdraw; keep fragments actually in view.
        let visible = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        var top: Int?, bottom: Int?
        manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY < visible.maxY else { return false }
            guard frame.maxY > visible.minY else { return true }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            if offset != NSNotFound, let byte = self.sourceByteOffset(forDisplay: offset) {
                let line = lines.displayLine(ofByte: byte).line
                top = top ?? line
                bottom = line
            }
            return true
        }
        guard let top, let bottom else { return (nil, caret) }
        return (top..<max(top + 1, bottom + 1), caret)
    }

    /// Centers display line `line`, as dragging the ruler does.
    func scrollToOverviewLine(_ line: Int) {
        guard let lines = overviewCache?.lines,
              let location = visibleDisplayOffset(forByte: lines.sourceByte(ofDisplayLine: line)),
              let scrollView = view.enclosingScrollView
        else { return }
        view.scrollRangeToVisible(NSRange(location: location, length: 0))
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        let clipView = scrollView.contentView
        let targetY = ReaderViewportGeometry.characterRect(displayLocation: location, in: view)
            .map { $0.midY - clipView.bounds.height / 2 } ?? clipView.bounds.minY
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: clampVerticalScrollOrigin(targetY, clipView: clipView)))
        scrollView.reflectScrolledClipView(clipView)
    }

    /// 1-based source line of `byte`, for the ruler's tooltips.
    func overviewSourceLine(ofByte byte: UInt32) -> Int {
        displayedDocument?.lineTable.lineColumn(at: byte).map { Int($0.line) } ?? 0
    }

    // MARK: Highlighted names

    /// Names to paint with their color slots. Matching is lexical: same
    /// spelling outside strings and comments, like the click occurrence.
    public func setHighlightedNames(_ names: [String: UInt8]) {
        guard names != highlightedNames else { return }
        highlightedNames = names
        refreshHighlights()
    }

    /// Project-search hits for one file, underlined in their condition colors.
    /// Ignored unless `contentID` is the displayed document's content.
    public func setQueryHits(_ hits: [(range: ByteRange, condition: Int)], contentID: ContentID?) {
        // Results re-render often while streaming; repaint only on a real change.
        guard contentID != queryHits.contentID || hits.count != queryHits.hits.count
            || !zip(hits, queryHits.hits).allSatisfy({ $0.range == $1.range && $0.condition == $1.condition })
        else { return }
        queryHits = (hits, contentID)
        redisplayRenderedText()
    }

    /// The identifier at the caret, or at the active click occurrence.
    public var identifierAtCaret: String? {
        guard let index = preparedIdentifierIndex else { return nil }
        if let offset = occurrenceSelectionByteOffset, let name = index.name(at: offset) { return name }
        // Read the live selection: accessibility and programmatic moves
        // never pass through the mouse/keyboard hooks that track the caret.
        guard let offset = byteOffset(forCharacterIndex: view.selectedRange().location) ?? caretByteOffset
        else { return nil }
        return index.name(at: offset) ?? (offset > 0 ? index.name(at: offset - 1) : nil)
    }

    /// The identifier covering `byteOffset`, once identifiers are prepared.
    public func identifier(atByteOffset byteOffset: UInt32) -> String? {
        preparedIdentifierIndex?.name(at: byteOffset)
    }

    /// Occurrences of `name` in the displayed document; nil until prepared.
    public func occurrenceCount(ofName name: String) -> Int? {
        preparedIdentifierIndex?.occurrences(named: name).count
    }

    /// Moves to the next (or previous) occurrence of `name`, wrapping around.
    @discardableResult
    public func revealOccurrence(ofName name: String, backwards: Bool) -> Bool {
        guard let ranges = preparedIdentifierIndex?.occurrences(named: name),
              let first = ranges.first, let last = ranges.last
        else { return false }
        let caret = occurrenceSelectionByteOffset ?? caretByteOffset ?? 0
        let target = backwards
            ? (ranges.last { $0.lowerBound < caret } ?? last)
            : (ranges.first { $0.lowerBound > caret } ?? first)
        reveal(byteOffset: target.lowerBound)
        activate(atByteOffset: target.lowerBound)
        return true
    }

    private func refreshHighlights() {
        var ranges: [(range: ByteRange, slot: UInt8)] = []
        if let index = preparedIdentifierIndex {
            for (name, slot) in highlightedNames {
                ranges.append(contentsOf: index.occurrences(named: name).map { ($0, slot) })
            }
        }
        renderingCoordinator.setHighlights(ranges, contentID: displayedDocument?.contentID)
        guard let layoutManager = view.textLayoutManager, displayedDocument != nil else { return }
        installRenderingValidator(in: layoutManager)
        if let viewportRange = layoutManager.textViewportLayoutController.viewportRange {
            layoutManager.invalidateRenderingAttributes(for: viewportRange)
            validateVisibleRenderingAttributes(in: layoutManager)
        }
        redisplayRenderedText()
        invalidateOverview()
    }

    /// TextKit 2 draws each line fragment in its own subview, which the text
    /// view's own `needsDisplay` never reaches. A change of fills alone (a
    /// menu command moves no selection) must ask every fragment to redraw, or
    /// added and removed fills appear only after the lines scroll.
    private func redisplayRenderedText() {
        func mark(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(mark)
        }
        mark(view)
    }

    /// When the clicked name is also highlighted its fill stays the
    /// highlight color; a thin ring marks the clicked group instead.
    private func drawHighlightRings(in textView: NSTextView, dirtyRect: NSRect) {
        guard findMatchByteRanges == nil,
              let offset = occurrenceSelectionByteOffset,
              let name = preparedIdentifierIndex?.name(at: offset),
              highlightedNames[name] != nil,
              let viewport = viewportDisplayRange()
        else { return }
        guard let slot = highlightedNames[name] else { return }
        let fill = theme.highlightColor(slot: slot)
        let ring = theme.foregroundColor.withAlphaComponent(0.55)
        for range in renderingCoordinator.occurrenceDisplayRanges
        where NSIntersectionRange(range, viewport).length > 0 {
            for segment in ReaderViewportGeometry.visibleRects(
                forDisplayRange: range, in: textView, clipTo: textView.visibleRect
            ) where segment.intersects(dirtyRect) {
                let path = NSBezierPath(
                    roundedRect: segment.insetBy(dx: -0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5
                )
                fill.setFill()
                path.fill()
                path.lineWidth = 1
                ring.setStroke()
                path.stroke()
            }
        }
    }

    /// Project-search hits in the displayed file, as condition-colored underlines.
    /// TextKit 2 ignores underline rendering attributes, so they are drawn here.
    private func drawQueryHitUnderlines(in textView: NSTextView, dirtyRect: NSRect) {
        guard !queryHits.hits.isEmpty, let contentID = queryHits.contentID,
              displayedDocument?.contentID == contentID, let map = displayMap,
              let viewport = viewportDisplayRange()
        else { return }
        for hit in queryHits.hits {
            guard let projected = map.project(byteRange: hit.range) else { continue }
            let color = theme.queryConditionColor(index: hit.condition)
            for range in projected.visible where NSIntersectionRange(range, viewport).length > 0 {
                for segment in ReaderViewportGeometry.visibleRects(
                    forDisplayRange: range, in: textView, clipTo: textView.visibleRect
                ) where segment.intersects(dirtyRect) {
                    color.setFill()
                    NSRect(x: segment.minX, y: segment.maxY - 2.5, width: segment.width, height: 2).fill()
                }
            }
        }
    }

    private func viewportDisplayRange() -> NSRange? {
        guard let manager = view.textLayoutManager,
              let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange
        else { return nil }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        guard start != NSNotFound, end != NSNotFound, start <= end else { return nil }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Bracket matching

    private func refreshBracketMatch() {
        var match: (bracket: UInt32, partner: UInt32?)?
        if let caret = caretByteOffset, let brackets = preparedIdentifierIndex?.brackets {
            let found = brackets.bracket(at: caret) ?? (caret > 0 ? brackets.bracket(at: caret - 1) : nil)
            match = found.map { ($0.offset, $0.partner) }
        }
        guard match?.bracket != bracketMatch?.bracket || match?.partner != bracketMatch?.partner else { return }
        bracketMatch = match
        view.needsDisplay = true
    }

    /// Moves the caret to the partner of the bracket beside it.
    @discardableResult
    public func jumpToMatchingBracket() -> Bool {
        if let live = byteOffset(forCharacterIndex: view.selectedRange().location), live != caretByteOffset {
            caretByteOffset = live
            refreshBracketMatch()
        }
        guard let partner = bracketMatch?.partner else { return false }
        reveal(byteOffset: partner)
        if let location = visibleDisplayOffset(forByte: partner) {
            view.setSelectedRange(NSRange(location: location, length: 0))
        }
        updateCurrentLine(byteOffset: partner)
        return true
    }

    /// Selects the text inside the innermost bracket pair around the caret;
    /// repeating widens to the next enclosing pair.
    @discardableResult
    public func selectInsideBrackets() -> Bool {
        guard let brackets = preparedIdentifierIndex?.brackets else { return false }
        let selection = view.selectedRange()
        guard let lower = byteOffset(forCharacterIndex: selection.location) else { return false }
        let upper = selection.length > 0
            ? byteOffset(forCharacterIndex: NSMaxRange(selection)) ?? lower
            : lower
        guard let pair = brackets.enclosingPair(lower: lower, upper: upper) else { return false }
        _ = unfoldAncestors(containing: pair.open)
        guard let visible = displayMap?.project(
            byteRange: ByteRange(lowerBound: pair.open + 1, upperBound: pair.close)
        )?.visible, let first = visible.first, let last = visible.last else { return false }
        clearOccurrences()
        let range = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        view.setSelectedRange(range)
        view.scrollRangeToVisible(range)
        return true
    }

    private func drawBracketMatch(in textView: NSTextView, dirtyRect: NSRect) {
        guard let match = bracketMatch else { return }
        for offset in [match.bracket] + (match.partner.map { [$0] } ?? []) {
            guard let location = visibleDisplayOffset(forByte: offset) else { continue }
            for segment in ReaderViewportGeometry.visibleRects(
                forDisplayRange: NSRange(location: location, length: 1),
                in: textView, clipTo: textView.visibleRect
            ) where segment.intersects(dirtyRect) {
                if match.partner == nil {
                    let path = NSBezierPath()
                    path.move(to: NSPoint(x: segment.minX, y: segment.maxY - 1))
                    path.line(to: NSPoint(x: segment.maxX, y: segment.maxY - 1))
                    path.lineWidth = 1.2
                    path.setLineDash([2, 2], count: 2, phase: 0)
                    theme.unresolvedColor.setStroke()
                    path.stroke()
                } else {
                    let path = NSBezierPath(
                        roundedRect: segment.insetBy(dx: -0.5, dy: 0.5), xRadius: 2, yRadius: 2
                    )
                    path.lineWidth = 1
                    theme.accentColor.setStroke()
                    path.stroke()
                }
            }
        }
    }

    // MARK: Block-end annotations

    private var blockEndAnnotationFont: NSFont {
        let size = CGFloat(max(9, theme.fontSize - 1.5))
        return NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
    }

    private func drawBlockEndAnnotations(in textView: NSTextView, dirtyRect: NSRect) {
        drawnBlockEndAnnotations = []
        guard theme.blockEndAnnotations, !blockEndAnnotations.isEmpty,
              let document = displayedDocument, let viewport = viewportDisplayRange(),
              let visibleBytes = displayMap?.visibleSourceRanges(forDisplay: viewport),
              let lowerByte = visibleBytes.first?.lowerBound,
              let upperByte = visibleBytes.last?.upperBound
        else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: blockEndAnnotationFont,
            .foregroundColor: theme.chromeTertiaryColor,
        ]
        var low = 0
        var high = blockEndAnnotations.count
        while low < high {
            let middle = low + (high - low) / 2
            if blockEndAnnotations[middle].closingBrace < lowerByte { low = middle + 1 } else { high = middle }
        }
        for annotation in blockEndAnnotations[low...] {
            guard annotation.closingBrace < upperByte else { break }
            guard let braceLocation = visibleDisplayOffset(forByte: annotation.closingBrace),
                  let line = document.lineTable.lineColumn(at: annotation.closingBrace)?.line
            else { continue }
            // Text after the brace (`});`) stays left of the label.
            let starts = document.lineTable.lineStarts
            let lineEndByte = starts.indices.contains(Int(line)) ? starts[Int(line)] - 1 : UInt32(document.bytes.count)
            let lineEnd = visibleDisplayOffset(forByte: lineEndByte) ?? braceLocation + 1
            guard let last = ReaderViewportGeometry.visibleRects(
                forDisplayRange: NSRange(location: braceLocation, length: max(1, lineEnd - braceLocation)),
                in: textView, clipTo: textView.bounds
            ).last else { continue }
            let text = "‹ " + annotation.label as NSString
            let size = text.size(withAttributes: attributes)
            let rect = NSRect(
                x: last.maxX + 16, y: last.midY - size.height / 2,
                width: ceil(size.width), height: ceil(size.height)
            )
            // A label never wraps or widens the line; it is dropped instead.
            if wrapLines, rect.maxX > textView.bounds.maxX - textView.textContainerInset.width { continue }
            drawnBlockEndAnnotations.append((rect, annotation))
            guard rect.intersects(dirtyRect) else { continue }
            text.draw(at: rect.origin, withAttributes: attributes)
        }
    }

    private func blockEndAnnotation(at point: NSPoint) -> BlockEndAnnotation? {
        drawnBlockEndAnnotations.first { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }?.annotation
    }

    package static func projectorSelfTestChecks() -> [String: Bool] {
        do {
            let source = "fn outer() {\n    let emoji = \"😀\";\n}\n"
            let bytes = Array(source.utf8)
            let document = try DocumentLoader(source: { _ in bytes })
                .load(file: URL(fileURLWithPath: "/projector-self-test.rs"))
                .document
            guard let fold = document.foldRegions.first(where: {
                $0.kind == .declaration
            }) else { return ["fixtureFoldExists": false] }
            let reader = ReaderTextView()
            guard let identity = project(
                document: document,
                renderedFoldIDs: [],
                attributes: reader.baseAttributes,
                theme: reader.theme
            ),
            let folded = project(
                document: document,
                renderedFoldIDs: [fold.id],
                attributes: reader.baseAttributes,
                theme: reader.theme
            ) else { return ["projectionBuilds": false] }
            let placeholder = (folded.attributed.string as NSString).range(
                of: "\u{FFFC}"
            )
            let copied = folded.map.sourceRanges(forDisplay: placeholder)
            let visible = folded.map.visibleSourceRanges(forDisplay: placeholder)
            return [
                "fixtureFoldExists": true,
                "identityTextMatches": identity.attributed.string == source,
                "identityLengthMatches": identity.attributed.length
                    == identity.map.projectedUTF16Length,
                "foldedLengthMatches": folded.attributed.length
                    == folded.map.projectedUTF16Length,
                "singlePlaceholder": placeholder.location != NSNotFound
                    && (folded.attributed.string as NSString)
                        .components(separatedBy: "\u{FFFC}").count == 2,
                "hiddenMapsToFold": folded.map.displayPosition(
                    ofByte: fold.bodyRange.lowerBound
                ) == .hidden(fold.id),
                "placeholderMapsToFold": folded.map.sourcePosition(
                    ofDisplay: placeholder.location
                ) == .placeholder(fold.id),
                "copyExpandsHiddenSource": copied == [fold.bodyRange],
                "viewportSkipsHiddenSource": visible == [],
            ]
        } catch {
            return ["projectorSelfTestThrew": false]
        }
    }

    package static func foldSelfTestChecks() -> [String: Bool] {
        do {
            let source = """
                mod outer {
                    fn inner() {
                        let one = 1;
                        let two = 2;
                        let three = one + two;
                    }
                }
                """
            let bytes = Array(source.utf8)
            let file = URL(fileURLWithPath: "/fold-self-test.rs")
            let document = try DocumentLoader(source: { _ in bytes })
                .load(file: file).document
            guard let outer = document.foldRegions.first(where: {
                $0.kind == .container
            }), let inner = document.foldRegions.first(where: {
                $0.kind == .declaration
            }) else { return ["fixtureFoldsExist": false] }

            let reader = ReaderTextView()
            let scrollView = NSScrollView(
                frame: NSRect(x: 0, y: 0, width: 480, height: 180)
            )
            scrollView.documentView = reader.view
            reader.view.frame = scrollView.contentView.bounds
            let window = NSWindow(
                contentRect: scrollView.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.contentView = scrollView
            reader.apply(settings: ReaderSettings(lineNumbers: false))
            reader.display(document: document, fileURL: file)

            _ = reader.toggleFold(id: inner.id)
            _ = reader.toggleFold(id: outer.id)
            let maximalOnly = reader.renderedFoldIDs == [outer.id]
            _ = reader.toggleFold(id: outer.id)
            let nestedStatePreserved = reader.logicalFoldIDs == [inner.id]
                && reader.renderedFoldIDs == [inner.id]
            let rulerWithoutNumbersOrDiff = scrollView.hasVerticalRuler
                && reader.diffMarkers.isEmpty

            reader.view.textLayoutManager?.textViewportLayoutController
                .layoutViewport()
            window.displayIfNeeded()
            var providers: [NSTextAttachmentViewProvider] = []
            if let manager = reader.view.textLayoutManager,
               let content = manager.textContentManager
            {
                manager.enumerateTextLayoutFragments(
                    from: content.documentRange.location,
                    options: [.ensuresLayout]
                ) { fragment in
                    providers.append(
                        contentsOf: fragment.textAttachmentViewProviders
                    )
                    return true
                }
            }
            let providerView = providers.first?.view
            let initialSize = providerView?.bounds.size
            reader.setFoldMatchCount(3, for: inner.id)
            let threeSize = providerView?.bounds.size
            reader.setFoldMatchCount(999, for: inner.id)
            let countWidthIsFixed = initialSize != nil
                && initialSize == threeSize
                && threeSize == providerView?.bounds.size
            let lineHeight = reader.view.textLayoutManager?
                .textLayoutFragment(for: .zero)?.layoutFragmentFrame.height ?? 0
            // The 22pt chip target intentionally overhangs the text line.
            let attachmentFitsLine = (providerView?.bounds.height ?? .infinity)
                <= max(lineHeight, 22)
            let axReadable = providerView?.accessibilityLabel()?
                .contains(localizedFormat("reader.collapsed.lines", Int64(inner.summary.hiddenLineCount))) == true
            let providerYieldsHitTesting = providerView.map {
                $0.hitTest(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY)) == nil
            } ?? false
            let placeholder = (reader.view.string as NSString).range(of: "\u{FFFC}")
            let placeholderIsOneUTF16 = placeholder.location != NSNotFound
                && placeholder.length == 1
            let viewportSkipsPlaceholder = reader.displayMap?
                .visibleSourceRanges(forDisplay: placeholder) == []

            reader.display(
                document: document,
                fileURL: URL(fileURLWithPath: "/other-fold-self-test.rs")
            )
            let newPairStartsEmpty = reader.logicalFoldIDs.isEmpty
            reader.display(document: document, fileURL: file)
            let oldPairReturns = reader.logicalFoldIDs == [inner.id]

            if let offset = reader.displayMap?.placeholderOffset(for: inner.id) {
                reader.activate(atCharacterIndex: offset)
            }
            let attachmentActivationExpands = !reader.renderedFoldIDs.contains(
                inner.id
            )
            withExtendedLifetime(window) {}
            return [
                "fixtureFoldsExist": true,
                "maximalRenderedOnly": maximalOnly,
                "nestedLogicalStatePreserved": nestedStatePreserved,
                "pairIsolationStartsEmpty": newPairStartsEmpty,
                "oldPairOverridesReturn": oldPairReturns,
                "attachmentProviderCreated": providers.count == 1,
                "attachmentCountWidthFixed": countWidthIsFixed,
                "attachmentFitsLineHeight": attachmentFitsLine,
                "attachmentAXReadable": axReadable,
                "attachmentYieldsHitTesting": providerYieldsHitTesting,
                "attachmentActivationExpands": attachmentActivationExpands,
                "singleUTF16Placeholder": placeholderIsOneUTF16,
                "viewportSkipsPlaceholder": viewportSkipsPlaceholder,
                "rulerVisibleForFoldingOnly": rulerWithoutNumbersOrDiff,
            ]
        } catch {
            return ["foldSelfTestThrew": false]
        }
    }

    public func display(document: ReaderDocument) {
        display(document: document, fileURL: nil)
    }

    package func display(document: ReaderDocument, fileURL: URL) {
        display(document: document, fileURL: Optional(fileURL))
    }

    private func display(document: ReaderDocument, fileURL: URL?) {
        guard document.foldTopology != nil else { return }
        readerWorkStopped = false
        paragraphLayout.reset()
        let scope = FoldScopeKey(
            file: (fileURL ?? URL(fileURLWithPath: "/__codeinsight_memory__"))
                .standardizedFileURL,
            contentID: document.contentID
        )
        activeFoldScope = scope
        baselineFoldIDs = ReadingPlan.baselineFoldIDs(
            for: readingHeightLevel,
            in: document.foldRegions
        )
        let overrides = foldOverridesByScope[scope] ?? FoldOverrides()
        foldOverridesByScope[scope] = overrides
        logicalFoldIDs = ReadingPlan.logicalFoldIDs(
            overrides: overrides,
            baseline: baselineFoldIDs
        )
        renderedFoldIDs = ReadingPlan.maximalFoldIDs(
            logicalFoldIDs,
            in: document
        )
        guard
            let projection = Self.project(
                document: document,
                renderedFoldIDs: renderedFoldIDs,
                attributes: baseAttributes,
                theme: theme
            ),
            let layoutManager = view.textLayoutManager
        else { return }

        isCommittingProjection = true
        layoutManager.renderingAttributesValidator = nil
        displayMap = projection.map
        foldAttachments = projection.attachments
        displayedDocument = document
        pendingOccurrenceActivation = nil
        prepareIdentifiers(for: document)
        diffMarkers = [:]
        bookmarkMarkers = [:]
        bracketMatch = nil
        caretByteOffset = nil
        blockEndAnnotations = BlockEndAnnotations.compute(for: document)
        drawnBlockEndAnnotations = []
        refreshVisibleFoldRegions()
        declarationKindsByLine = Self.declarationKindsByLine(in: document)
        occurrenceSelectionByteOffset = nil
        findMatchByteRanges = nil
        findSelectionIndex = nil
        primarySelectionRange = nil
        view.selectedTextAttributes = nativeSelectedTextAttributes
        currentLineNumber = nil
        occurrenceCount = 0
        visibleLineNumbers = []
        visibleCurrentLineNumbers = []
        visibleDeclarationMarkerLines = []
        projectionSelectionUsesPrimaryStyle = false
        latentProjectionSelection = nil
        latentSelectionAnchor = nil
        latentViewportAnchor = nil
        foldGutterHoveredID = nil
        navigationLandingLine = nil
        navigationMarkerGeneration += 1
        // New content: any pending reflow restore and its corrections die
        // here (D3.6), and display offsets from the old projection are
        // void (D3.1).
        projectionRevision += 1
        viewportStateGeneration += 1
        invalidateReflowSequence()
        widthReflowCapturedState = nil
        refreshFoldExposures(in: document)
        renderingCoordinator.setOccurrences([])
        ruler?.needsDisplay = true
        renderingCoordinator.update(
            document: document,
            map: projection.map,
            theme: theme
        )
        updateRulerThickness()
        if let scrollView = view.enclosingScrollView ?? scrollView {
            configureGutter(in: scrollView, lineNumbers: lineNumbers)
        }
        installProjectedText(projection.attributed)
        isCommittingProjection = false
        installRenderingValidator(in: layoutManager)
        if renderingCoordinator.hasRenderingAttributes {
            validateVisibleRenderingAttributes(in: layoutManager)
        }
    }

    public func clear() {
        isCommittingProjection = true
        defer { isCommittingProjection = false }
        cancelDerivedDataSubscription()
        paragraphLayout.reset()
        if let focusState {
            readingHeightLevel = focusState.readingHeightLevel
            foldOverridesByScope = focusState.foldOverridesByScope
            self.focusState = nil
        }
        view.textLayoutManager?.renderingAttributesValidator = nil
        displayedDocument = nil
        displayMap = nil
        activeFoldScope = nil
        baselineFoldIDs = []
        logicalFoldIDs = []
        renderedFoldIDs = []
        foldAttachments = [:]
        visibleFoldRegionsCache = []
        renderedFoldRegionsCache = []
        visibleFoldsByLine = [:]
        foldedDiffCache = [:]
        foldedDiffByLine = [:]
        visibleBookmarksByLine = [:]
        projectionSelectionUsesPrimaryStyle = false
        latentProjectionSelection = nil
        latentSelectionAnchor = nil
        latentViewportAnchor = nil
        foldGutterHoveredID = nil
        navigationLandingLine = nil
        navigationMarkerGeneration += 1
        projectionRevision += 1
        viewportStateGeneration += 1
        invalidateReflowSequence()
        widthReflowCapturedState = nil
        diffMarkers = [:]
        bookmarkMarkers = [:]
        declarationKindsByLine = [:]
        occurrenceSelectionByteOffset = nil
        findMatchByteRanges = nil
        findSelectionIndex = nil
        primarySelectionRange = nil
        view.selectedTextAttributes = nativeSelectedTextAttributes
        currentLineNumber = nil
        occurrenceCount = 0
        visibleLineNumbers = []
        visibleCurrentLineNumbers = []
        visibleDeclarationMarkerLines = []
        renderingCoordinator.clear()
        installProjectedText(NSAttributedString(string: ""))
        if let scrollView = view.enclosingScrollView ?? scrollView {
            configureGutter(in: scrollView, lineNumbers: lineNumbers)
        }
        updateRulerThickness()
        ruler?.needsDisplay = true
        view.needsDisplay = true
    }

    @discardableResult
    internal func toggleFold(id: FoldID) -> Bool {
        guard !isFocusMode,
              let document = displayedDocument,
              document.foldTopology?.region(for: id) != nil
        else { return false }
        let shouldFold = !logicalFoldIDs.contains(id)
        return applyFoldMutation { overrides in
            ReadingPlan.setFold(
                id,
                folded: shouldFold,
                baseline: baselineFoldIDs,
                overrides: &overrides
            )
        }
    }

    @discardableResult
    package func toggleFold(
        atLine line: Int,
        recursiveSiblings: Bool = false
    ) -> Bool {
        guard !isFocusMode,
              let document = displayedDocument,
              let region = visibleFoldsByLine[line]
        else { return false }
        guard recursiveSiblings else { return toggleFold(id: region.id) }

        let shouldFold = !logicalFoldIDs.contains(region.id)
        let affected = document.foldTopology?.recursiveSiblings(of: region.id) ?? []
        return applyFoldMutation { overrides in
            for id in affected {
                ReadingPlan.setFold(
                    id,
                    folded: shouldFold,
                    baseline: baselineFoldIDs,
                    overrides: &overrides
                )
            }
        }
    }

    package func canToggleFold(atLine line: Int) -> Bool {
        guard !isFocusMode, let document = displayedDocument else { return false }
        return visibleFoldRegions(in: document).contains {
            document.lineTable.lineColumn(at: $0.headerRange.lowerBound)
                .map { Int($0.line) == line } ?? false
        }
    }

    internal var renderedFoldIDsForTesting: Set<FoldID> { renderedFoldIDs }
    internal var logicalFoldIDsForTesting: Set<FoldID> { logicalFoldIDs }
    internal func foldOverrideMembershipForTesting(
        _ id: FoldID
    ) -> (forcedFolded: Bool, forcedUnfolded: Bool) {
        guard let scope = activeFoldScope,
              let overrides = foldOverridesByScope[scope]
        else { return (false, false) }
        return (
            overrides.forcedFolded.contains(id),
            overrides.forcedUnfolded.contains(id)
        )
    }
    internal var foldOverridesAreDisjointForTesting: Bool {
        foldOverridesByScope.values.allSatisfy {
            $0.forcedFolded.isDisjoint(with: $0.forcedUnfolded)
        }
    }
    package var isFocusMode: Bool { focusState != nil }
    internal var focusedFoldIDForTesting: FoldID? {
        focusState?.focusedFoldID
    }
    internal var focusFollowsExplicitNavigationForTesting: Bool {
        focusState?.followsExplicitNavigation ?? false
    }
    internal var latentSelectionAnchorForTesting: (UInt32, FoldID)? {
        latentSelectionAnchor.map { ($0.byteOffset, $0.foldID) }
    }
    internal var latentViewportAnchorForTesting: (UInt32, FoldID)? {
        latentViewportAnchor.map { ($0.byteOffset, $0.foldID) }
    }
    internal var visibleFoldHandleLinesForTesting: [Int] {
        guard let document = displayedDocument else { return [] }
        return visibleFoldRegions(in: document).compactMap {
            document.lineTable.lineColumn(at: $0.headerRange.lowerBound)
                .map { Int($0.line) }
        }
    }
    internal var navigationLandingLineForTesting: Int? {
        navigationLandingLine
    }
    internal func foldExposureTextForTesting(_ id: FoldID) -> String? {
        foldAttachments[id]?.visualExposureText
    }
    internal var foldedDiffMarkersForTesting: [Int: DiffCore.MarkerKind] {
        foldedDiffByLine
    }

    @discardableResult
    package func focusCurrentScope(at byteOffset: UInt32) -> Bool {
        guard focusState == nil,
              let document = displayedDocument,
              let target = ReadingPlan.focusTarget(at: byteOffset, in: document)
        else { return false }
        let saved = FocusState(
            readingHeightLevel: readingHeightLevel,
            foldOverridesByScope: foldOverridesByScope,
            focusedFoldID: target.region.id,
            byteOffset: byteOffset
        )
        guard applyFoldProjection(
            ReadingPlan.focusFoldIDs(around: target.facet, in: document)
        ) else { return false }
        focusState = saved
        return true
    }

    package func scopeHeaderFacets(at byteOffset: UInt32) -> [OutlineFacet] {
        guard let document = displayedDocument else { return [] }
        let facets = ReadingPlan.enclosingAssociatedFacets(
            at: byteOffset,
            in: document
        )
        guard facets.count > 2,
              let first = facets.first,
              let last = facets.last
        else { return facets }
        return [first, last]
    }

    @discardableResult
    package func exitFocusMode() -> Bool {
        guard let focusState else { return false }
        let restoredBaseline = displayedDocument.map {
            ReadingPlan.baselineFoldIDs(
                for: focusState.readingHeightLevel,
                in: $0.foldRegions
            )
        } ?? []
        let restoredOverrides = activeFoldScope.flatMap {
            focusState.foldOverridesByScope[$0]
        } ?? FoldOverrides()
        let restoredLogical = ReadingPlan.logicalFoldIDs(
            overrides: restoredOverrides,
            baseline: restoredBaseline
        )
        if displayedDocument != nil,
           !applyFoldProjection(restoredLogical)
        {
            return false
        }
        readingHeightLevel = focusState.readingHeightLevel
        foldOverridesByScope = focusState.foldOverridesByScope
        baselineFoldIDs = restoredBaseline
        self.focusState = nil
        return true
    }

    @discardableResult
    package func followFocusForExplicitNavigation(
        to byteOffset: UInt32
    ) -> Bool {
        guard var focusState, let document = displayedDocument else {
            return false
        }
        guard let target = ReadingPlan.focusTarget(at: byteOffset, in: document) else {
            _ = exitFocusMode()
            return false
        }
        guard applyFoldProjection(
            ReadingPlan.focusFoldIDs(around: target.facet, in: document)
        ) else { return false }
        markNavigationLanding(at: byteOffset)
        focusState.followsExplicitNavigation = true
        focusState.focusedFoldID = target.region.id
        focusState.byteOffset = byteOffset
        self.focusState = focusState
        return true
    }

    package func didLiveScrollWhileFocused() {
        focusState?.followsExplicitNavigation = false
    }

    @discardableResult
    package func setReadingHeightLevel(_ level: ReadingHeightLevel) -> Bool {
        if isFocusMode { _ = exitFocusMode() }
        guard level != readingHeightLevel else { return false }
        let previousLevel = readingHeightLevel
        let previousOverrides = foldOverridesByScope
        let previousBaseline = baselineFoldIDs
        readingHeightLevel = level
        foldOverridesByScope.removeAll(keepingCapacity: true)
        baselineFoldIDs =
            displayedDocument.map {
                ReadingPlan.baselineFoldIDs(for: level, in: $0.foldRegions)
            } ?? []

        guard displayedDocument != nil else { return true }
        guard applyFoldMutation({ $0 = FoldOverrides() }) else {
            readingHeightLevel = previousLevel
            foldOverridesByScope = previousOverrides
            baselineFoldIDs = previousBaseline
            return false
        }
        return true
    }

    internal func setFoldMatchCount(_ count: Int, for id: FoldID) {
        foldAttachments[id]?.setMatchCount(max(0, count))
    }

    package func applyFoldPerformanceOverview() -> (
        logical: Int,
        rendered: Int
    )? {
        guard displayedDocument != nil else { return nil }
        guard
            readingHeightLevel == .overview
                ? applyFoldMutation({ _ in })
                : setReadingHeightLevel(.overview)
        else { return nil }
        return (logicalFoldIDs.count, renderedFoldIDs.count)
    }

    package var foldPerformanceCounts: (logical: Int, rendered: Int) {
        (logicalFoldIDs.count, renderedFoldIDs.count)
    }

    package var foldPerformanceEffectiveSettings: (
        lineNumbers: Bool,
        theme: ReaderSettings.Theme
    ) {
        (lineNumbers, theme.selection)
    }

    @discardableResult
    private func unfoldAncestors(containing byteOffset: UInt32) -> Bool {
        guard !isFocusMode, let document = displayedDocument else { return false }
        let containing = document.foldTopology?.containing(byteOffset) ?? []
        let ancestors = containing.filter { logicalFoldIDs.contains($0.id) }
        guard !ancestors.isEmpty else { return false }
        let unfolded = applyFoldMutation { overrides in
            for region in ancestors {
                ReadingPlan.setFold(
                    region.id,
                    folded: false,
                    baseline: baselineFoldIDs,
                    overrides: &overrides
                )
            }
        }
        if unfolded { markNavigationLanding(at: byteOffset) }
        return unfolded
    }

    private func markNavigationLanding(at byteOffset: UInt32) {
        guard let line = displayedDocument?.lineTable.lineColumn(
            at: byteOffset
        )?.line else { return }
        navigationMarkerGeneration += 1
        let generation = navigationMarkerGeneration
        navigationLandingLine = Int(line)
        if let scrollView = view.enclosingScrollView ?? scrollView {
            configureGutter(in: scrollView, lineNumbers: lineNumbers)
        }
        updateRulerThickness()
        ruler?.needsDisplay = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self,
                  navigationMarkerGeneration == generation
            else { return }
            navigationLandingLine = nil
            if let scrollView = view.enclosingScrollView ?? scrollView {
                configureGutter(in: scrollView, lineNumbers: lineNumbers)
            }
            updateRulerThickness()
            ruler?.needsDisplay = true
        }
    }

    private func applyFoldMutation(
        _ mutate: (inout FoldOverrides) -> Void
    ) -> Bool {
        guard !isFocusMode,
              let scope = activeFoldScope
        else { return false }

        var overrides = foldOverridesByScope[scope] ?? FoldOverrides()
        mutate(&overrides)
        let logical = ReadingPlan.logicalFoldIDs(
            overrides: overrides,
            baseline: baselineFoldIDs
        )
        guard applyFoldProjection(logical) else { return false }
        foldOverridesByScope[scope] = overrides
        return true
    }

    private func applyFoldProjection(_ logical: Set<FoldID>) -> Bool {
        guard !isCommittingProjection, let document = displayedDocument, let oldMap = displayMap,
              let manager = view.textLayoutManager else { return false }
        projectionCommitRejectionReason = nil
        let oldRevision = projectionRevision
        let oldAnalysisKey = document.analysisKey
        let oldTheme = theme
        let oldTypographyKey = typographyKey
        let oldEnvironmentRevision = fontEnvironmentRevision
        func targetIsCurrent() -> Bool {
            displayedDocument === document
                && displayedDocument?.analysisKey == oldAnalysisKey
                && displayMap?.projection.identity == oldMap.projection.identity
                && projectionRevision == oldRevision
                && theme == oldTheme && typographyKey == oldTypographyKey
                && fontEnvironmentRevision == oldEnvironmentRevision
        }
        let rendered = ReadingPlan.maximalFoldIDs(logical, in: document)
        // Logical child overrides may change while hidden by the same ancestor.
        if rendered == renderedFoldIDs {
            logicalFoldIDs = logical
            return true
        }
        guard let target = DisplayMap(document: document, renderedFoldIDs: rendered) else {
            projectionCommitRejectionReason = "invalid-target"
            projectionRejectedCount += 1
            return false
        }
        let selections = captureProjectionSelections()
        let affinity = view.selectionAffinity
        let viewport = latentViewportAnchor.flatMap {
            renderedFoldIDs.contains($0.foldID) ? $0.byteOffset : nil
        } ?? firstVisibleByteOffset()

        var replacements: [(range: NSRange, targetRange: NSRange, text: NSMutableAttributedString)] = []
        var attachments = foldAttachments.filter { rendered.contains($0.key) }
        var fallback: (attributed: NSMutableAttributedString, attachments: [FoldID: FoldAttachment])?
        var reason: String?
        if !localProjectionUpdatesEnabled { reason = "disabled" }
        else if forceProjectionPreflightFailureForTesting { reason = "forced-preflight" }
        else if let delta = ProjectionDelta(old: oldMap.projection, new: target.projection),
                delta.isApplicable(current: oldMap.projection, target: target.projection,
                    storageUTF16Length: backingTextStorage.length) {
            for patch in delta.patches {
                guard oldMap.sourceRanges(forDisplay: patch.oldDisplayRange) != nil,
                      target.sourceRanges(forDisplay: patch.newDisplayRange) != nil,
                      let piece = Self.materializeProjection(document: document, map: target,
                          attributes: baseAttributes, theme: theme, displayRange: patch.newDisplayRange),
                      piece.attributed.length == patch.newDisplayRange.length
                else { reason = "invalid-replacement"; break }
                guard let targetPlaceholders = target.foldPlaceholders(in: patch.newDisplayRange) else {
                    reason = "invalid-placeholder-range"; break
                }
                for placeholder in targetPlaceholders {
                    let local = placeholder.offset - patch.newDisplayRange.location
                    guard piece.attributed.mutableString.character(at: local) == 0xFFFC,
                          (piece.attributed.attribute(.attachment, at: local, effectiveRange: nil) as? FoldAttachment) === piece.attachments[placeholder.id] else {
                        reason = "new-attachment-mismatch"; break
                    }
                }
                if reason != nil { break }
                attachments.merge(piece.attachments) { _, new in new }
                replacements.append((patch.oldDisplayRange, patch.newDisplayRange, piece.attributed))
            }
            // Unchanged attachments remain in storage. TextKit's opaque
            // locations relocate surviving providers; invalidated fragments
            // create new providers. Only current fragment providers are used.
        } else { reason = "invalid-delta" }

        let preflightHook = projectionPreflightHookForTesting
        projectionPreflightHookForTesting = nil
        preflightHook?()
        // A stale intent is rejected, never "recovered" by installing its old
        // target over the user's new document, analysis, projection or settings.
        guard targetIsCurrent() else {
            projectionCommitRejectionReason = "stale-target"
            projectionRejectedCount += 1
            return false
        }
        if backingTextStorage.length != oldMap.projectedUTF16Length {
            reason = "storage-length-mismatch"
        }
        if reason == nil {
            for replacement in replacements {
                guard let oldPlaceholders = oldMap.foldPlaceholders(in: replacement.range) else {
                    reason = "invalid-placeholder-range"; break
                }
                for placeholder in oldPlaceholders {
                    if (backingTextStorage.attribute(.attachment, at: placeholder.offset, effectiveRange: nil) as? FoldAttachment)
                        !== foldAttachments[placeholder.id] {
                        reason = "old-attachment-mismatch"
                        break
                    }
                }
                if reason != nil { break }
            }
        }
        if reason != nil {
            guard let full = Self.materializeProjection(document: document, map: target,
                attributes: baseAttributes, theme: theme) else {
                projectionCommitRejectionReason = "invalid-target-materialization"
                projectionRejectedCount += 1
                return false
            }
            fallback = full
            attachments = full.attachments
        }
        // Full recovery also has to pass the identity guard after preparation.
        guard targetIsCurrent() else {
            projectionCommitRejectionReason = "stale-target"
            projectionRejectedCount += 1
            return false
        }
        projectionFallbackReason = reason
        if fallback != nil { projectionFallbackCount += 1 }

        projectionRevision += 1
        invalidateReflowSequence()
        widthReflowCapturedState = nil
        let wasRestoring = isRestoringViewport
        isRestoringViewport = true
        isCommittingProjection = true
        manager.renderingAttributesValidator = nil
        let commit = {
            self.backingTextStorage.beginEditing()
            if let fallback {
                // The target map is needed by paragraph source metadata, but
                // external mapping callbacks stay blocked until the commit ends.
                self.displayMap = target
                self.lastParagraphIndentLimit = nil
                self.projectionInstallCount += 1
                ReaderWorkCounters.record(\.fullTextReplacementCount)
                ReaderWorkCounters.record(\.replacedUTF16Units, self.backingTextStorage.length)
                if self.wrapLines { self.applyParagraphLayout(to: fallback.attributed) }
                self.backingTextStorage.setAttributedString(fallback.attributed)
            } else {
                for replacement in replacements.reversed() {
                    ReaderWorkCounters.record(\.partialTextReplacementCount)
                    ReaderWorkCounters.record(\.replacedUTF16Units, replacement.range.length)
                    self.backingTextStorage.replaceCharacters(in: replacement.range, with: replacement.text)
                }
                self.displayMap = target
                // Every patch carries final coordinates. Only its paragraphs
                // and their join neighbors may need indentation recomputation.
                for replacement in replacements {
                    self.applyParagraphLayout(to: self.backingTextStorage, in: replacement.targetRange)
                }
                self.partialProjectionCommitCount += 1
            }
            self.logicalFoldIDs = logical
            self.renderedFoldIDs = rendered
            self.foldAttachments = attachments
            self.backingTextStorage.endEditing()
        }
        if let content = view.textContentStorage { content.performEditingTransaction(commit) }
        else { commit() }
        isCommittingProjection = false

        refreshVisibleFoldRegions()
        renderingCoordinator.update(document: document, map: target, theme: theme)
        restoreProjectionSelections(selections, affinity: affinity)
        refreshOccurrenceRendering(in: document, updateLayout: false)
        installRenderingValidator(in: manager)
        restoreViewportAnchor(viewport, in: document)
        if let scroll = view.enclosingScrollView ?? scrollView {
            configureGutter(in: scroll, lineNumbers: lineNumbers)
        }
        updateBookmarkAccessibilityLabel()
        ruler?.needsDisplay = true
        validateVisibleRenderingAttributes(in: manager)
        isRestoringViewport = wasRestoring
        view.needsDisplay = true
        onViewportChange?()
        return true
    }

    /// Installs a freshly projected attributed string into the backing
    /// storage inside one editing transaction. Every wrap reflow goes through
    /// this seam so the perf probe can count projection commits (§7.4.2).
    private func installProjectedText(_ attributed: NSAttributedString) {
        lastParagraphIndentLimit = nil
        projectionInstallCount += 1
        ReaderWorkCounters.record(\.fullTextReplacementCount)
        ReaderWorkCounters.record(\.replacedUTF16Units, backingTextStorage.length)
        let attributed = (attributed as? NSMutableAttributedString)
            ?? NSMutableAttributedString(attributedString: attributed)
        // Fresh projections already have the unwrapped base paragraph style.
        if wrapLines { applyParagraphLayout(to: attributed) }
        if let contentStorage = view.textContentStorage {
            contentStorage.performEditingTransaction {
                backingTextStorage.beginEditing()
                backingTextStorage.setAttributedString(attributed)
                backingTextStorage.endEditing()
            }
        } else {
            backingTextStorage.setAttributedString(attributed)
        }
    }

    private func sourceAnchor(
        atDisplayOffset offset: Int,
        latent: LatentFoldAnchor?
    ) -> UInt32? {
        guard let position = displayMap?.sourcePosition(ofDisplay: offset) else {
            return nil
        }
        switch position {
        case .source(let byteOffset):
            return byteOffset
        case .placeholder(let foldID):
            if latent?.foldID == foldID { return latent?.byteOffset }
            return displayedDocument?.foldTopology?.region(for: foldID)?
                .bodyRange.lowerBound
        }
    }

    private func clearProjectionSelection() {
        latentProjectionSelection = nil
        projectionSelectionUsesPrimaryStyle = false
        latentSelectionAnchor = nil
    }

    private func captureProjectionSelections() -> [ByteRange] {
        let actual = view.selectedRanges.map(\.rangeValue)
        if let latent = latentProjectionSelection, latent.displayRanges == actual {
            return latent.sourceRanges
        }
        let usesPrimaryStyle = primarySelectionRange != nil
        clearProjectionSelection()
        projectionSelectionUsesPrimaryStyle = usesPrimaryStyle
        guard let map = displayMap else { return [] }
        return actual.compactMap { range in
            if range.length == 0 {
                guard let byte = sourceAnchor(atDisplayOffset: range.location, latent: nil) else { return nil }
                return ByteRange(lowerBound: byte, upperBound: byte)
            }
            guard let ranges = map.sourceRanges(forDisplay: range),
                  let first = ranges.first, let last = ranges.last else { return nil }
            return ByteRange(lowerBound: first.lowerBound, upperBound: last.upperBound)
        }
    }

    private func projectedSelection(_ source: ByteRange) -> NSRange? {
        guard let map = displayMap else { return nil }
        func offset(_ byte: UInt32, upper: Bool) -> Int? {
            switch map.displayPosition(ofByte: byte) {
            case .visible(let offset): return offset
            case .hidden(let id):
                guard let body = displayedDocument?.foldTopology?.region(for: id)?.bodyRange else { return nil }
                // A half-open upper endpoint exactly at the hidden body start
                // excludes that body and must stay before the placeholder.
                let coversHiddenSource = upper && byte > body.lowerBound
                return map.placeholderOffset(for: id).map { $0 + (coversHiddenSource ? 1 : 0) }
            case nil: return nil
            }
        }
        guard let lower = offset(source.lowerBound, upper: false),
              let upper = offset(source.upperBound, upper: source.length > 0), lower <= upper else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    private func restoreProjectionSelections(_ sources: [ByteRange], affinity: NSSelectionAffinity) {
        let ranges = sources.compactMap(projectedSelection)
        guard ranges.count == sources.count, !ranges.isEmpty else { return }
        if let native = view as? ClickTextView {
            native.restoreProjectionRanges(ranges.map(NSValue.init(range:)), affinity: affinity)
        } else {
            view.setSelectedRanges(ranges.map(NSValue.init(range:)), affinity: affinity, stillSelecting: false)
        }
        if projectionSelectionUsesPrimaryStyle,
           let selected = sources.first, sources.count == 1,
           let focused = occurrenceSelectionByteOffset,
           findMatchByteRanges == nil,
           selected.contains(focused),
           case .visible = displayMap?.displayPosition(ofByte: selected.lowerBound),
           case .visible = displayMap?.displayPosition(ofByte: selected.upperBound) {
            primarySelectionRange = view.selectedRange()
        } else {
            primarySelectionRange = nil
        }
        view.selectedTextAttributes = primarySelectionRange == nil
            ? nativeSelectedTextAttributes : [.backgroundColor: NSColor.clear]
        // AppKit may merge several hidden selections into one placeholder.
        // Match its actual normalized ranges, but retain every original endpoint.
        latentProjectionSelection = (sources, view.selectedRanges.map(\.rangeValue))
        latentSelectionAnchor = sources.first.flatMap { first in
            guard case .hidden(let id) = displayMap?.displayPosition(ofByte: first.lowerBound) else { return nil }
            return LatentFoldAnchor(byteOffset: first.lowerBound, foldID: id)
        }
    }

    private func copiedSourceRanges(for ranges: [NSRange]) -> [ByteRange]? {
        if let latent = latentProjectionSelection,
           view.selectedRanges.map(\.rangeValue) == latent.displayRanges,
           ranges == latent.displayRanges {
            return latent.sourceRanges.filter { $0.length > 0 }
        }
        guard let map = displayMap else { return nil }
        var result: [ByteRange] = []
        for range in ranges where range.length > 0 {
            guard let sources = map.sourceRanges(forDisplay: range) else { return nil }
            // A selected placeholder means its entire hidden source range.
            if let first = sources.first, let last = sources.last {
                result.append(ByteRange(lowerBound: first.lowerBound, upperBound: last.upperBound))
            }
        }
        return result
    }

    private func sourceTextForCurrentSelections() -> String? {
        guard !isCommittingProjection, let document = displayedDocument,
              let ranges = copiedSourceRanges(for: view.selectedRanges.map(\.rangeValue)),
              !ranges.isEmpty else { return nil }
        return ranges.map {
            String(decoding: document.bytes[Int($0.lowerBound)..<Int($0.upperBound)], as: UTF8.self)
        }.joined()
    }

    private func restoreViewportAnchor(
        _ byteOffset: UInt32?,
        in document: ReaderDocument
    ) {
        guard let byteOffset,
              let position = displayMap?.displayPosition(ofByte: byteOffset)
        else { return }
        switch position {
        case .visible:
            restore(scrollByteOffset: byteOffset, selectionByteOffset: nil)
            if latentViewportAnchor?.byteOffset == byteOffset {
                latentViewportAnchor = nil
            }
        case .hidden(let foldID):
            guard let region = document.foldTopology?.region(for: foldID) else { return }
            latentViewportAnchor = LatentFoldAnchor(
                byteOffset: byteOffset,
                foldID: foldID
            )
            restore(
                scrollByteOffset: region.headerRange.lowerBound,
                selectionByteOffset: nil
            )
        }
    }

    // MARK: - Reflow viewport state (reader-wrap design D3)

    /// Synchronous viewport restores force TextKit to materialize layout
    /// state for the width-invalidated document (measured: multi-second
    /// stalls and multi-GB peaks on the 30k-line fixture). Documents this
    /// large keep their selection and settings and let the natural layout
    /// lifecycle own the viewport instead (§8.1: never jump to the top as a
    /// fallback — simply do not fight the lazy layout).
    private func supportsSynchronousViewportRestore(for state: ReaderViewportState) -> Bool {
        guard let document = displayedDocument else { return false }
        if usesCostAwareReflow {
            guard !requiresViewportOnlyLayout else { return false }
        } else if document.lineTable.lineStarts.count > 8_000 { return false }
        let byte: UInt32
        switch state.anchor {
        case .source(let offset): byte = offset
        case .documentStart: byte = 0
        case .documentEnd: byte = UInt32(clamping: document.bytes.count)
        case .foldPlaceholder(let id):
            guard let fold = document.foldTopology?.region(for: id) else { return false }
            byte = fold.bodyRange.lowerBound
        }
        guard let line = document.lineTable.lineColumn(at: byte)?.line else { return true }
        let index = Int(line) - 1
        let starts = document.lineTable.lineStarts
        guard starts.indices.contains(index) else { return false }
        let end = starts.indices.contains(index + 1) ? Int(starts[index + 1]) : document.bytes.count
        // Core Text caret offsets scan a whole shaped line (1.7s at 1.8MB).
        // ponytail: cap synchronous precision at 64KiB; async restore if needed.
        return end - Int(starts[index]) <= (usesCostAwareReflow ? reflowPolicy.maximumSynchronousLineBytes : 64 * 1024)
    }

    /// Ends the current pure-reflow sequence: the next reflow picks a fresh
    /// anchor from the live viewport instead of reusing the saved one.
    /// Called for user scrolling, selection changes, navigation, fold
    /// changes, and content replacement (D3.5/E3). Any not-yet-run
    /// correction passes die too: user interaction always outranks a
    /// pending restore (D3.6).
    private func invalidateReflowSequence() {
        viewportStateGeneration &+= 1
        widthReflowCapturedState = nil
        pendingHorizontalState = nil
        pendingReflowState = nil
        pendingViewportCorrection = nil
        pendingWidthReflowGeneration = nil
        hasScheduledWidthReflow = false
    }

    /// Captures the stable viewport state to carry across a reflow. Within an
    /// active pure-reflow sequence the previously captured anchor and offset
    /// are reused (D3.5) so consecutive toggles cannot drift — re-picking the
    /// 25% row after every toggle would walk a long logical line toward its
    /// start. Selection and horizontal state are always re-read live.
    private func captureViewportStateForReflow(previousViewportWidth: CGFloat? = nil) -> ReaderViewportState? {
        guard let document = displayedDocument, !readerWorkStopped else { return nil }
        // Run before old-state reuse or any native insertion/caret geometry query.
        guard !usesCostAwareReflow || !requiresViewportOnlyLayout else {
            lastViewportRestoreWasLimited = true
            lastViewportAnchorErrorPt = nil
            lastViewportRestoreLimitation = "cost-limited-capture"
            pendingHorizontalState = currentHorizontalState()
            return nil
        }
        // Settings may arrive before queued width work. Preserve the earliest
        // source anchor instead of sampling the intermediate layout again.
        if let pending = pendingReflowState ?? widthReflowCapturedState, pending.contentID == document.contentID {
            var updated = pending
            updated.selectedRanges = currentSelectedRanges()
            updated.selectionAffinity = view.selectionAffinity
            updated.primarySelectionRange = primarySelectionRange
            updated.findSelectionIndex = findSelectionIndex
            updated.currentLineByteOffset = currentLineByteOffset(in: document)
            updated.horizontal = currentHorizontalState()
            return updated
        }
        guard let captured = captureFreshViewportState(for: document, previousViewportWidth: previousViewportWidth) else {
            return nil
        }
        return captured
    }

    private func captureFreshViewportState(
        for document: ReaderDocument,
        previousViewportWidth: CGFloat? = nil
    ) -> ReaderViewportState? {
        guard let manager = view.textLayoutManager,
              let content = manager.textContentManager
        else { return nil }
        var visible = view.visibleRect
        // During a wrapped width hook the clip already has its new width,
        // while character geometry still belongs to the old document-view width.
        // Reuse that old horizontal probe position instead of choosing another source character.
        // visibleRect starts behind the ruler inset, which the wrapped document width excludes.
        if let previousViewportWidth {
            let insets = view.enclosingScrollView?.contentView.contentInsets
            visible.size.width = previousViewportWidth + (insets?.left ?? 0) + (insets?.right ?? 0)
        }
        // Zero-size or unmounted surfaces keep only settings and selection;
        // a stable anchor forms once real geometry exists (D3.2).
        guard visible.height > 1, visible.width > 1 else {
            lastViewportRestoreWasLimited = true
            lastViewportAnchorErrorPt = nil
            lastViewportRestoreLimitation = "zero-geometry"
            pendingHorizontalState = currentHorizontalState()
            return nil
        }

        viewportGeometryCaptureCount += 1
        lastViewportRestoreLimitation = nil
        let anchorYInView = visible.minY + visible.height * 0.25
        // Resolve an actual character at the probe point inside the visible
        // horizontal region, so a horizontally scrolled long line anchors to
        // visible text rather than its line start (D3.2).
        var anchorLocation = view.characterIndexForInsertion(
            at: NSPoint(x: visible.midX, y: anchorYInView)
        )
        if anchorLocation < 0 || anchorLocation > backingTextStorage.length {
            // No glyph at the point (blank area, empty document): fall back
            // to the first row of the fragment at the viewport start.
            let containerOrigin = view.textContainerOrigin
            let probe = NSPoint(
                x: visible.midX - containerOrigin.x,
                y: anchorYInView - containerOrigin.y
            )
            var fragment = manager.textLayoutFragment(for: probe)
            if fragment == nil,
               let viewportRange = manager.textViewportLayoutController.viewportRange
            {
                fragment = manager.textLayoutFragment(for: viewportRange.location)
            }
            anchorLocation = fragment.flatMap { fragment in
                content.offset(
                    from: content.documentRange.location,
                    to: fragment.rangeInElement.location
                ) == NSNotFound
                    ? nil
                    : content.offset(
                        from: content.documentRange.location,
                        to: fragment.rangeInElement.location
                    ) + (fragment.textLineFragments.first?.characterRange.location ?? 0)
            } ?? 0
        }
        if anchorLocation < 0 { anchorLocation = 0 }
        if anchorLocation > backingTextStorage.length {
            anchorLocation = backingTextStorage.length
        }

        var anchor: ReaderViewportState.Anchor = .documentStart
        var anchorRowRect = NSRect.zero
        if anchorLocation > 0 || backingTextStorage.length > 0 {
            anchorRowRect = ReaderViewportGeometry.rowRect(
                containingDisplayLocation: anchorLocation,
                in: view
            ) ?? .zero
            switch displayMap?.sourcePosition(ofDisplay: anchorLocation) {
            case .placeholder(let foldID):
                // A visible fold chip anchors to its placeholder so a pure
                // reflow never expands the fold (D3.2).
                anchor = .foldPlaceholder(foldID)
            case .source(let byteOffset):
                anchor = .source(byteOffset)
            default:
                anchor = .documentStart
            }
        }

        return ReaderViewportState(
            contentID: document.contentID,
            surfaceFileURL: activeFoldScope?.file,
            projectionRevision: projectionRevision,
            anchor: anchor,
            anchorDisplayLocation: anchorLocation,
            offsetFromViewportTop: anchor == .documentStart
                ? 0
                : anchorRowRect.minY - visible.minY,
            selectedRanges: currentSelectedRanges(),
            selectionAffinity: view.selectionAffinity,
            primarySelectionRange: primarySelectionRange,
            findSelectionIndex: findSelectionIndex,
            currentLineByteOffset: currentLineByteOffset(in: document),
            horizontal: currentHorizontalState()
        )
    }

    private func currentLineByteOffset(in document: ReaderDocument) -> UInt32? {
        guard let currentLineNumber,
              document.lineTable.lineStarts.indices.contains(currentLineNumber - 1)
        else { return nil }
        return document.lineTable.lineStarts[currentLineNumber - 1]
    }


    private func currentSelectedRanges() -> [NSRange] {
        view.selectedRanges.compactMap(\.rangeValue)
    }

    private func currentHorizontalState() -> ReaderViewportState.HorizontalState {
        let originX = view.enclosingScrollView?.contentView.bounds.minX ?? 0
        let stash = pendingReflowState?.horizontal.stashedUnwrappedX
            ?? pendingHorizontalState?.stashedUnwrappedX
            ?? (wrapLines ? nil : originX)
        return ReaderViewportState.HorizontalState(
            clipOriginX: originX,
            stashedUnwrappedX: stash
        )
    }

    /// Resolves a captured anchor to a display location under the CURRENT
    /// projection. Folded-away sources resolve to their chip placeholder.
    private func anchorDisplayLocation(
        for anchor: ReaderViewportState.Anchor,
        in document: ReaderDocument
    ) -> Int? {
        switch anchor {
        case .source(let byteOffset):
            switch displayMap?.displayPosition(ofByte: byteOffset) {
            case .visible(let offset):
                return offset
            case .hidden(let foldID):
                return displayMap?.placeholderOffset(for: foldID)
            case nil:
                return nil
            }
        case .foldPlaceholder(let foldID):
            return displayMap?.placeholderOffset(for: foldID)
        case .documentStart:
            return 0
        case .documentEnd:
            return displayMap.map { max(0, $0.projectedUTF16Length) }
        }
    }

    /// Restores selection, viewport anchor, and horizontal position captured
    /// before a reflow (D3.3–D3.5). A state from another projection or
    /// content is rejected outright: stale display ranges never apply to a
    /// new projection (D3.4).
    private func restoreViewportState(_ state: ReaderViewportState) {
        guard let document = displayedDocument,
              document.contentID == state.contentID,
              state.projectionRevision == projectionRevision
        else { return }
        restoreSelection(from: state)
        lastViewportRestoreWasLimited = !supportsSynchronousViewportRestore(for: state)
        if lastViewportRestoreWasLimited {
            lastViewportAnchorErrorPt = nil
            restoreHorizontalPosition(from: state, anchorGeometry: nil)
            return
        }
        let anchorGeometry = placeViewportAnchor(from: state, in: document)
        restoreHorizontalPosition(from: state, anchorGeometry: anchorGeometry)
    }

    private func restoreSelection(from state: ReaderViewportState) {
        let storageLength = backingTextStorage.length
        // Same projection → the captured display ranges address exactly the
        // same characters; restore the complete selection as-is (D3.4).
        let ranges = state.selectedRanges.filter {
            $0.location >= 0 && NSMaxRange($0) <= storageLength
        }
        let restoredRanges = ranges.map { NSValue(range: $0) }
        // Reassigning an unchanged selection resets AppKit's Shift-extension
        // anchor, even when affinity is identical (notably reverse selections).
        if !ranges.isEmpty,
           view.selectedRanges != restoredRanges || view.selectionAffinity != state.selectionAffinity {
            view.setSelectedRanges(
                restoredRanges,
                affinity: state.selectionAffinity,
                stillSelecting: false
            )
        }
        if let primary = state.primarySelectionRange,
           primary.location >= 0, NSMaxRange(primary) <= storageLength
        {
            primarySelectionRange = primary
            view.selectedTextAttributes = [.backgroundColor: NSColor.clear]
        }
        // The current-line marker follows its captured source line, not the
        // restored caret: it may have been set by reveal/navigation without
        // a selection (D3.4 final state merge).
        if let lineByteOffset = state.currentLineByteOffset {
            updateCurrentLine(byteOffset: lineByteOffset)
        }
    }

    /// Anchor row geometry validated against the CURRENT container state.
    /// After a wrap toggle, TextKit can keep serving fragments from the
    /// previous layout until its next pass; restoring against them moves
    /// the viewport with old coordinates (D3.6). Unwrapped paragraphs may
    /// have explicit hard breaks and an extra empty row, but no soft breaks.
    /// Unbreakable single rows wider
    /// than the container (fixture F3) are legitimate and accepted.
    private func freshAnchorRowRect(
        containingDisplayLocation location: Int
    ) -> NSRect? {
        guard let rowRect = ReaderViewportGeometry.rowRect(
            containingDisplayLocation: location,
            in: view
        ), let fragment = ReaderViewportGeometry.fragment(
            containingDisplayLocation: location, in: view
        )
        else { return nil }
        // A same-width font change can leave old fragments alive for one pass.
        // Compare the anchor's own role attributes, not the global body font.
        if location < backingTextStorage.length,
           let content = view.textLayoutManager?.textContentManager {
            let start = content.offset(from: content.documentRange.location,
                to: fragment.rangeInElement.location)
            let local = location - start
            guard let line = fragment.textLineFragments.first(where: {
                NSLocationInRange(local, $0.characterRange)
            }), local >= 0, local < line.attributedString.length else { return nil }
            for key in [NSAttributedString.Key.font, .ligature, .kern] {
                let laid = line.attributedString.attribute(key, at: local, effectiveRange: nil) as? NSObject
                let current = backingTextStorage.attribute(key, at: location, effectiveRange: nil) as? NSObject
                guard laid == current else { return nil }
            }
        }
        // Empty extra rows and explicit Unicode line separators remain legal
        // unwrapped. Only soft line breaks indicate stale wrapped geometry.
        if !wrapLines {
            let rows = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            for row in rows.dropLast() {
                let string = row.attributedString.string as NSString
                let end = NSMaxRange(row.characterRange)
                guard end > 0, end <= string.length,
                      let scalar = UnicodeScalar(string.character(at: end - 1)),
                      CharacterSet.newlines.contains(scalar) else { return nil }
            }
        }
        return rowRect
    }

    /// Places the anchor's visual row at the captured offset from the
    /// viewport top (D3.3): `newScrollY = newAnchorY - savedOffset`, clamped
    /// to the clip view's legal range. Returns the anchor's row rect (for
    /// vertical bookkeeping) and the anchor character's own rect in text
    /// view coordinates; the character rect, not the row rect, drives the
    /// horizontal visibility nudge — an unwrapped row can span many
    /// viewport widths.
    @discardableResult
    private func placeViewportAnchor(
        from state: ReaderViewportState,
        in document: ReaderDocument
    ) -> (rowRect: NSRect, characterRect: NSRect)? {
        guard let scrollView = view.enclosingScrollView,
              let location = anchorDisplayLocation(
                  for: state.anchor,
                  in: document
              )
        else { return nil }
        // Lay the visible region first: after a container-width change every
        // fragment is invalidated, and querying one directly then forces
        // TextKit to resolve the whole invalidated chain (seconds on the
        // 30k-line fixture). layoutViewport re-lays the viewport cheaply, so
        // the measurement below hits laid fragments. This uses no navigation
        // path: it never expands folds, records history, or shows find
        // indicators (D3.3).
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        if supportsSynchronousViewportRestore(for: state),
           freshAnchorRowRect(containingDisplayLocation: location) == nil,
           let manager = view.textLayoutManager,
           let content = manager.textContentManager {
            // A larger font or new wrapping can move the anchor outside the
            // old viewport. Materialize that character's layout on ordinary
            // files; viewport-only passes cannot discover its new position.
            let string = backingTextStorage.mutableString
            let query = location < string.length
                ? string.rangeOfComposedCharacterSequence(at: location)
                : NSRange(location: location, length: 0)
            if let start = content.location(content.documentRange.location, offsetBy: query.location),
               let end = content.location(start, offsetBy: query.length),
               let range = NSTextRange(location: start, end: end) {
                manager.ensureLayout(for: range)
            }
        }
        guard let rowRect = freshAnchorRowRect(containingDisplayLocation: location),
              rowRect.height > 0 else {
            // Stale or unavailable geometry (container flips leave the old
            // fragments until AppKit relayouts): skip the synchronous
            // placement and let the bounded correction passes take over
            // once the layout settles (D3.6).
            return nil
        }
        var characterRect = rowRect
        if !wrapLines, rowRect.width > 0, let segment = ReaderViewportGeometry.characterRect(
            displayLocation: location,
            in: view
        ) {
            characterRect = segment
        }
        lastViewportRestoreWasLimited = false
        lastViewportRestoreLimitation = nil
        let clipView = scrollView.contentView
        let desiredOriginY = rowRect.minY - state.offsetFromViewportTop
        let clamped = clampVerticalScrollOrigin(desiredOriginY, clipView: clipView)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: clamped))
        scrollView.reflectScrolledClipView(clipView)
        if let achieved = ReaderViewportGeometry.rowRect(
            containingDisplayLocation: location,
            in: view
        ) {
            lastViewportAnchorErrorPt = abs(
                clipView.bounds.minY + state.offsetFromViewportTop - achieved.minY
            )
        }
        return (rowRect, characterRect)
    }

    private func clampVerticalScrollOrigin(_ y: CGFloat, clipView: NSClipView) -> CGFloat {
        let insets = clipView.contentInsets
        let minY = -insets.top
        // Documents shorter than the viewport pin to the top; the clamp is
        // a legal-range correction, not a drift excuse (D3.3/W17).
        let maxY = max(minY, view.frame.height - clipView.bounds.height + insets.bottom)
        return min(max(y, minY), maxY)
    }

    /// Horizontal position across wrap toggles (D3.5): on → off prefers the
    /// stashed unwrapped x (nudged minimally if the anchor would leave the
    /// viewport); off → on scrolls to the legal start and keeps the stash.
    private func restoreHorizontalPosition(
        from state: ReaderViewportState,
        anchorGeometry: (rowRect: NSRect, characterRect: NSRect)?
    ) {
        restoreHorizontalPosition(state.horizontal, anchorGeometry: anchorGeometry)
    }

    private func restoreHorizontalPosition(
        _ horizontal: ReaderViewportState.HorizontalState,
        anchorGeometry: (rowRect: NSRect, characterRect: NSRect)? = nil
    ) {
        guard let scrollView = view.enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let insets = clipView.contentInsets
        let minX = -insets.left
        let maxX = max(minX, view.frame.width - clipView.bounds.width + insets.right)
        if wrapLines {
            clipView.scroll(to: NSPoint(x: minX, y: clipView.bounds.minY))
        } else {
            var x = horizontal.stashedUnwrappedX ?? horizontal.clipOriginX
            x = min(max(x, minX), maxX)
            clipView.scroll(to: NSPoint(x: x, y: clipView.bounds.minY))
            scrollView.reflectScrolledClipView(clipView)
            // Minimal horizontal adjustment so the anchor CHARACTER stays
            // visible; the row itself may span many viewport widths.
            if let characterRect = anchorGeometry?.characterRect {
                let visibleRect = view.visibleRect
                if characterRect.maxX > visibleRect.maxX {
                    x = min(
                        max(x + (characterRect.maxX - visibleRect.maxX), minX),
                        maxX
                    )
                } else if characterRect.minX < visibleRect.minX {
                    x = min(
                        max(x - (visibleRect.minX - characterRect.minX), minX),
                        maxX
                    )
                }
            }
            clipView.scroll(to: NSPoint(x: x, y: clipView.bounds.minY))
        }
        scrollView.reflectScrolledClipView(clipView)
    }

    /// TextKit may adjust document geometry again after the synchronous
    /// restore. A bounded number of follow-up passes re-assert the anchor
    /// offset; each validates content identity and generation, and the whole
    /// correction chain dies once either moves (D3.6, max 3 passes). The
    /// work is queued to the main queue in the app and can also be drained
    /// synchronously by `processPendingViewportRestoresForTesting`.
    private func scheduleViewportCorrections(
        for state: ReaderViewportState,
        generation: Int,
        remaining: Int,
        staleAttempts: Int = 0
    ) {
        guard !readerWorkStopped, remaining > 0, supportsSynchronousViewportRestore(for: state) else { return }
        pendingViewportCorrection = (
            state: state,
            generation: generation,
            remaining: remaining,
            staleAttempts: staleAttempts,
            targetWidth: view.textContainer?.size.width ?? 0,
            targetTypography: typographyKey,
            targetFontEnvironment: fontEnvironmentRevision
        )
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.readerWorkStopped,
                  self.viewportStateGeneration == generation else { return }
            self.processPendingViewportCorrection()
        }
    }

    /// Runs one pending correction pass if its generation still matches.
    /// Safe to call from the main queue drain or directly from tests.
    package func processPendingViewportCorrection() {
        guard let pending = pendingViewportCorrection else { return }
        pendingViewportCorrection = nil
        performViewportCorrection(
            state: pending.state,
            generation: pending.generation,
            remaining: pending.remaining,
            staleAttempts: pending.staleAttempts,
            targetWidth: pending.targetWidth,
            targetTypography: pending.targetTypography,
            targetFontEnvironment: pending.targetFontEnvironment
        )
    }

    /// Drains both deferred restore channels once; tests pump this between
    /// interactions because their main thread never services the main queue
    /// mid-test.
    package func processPendingViewportRestoresForTesting() {
        processPendingViewportCorrection()
        processPendingWidthReflow()
    }

    private func performViewportCorrection(
        state: ReaderViewportState,
        generation: Int,
        remaining: Int,
        staleAttempts: Int,
        targetWidth: CGFloat,
        targetTypography: ReaderTypographyKey,
        targetFontEnvironment: UInt64
    ) {
        guard !readerWorkStopped, viewportStateGeneration == generation,
              let document = displayedDocument,
              document.contentID == state.contentID,
              state.surfaceFileURL == activeFoldScope?.file,
              state.projectionRevision == projectionRevision,
              targetWidth == view.textContainer?.size.width,
              targetTypography == typographyKey,
              targetFontEnvironment == fontEnvironmentRevision,
              targetFontEnvironment == ReaderFontResolver.shared.fontEnvironmentRevision,
              let scrollView = view.enclosingScrollView
        else { return }
        guard let location = anchorDisplayLocation(
            for: state.anchor,
            in: document
        ) else { return }
        // Rows between the viewport top and the anchor can still carry frames
        // from before a typography change; relaying them later moves the anchor
        // after this pass has already converged (macOS 15 does not compensate).
        layoutViewportForCorrection()
        guard let rowRect = freshAnchorRowRect(
            containingDisplayLocation: location
        ) else {
            lastViewportRestoreWasLimited = true
            lastViewportAnchorErrorPt = nil
            lastViewportRestoreLimitation = staleAttempts < 6
                ? "awaiting-target-layout" : "target-layout-unavailable"
            // Actual layout callbacks also drain pending corrections. Keep the
            // existing bounded next-turn retry for surfaces without a new draw.
            if staleAttempts < 6 {
                scheduleViewportCorrections(
                    for: state,
                    generation: generation,
                    remaining: remaining,
                    staleAttempts: staleAttempts + 1
                )
            }
            return
        }
        lastViewportRestoreWasLimited = false
        lastViewportRestoreLimitation = nil
        let clipView = scrollView.contentView
        let desiredOriginY = rowRect.minY - state.offsetFromViewportTop
        isRestoringViewport = true
        let oldX = clipView.bounds.minX
        let characterRect = !wrapLines && rowRect.width > 0
            ? (ReaderViewportGeometry.characterRect(displayLocation: location, in: view) ?? rowRect)
            : rowRect
        restoreHorizontalPosition(from: state, anchorGeometry: (rowRect, characterRect))
        lastViewportAnchorErrorPt = abs(desiredOriginY - clipView.bounds.minY)
        guard abs(desiredOriginY - clipView.bounds.minY) > 0.5 else {
            if abs(oldX - clipView.bounds.minX) > 0.5 { viewportRestorePassCount += 1 }
            isRestoringViewport = false
            return
        }
        let clamped = clampVerticalScrollOrigin(desiredOriginY, clipView: clipView)
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: clamped))
        scrollView.reflectScrolledClipView(clipView)
        // The scroll exposes rows that may relayout with current attributes.
        // Settle them now so the last queued pass cannot leave a stale offset.
        for _ in 0..<2 {
            layoutViewportForCorrection()
            guard let achieved = freshAnchorRowRect(containingDisplayLocation: location) else { break }
            let settled = clampVerticalScrollOrigin(achieved.minY - state.offsetFromViewportTop, clipView: clipView)
            guard abs(settled - clipView.bounds.minY) > 0.5 else { break }
            clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: settled))
            scrollView.reflectScrolledClipView(clipView)
        }
        if let achieved = freshAnchorRowRect(
            containingDisplayLocation: location
        ) {
            lastViewportAnchorErrorPt = abs(
                clipView.bounds.minY + state.offsetFromViewportTop - achieved.minY
            )
        }
        viewportRestorePassCount += 1
        isRestoringViewport = false
        ruler?.needsDisplay = true
        scheduleViewportCorrections(
            for: state,
            generation: generation,
            remaining: remaining - 1,
            staleAttempts: staleAttempts
        )
    }

    private func layoutViewportForCorrection() {
        let wasRestoring = isRestoringViewport
        isRestoringViewport = true
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
        isRestoringViewport = wasRestoring
    }

    /// Pre-change hook for width-driven reflows (D3.7). AppKit delivers
    /// several frame changes per resize; only the first captures, while the
    /// geometry is still the old stable one.
    private func captureStateForWidthChange(previousViewportWidth: CGFloat) {
        foldGutterHoveredID = nil
        guard !readerWorkStopped, !isCommittingProjection, wrapLines,
              !isRestoringViewport,
              widthReflowCapturedState == nil
        else { return }
        widthReflowCapturedState = captureViewportStateForReflow(previousViewportWidth: previousViewportWidth)
    }

    /// Merges all width notifications of one resize into a single reflow
    /// restore on the next runloop turn (D3.7).
    private func scheduleWidthReflow() {
        widthReflowNotificationCount += 1
        guard !readerWorkStopped, !isCommittingProjection, wrapLines,
              !isRestoringViewport,
              displayedDocument != nil
        else { return }
        paragraphWidthUpdatePending = true
        if hasScheduledWidthReflow {
            mergedWidthReflowCount += 1
            // Font/analysis changes can advance the generation between two widths.
            // Keep the queued width work attached to the latest compatible target.
            pendingWidthReflowGeneration = viewportStateGeneration
            return
        }
        hasScheduledWidthReflow = true
        viewportStateGeneration += 1
        pendingWidthReflowGeneration = viewportStateGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.readerWorkStopped else { return }
            // Drain even after another settings/analysis transaction changes generation.
            // The worker discards stale anchors, but must clear its scheduling flag
            // and still apply paragraph geometry for the current width.
            self.processPendingWidthReflow()
        }
    }

    package func processPendingWidthReflow() {
        guard !readerWorkStopped else { return }
        // Scrolling cancels position restoration, but cannot cancel the
        // paragraph values required by the current container width.
        if paragraphWidthUpdatePending {
            paragraphWidthUpdatePending = false
            isRestoringViewport = true
            updateParagraphLayout()
            isRestoringViewport = false
        }
        guard let generation = pendingWidthReflowGeneration else { return }
        pendingWidthReflowGeneration = nil
        performWidthReflow(generation: generation)
    }

    private func performWidthReflow(generation: Int) {
        hasScheduledWidthReflow = false
        let captured = widthReflowCapturedState
        widthReflowCapturedState = nil
        guard viewportStateGeneration == generation else { return }
        isRestoringViewport = true
        if let captured {
            restoreViewportState(captured)
            scheduleViewportCorrections(
                for: captured,
                generation: generation,
                remaining: 3
            )
        }
        if captured == nil, let horizontal = pendingHorizontalState {
            restoreHorizontalPosition(horizontal)
        }
        isRestoringViewport = false
        // A width reflow changes no attribute ranges: the installed
        // rendering-attributes validator re-applies them lazily as TextKit
        // relays fragments during the next natural draw. Forcing validation
        // here instead lays the whole width-invalidated document (seconds on
        // the 30k-line fixture).
        ruler?.needsDisplay = true
        view.needsDisplay = true
        onViewportChange?()
    }

    private func visibleFoldRegions(in document: ReaderDocument) -> [FoldRegion] {
        if document === displayedDocument { return visibleFoldRegionsCache }
        return Self.visibleFoldRegions(in: document, map: displayMap)
    }

    private func refreshVisibleFoldRegions() {
        guard let document = displayedDocument else {
            visibleFoldRegionsCache = []
            renderedFoldRegionsCache = []
            visibleFoldsByLine = [:]
            foldedDiffCache = [:]
            foldedDiffByLine = [:]
            visibleBookmarksByLine = [:]
            return
        }
        ReaderWorkCounters.record(\.decorationBuildCount)
        if isDrawingRuler { ReaderWorkCounters.record(\.drawGlobalRecordVisits, document.foldRegions.count * 2) }
        visibleFoldRegionsCache = Self.visibleFoldRegions(in: document, map: displayMap)
        renderedFoldRegionsCache = document.foldRegions.filter {
            renderedFoldIDs.contains($0.id)
        }.sorted {
            ($0.bodyRange.lowerBound, $0.bodyRange.upperBound)
                < ($1.bodyRange.lowerBound, $1.bodyRange.upperBound)
        }
        visibleFoldsByLine = [:]
        for region in visibleFoldRegionsCache {
            if isDrawingRuler { ReaderWorkCounters.record(\.drawGlobalRecordVisits) }
            guard let line = document.foldTopology?.headerLine(for: region.id) else { continue }
            // Keep the original document-order priority when several folds share a line.
            visibleFoldsByLine[Int(line)] = visibleFoldsByLine[Int(line)] ?? region
        }
        refreshFoldedDiffMarkers()
        refreshVisibleBookmarkMarkers()
    }

    private func refreshFoldedDiffMarkers() {
        ReaderWorkCounters.record(\.decorationBuildCount)
        guard let document = displayedDocument else {
            foldedDiffCache = [:]
            foldedDiffByLine = [:]
            return
        }
        foldedDiffCache = foldedDiffMarkers(in: document)
        foldedDiffByLine = [:]
        // Rendered folds are disjoint; reuse their records instead of building another ID dictionary.
        for region in renderedFoldRegionsCache {
            if isDrawingRuler { ReaderWorkCounters.record(\.drawGlobalRecordVisits) }
            guard let marker = foldedDiffCache[region.id],
                  let line = document.foldTopology?.headerLine(for: region.id) else { continue }
            foldedDiffByLine[Int(line)] = marker
        }
    }

    private func refreshVisibleBookmarkMarkers() {
        ReaderWorkCounters.record(\.decorationBuildCount)
        visibleBookmarksByLine = buildVisibleBookmarkMarkers()
    }

    private static func visibleFoldRegions(
        in document: ReaderDocument,
        map: DisplayMap?
    ) -> [FoldRegion] {
        document.foldRegions.filter { region in
            guard region.summary.hiddenLineCount >= 2 else { return false }
            if case .visible = map?.displayPosition(
                ofByte: region.headerRange.lowerBound
            ) {
                return true
            }
            return false
        }
    }

    public func updateSyntax(
        document: ReaderDocument,
        focusByteOffset: UInt32? = nil
    ) {
        guard
            let layoutManager = view.textLayoutManager,
            document.foldTopology != nil,
            displayedDocument?.contentID == document.contentID,
            displayedDocument?.languageMode == document.languageMode
        else { return }
        let projectionSelections = captureProjectionSelections()
        let projectionAffinity = view.selectionAffinity
        let previousDocument = displayedDocument
        let analysisChanged = displayedDocument?.analysisKey != document.analysisKey
        baselineFoldIDs = ReadingPlan.baselineFoldIDs(
            for: readingHeightLevel,
            in: document.foldRegions
        )
        if var focusState,
           let target = ReadingPlan.focusTarget(
               at: focusByteOffset ?? focusState.byteOffset,
               in: document
           )
        {
            logicalFoldIDs = ReadingPlan.focusFoldIDs(
                around: target.facet,
                in: document
            )
            focusState.focusedFoldID = target.region.id
            focusState.byteOffset = focusByteOffset ?? focusState.byteOffset
            self.focusState = focusState
        } else if let focusState {
            readingHeightLevel = focusState.readingHeightLevel
            foldOverridesByScope = focusState.foldOverridesByScope
            baselineFoldIDs = ReadingPlan.baselineFoldIDs(
                for: readingHeightLevel,
                in: document.foldRegions
            )
            logicalFoldIDs = ReadingPlan.logicalFoldIDs(
                overrides: activeFoldScope.flatMap {
                    foldOverridesByScope[$0]
                } ?? FoldOverrides(),
                baseline: baselineFoldIDs
            )
            self.focusState = nil
        } else {
            logicalFoldIDs = ReadingPlan.logicalFoldIDs(
                overrides: activeFoldScope.flatMap {
                    foldOverridesByScope[$0]
                } ?? FoldOverrides(),
                baseline: baselineFoldIDs
            )
        }
        let previousRenderedFoldIDs = renderedFoldIDs
        renderedFoldIDs = ReadingPlan.maximalFoldIDs(
            logicalFoldIDs,
            in: document
        )
        let selectedRegions = document.foldRegions.filter { renderedFoldIDs.contains($0.id) }
            .sorted { $0.bodyRange.lowerBound < $1.bodyRange.lowerBound }
        let previousRegions = (previousDocument?.foldRegions.filter {
            previousRenderedFoldIDs.contains($0.id)
        } ?? []).sorted { $0.bodyRange.lowerBound < $1.bodyRange.lowerBound }
        let foldsChanged = renderedFoldIDs != previousRenderedFoldIDs
            || selectedRegions.map(\.bodyRange) != previousRegions.map(\.bodyRange)
        let attachmentsChanged = selectedRegions != previousRegions
        let typographyChanged = theme.syntaxFormatting
            && Self.metricSpans(previousDocument?.highlightSpans ?? [], theme: theme,
                                proseComments: previousDocument.map(proseCommentsEnabled(for:)) ?? false)
                != Self.metricSpans(document.highlightSpans, theme: theme,
                                    proseComments: proseCommentsEnabled(for: document))
        let geometryChanged = previousDocument?.foldRegions != document.foldRegions
        let needsLayout = foldsChanged || attachmentsChanged || typographyChanged || geometryChanged
        let captured = needsLayout && !foldsChanged ? captureViewportStateForReflow() : nil
        let wasRestoring = isRestoringViewport
        isRestoringViewport = true
        defer {
            if needsLayout, captured == nil, let horizontal = pendingHorizontalState {
                restoreHorizontalPosition(horizontal)
            }
            isRestoringViewport = wasRestoring
        }
        if foldsChanged {
            projectionRevision += 1
            invalidateReflowSequence()
            widthReflowCapturedState = nil
        }
        if needsLayout { viewportStateGeneration += 1 }
        let generation = viewportStateGeneration
        let viewportRange = layoutManager.textViewportLayoutController.viewportRange
        let syntaxProjection = (foldsChanged || displayMap == nil)
            ? Self.project(document: document, renderedFoldIDs: renderedFoldIDs,
                           attributes: baseAttributes, theme: theme) : nil
        if (foldsChanged || displayMap == nil) && syntaxProjection == nil { return }
        if let map = displayMap, !foldsChanged, !projectionMatchesStorage(map) {
            layoutManager.renderingAttributesValidator = nil
            return
        }
        isCommittingProjection = true
        defer { isCommittingProjection = false }
        layoutManager.renderingAttributesValidator = nil
        displayedDocument = document
        if analysisChanged { prepareIdentifiers(for: document) }
        if let projection = syntaxProjection {
            projectionFallbackReason = "syntax-projection-change"
            projectionFallbackCount += 1
            displayMap = projection.map
            foldAttachments = projection.attachments
            layoutManager.renderingAttributesValidator = nil
            installProjectedText(projection.attributed)
        } else if let map = displayMap {
            guard projectionMatchesStorage(map) else {
                layoutManager.renderingAttributesValidator = nil
                return
            }
            if typographyChanged {
                updateTypography(document: document, map: map)
            } else if attachmentsChanged {
                let update = { self.updateFoldAttachmentAttributes(document: document, map: map) }
                if let content = view.textContentStorage { content.performEditingTransaction(update) }
                else { update() }
            }
        }
        guard let map = displayMap else { return }
        refreshVisibleFoldRegions()
        declarationKindsByLine = Self.declarationKindsByLine(in: document)
        renderingCoordinator.update(document: document, map: map, theme: theme)
        isCommittingProjection = false
        if foldsChanged { restoreProjectionSelections(projectionSelections, affinity: projectionAffinity) }
        refreshOccurrenceRendering(in: document, updateLayout: false)
        if geometryChanged, let scrollView = view.enclosingScrollView ?? scrollView {
            configureGutter(in: scrollView, lineNumbers: lineNumbers)
        }
        ruler?.needsDisplay = true
        installRenderingValidator(in: layoutManager)
        if let viewportRange { layoutManager.invalidateRenderingAttributes(for: viewportRange) }
        if let captured {
            pendingReflowState = captured
            isRestoringViewport = true
            restoreViewportState(captured)
            isRestoringViewport = false
            scheduleViewportCorrections(for: captured, generation: generation, remaining: 3)
        }
        view.needsDisplay = true
        DispatchQueue.main.async { [weak self, weak layoutManager] in
            guard let self, let layoutManager else { return }
            self.validateVisibleRenderingAttributes(in: layoutManager, updateLayout: needsLayout)
        }
    }

    public func apply(settings: ReaderSettings) {
        guard !readerWorkStopped else { return }
        let newTheme = ReaderTheme(settings: settings)
        let themeChanged = newTheme != theme
        let newTypographyKey = ReaderTypographyKey(settings: settings)
        let environmentRevision = ReaderFontResolver.shared.fontEnvironmentRevision
        let typographyChanged = newTypographyKey != typographyKey
            || environmentRevision != fontEnvironmentRevision
        let wrapChanged = settings.wrapLines != wrapLines
        // Idempotent apply (D1.2/W06): equal settings perform no projection
        // and no layout work — unless the reader was mounted into a new
        // scroll view that still needs its gutter configured.
        let settingsEqual = !themeChanged && !typographyChanged
            && settings.lineNumbers == lineNumbers
            && !wrapChanged
        let mountedScrollView = view.enclosingScrollView ?? scrollView
        if settingsEqual, mountedScrollView == nil || scrollView === mountedScrollView {
            return
        }

        let geometryChanged = wrapChanged || settings.lineNumbers != lineNumbers
            || (mountedScrollView != nil && scrollView !== mountedScrollView)
        if !typographyChanged && !geometryChanged {
            theme = newTheme
            applyThemeColors()
            for attachment in foldAttachments.values { attachment.updateTheme(theme) }
            if let document = displayedDocument, let map = displayMap,
               let layoutManager = view.textLayoutManager {
                guard projectionMatchesStorage(map) else {
                    layoutManager.renderingAttributesValidator = nil
                    return
                }
                renderingCoordinator.update(document: document, map: map, theme: theme)
                installRenderingValidator(in: layoutManager)
                validateVisibleRenderingAttributes(in: layoutManager, updateLayout: false)
            }
            ruler?.needsDisplay = true
            view.needsDisplay = true
            return
        }

        // The stable snapshot must be captured before configureGutter can
        // reach configureWrapping and trigger layout (D3.6).
        let captured = captureViewportStateForReflow()
        let selectedRanges = view.selectedRanges
        let selectionAffinity = view.selectionAffinity

        theme = newTheme
        typographyKey = newTypographyKey
        fontEnvironmentRevision = environmentRevision
        lineNumbers = settings.lineNumbers
        wrapLines = settings.wrapLines
        foldGutterHoveredID = nil
        applyThemeColors()

        viewportStateGeneration += 1
        let generation = viewportStateGeneration
        isRestoringViewport = true

        if let scrollView = view.enclosingScrollView ?? scrollView {
            configureGutter(in: scrollView, lineNumbers: settings.lineNumbers)
        }
        ruler?.needsDisplay = true

        guard let document = displayedDocument,
              let layoutManager = view.textLayoutManager
        else {
            isRestoringViewport = false
            return
        }

        guard let map = displayMap, projectionMatchesStorage(map) else {
            layoutManager.renderingAttributesValidator = nil
            isRestoringViewport = false
            return
        }
        if typographyChanged {
            updateTypography(document: document, map: map)
        } else {
            updateParagraphLayout()
            for attachment in foldAttachments.values { attachment.updateTheme(theme) }
        }
        renderingCoordinator.update(document: document, map: map, theme: theme)
        installRenderingValidator(in: layoutManager)

        if let captured {
            pendingReflowState = captured
            restoreViewportState(captured)
            scheduleViewportCorrections(
                for: captured,
                generation: generation,
                remaining: 3
            )
        }
        if captured == nil, let horizontal = pendingHorizontalState {
            restoreHorizontalPosition(horizontal)
        }
        if captured == nil,
           view.selectedRanges != selectedRanges || view.selectionAffinity != selectionAffinity {
            view.setSelectedRanges(selectedRanges, affinity: selectionAffinity, stillSelecting: false)
        }
        isRestoringViewport = false
        // Publish the settled state exactly once (D3.4): one decoration
        // refresh and one viewport callback for the whole transaction.
        validateVisibleRenderingAttributes(in: layoutManager)
        view.needsDisplay = true
        onViewportChange?()
    }

    public func reveal(byteOffset: UInt32) {
        clearProjectionSelection()
        invalidateReflowSequence()
        _ = unfoldAncestors(containing: byteOffset)
        guard let location = visibleDisplayOffset(forByte: byteOffset),
              location <= backingTextStorage.length
        else { return }
        let lineRange = (backingTextStorage.mutableString).lineRange(
            for: NSRange(location: location, length: 0)
        )
        updateCurrentLine(byteOffset: byteOffset)
        revealLineRange(lineRange, targetLocation: location)
    }

    private func revealLineRange(_ range: NSRange, targetLocation: Int) {
        // A declaration can wrap across several rows. Center the requested
        // source character, rather than only exposing part of its logical line.
        view.scrollRangeToVisible(NSRange(location: targetLocation, length: 0))
        if let scrollView = view.enclosingScrollView {
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let clipView = scrollView.contentView
            let targetY = ReaderViewportGeometry.characterRect(
                displayLocation: targetLocation, in: view
            ).map { $0.midY - clipView.bounds.height / 2 } ?? clipView.bounds.minY
            // The ruler reserves a left inset; zero would hide code behind it.
            clipView.scroll(to: NSPoint(
                x: -clipView.contentInsets.left,
                y: clampVerticalScrollOrigin(targetY, clipView: clipView)
            ))
            scrollView.reflectScrolledClipView(clipView)
        }
        view.showFindIndicator(for: range)
    }

    public func restore(
        scrollByteOffset: UInt32?,
        selectionByteOffset: UInt32?
    ) {
        if selectionByteOffset != nil { clearProjectionSelection() }
        invalidateReflowSequence()
        if let selectionByteOffset,
           let location = visibleDisplayOffset(forByte: selectionByteOffset),
           location <= backingTextStorage.length
        {
            view.setSelectedRange(NSRange(location: location, length: 0))
            updateCurrentLine(byteOffset: selectionByteOffset)
        }
        guard let scrollByteOffset,
              let document = displayedDocument,
              let desired = document.lineTable.lineColumn(
                  at: scrollByteOffset
              ),
              let scrollView = view.enclosingScrollView,
              let window = view.window
        else { return }
        var candidateLine = Int(desired.line)
        for _ in 0..<3 {
            guard candidateLine > 0,
                  document.lineTable.lineStarts.indices.contains(candidateLine - 1),
                  let location = visibleDisplayOffset(
                      forByte: document.lineTable.lineStarts[candidateLine - 1]
                  )
            else { return }
            let range = NSRange(location: location, length: 0)
            if let manager = view.textLayoutManager,
               let content = manager.textContentManager,
               let target = content.location(content.documentRange.location, offsetBy: location) {
                // A partial edit can leave the old viewport beyond the new
                // document extent. Relocate lazy layout to the source target
                // before asking AppKit for its native line rectangle.
                let controller = manager.textViewportLayoutController
                let y = controller.relocateViewport(to: target)
                scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: y))
                controller.layoutViewport()
            }
            view.scrollRangeToVisible(range)
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            let screenRect = view.firstRect(
                forCharacterRange: range,
                actualRange: nil
            )
            let lineRect = view.convert(
                window.convertFromScreen(screenRect),
                from: nil
            )
            let clipView = scrollView.contentView
            clipView.scroll(to: NSPoint(
                x: -clipView.contentInsets.left,
                y: clampVerticalScrollOrigin(lineRect.minY, clipView: clipView)
            ))
            scrollView.reflectScrolledClipView(clipView)
            // Settle this explicit scroll before measuring the restoration error.
            view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            guard let actualOffset = firstVisibleByteOffset(),
                  let actual = document.lineTable.lineColumn(at: actualOffset)
            else { return }
            let lineDelta = Int(actual.line) - Int(desired.line)
            if lineDelta == 0 { return }
            candidateLine = max(
                1,
                min(
                    document.lineTable.lineStarts.count,
                    candidateLine - lineDelta
                )
            )
        }
    }

    public func configureGutter(
        in scrollView: NSScrollView,
        lineNumbers: Bool
    ) {
        self.scrollView = scrollView
        self.lineNumbers = lineNumbers
        let needsRuler = lineNumbers || !diffMarkers.isEmpty
            || hasVisibleFoldRegions || navigationLandingLine != nil
        guard needsRuler else {
            scrollView.hasVerticalRuler = false
            scrollView.rulersVisible = false
            scrollView.verticalRulerView = nil
            ruler = nil
            view.textContainerInset.width = 10
            scrollView.tile()
            configureWrapping(in: scrollView)
            return
        }
        let activeRuler: ReaderRulerView
        if let existing = scrollView.verticalRulerView as? ReaderRulerView {
            activeRuler = existing
        } else {
            activeRuler = ReaderRulerView(scrollView: scrollView, reader: self)
            scrollView.verticalRulerView = activeRuler
        }
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        ruler = activeRuler
        updateRulerThickness()
        updateBookmarkAccessibilityLabel()
        scrollView.tile()
        configureWrapping(in: scrollView)
        activeRuler.needsDisplay = true
    }

    public func installDiffGutter(in scrollView: NSScrollView) {
        configureGutter(in: scrollView, lineNumbers: lineNumbers)
    }

    public func setDiffMarkers(_ markers: [Int: DiffCore.MarkerKind]) {
        // Window renders resend markers on selection/Context changes. Retiling
        // an unchanged gutter can move TextKit's wrapped viewport.
        guard diffMarkers != markers else { return }
        diffMarkers = markers
        invalidateOverview()
        refreshFoldedDiffMarkers()
        refreshFoldExposures()
        if let scrollView = view.enclosingScrollView ?? scrollView {
            configureGutter(in: scrollView, lineNumbers: lineNumbers)
        }
        updateRulerThickness()
        ruler?.needsDisplay = true
    }

    public func setBookmarkMarkers(_ labelsBySourceLine: [Int: [String]]) {
        let markers: [Int: [String]] = labelsBySourceLine.reduce(into: [:]) { result, entry in
            guard entry.key > 0, !entry.value.isEmpty else { return }
            result[entry.key] = entry.value.sorted()
        }
        guard bookmarkMarkers != markers else { return }
        bookmarkMarkers = markers
        invalidateOverview()
        refreshVisibleBookmarkMarkers()
        if let scrollView = view.enclosingScrollView ?? scrollView {
            configureGutter(in: scrollView, lineNumbers: lineNumbers)
        }
        updateRulerThickness()
        updateBookmarkAccessibilityLabel()
        ruler?.needsDisplay = true
    }

    public var diffMarkerCounts: [DiffCore.MarkerKind: Int] {
        Dictionary(grouping: diffMarkers.values, by: { $0 }).mapValues(\.count)
    }

    internal var bookmarkMarkerLabelsForTesting: [Int: [String]] {
        visibleBookmarksByLine
    }

    internal var bookmarkMarkerAccessibilityLabelForTesting: String {
        bookmarkAccessibilityLabel
    }

    package var bookmarkMarkerLines: [Int] { visibleBookmarksByLine.keys.sorted() }

    package var bookmarkMarkerAccessibilityLabel: String? {
        guard lineNumbers, !bookmarkMarkers.isEmpty else { return nil }
        return ruler?.accessibilityLabel()
    }

    public var rulerThickness: CGFloat {
        ruler?.ruleThickness ?? 0
    }

    package var foldGutterIsHovered: Bool { foldGutterHoveredID != nil }

    /// First-row decoration observables (§7.1), recorded per ruler draw:
    /// logical line -> first visual row rect and the line-number label draw
    /// rect, both in text view coordinates.
    package private(set) var lastRulerFirstRowRectsForTesting: [Int: NSRect] = [:]
    package private(set) var lastRulerLabelDrawRectsForTesting: [Int: NSRect] = [:]
    /// Segments the last primary-selection pass actually drew (§7.1), in
    /// text view coordinates, one per visible visual-row fragment.
    package private(set) var lastPrimarySelectionSegmentsForTesting: [NSRect] = []

    /// The currently hovered fold handle, if any (D2.3).
    package var foldGutterHoveredFoldID: FoldID? { foldGutterHoveredID }

    package func setFoldGutterHoverForTesting(_ point: NSPoint?) {
        guard let ruler else { return }
        updateFoldHover(at: point, in: ruler)
    }

    public var gutterShowsLineNumbersAndDiff: Bool {
        lineNumbers && !diffMarkers.isEmpty && rulerThickness > diffColumnWidth
    }

    @discardableResult
    public func activate(atByteOffset byteOffset: UInt32) -> Int {
        clearProjectionSelection()
        invalidateReflowSequence()
        _ = unfoldAncestors(containing: byteOffset)
        updateCurrentLine(byteOffset: byteOffset)
        guard let document = displayedDocument else {
            clearOccurrences()
            return 0
        }
        occurrenceSelectionByteOffset = byteOffset
        guard identifierPreparationState == .ready else {
            pendingOccurrenceActivation = byteOffset
            primarySelectionRange = nil
            view.selectedTextAttributes = nativeSelectedTextAttributes
            let location = visibleDisplayOffset(forByte: byteOffset) ?? 0
            view.setSelectedRange(NSRange(location: location, length: 0))
            setOccurrences([])
            refreshFoldExposures(in: document, occurrenceRanges: [])
            return 0
        }
        return finishOccurrenceActivation(at: byteOffset)
    }

    @discardableResult
    private func finishOccurrenceActivation(at byteOffset: UInt32) -> Int {
        guard let document = displayedDocument else { return 0 }
        let occurrenceRanges = preparedOccurrences(in: document, at: byteOffset)
        let ranges = projectedOccurrenceNSRanges(occurrenceRanges)
        occurrenceSelectionByteOffset = ranges.isEmpty ? nil : byteOffset
        let location = visibleDisplayOffset(forByte: byteOffset)
        let selected = location.flatMap { location in
            ranges.first { NSLocationInRange(location, $0) }
        }
        primarySelectionRange = selected
        view.selectedTextAttributes = selected == nil
            ? nativeSelectedTextAttributes
            : [.backgroundColor: NSColor.clear]
        view.setSelectedRange(selected ?? NSRange(location: location ?? 0, length: 0))
        setOccurrences(ranges)
        refreshFoldExposures(
            in: document,
            occurrenceRanges: occurrenceRanges
        )
        return ranges.count
    }

    public func clearOccurrences() {
        clearProjectionSelection()
        pendingOccurrenceActivation = nil
        occurrenceSelectionByteOffset = nil
        primarySelectionRange = nil
        view.selectedTextAttributes = nativeSelectedTextAttributes
        view.setSelectedRange(NSRange(location: view.selectedRange().location, length: 0))
        setOccurrences([])
        refreshFoldExposures()
    }

    package var symbolOccurrenceByteOffset: UInt32? {
        occurrenceSelectionByteOffset
    }

    package var findMatchCount: Int {
        findMatchByteRanges?.count ?? 0
    }

    package var selectedFindMatchIndex: Int? {
        findSelectionIndex
    }

    package var selectedFindMatchRange: ByteRange? {
        findSelectionIndex.flatMap { index in
            guard let findMatchByteRanges,
                  findMatchByteRanges.indices.contains(index)
            else { return nil }
            return findMatchByteRanges[index]
        }
    }

    package func setFindMatches(
        _ ranges: [ByteRange],
        selectedIndex: Int?
    ) {
        pendingOccurrenceActivation = nil
        findMatchByteRanges = ranges
        findSelectionIndex = selectedIndex.flatMap {
            ranges.indices.contains($0) ? $0 : nil
        }
        occurrenceSelectionByteOffset = nil
        refreshOccurrenceRendering()
    }

    package func clearFindMatches(restoringSymbolAt byteOffset: UInt32?) {
        findMatchByteRanges = nil
        findSelectionIndex = nil
        occurrenceSelectionByteOffset = byteOffset
        primarySelectionRange = nil
        view.selectedTextAttributes = nativeSelectedTextAttributes
        refreshOccurrenceRendering()
    }

    @discardableResult
    package func revealFindMatch(at index: Int) -> Bool {
        clearProjectionSelection()
        invalidateReflowSequence()
        guard let ranges = findMatchByteRanges,
              ranges.indices.contains(index)
        else { return false }
        let range = ranges[index]
        if isFocusMode {
            _ = followFocusForExplicitNavigation(to: range.lowerBound)
        } else {
            _ = unfoldAncestors(containing: range.lowerBound)
        }
        guard let displayRange = displayMap?.project(byteRange: range)?.visible.first
        else { return false }
        findSelectionIndex = index
        primarySelectionRange = displayRange
        view.selectedTextAttributes = [.backgroundColor: NSColor.clear]
        view.setSelectedRange(displayRange)
        updateCurrentLine(byteOffset: range.lowerBound)
        refreshOccurrenceRendering()
        view.scrollRangeToVisible(displayRange)
        view.showFindIndicator(for: displayRange)
        return true
    }

    public var selectedSourceText: String? { sourceText(forDisplaySelection: view.selectedRange()) }

    /// Reuses the reader's projection when selecting a project-search hit.
    public func revealSearchMatch(range: ByteRange) {
        clearProjectionSelection()
        invalidateReflowSequence()
        if isFocusMode { _ = followFocusForExplicitNavigation(to: range.lowerBound) }
        else { _ = unfoldAncestors(containing: range.lowerBound) }
        guard let displayRange = displayMap?.project(byteRange: range)?.visible.first else { return }
        primarySelectionRange = nil
        pendingOccurrenceActivation = nil
        view.selectedTextAttributes = nativeSelectedTextAttributes
        view.setSelectedRange(displayRange)
        updateCurrentLine(byteOffset: range.lowerBound)
        view.scrollRangeToVisible(displayRange)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { view.showFindIndicator(for: displayRange) }
    }

    public func captureVisibleDecorationState() {
        guard !isCommittingProjection else { return }
        var lines: [Int] = []
        enumerateVisibleLayoutFragments { _, line in
            lines.append(line)
        }
        visibleLineNumbers = lineNumbers ? lines : []
        visibleCurrentLineNumbers = currentLineNumber.map {
            lines.contains($0) ? [$0] : []
        } ?? []
        visibleDeclarationMarkerLines = lineNumbers
            ? lines.filter { declarationKindsByLine[$0] != nil }
            : []
    }

    @discardableResult
    public func revealDiffLine(_ line: Int) -> Bool {
        clearProjectionSelection()
        invalidateReflowSequence()
        guard line > 0,
              let document = displayedDocument,
              document.lineTable.lineStarts.indices.contains(line - 1)
        else { return false }
        let byteOffset = document.lineTable.lineStarts[line - 1]
        _ = unfoldAncestors(containing: byteOffset)
        guard let location = visibleDisplayOffset(forByte: byteOffset) else {
            return false
        }
        let range = (backingTextStorage.mutableString).lineRange(
            for: NSRange(location: location, length: 0)
        )
        view.setSelectedRange(range)
        updateCurrentLine(line: line)
        revealLineRange(range, targetLocation: location)
        return true
    }

    public var selectedLineNumber: Int? {
        guard let document = displayedDocument,
              let byteOffset = sourceByteOffset(
                  forDisplay: view.selectedRange().location
              ),
              let position = document.lineTable.lineColumn(at: byteOffset)
        else { return nil }
        return Int(position.line)
    }

    public var displayedBytes: [UInt8]? { displayedDocument?.bytes }

    package func font(atByteOffset byteOffset: UInt32) -> NSFont? {
        guard let location = visibleDisplayOffset(forByte: byteOffset),
              location < backingTextStorage.length
        else { return nil }
        return backingTextStorage.attribute(
            .font,
            at: location,
            effectiveRange: nil
        ) as? NSFont
    }

    private func handleHover(at point: NSPoint?) {
        guard let onHover else { return }
        guard let point, let target = hoverTarget(atViewPoint: point) else {
            lastHoverTarget = nil
            onHover(nil)
            return
        }
        onHover(target)
    }

    private func hoverTarget(atViewPoint point: NSPoint) -> ReaderHoverTarget? {
        guard !isCommittingProjection, let document = displayedDocument,
              let window = view.window
        else { return nil }
        let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
        let index = view.characterIndex(for: screenPoint)
        guard index != NSNotFound, index < backingTextStorage.length else { return nil }
        if let lastHoverTarget, lastHoverTarget.screenRect.contains(screenPoint),
           let offset = sourceByteOffset(forDisplay: index),
           lastHoverTarget.byteRange.contains(offset)
        {
            return lastHoverTarget
        }
        // `characterIndex(for:)` snaps to the nearest glyph; only a pointer
        // actually over that glyph counts.
        let glyph = view.firstRect(forCharacterRange: NSRange(location: index, length: 1), actualRange: nil)
        guard glyph.insetBy(dx: -0.5, dy: -1).contains(screenPoint),
              let offset = sourceByteOffset(forDisplay: index),
              let range = hoverIdentifierRange(at: offset, in: document)
        else { return nil }
        let target = hoverTarget(for: range)
        lastHoverTarget = target
        return target
    }

    /// The hover target for the identifier at or just before `byteOffset`,
    /// for keyboard and ⌥-click requests.
    public func hoverTarget(atByteOffset byteOffset: UInt32) -> ReaderHoverTarget? {
        guard !isCommittingProjection, let document = displayedDocument else { return nil }
        let range = hoverIdentifierRange(at: byteOffset, in: document)
            ?? (byteOffset > 0 ? hoverIdentifierRange(at: byteOffset - 1, in: document) : nil)
        return range.flatMap(hoverTarget(for:))
    }

    /// The hover target at the caret or the start of the selection.
    public func hoverTargetAtSelection() -> ReaderHoverTarget? {
        guard let offset = sourceByteOffset(forDisplay: view.selectedRange().location) else {
            return nil
        }
        return hoverTarget(atByteOffset: offset)
    }

    private func hoverTarget(for range: ByteRange) -> ReaderHoverTarget? {
        guard let lower = visibleDisplayOffset(forByte: range.lowerBound),
              let upper = visibleDisplayOffset(forByte: range.upperBound),
              upper > lower
        else { return nil }
        let rect = view.firstRect(
            forCharacterRange: NSRange(location: lower, length: upper - lower),
            actualRange: nil
        )
        guard !rect.isEmpty else { return nil }
        return ReaderHoverTarget(byteRange: range, screenRect: rect)
    }

    public func byteOffset(forCharacterIndex index: Int) -> UInt32? {
        guard !isCommittingProjection else { return nil }
        return sourceByteOffset(forDisplay: index)
    }

    public func firstVisibleByteOffset() -> UInt32? {
        guard !isCommittingProjection, let layoutManager = view.textLayoutManager,
              let content = layoutManager.textContentManager
        else { return nil }
        // Reading the current viewport must not trigger TextKit layout/extent changes.
        guard let viewport = layoutManager.textViewportLayoutController.viewportRange else {
            return nil
        }
        let location = content.offset(
            from: content.documentRange.location,
            to: viewport.location
        )
        guard location != NSNotFound else { return nil }
        let lineStart = (backingTextStorage.mutableString).lineRange(
            for: NSRange(location: location, length: 0)
        ).location
        return sourceByteOffset(forDisplay: lineStart)
    }

    public func followAnchorByteOffset() -> UInt32? {
        guard let layoutManager = view.textLayoutManager,
              let content = layoutManager.textContentManager,
              let viewportRange = layoutManager.textViewportLayoutController.viewportRange
        else { return nil }
        let anchorY = layoutManager.textViewportLayoutController.viewportBounds.minY
            + layoutManager.textViewportLayoutController.viewportBounds.height * 0.25
        var nearest: (distance: CGFloat, offset: UInt32)?
        layoutManager.enumerateTextLayoutFragments(
            from: viewportRange.location,
            options: []
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            let utf16Offset = content.offset(
                from: content.documentRange.location,
                to: fragment.rangeInElement.location
            )
            guard utf16Offset != NSNotFound,
                  let offset = self.sourceByteOffset(forDisplay: utf16Offset)
            else { return true }
            let candidate = (abs(frame.midY - anchorY), offset)
            if nearest == nil || candidate.0 < nearest!.distance {
                nearest = (candidate.0, candidate.1)
            }
            return frame.minY <= layoutManager.textViewportLayoutController.viewportBounds.maxY
        }
        return nearest?.offset
    }

    private func visibleDisplayOffset(forByte byteOffset: UInt32) -> Int? {
        guard !isCommittingProjection, case .visible(let offset) = displayMap?.displayPosition(ofByte: byteOffset)
        else { return nil }
        return offset
    }

    private func sourceByteOffset(forDisplay displayOffset: Int) -> UInt32? {
        guard !isCommittingProjection, case .source(let offset) = displayMap?.sourcePosition(
            ofDisplay: displayOffset
        ) else { return nil }
        return offset
    }

    func sourceText(forDisplaySelection range: NSRange) -> String? {
        guard !isCommittingProjection, range.length > 0,
              let document = displayedDocument,
              let ranges = displayMap?.sourceRanges(forDisplay: range)
        else { return nil }
        var source = ""
        source.reserveCapacity(ranges.reduce(0) {
            $0 + Int($1.upperBound - $1.lowerBound)
        })
        for range in ranges {
            guard Int(range.upperBound) <= document.bytes.count else {
                return nil
            }
            source += String(
                decoding: document.bytes[
                    Int(range.lowerBound)..<Int(range.upperBound)
                ],
                as: UTF8.self
            )
        }
        return source
    }

    private func activate(atCharacterIndex index: Int) {
        if case .placeholder(let foldID) = displayMap?.sourcePosition(
            ofDisplay: index
        ) {
            _ = toggleFold(id: foldID)
            return
        }
        if index > 0,
           case .placeholder(let foldID) = displayMap?.sourcePosition(
               ofDisplay: index - 1
           )
        {
            _ = toggleFold(id: foldID)
            return
        }
        guard let byteOffset = byteOffset(forCharacterIndex: index) else {
            clearOccurrences()
            return
        }
        activate(atByteOffset: byteOffset)
    }

    private func setOccurrences(
        _ ranges: [NSRange],
        logicalCount: Int? = nil,
        updateLayout: Bool = true
    ) {
        occurrenceCount = logicalCount ?? ranges.count
        invalidateOverview()
        renderingCoordinator.setOccurrences(
            ranges.filter { $0 != primarySelectionRange },
            primary: primarySelectionRange
        )
        guard let layoutManager = view.textLayoutManager else { return }
        installRenderingValidator(in: layoutManager)
        if let viewportRange =
            layoutManager.textViewportLayoutController.viewportRange
        {
            layoutManager.invalidateRenderingAttributes(for: viewportRange)
            validateVisibleRenderingAttributes(in: layoutManager, updateLayout: updateLayout)
        }
        view.needsDisplay = true
    }

    private func refreshOccurrenceRendering(
        in document: ReaderDocument? = nil,
        updateLayout: Bool = true
    ) {
        guard let document = document ?? displayedDocument else {
            setOccurrences([], updateLayout: updateLayout)
            return
        }
        if let findMatchByteRanges {
            refreshFoldExposures(in: document)
            let visible = findMatchByteRanges.flatMap {
                displayMap?.project(byteRange: $0)?.visible ?? []
            }
            primarySelectionRange = findSelectionIndex.flatMap { index in
                guard findMatchByteRanges.indices.contains(index) else { return nil }
                return displayMap?.project(
                    byteRange: findMatchByteRanges[index]
                )?.visible.first
            }
            setOccurrences(visible, logicalCount: findMatchByteRanges.count, updateLayout: updateLayout)
            return
        }
        guard let occurrenceSelectionByteOffset else {
            refreshFoldExposures(in: document)
            setOccurrences([], updateLayout: updateLayout)
            return
        }
        let occurrenceRanges = preparedOccurrences(in: document, at: occurrenceSelectionByteOffset)
        let ranges = projectedOccurrenceNSRanges(occurrenceRanges)
        if identifierPreparationState == .ready, occurrenceRanges.isEmpty { self.occurrenceSelectionByteOffset = nil }
        refreshFoldExposures(
            in: document,
            occurrenceRanges: occurrenceRanges
        )
        setOccurrences(ranges, updateLayout: updateLayout)
    }

    private func occurrenceNSRanges(
        in document: ReaderDocument,
        at byteOffset: UInt32
    ) -> [NSRange] {
        projectedOccurrenceNSRanges(
            preparedOccurrences(in: document, at: byteOffset)
        )
    }

    private func projectedOccurrenceNSRanges<R: Sequence>(
        _ ranges: R
    ) -> [NSRange] where R.Element == ByteRange {
        guard let displayMap else { return [] }
        return ranges.flatMap {
            displayMap.project(byteRange: $0)?.visible ?? []
        }
    }

    private func refreshFoldExposures(
        in document: ReaderDocument? = nil,
        occurrenceRanges: ArraySlice<ByteRange>? = nil
    ) {
        guard let document = document ?? displayedDocument else { return }
        let matchCounts = foldedRangeCounts(
            findMatchByteRanges ?? [],
            in: document
        )
        let occurrenceRanges = occurrenceRanges ?? occurrenceSelectionByteOffset.map {
            preparedOccurrences(in: document, at: $0)
        } ?? []
        let occurrenceCounts = foldedRangeCounts(
            occurrenceRanges,
            in: document
        )
        let foldedDiff = foldedDiffCache
        for (id, attachment) in foldAttachments {
            attachment.updateExposure(
                matchCount: matchCounts[id] ?? 0,
                hasDiff: foldedDiff[id] != nil,
                occurrenceCount: occurrenceCounts[id] ?? 0
            )
        }
    }

    private func foldedRangeCounts<R: Collection>(
        _ ranges: R,
        in document: ReaderDocument
    ) -> [FoldID: Int] where R.Element == ByteRange {
        let regions = renderedFoldRegionsCache
        guard !regions.isEmpty, !ranges.isEmpty else { return [:] }
        var result: [FoldID: Int] = [:]
        var regionIndex = 0
        for range in ranges.sorted(by: {
            ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound)
        }) {
            while regions.indices.contains(regionIndex),
                  regions[regionIndex].bodyRange.upperBound <= range.lowerBound
            {
                regionIndex += 1
            }
            guard regions.indices.contains(regionIndex) else { break }
            let region = regions[regionIndex]
            if region.bodyRange.overlaps(range) {
                result[region.id, default: 0] += 1
            }
        }
        return result
    }

    private func foldedDiffMarkers(
        in document: ReaderDocument
    ) -> [FoldID: DiffCore.MarkerKind] {
        let regions = renderedFoldRegionsCache
        guard !regions.isEmpty, !diffMarkers.isEmpty else { return [:] }
        var result: [FoldID: DiffCore.MarkerKind] = [:]
        var regionIndex = 0
        for (line, kind) in diffMarkers.sorted(by: { $0.key < $1.key }) {
            if isDrawingRuler { ReaderWorkCounters.record(\.drawGlobalRecordVisits) }
            guard line > 0,
                  document.lineTable.lineStarts.indices.contains(line - 1)
            else { continue }
            let byteOffset = document.lineTable.lineStarts[line - 1]
            while regions.indices.contains(regionIndex),
                  regions[regionIndex].bodyRange.upperBound <= byteOffset
            {
                regionIndex += 1
            }
            guard regions.indices.contains(regionIndex) else { break }
            let region = regions[regionIndex]
            guard region.bodyRange.contains(byteOffset) else { continue }
            if let current = result[region.id], current.rawValue != kind.rawValue {
                result[region.id] = .changed
            } else {
                result[region.id] = kind
            }
        }
        return result
    }

    private func buildVisibleBookmarkMarkers() -> [Int: [String]] {
        guard let document = displayedDocument else { return [:] }
        var result: [Int: [String]] = [:]
        let regions = renderedFoldRegionsCache
        for (line, labels) in bookmarkMarkers {
            if isDrawingRuler { ReaderWorkCounters.record(\.drawGlobalRecordVisits, 1 + regions.count) }
            guard line > 0,
                  document.lineTable.lineStarts.indices.contains(line - 1)
            else { continue }
            let offset = document.lineTable.lineStarts[line - 1]
            let targetLine: Int
            if let region = regions.filter({ $0.bodyRange.contains(offset) }).max(
                by: { $0.outlineDepth < $1.outlineDepth }
            ), let header = document.lineTable.lineColumn(
                at: region.headerRange.lowerBound
            )?.line {
                targetLine = Int(header)
            } else {
                targetLine = line
            }
            result[targetLine, default: []].append(contentsOf: labels)
        }
        return result.mapValues { labels in
            labels.sorted()
        }
    }

    private var bookmarkAccessibilityLabel: String {
        let markers = visibleBookmarksByLine
        guard !markers.isEmpty else { return "" }
        return localizedFormat("reader.bookmarks", markers.keys.sorted().map { line in
            localizedFormat("reader.bookmark.line", Int64(line), markers[line, default: []].joined(separator: ", "))
        }.joined(separator: "; "))
    }

    private func updateBookmarkAccessibilityLabel() {
        guard lineNumbers, !bookmarkMarkers.isEmpty else {
            ruler?.setAccessibilityLabel(nil)
            return
        }
        ruler?.setAccessibilityLabel(bookmarkAccessibilityLabel)
    }

    private func installRenderingValidator(
        in layoutManager: NSTextLayoutManager
    ) {
        guard !isCommittingProjection else { return }
        guard renderingCoordinator.hasRenderingAttributes else {
            layoutManager.renderingAttributesValidator = nil
            return
        }
        layoutManager.renderingAttributesValidator = {
            [weak renderingCoordinator] manager, fragment in
            renderingCoordinator?.style(fragment: fragment, in: manager)
        }
    }

    private func updateCurrentLine(byteOffset: UInt32) {
        caretByteOffset = byteOffset
        refreshBracketMatch()
        onCaretChange?(byteOffset)
        guard let line = displayedDocument?.lineTable.lineColumn(at: byteOffset)?.line
        else {
            updateCurrentLine(line: nil)
            return
        }
        updateCurrentLine(line: Int(line))
    }

    private func updateCurrentLine(line: Int?) {
        guard currentLineNumber != line else { return }
        currentLineNumber = line
        view.needsDisplay = true
        overviewRulerView?.needsDisplay = true
    }

    private func updateRulerThickness() {
        guard let ruler else { return }
        ruler.ruleThickness = lineNumberColumnWidth
            + declarationColumnWidth
            + foldColumnWidth
            + bookmarkColumnWidth
            + diffColumnWidth
        // NSScrollView already offsets its document view past the ruler.
        view.textContainerInset.width = 10
        scrollView?.tile()
    }

    /// Read several times per gutter row while drawing; measure only when the
    /// digit count or number font changes.
    private var lineNumberWidthCache: (lineCount: Int, fontSize: CGFloat, width: CGFloat)?

    private var lineNumberColumnWidth: CGFloat {
        guard lineNumbers else { return 0 }
        let lineCount = displayedDocument?.lineTable.lineStarts.count ?? 1
        let fontSize = CGFloat(max(10, theme.fontSize - 2))
        if let cache = lineNumberWidthCache, cache.lineCount == lineCount, cache.fontSize == fontSize {
            return cache.width
        }
        let width = ceil((String(lineCount) as NSString).size(
            withAttributes: [.font: lineNumberFont]
        ).width) + 12
        lineNumberWidthCache = (lineCount, fontSize, width)
        return width
    }

    private var lineNumberFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(10, theme.fontSize - 2), weight: .regular)
    }

    private let lineNumberLabels = LineNumberLabels()

    private var declarationColumnWidth: CGFloat {
        lineNumbers ? 7 : 0
    }

    private var diffColumnWidth: CGFloat {
        diffMarkers.isEmpty ? 0 : 7
    }

    private var bookmarkColumnWidth: CGFloat {
        lineNumbers && !bookmarkMarkers.isEmpty ? 7 : 0
    }

    private var foldColumnWidth: CGFloat {
        hasVisibleFoldRegions || navigationLandingLine != nil ? 12 : 0
    }

    private var hasVisibleFoldRegions: Bool {
        guard let document = displayedDocument else { return false }
        return !visibleFoldRegions(in: document).isEmpty
    }

    private static func declarationKindsByLine(
        in document: ReaderDocument
    ) -> [Int: OutlineKind] {
        ReaderWorkCounters.record(\.decorationBuildCount)
        var result: [Int: OutlineKind] = [:]
        for facet in document.outlineFacets {
            guard let position = document.lineTable.lineColumn(
                at: facet.nameRange.lowerBound
            ) else { continue }
            result[Int(position.line)] = facet.kind
        }
        return result
    }

    private func enumerateVisibleLayoutFragments(
        _ body: (NSTextLayoutFragment, Int) -> Void
    ) {
        guard let document = displayedDocument,
              let manager = view.textLayoutManager,
              let content = manager.textContentManager,
              let viewportRange =
                manager.textViewportLayoutController.viewportRange
        else { return }
        let viewport = manager.textViewportLayoutController.viewportBounds
        manager.enumerateTextLayoutFragments(
            from: viewportRange.location,
            options: []
        ) { fragment in
            // Permit the terminal empty fragment, but never scan an unlaid tail.
            guard fragment.rangeInElement.location.compare(viewportRange.endLocation) != .orderedDescending else { return false }
            let frame = fragment.layoutFragmentFrame
            guard frame.minY <= viewport.maxY else { return false }
            guard frame.intersects(viewport) else { return true }
            let utf16Offset = content.offset(
                from: content.documentRange.location,
                to: fragment.rangeInElement.location
            )
            guard utf16Offset != NSNotFound,
                  let byteOffset = self.sourceByteOffset(forDisplay: utf16Offset),
                  let line = document.lineTable.lineColumn(at: byteOffset)?.line
            else { return true }
            body(fragment, Int(line))
            return true
        }
    }

    private func fragmentRectInTextView(
        _ fragment: NSTextLayoutFragment
    ) -> NSRect {
        fragment.layoutFragmentFrame.offsetBy(
            dx: view.textContainerInset.width,
            dy: view.textContainerInset.height
        )
    }

    private func drawCurrentLineBackground(
        in textView: NSTextView,
        dirtyRect: NSRect
    ) {
        guard let currentLineNumber else { return }
        enumerateVisibleLayoutFragments { fragment, line in
            guard line == currentLineNumber else { return }
            let fragmentRect = fragmentRectInTextView(fragment)
            let rect = NSRect(
                x: textView.visibleRect.minX,
                y: fragmentRect.minY,
                width: textView.visibleRect.width,
                height: fragmentRect.height
            ).intersection(dirtyRect)
            guard !rect.isNull else { return }
            theme.currentLineColor.setFill()
            rect.fill()
        }
    }

    private func drawPrimarySelection(
        in textView: NSTextView,
        dirtyRect: NSRect
    ) {
        guard let range = primarySelectionRange,
              range.length > 0
        else {
            lastPrimarySelectionSegmentsForTesting = []
            return
        }
        let segments = ReaderViewportGeometry.visibleRects(
            forDisplayRange: range,
            in: textView,
            clipTo: textView.visibleRect
        )
        lastPrimarySelectionSegmentsForTesting = segments
        for segment in segments {
            // Zero-length carets never reach here (length > 0 above); each
            // visible visual-row fragment of the hit is emphasized on its
            // own, never one box spanning whole rows (W23).
            let rect = NSRect(
                x: segment.minX - 1.5,
                y: segment.minY,
                width: segment.width + 3,
                height: segment.height
            )
            guard rect.intersects(dirtyRect) else { continue }
            let outer = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            theme.primarySelectionFillColor.setFill()
            outer.fill()
            let stroke = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.8, dy: 0.8),
                xRadius: 3.2,
                yRadius: 3.2
            )
            stroke.lineWidth = 1.6
            theme.accentColor.setStroke()
            stroke.stroke()
        }
    }

    func drawRuler(
        in ruler: NSRulerView,
        dirtyRect: NSRect
    ) {
        guard !isCommittingProjection else { return }
        isDrawingRuler = true
        defer { isDrawingRuler = false }
        if !usesPreparedDecorations { refreshVisibleFoldRegions() }
        theme.backgroundColor.setFill()
        dirtyRect.intersection(ruler.bounds).fill()
        var lines: [Int] = []
        let font = lineNumberFont
        let bookmarksByLine = lineNumbers ? visibleBookmarksByLine : [:]
        // First-row decoration observables (§7.1): what this pass actually
        // drew and where. Cleared per draw so stale rows never linger.
        lastRulerFirstRowRectsForTesting = [:]
        lastRulerLabelDrawRectsForTesting = [:]
        enumerateVisibleLayoutFragments { fragment, line in
            guard let firstRowInView = ReaderViewportGeometry
                .firstVisualRowRect(ofFragment: fragment, in: view)
            else { return }
            let firstRow = ruler.convert(firstRowInView, from: view)
            // Gutter row spans the ruler width; decorations may only occupy
            // the FIRST visual row of the logical line (D2.2).
            let rowRect = NSRect(
                x: ruler.bounds.minX, y: firstRow.minY,
                width: ruler.bounds.width, height: firstRow.height
            )
            // Decoration visibility follows the decoration's own rect, not
            // the whole (possibly wrapped) fragment: a first row scrolled
            // out leaves nothing to draw on continuation rows (W21).
            guard rowRect.intersects(dirtyRect) else { return }
            lastRulerFirstRowRectsForTesting[line] = firstRowInView
            if lineNumbers {
                // Explicit vertical centering from the measured number-font
                // height; the label box never borrows the row's own height
                // (D2.2: labelRect.minY != rowRect.minY when fonts differ).
                let labelHeight = ceil(font.ascender - font.descender)
                let labelRect = NSRect(
                    x: 2,
                    y: firstRow.midY - labelHeight / 2,
                    width: max(0, lineNumberColumnWidth - 6),
                    height: labelHeight
                )
                lineNumberLabels.draw(
                    line, font: font, color: theme.lineNumberColor,
                    rightAlignedIn: labelRect, flipped: ruler.isFlipped
                )
                lastRulerLabelDrawRectsForTesting[line] = ruler.convert(
                    labelRect,
                    to: view
                )
                lines.append(line)
                if let kind = declarationKindsByLine[line] {
                    drawDeclarationMarker(
                        kind,
                        in: NSRect(
                            x: lineNumberColumnWidth + 1,
                            y: firstRow.midY - 2,
                            width: 4,
                            height: 4
                        )
                    )
                }
            }
            if let fold = visibleFoldsByLine[line],
               foldGutterHoveredID == fold.id
            {
                drawFoldChevron(
                    collapsed: renderedFoldIDs.contains(fold.id),
                    in: NSRect(
                        x: lineNumberColumnWidth + declarationColumnWidth,
                        y: firstRow.minY,
                        width: foldColumnWidth,
                        height: firstRow.height
                    )
                )
            }
            if navigationLandingLine == line {
                theme.accentColor.setFill()
                let markerHeight = min(8, max(3, firstRow.height - 4))
                NSBezierPath(
                    roundedRect: NSRect(
                        x: lineNumberColumnWidth + declarationColumnWidth + 4,
                        y: firstRow.midY - markerHeight / 2,
                        width: 4,
                        height: markerHeight
                    ),
                    xRadius: 2,
                    yRadius: 2
                ).fill()
            }
            if bookmarksByLine[line] != nil {
                theme.accentColor.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: lineNumberColumnWidth + declarationColumnWidth
                        + foldColumnWidth + 1,
                    y: firstRow.midY - 2.25,
                    width: 4.5,
                    height: 4.5
                )).fill()
            }
            let directDiff = diffMarkers[line]
            let foldedDiff = foldedDiffByLine[line]
            let mergedDiff: DiffCore.MarkerKind?
            if let directDiff, let foldedDiff,
               directDiff.rawValue != foldedDiff.rawValue
            {
                mergedDiff = .changed
            } else {
                mergedDiff = directDiff ?? foldedDiff
            }
            if let kind = mergedDiff {
                theme.color(for: kind).setFill()
                NSRect(
                    x: lineNumberColumnWidth + declarationColumnWidth
                        + foldColumnWidth + bookmarkColumnWidth + 1,
                    y: firstRow.minY,
                    width: max(2, diffColumnWidth - 2),
                    height: max(2, firstRow.height)
                ).fill()
            }
        }
        visibleLineNumbers = lineNumbers ? lines : []
    }

    private func drawFoldChevron(collapsed: Bool, in rect: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if collapsed {
            path.move(to: NSPoint(x: rect.midX - 2, y: rect.midY - 3))
            path.line(to: NSPoint(x: rect.midX + 2, y: rect.midY))
            path.line(to: NSPoint(x: rect.midX - 2, y: rect.midY + 3))
        } else {
            path.move(to: NSPoint(x: rect.midX - 3, y: rect.midY - 2))
            path.line(to: NSPoint(x: rect.midX, y: rect.midY + 2))
            path.line(to: NSPoint(x: rect.midX + 3, y: rect.midY - 2))
        }
        theme.chromeSecondaryColor.setStroke()
        path.stroke()
    }

    func updateFoldHover(at point: NSPoint?, in ruler: NSRulerView) {
        let next = point.flatMap { foldRegion(at: $0, in: ruler)?.id }
        guard next != foldGutterHoveredID else { return }
        foldGutterHoveredID = next
        ruler.needsDisplay = true
    }

    func clickFoldHandle(
        at point: NSPoint,
        in ruler: NSRulerView,
        modifiers: NSEvent.ModifierFlags
    ) {
        guard let region = foldRegion(at: point, in: ruler),
              let document = displayedDocument,
              let line = document.lineTable.lineColumn(
                  at: region.headerRange.lowerBound
              )?.line
        else { return }
        _ = toggleFold(
            atLine: Int(line),
            recursiveSiblings: modifiers.contains(.option)
        )
    }

    private func foldRegion(
        at point: NSPoint,
        in ruler: NSRulerView
    ) -> FoldRegion? {
        let foldX = lineNumberColumnWidth + declarationColumnWidth
        guard foldColumnWidth > 0,
              point.x >= foldX,
              point.x <= foldX + foldColumnWidth,
              displayedDocument != nil
        else { return nil }
        if !usesPreparedDecorations { refreshVisibleFoldRegions() }
        var match: FoldRegion?
        enumerateVisibleLayoutFragments { fragment, line in
            guard match == nil, let region = visibleFoldsByLine[line] else { return }
            guard let firstRow = ReaderViewportGeometry.firstVisualRowRect(
                ofFragment: fragment,
                in: view
            ) else { return }
            // Half-open y range on the first visual row only: continuation
            // rows of a wrapped fold header never hit (C4/D2.3).
            let rowRect = ruler.convert(firstRow, from: view)
            if rowRect.minY <= point.y, point.y < rowRect.maxY {
                match = region
            }
        }
        return match
    }

    private func drawDeclarationMarker(
        _ kind: OutlineKind,
        in rect: NSRect
    ) {
        declarationMarkerColor(for: kind).setFill()
        switch kind {
        case .fn, .method:
            NSBezierPath(ovalIn: rect).fill()
        case .impl:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            path.line(to: NSPoint(x: rect.midX, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX, y: rect.midY))
            path.close()
            path.fill()
        case .mod, .const, .static, .field, .enumMember:
            NSRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1)
                .fill()
        case .struct, .enum, .trait, .typeAlias, .class:
            rect.fill()
        }
    }

    func declarationMarkerColor(for kind: OutlineKind) -> NSColor {
        let color: NSColor
        switch kind {
        case .fn, .method:
            color = theme.color(for: .functionName)
        case .struct, .enum, .trait, .typeAlias, .class:
            color = theme.color(for: .declarationTitle)
        case .impl:
            color = theme.color(for: .typeName)
        case .mod, .const, .static:
            color = theme.color(for: .declarationEmphasis)
        case .field:
            color = theme.color(for: .property)
        case .enumMember:
            color = theme.color(for: .enumMember)
        }
        return color.withAlphaComponent(theme.declarationMarkerAlpha)
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = theme.lineHeightMultiple
        var attributes = ReaderFontResolver.shared.resolve(theme: theme).attributes
        attributes[.foregroundColor] = theme.foregroundColor
        attributes[.paragraphStyle] = paragraph
        return attributes
    }

    /// Preserve source text and the map; remeasure attachments through attributes.
    private func updateTypography(document: ReaderDocument, map: DisplayMap) {
        let started = ContinuousClock.now
        defer {
            let duration = started.duration(to: .now).components
            typographyAttributeUpdateMilliseconds += Double(duration.seconds) * 1000
                + Double(duration.attoseconds) / 1e15
        }
        let attributes = baseAttributes
        let range = NSRange(location: 0, length: backingTextStorage.length)
        let update = {
            self.backingTextStorage.beginEditing()
            // Match initial projection attributes, including fold placeholders.
            // Merging leaves attachments, links and other owners' keys intact.
            self.backingTextStorage.removeAttribute(.ligature, range: range)
            self.backingTextStorage.removeAttribute(.kern, range: range)
            ReaderWorkCounters.record(\.attributeUpdatedUTF16Units, range.length)
            self.backingTextStorage.addAttributes(attributes, range: range)
            self.updateFoldAttachmentAttributes(document: document, map: map)
            Self.applyTypography(document.highlightSpans, map: map,
                to: self.backingTextStorage, theme: self.theme,
                proseComments: self.proseCommentsEnabled(for: document))
            self.paragraphLayout.reset()
            self.applyParagraphLayout(to: self.backingTextStorage)
            self.backingTextStorage.endEditing()
        }
        if let content = view.textContentStorage {
            content.performEditingTransaction(update)
        } else {
            update()
        }
        typographyAttributeUpdateCount += 1
    }

    private func updateFoldAttachmentAttributes(document: ReaderDocument, map: DisplayMap) {
        for placeholder in map.foldPlaceholders {
            guard let region = document.foldTopology?.region(for: placeholder.id) else { continue }
            let attachment: FoldAttachment
            if let previous = foldAttachments[placeholder.id], previous.matches(region) {
                previous.updateTypography(theme)
                attachment = previous
            } else {
                attachment = FoldAttachment(region: region, theme: theme)
                if let previous = foldAttachments[placeholder.id] {
                    attachment.updateExposure(matchCount: previous.matchCount,
                        hasDiff: previous.hasDiff, occurrenceCount: previous.occurrenceCount)
                }
                foldAttachments[placeholder.id] = attachment
            }
            backingTextStorage.addAttribute(.attachment, value: attachment,
                range: NSRange(location: placeholder.offset, length: 1))
            ReaderWorkCounters.record(\.attributeUpdatedUTF16Units)
        }
    }

    private var paragraphIndentLimit: CGFloat? {
        guard wrapLines, let container = view.textContainer else { return nil }
        return ReaderParagraphLayout.maximumIndent(
            width: container.size.width - 2 * container.lineFragmentPadding,
            font: ReaderFontResolver.shared.resolve(theme: theme).font
        )
    }

    private func applyParagraphLayout(to text: NSMutableAttributedString, in range: NSRange? = nil) {
        guard let container = view.textContainer else { return }
        defer { lastParagraphIndentLimit = paragraphIndentLimit }
        let document = displayedDocument
        let map = displayMap
        paragraphUpdateCount += paragraphLayout.apply(
            to: text, wrap: wrapLines,
            width: container.size.width - 2 * container.lineFragmentPadding,
            font: ReaderFontResolver.shared.resolve(theme: theme).font,
            sourceLineAt: { offset in
            guard let document, let position = map?.sourcePosition(ofDisplay: offset) else { return nil }
            let byte: UInt32
            switch position {
            case .source(let source): byte = source
            case .placeholder(let id):
                guard let header = document.foldTopology?.region(for: id)?.headerRange.lowerBound else { return nil }
                byte = header
            }
            guard let line = document.lineTable.lineColumn(at: byte)?.line else { return nil }
            let start = Int(document.lineTable.lineStarts[Int(line) - 1])
            var end = start
            while end < document.bytes.count,
                  document.bytes[end] == 32 || document.bytes[end] == 9 { end += 1 }
            let prefix = String(decoding: document.bytes[start..<end], as: UTF8.self)
            let hasBody = end < document.bytes.count && document.bytes[end] != 10 && document.bytes[end] != 13
            return prefix + (hasBody ? "x" : "")
        }, in: range)
    }

    private func updateParagraphLayout() {
        // Geometry-only updates cannot change any indent when both widths
        // have the same effective cap. Content/typography installs always
        // use applyParagraphLayout directly and refresh this cached limit.
        if let limit = paragraphIndentLimit, limit == lastParagraphIndentLimit { return }
        let selection = view.selectedRanges
        let affinity = view.selectionAffinity
        if let content = view.textContentStorage {
            content.performEditingTransaction { applyParagraphLayout(to: backingTextStorage) }
        } else {
            applyParagraphLayout(to: backingTextStorage)
        }
        if view.selectedRanges != selection || view.selectionAffinity != affinity {
            view.setSelectedRanges(selection, affinity: affinity, stillSelecting: false)
        }
    }

    private func configure() {
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = true
        view.textContainerInset = NSSize(width: 10, height: 12)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func configureWrapping(in scrollView: NSScrollView) {
        configureWrapping(in: scrollView,
                          previousViewportStart: view.textLayoutManager?.textViewportLayoutController.viewportRange?.location)
    }

    /// Exercises the missing-state policy independently of TextKit eagerly creating a viewport.
    package func configureWrappingForTesting(previousViewportStart: (any NSTextLocation)?) {
        guard let scrollView = view.enclosingScrollView else { return }
        configureWrapping(in: scrollView, previousViewportStart: previousViewportStart)
    }

    private func configureWrapping(in scrollView: NSScrollView, previousViewportStart: (any NSTextLocation)?) {
        // The clip's bounds start behind the ruler (negative x by its inset);
        // wrapped text may only use the part the reader can actually see.
        let clipView = scrollView.contentView
        let width = clipView.bounds.width - clipView.contentInsets.left - clipView.contentInsets.right
        // Do not consume the container-width transition before a real viewport exists.
        guard width > 1, scrollView.contentView.bounds.height > 1 else {
            lastViewportRestoreWasLimited = true
            lastViewportAnchorErrorPt = nil
            lastViewportRestoreLimitation = "zero-geometry"
            return
        }
        // TextKit 2 does not invalidate layout when the container size
        // changes: without this, a wrap toggle keeps serving fragments from
        // the previous layout (verified by the S1 probes). Invalidate only
        // when the effective width actually changes so repeated gutter
        // reconfigures never trigger redundant relayouts.
        let previousWidth = view.textContainer?.size.width
        let targetWidth: CGFloat = wrapLines ? width : CGFloat.greatestFiniteMagnitude
        scrollView.hasHorizontalScroller = !wrapLines
        view.isHorizontallyResizable = !wrapLines
        if wrapLines {
            view.autoresizingMask.insert(.width)
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
        } else {
            view.autoresizingMask.remove(.width)
        }
        view.textContainer?.widthTracksTextView = wrapLines
        view.textContainer?.containerSize = NSSize(
            width: targetWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        if let previousWidth, abs(targetWidth - previousWidth) > 0.01 {
            if !wrapLines,
               let manager = view.textLayoutManager,
               let content = manager.textContentManager,
               previousWidth.isFinite
            {
                // The old wrapped viewport can sit past the shorter content.
                // Ordinary files resolve the full extent; large files use the
                // native viewport estimate and refine it as content is visited.
                var extent = CGRect.null
                let viewportOnly = usesCostAwareReflow ? requiresViewportOnlyLayout
                    : ((displayedDocument?.lineTable.lineStarts.count ?? 0) > 8_000 && previousViewportStart != nil)
                if viewportOnly {
                    // Estimated extent is the large-cost policy even without an old viewport.
                    if let previousViewportStart {
                        let controller = manager.textViewportLayoutController
                        for _ in 0..<2 {
                            let y = controller.relocateViewport(to: previousViewportStart)
                            scrollView.contentView.scroll(to: NSPoint(
                                x: scrollView.contentView.bounds.minX, y: y
                            ))
                            controller.layoutViewport()
                        }
                    } else {
                        lastViewportRestoreWasLimited = true
                        lastViewportAnchorErrorPt = nil
                        lastViewportRestoreLimitation = "no-previous-viewport"
                    }
                    extent = manager.usageBoundsForTextContainer
                } else {
                    ReaderWorkCounters.record(\.applicationFullLayoutCount)
                    manager.enumerateTextLayoutFragments(
                        from: content.documentRange.location,
                        options: [.ensuresLayout]
                    ) { fragment in
                        extent = extent.union(fragment.layoutFragmentFrame)
                        return true
                    }
                }
                if !extent.isNull, !extent.isEmpty {
                    let inset = view.textContainerInset
                    view.setFrameSize(NSSize(
                        width: extent.maxX + inset.width * 2,
                        height: extent.maxY + inset.height * 2
                    ))
                }
            }
        }
        scrollView.tile()
        guard scrollView.contentView.bounds.width > 1,
              scrollView.contentView.bounds.height > 1 else {
            lastViewportRestoreWasLimited = true
            lastViewportAnchorErrorPt = nil
            lastViewportRestoreLimitation = "zero-geometry"
            return
        }
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    /// Reading a historical commit: the page turns sepia so the past is never
    /// mistaken for the working tree.
    public var historicalSnapshot = false {
        didSet {
            guard historicalSnapshot != oldValue else { return }
            applyThemeColors()
        }
    }

    private func applyThemeColors() {
        view.backgroundColor = historicalSnapshot ? theme.histReaderColor : theme.backgroundColor
        overviewRulerView?.needsDisplay = true
    }

    private static func project(
        document: ReaderDocument,
        renderedFoldIDs: Set<FoldID>,
        attributes: [NSAttributedString.Key: Any],
        theme: ReaderTheme
    ) -> (
        attributed: NSMutableAttributedString,
        map: DisplayMap,
        attachments: [FoldID: FoldAttachment]
    )? {
        guard let map = DisplayMap(document: document, renderedFoldIDs: renderedFoldIDs),
              let materialized = materializeProjection(document: document, map: map,
                  attributes: attributes, theme: theme) else { return nil }
        return (materialized.attributed, map, materialized.attachments)
    }

    /// Geometry is already validated; this is the explicit UI materialization seam.
    private static func materializeProjection(
        document: ReaderDocument, map: DisplayMap,
        attributes: [NSAttributedString.Key: Any], theme: ReaderTheme,
        displayRange: NSRange? = nil
    ) -> (attributed: NSMutableAttributedString, attachments: [FoldID: FoldAttachment])? {
        guard let topology = document.foldTopology else { return nil }
        let range = displayRange ?? NSRange(location: 0, length: map.projectedUTF16Length)
        guard let string = map.projection.materialize(displayRange: range) else { return nil }
        ReaderWorkCounters.record(\.attributeUpdatedUTF16Units, range.length)
        let attributed = NSMutableAttributedString(
            string: string,
            attributes: attributes
        )
        applyTypography(
            document.highlightSpans,
            map: map,
            to: attributed,
            theme: theme, displayRange: range,
            proseComments: proseCommentsEnabled(document, theme: theme)
        )
        var attachments: [FoldID: FoldAttachment] = [:]
        guard let placeholders = map.foldPlaceholders(in: range) else { return nil }
        attachments.reserveCapacity(placeholders.count)
        for placeholder in placeholders {
            guard let region = topology.region(for: placeholder.id) else { return nil }
            let attachment = FoldAttachment(region: region, theme: theme)
            attributed.addAttribute(
                .attachment,
                value: attachment,
                range: NSRange(location: placeholder.offset - range.location, length: 1)
            )
            attachments[placeholder.id] = attachment
        }
        return (attributed, attachments)
    }

    // Defense-in-depth fuse only; projection construction is the root consistency seam.
    private func projectionMatchesStorage(_ map: DisplayMap) -> Bool {
        let matches = map.projectedUTF16Length == backingTextStorage.length
#if DEBUG
        // Unit tests have no app delegate so they can exercise the release fallback.
        if !matches, NSApp?.delegate != nil {
            assertionFailure("Reader document and text storage lengths diverged")
        }
#endif
        return matches
    }

    /// Prose comments are a font run per comment, applied to the whole backing
    /// store. Documents that already need viewport-only layout keep monospaced
    /// comments so a comment-dense file never builds hundreds of thousands of runs.
    static func proseCommentsEnabled(
        _ document: ReaderDocument,
        theme: ReaderTheme,
        policy: ReaderReflowPolicy = ReaderReflowPolicy()
    ) -> Bool {
        guard theme.humanistComments else { return false }
        guard let cost = document.cost else { return false }
        return !policy.requiresViewportOnlyLayout(for: cost)
    }

    private func proseCommentsEnabled(for document: ReaderDocument) -> Bool {
        Self.proseCommentsEnabled(document, theme: theme, policy: reflowPolicy)
    }

    private static func metricSpans(
        _ spans: [HighlightSpan], theme: ReaderTheme, proseComments: Bool
    ) -> [HighlightSpan] {
        spans.filter {
            switch $0.kind {
            case .functionName, .declarationTitle, .declarationEmphasis: true
            case .comment: proseComments
            default: false
            }
        }
    }

    /// Prose comments use the system serif italic (New York), one point larger
    /// so it reads at the same visual size as the monospaced code beside it.
    static func proseCommentFont(size: Double) -> NSFont {
        let pointSize = CGFloat(size + 1)
        let base = NSFont.systemFont(ofSize: pointSize)
        guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
        let italic = serif.withSymbolicTraits(.italic)
        return NSFont(descriptor: italic, size: pointSize)
            ?? NSFont(descriptor: serif, size: pointSize) ?? base
    }

    static func applyTypography(
        _ spans: [HighlightSpan],
        map: DisplayMap,
        to attributed: NSMutableAttributedString,
        theme: ReaderTheme,
        displayRange: NSRange? = nil,
        proseComments: Bool? = nil
    ) {
        guard theme.syntaxFormatting else { return }
        let proseComments = proseComments ?? theme.humanistComments
        let extent = displayRange ?? NSRange(location: 0, length: map.projectedUTF16Length)

        func apply(_ span: HighlightSpan) {
            guard let projected = map.project(byteRange: span.range) else { return }
            for range in projected.visible {
                let intersection = NSIntersectionRange(range, extent)
                let safeRange = NSRange(location: intersection.location - extent.location,
                                        length: intersection.length)
                guard safeRange.length > 0 else { continue }
                switch span.kind {
                case .functionName, .declarationTitle:
                    ReaderWorkCounters.record(\.attributeUpdatedUTF16Units, safeRange.length)
                    // Source Insight hierarchy: definitions read as headings,
                    // type titles one step below function names.
                    let size = span.kind == .functionName
                        ? theme.functionNameFontSize : theme.typeNameFontSize
                    let resolved = ReaderFontResolver.shared.resolve(
                        theme: theme, size: size,
                        weight: NSFont.Weight(rawValue: theme.functionDeclarationFontWeight)
                    )
                    attributed.addAttributes(resolved.attributes, range: safeRange)
                    if theme.codeFont == .systemMonospaced && theme.codeLigatures == .fontDefault {
                        attributed.addAttribute(.kern,
                            value: size > theme.fontSize ? 0.15 : 0,
                            range: safeRange)
                    } else {
                        attributed.removeAttribute(.kern, range: safeRange)
                    }
                case .declarationEmphasis:
                    ReaderWorkCounters.record(\.attributeUpdatedUTF16Units, safeRange.length)
                    attributed.addAttributes(ReaderFontResolver.shared.resolve(
                        theme: theme,
                        weight: NSFont.Weight(rawValue: theme.declarationEmphasisFontWeight)
                    ).attributes, range: safeRange)
                case .comment where proseComments:
                    ReaderWorkCounters.record(\.attributeUpdatedUTF16Units, safeRange.length)
                    attributed.addAttribute(.font,
                        value: Self.proseCommentFont(size: theme.fontSize), range: safeRange)
                    attributed.removeAttribute(.ligature, range: safeRange)
                    attributed.removeAttribute(.kern, range: safeRange)
                default:
                    break
                }
            }
        }

        guard let visibleRanges = map.visibleSourceRanges(forDisplay: extent) else { return }
        for visible in visibleRanges {
            for span in ViewportGating.spans(spans,
                intersectingBytes: visible.lowerBound..<visible.upperBound, buffer: 0) {
                apply(span)
            }
        }
    }

    /// Scroll-time counterpart of `validateVisibleRenderingAttributes`: style
    /// data is unchanged, so republishing every visible fragment would only
    /// force TextKit to redraw text that already has current attributes.
    private func styleUnstyledVisibleFragments(
        in layoutManager: NSTextLayoutManager, updateLayout: Bool = false
    ) {
        guard !isCommittingProjection, !isValidatingVisibleRenderingAttributes,
              renderingCoordinator.hasRenderingAttributes,
              layoutManager.renderingAttributesValidator != nil
        else { return }
        isValidatingVisibleRenderingAttributes = true
        defer { isValidatingVisibleRenderingAttributes = false }
        let controller = layoutManager.textViewportLayoutController
        if updateLayout {
            // Same native layout as the full pass (see there): TextKit does not
            // reliably re-run the validator for fragments this layout brings in.
            let wasRestoring = isRestoringViewport
            isRestoringViewport = true
            controller.layoutViewport()
            isRestoringViewport = wasRestoring
        }
        guard let viewportRange = controller.viewportRange else { return }
        let origin = view.textContainerOrigin
        let visible = view.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        var restyled = NSRect.null
        layoutManager.enumerateTextLayoutFragments(
            from: viewportRange.location,
            options: []
        ) { fragment in
            // Same bounds as the full pass: never walk an unlaid tail.
            guard fragment.rangeInElement.location.compare(viewportRange.endLocation) == .orderedAscending
            else { return false }
            let frame = fragment.layoutFragmentFrame
            guard frame.minY <= visible.maxY else { return false }
            guard frame.intersects(visible), renderingCoordinator.needsStyle(fragment) else { return true }
            renderingCoordinator.style(fragment: fragment, in: layoutManager)
            restyled = restyled.union(frame)
            return true
        }
        if !restyled.isNull {
            view.setNeedsDisplay(restyled.offsetBy(dx: origin.x, dy: origin.y))
        }
        captureVisibleDecorationState()
    }

    private func validateVisibleRenderingAttributes(
        in layoutManager: NSTextLayoutManager, updateLayout: Bool = true
    ) {
        // TextKit can resize the document and post scroll notifications during layout.
        // Finish this pass before another notification can start viewport layout again.
        guard !isCommittingProjection, !isValidatingVisibleRenderingAttributes else { return }
        isValidatingVisibleRenderingAttributes = true
        defer { isValidatingVisibleRenderingAttributes = false }
        let controller = layoutManager.textViewportLayoutController
        if updateLayout {
            (view as? ClickTextView)?.viewportNeedsValidationAfterLayout = true
            // Native layout may adjust the clip origin. That is not user
            // scrolling and must not discard the reflow anchor/corrections.
            let wasRestoring = isRestoringViewport
            isRestoringViewport = true
            controller.layoutViewport()
            // After the document shrinks (e.g. switching to Structure), TextKit
            // can relocate the viewport past its new end: only the last rows
            // show and wheel scrolling stalls until the scroller re-tiles.
            if let scrollView = view.enclosingScrollView {
                let clipView = scrollView.contentView
                let y = clampVerticalScrollOrigin(clipView.bounds.minY, clipView: clipView)
                if y != clipView.bounds.minY {
                    clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: y))
                    scrollView.reflectScrolledClipView(clipView)
                    controller.layoutViewport()
                }
            }
            isRestoringViewport = wasRestoring
        }
        guard let viewportRange = controller.viewportRange else { return }
        layoutManager.invalidateRenderingAttributes(for: viewportRange)
        let viewport = controller.viewportBounds.insetBy(
            dx: 0,
            dy: -controller.viewportBounds.height * 2
        )
        layoutManager.enumerateTextLayoutFragments(
            from: viewportRange.location,
            options: []
        ) { fragment in
            // Unlaid fragments can have a zero frame; geometry alone would
            // walk and style the rest of the document outside this viewport.
            guard fragment.rangeInElement.location.compare(viewportRange.endLocation) == .orderedAscending,
                  fragment.layoutFragmentFrame.minY <= viewport.maxY else {
                return false
            }
            layoutManager.renderingAttributesValidator?(layoutManager, fragment)
            return true
        }
        captureVisibleDecorationState()
        view.needsDisplay = true
    }

}

@MainActor
private final class FoldAttachment: NSTextAttachment, @unchecked Sendable {
    private weak var activeProvider: FoldAttachmentViewProvider?
    private nonisolated let measuredSize: OSAllocatedUnfairLock<NSSize>
    nonisolated var chipSize: NSSize { measuredSize.withLock { $0 } }
    private let kind: FoldKind
    private let summary: FoldSummary
    nonisolated let bodyText: String
    nonisolated let accessibilityText: String
    private(set) var theme: ReaderTheme
    private(set) var chipFont: NSFont
    private(set) var chipAttributes: [NSAttributedString.Key: Any]
    private(set) var matchCount = 0
    private(set) var hasDiff = false
    private(set) var occurrenceCount = 0

    var visualExposureText: String {
        if matchCount > 999 { return " · 999" }
        if matchCount > 0 { return " · " + localizedFormat("reader.matches", Int64(matchCount)) }
        if occurrenceCount > 999 { return " · 999" }
        if occurrenceCount > 0 { return " · " + localizedFormat("reader.occurrences", Int64(occurrenceCount)) }
        return hasDiff ? " · " + localized("reader.diff") : ""
    }

    var accessibilityExposureText: String {
        var values: [String] = []
        if matchCount > 0 { values.append(localizedFormat("reader.matches", Int64(matchCount))) }
        if occurrenceCount > 0 { values.append(localizedFormat("reader.occurrences", Int64(occurrenceCount))) }
        if hasDiff { values.append(localized("reader.diff")) }
        return values.isEmpty ? "" : ", " + values.joined(separator: ", ")
    }

    init(region: FoldRegion, theme: ReaderTheme) {
        self.theme = theme
        kind = region.kind
        summary = region.summary
        bodyText = Self.bodyText(for: region)
        accessibilityText = Self.accessibilityText(for: region)
        let resolved = ReaderFontResolver.shared.resolve(
            theme: theme, size: max(8, theme.fontSize * 10 / 13), weight: .medium
        )
        chipFont = resolved.font
        chipAttributes = resolved.attributes
        measuredSize = OSAllocatedUnfairLock(initialState: Self.measure(
            bodyText, font: resolved.font, attributes: resolved.attributes
        ))
        super.init(data: nil, ofType: "com.codeinsight.fold-attachment")
        allowsTextAttachmentView = true
    }

    private static func measure(_ text: String, font: NSFont,
                                attributes: [NSAttributedString.Key: Any]) -> NSSize {
        let width = min(180, ceil((text as NSString).size(withAttributes: attributes).width))
        return NSSize(width: 5 + width + 54 + 5,
                      height: max(22, ceil(font.ascender - font.descender) + 8))
    }

    func matches(_ region: FoldRegion) -> Bool { kind == region.kind && summary == region.summary }

    func updateTypography(_ theme: ReaderTheme) {
        self.theme = theme
        let resolved = ReaderFontResolver.shared.resolve(
            theme: theme, size: max(8, theme.fontSize * 10 / 13), weight: .medium
        )
        chipFont = resolved.font
        chipAttributes = resolved.attributes
        let size = Self.measure(bodyText, font: resolved.font, attributes: resolved.attributes)
        measuredSize.withLock { $0 = size }
        activeProvider?.update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateTheme(_ theme: ReaderTheme) {
        self.theme = theme
        activeProvider?.update()
    }

    func setMatchCount(_ count: Int) {
        updateExposure(
            matchCount: count,
            hasDiff: hasDiff,
            occurrenceCount: occurrenceCount
        )
    }

    func updateExposure(
        matchCount: Int,
        hasDiff: Bool,
        occurrenceCount: Int
    ) {
        let matchCount = max(0, matchCount)
        let occurrenceCount = max(0, occurrenceCount)
        guard self.matchCount != matchCount
                || self.hasDiff != hasDiff
                || self.occurrenceCount != occurrenceCount
        else { return }
        self.matchCount = matchCount
        self.hasDiff = hasDiff
        self.occurrenceCount = occurrenceCount
        activeProvider?.update()
    }

    @preconcurrency override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = FoldAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        // AppKit invokes this nonisolated SDK hook on its main UI thread.
        nonisolated(unsafe) let owner = self
        nonisolated(unsafe) let created = provider
        MainActor.assumeIsolated { owner.activeProvider = created }
        return provider
    }

    private static func bodyText(for region: FoldRegion) -> String {
        let summary = region.summary
        switch region.kind {
        case .declaration:
            return joined(
                summary.leadingText,
                localizedFormat("reader.lines", Int64(summary.hiddenLineCount))
            )
        case .container:
            let members = orderedMembers(summary.memberCounts)
            return "⋯ " + (members + [localizedFormat("reader.lines", Int64(summary.hiddenLineCount))])
                .joined(separator: " · ")
        case .imports:
            return localizedFormat("reader.imports", Int64(summary.itemCount ?? 0))
        case .comment:
            return localizedFormat("reader.comments", Int64(summary.hiddenLineCount))
        case .attributes:
            return localizedFormat("reader.attributes", Int64(summary.itemCount ?? 0))
        case .cfgTest:
            let functionCount = (summary.memberCounts[.fn] ?? 0)
                + (summary.memberCounts[.method] ?? 0)
            return localizedFormat("reader.tests", localizedFormat("reader.member.fn", Int64(functionCount)), localizedFormat("reader.lines", Int64(summary.hiddenLineCount)))
        case .block:
            if let itemCount = summary.itemCount {
                return localizedFormat("reader.arms", Int64(itemCount))
            }
            return "⋯ " + localizedFormat("reader.lines", Int64(summary.hiddenLineCount))
        }
    }

    private static func accessibilityText(for region: FoldRegion) -> String {
        let members = orderedMembers(region.summary.memberCounts)
        let hidden = localizedFormat("reader.collapsed.lines", Int64(region.summary.hiddenLineCount))
        return members.isEmpty ? hidden : localizedFormat("reader.collapsed.members", hidden, members.joined(separator: ", "))
    }

    private static func joined(_ leading: String?, _ trailing: String) -> String {
        ["⋯", leading, trailing]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    private static func orderedMembers(
        _ counts: [OutlineKind: Int]
    ) -> [String] {
        let order: [OutlineKind] = [
            .mod, .trait, .impl, .struct, .class, .enum, .typeAlias,
            .const, .static, .fn, .method, .field, .enumMember,
        ]
        return order.compactMap { kind in
            guard let count = counts[kind], count > 0 else { return nil }
            return localizedFormat("reader.member.\(kind.rawValue)", Int64(count))
        }
    }
}

private final class FoldAttachmentViewProvider:
    NSTextAttachmentViewProvider,
    @unchecked Sendable
{
    nonisolated override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        guard let attachment = textAttachment as? FoldAttachment else {
            return super.attachmentBounds(
                for: attributes,
                location: location,
                textContainer: textContainer,
                proposedLineFragment: proposedLineFragment,
                position: position
            )
        }
        let size = attachment.chipSize
        return CGRect(x: 0, y: -6, width: size.width, height: size.height)
    }

    nonisolated override func loadView() {
        // AppKit invokes this nonisolated SDK hook on its main UI thread.
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated {
            guard let attachment = provider.textAttachment as? FoldAttachment else {
                provider.view = NSView(frame: .zero)
                return
            }
            provider.view = FoldChipView(attachment: attachment)
            provider.updateOnMainActor()
        }
    }

    @MainActor
    func update() { updateOnMainActor() }

    @MainActor
    private func updateOnMainActor() {
        guard let attachment = textAttachment as? FoldAttachment,
              let chip = view as? FoldChipView
        else { return }
        let size = attachment.chipSize
        if chip.frame.size != size { chip.setFrameSize(size) }
        chip.exposureText = attachment.visualExposureText
        chip.setAccessibilityLabel(
            attachment.accessibilityText + attachment.accessibilityExposureText
        )
        chip.needsDisplay = true
    }
}

private final class FoldChipView: NSView {
    let attachment: FoldAttachment
    var exposureText = ""

    init(attachment: FoldAttachment) {
        self.attachment = attachment
        super.init(frame: NSRect(origin: .zero, size: attachment.chipSize))
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let borderRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let border = NSBezierPath(roundedRect: borderRect, xRadius: 4, yRadius: 4)
        border.lineWidth = 1
        attachment.theme.chromeDividerColor.setStroke()
        border.stroke()

        let font = attachment.chipFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes = attachment.chipAttributes
        attributes[.foregroundColor] = attachment.theme.chipForegroundColor
        attributes[.paragraphStyle] = paragraph
        let countWidth: CGFloat = 54
        let textY = floor((bounds.height - font.ascender + font.descender) / 2)
        (attachment.bodyText as NSString).draw(
            in: NSRect(
                x: 5,
                y: textY,
                width: max(0, bounds.width - countWidth - 10),
                height: ceil(font.ascender - font.descender)
            ),
            withAttributes: attributes
        )
        (exposureText as NSString).draw(
            in: NSRect(
                x: bounds.width - countWidth - 5,
                y: textY,
                width: countWidth,
                height: ceil(font.ascender - font.descender)
            ),
            withAttributes: attributes
        )
    }
}

@MainActor
private final class ReaderRulerView: NSRulerView {
    private weak var reader: ReaderTextView?
    private var hoverTrackingArea: NSTrackingArea?

    init(scrollView: NSScrollView, reader: ReaderTextView) {
        self.reader = reader
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 7
        clientView = reader.view
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        // This ruler has no system markers. Bypass NSRulerView's edge hairline
        // and clip only Cairn's custom pass so line numbers stay visible.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        reader?.drawRuler(in: self, dirtyRect: dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseEntered(with event: NSEvent) {
        reader?.updateFoldHover(at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func mouseMoved(with event: NSEvent) {
        reader?.updateFoldHover(at: convert(event.locationInWindow, from: nil), in: self)
    }

    override func mouseExited(with event: NSEvent) {
        reader?.updateFoldHover(at: nil, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        reader?.clickFoldHandle(
            at: convert(event.locationInWindow, from: nil),
            in: self,
            modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        )
    }
}

@MainActor
private final class ClickTextView: NSTextView, NSTextViewDelegate {
    private var projectionRestoreRanges: [NSValue]?

    /// Setting NSRange+affinity loses AppKit's reverse Shift-extension anchor.
    /// One native command establishes it; the public delegate supplies the full
    /// target range instead of requiring one command per selected character.
    func restoreProjectionRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity) {
        guard ranges.count == 1, affinity == .upstream,
              let range = ranges.first?.rangeValue, range.length > 0 else {
            setSelectedRanges(ranges, affinity: affinity, stillSelecting: false)
            return
        }
        let previousDelegate = delegate
        setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        projectionRestoreRanges = ranges
        delegate = self
        defer {
            projectionRestoreRanges = nil
            delegate = previousDelegate
        }
        // Direct command, not a synthesized key event: selectionHandler remains
        // reserved for actual user gestures and must not erase latent ranges.
        super.moveLeftAndModifySelection(nil)
    }

    func textView(
        _ textView: NSTextView, willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue],
        toCharacterRanges newSelectedCharRanges: [NSValue]
    ) -> [NSValue] {
        projectionRestoreRanges ?? newSelectedCharRanges
    }


    // Code is top-left aligned. AppKit's inferred origin can force full-document
    // layout during scrolling; all native drawing and hit-testing use this origin.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: textContainerInset.height)
    }

    var clickHandler: ((Int, NSEvent.ModifierFlags) -> Void)?
    /// Consumes a click on drawn chrome (block-end labels) before selection.
    var annotationClickHandler: ((NSPoint) -> Bool)?
    var sourceCopyHandler: (() -> String?)?
    var contextMenuHandler: ((Int) -> Void)?
    var selectionHandler: ((Int) -> Void)?
    var viewportChanged: (() -> Void)?
    var userScrollHandler: (() -> Void)?
    var layoutCompleted: (() -> Void)?
    var escapeHandler: (() -> Bool)?
    var backgroundHandler: ((NSRect) -> Void)?
    /// Narrow size-change hooks (reader-wrap design D3.7): fired from
    /// setFrameSize only when the width actually changes. The will-change
    /// call is the last point where the pre-resize geometry is still
    /// observable; AppKit's own resize notifications are strictly
    /// after-the-fact (see the S0 resize-timing probe).
    var widthWillChange: ((CGFloat) -> Void)?
    var widthDidChange: ((CGFloat) -> Void)?
    /// Pointer location in view coordinates, or `nil` when it left the text.
    var hoverHandler: ((NSPoint?) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var viewportBounds: NSRect?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hoverHandler?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverTrackingArea { hoverHandler?(nil) }
    }
    fileprivate var viewportNeedsValidationAfterLayout = false

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = bounds.width
        let widthChanged = abs(newSize.width - oldWidth) > 0.01
        if widthChanged { widthWillChange?(oldWidth) }
        super.setFrameSize(newSize)
        if widthChanged { widthDidChange?(newSize.width) }
    }

    override func layout() {
        super.layout()
        // A scroll can notify before TextKit has moved its viewport. Style once
        // after that move, not on every otherwise unchanged layout/display pass.
        if viewportNeedsValidationAfterLayout {
            viewportNeedsValidationAfterLayout = false
            layoutCompleted?()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(self, name: NSScrollView.willStartLiveScrollNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSScrollView.didLiveScrollNotification, object: nil)
        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(userDidScroll(_:)), name: name, object: scrollView)
        }
        viewportBounds = clipView.bounds
        viewportNeedsValidationAfterLayout = true
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1,
           annotationClickHandler?(convert(event.locationInWindow, from: nil)) == true {
            return
        }
        let index = characterIndex(for: event)
        super.mouseDown(with: event)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let selection = selectedRange()
        let selectedAttachment = selectedRanges.count == 1 && selection.length == 1
            && (selection.location == index || selection.location == index - 1)
            && selection.location < (textStorage?.length ?? 0)
            && textStorage?.attribute(.attachment, at: selection.location, effectiveRange: nil) != nil
        // Native drag/Shift-click/word selection owns its range and affinity.
        // Activating a token here would replace it and can also trigger navigation.
        if !modifiers.contains(.command), !selectedAttachment,
           selectedRanges.contains(where: { $0.rangeValue.length > 0 }) {
            selectionHandler?(selection.location)
            return
        }
        clickHandler?(index, modifiers)
    }

    override func showFindIndicator(for charRange: NSRange) {
        // An unattached/closed reader has no native geometry for the deferred effect.
        guard window?.isVisible == true else { return }
        super.showFindIndicator(for: charRange)
    }

    override func writeSelection(
        to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let sourceCopyHandler else { return super.writeSelection(to: pasteboard, types: types) }
        guard types.contains(.string) || types.contains(where: { $0.rawValue == "NSStringPboardType" }),
              let source = sourceCopyHandler() else { return false }
        pasteboard.declareTypes([.string], owner: nil)
        return pasteboard.setString(source, forType: .string)
    }

    override func writeSelection(
        to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard let sourceCopyHandler else { return super.writeSelection(to: pasteboard, type: type) }
        guard type == .string || type.rawValue == "NSStringPboardType",
              let source = sourceCopyHandler() else { return false }
        return pasteboard.setString(source, forType: .string)
    }

    override func copy(_ sender: Any?) {
        guard let sourceCopyHandler else { super.copy(sender); return }
        guard let source = sourceCopyHandler() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([source as NSString])
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuHandler?(characterIndex(for: event))
        return super.menu(for: event)
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        selectionHandler?(selectedRange().location)
    }

    override func cancelOperation(_ sender: Any?) {
        if escapeHandler?() != true {
            super.cancelOperation(sender)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        backgroundHandler?(rect)
    }

    override func scrollWheel(with event: NSEvent) {
        userScrollHandler?()
        super.scrollWheel(with: event)
    }

    @objc private func userDidScroll(_ notification: Notification) {
        // Synchronous: a queued restore must not run between user input and cancellation.
        userScrollHandler?()
    }

    @objc private func viewportDidChange(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              clipView.bounds != viewportBounds
        else { return }
        let moved = clipView.bounds.origin != viewportBounds?.origin
        viewportBounds = clipView.bounds
        viewportNeedsValidationAfterLayout = true
        if moved { viewportChanged?() }
    }
}

@MainActor
private extension NSTextView {
    func characterIndex(for event: NSEvent) -> Int {
        characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
    }
}
