@preconcurrency import AppKit
import CodeInsightCore
import CodeInsightReaderCore

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

    var chromeColor: NSColor {
        selection == .auto ? .windowBackgroundColor : dynamicColor(chromeRGB(isDark:))
    }

    var chromeHeaderColor: NSColor {
        selection == .auto ? .controlBackgroundColor : dynamicColor(chromeHeaderRGB(isDark:))
    }

    var chromeDividerColor: NSColor {
        selection == .auto ? .separatorColor : dynamicColor(chromeDividerRGB(isDark:))
    }

    var chromeSelectionColor: NSColor {
        selection == .auto ? .selectedContentBackgroundColor : dynamicColor(chromeSelectionRGB(isDark:))
    }

    var accentColor: NSColor {
        selection == .auto ? .controlAccentColor : dynamicColor(accentRGB(isDark:))
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

    private var spans: [HighlightSpan] = []
    private var occurrenceRanges: [NSRange] = []
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
        spans = document.highlightSpans
        self.document = document
        self.map = map
        self.theme = theme
        styledFragmentCount = 0
        referenceStyledFragmentCount = 0
        referenceAttributeRunCount = 0
        referenceScannedCount = 0
    }

    var hasRenderingAttributes: Bool {
        !spans.isEmpty
            || !occurrenceRanges.isEmpty
            || (
                theme.syntaxFormatting
                    && document?.localBindings.isEmpty == false
            )
    }

    func setOccurrences(_ ranges: [NSRange]) {
        occurrenceRanges = ranges
        styledFragmentCount = 0
        referenceStyledFragmentCount = 0
        referenceAttributeRunCount = 0
        referenceScannedCount = 0
    }

    func clear() {
        spans = []
        occurrenceRanges = []
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

        var visibleSpans: [HighlightSpan] = []
        for sourceRange in sourceRanges {
            visibleSpans.append(contentsOf: ViewportGating.spans(
                spans,
                intersectingBytes: sourceRange.lowerBound..<sourceRange.upperBound,
                buffer: 0
            ))
        }
        let fragmentNSRange = NSRange(location: start, length: end - start)
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

        var styledRanges: [
            (
                range: NSRange,
                kind: HighlightKind?,
                occurrence: Bool,
                isParameterReference: Bool?
            )
        ] = []
        styledRanges.reserveCapacity(
            syntaxRanges.count
                + visibleOccurrences.count
                + referenceRanges.count
        )
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

            let syntax = syntaxRanges.indices.contains(spanIndex)
                ? syntaxRanges[spanIndex]
                : nil
            let occurrence = visibleOccurrences.indices.contains(occurrenceIndex)
                ? visibleOccurrences[occurrenceIndex]
                : nil
            let reference = referenceRanges.indices.contains(referenceIndex)
                ? referenceRanges[referenceIndex]
                : nil
            let kind = syntax.flatMap {
                $0.range.location <= location ? $0.kind : nil
            }
            let isOccurrence = occurrence.map {
                $0.location <= location
            } ?? false
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
                isParameterReference == nil
                    ? $0.range.location
                    : NSMaxRange($0.range)
            } ?? Int.max
            let next = min(
                nextSyntaxBoundary,
                nextOccurrenceBoundary,
                nextReferenceBoundary
            )
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

        var wroteAttributes = false
        var wroteReferenceAttributes = false
        for styled in styledRanges {
            guard let textRange = textRange(styled.range, in: content) else {
                continue
            }
            var foregroundColor = styled.kind.map {
                theme.color(for: $0)
            } ?? theme.foregroundColor
            if styled.isParameterReference == true {
                foregroundColor = foregroundColor.withAlphaComponent(
                    theme.parameterReferenceAlpha
                )
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: foregroundColor,
            ]
            if styled.occurrence {
                attributes[.backgroundColor] = theme.occurrenceColor
            }
            manager.setRenderingAttributes(attributes, for: textRange)
            wroteAttributes = true
            if styled.isParameterReference != nil {
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

package enum ReadingHeightLevel: Int, CaseIterable, Sendable {
    case full
    case structure
    case overview

    package var title: String {
        switch self {
        case .full: "Full"
        case .structure: "Structure"
        case .overview: "Overview"
        }
    }
}

@MainActor
public final class ReaderTextView {
    private struct FoldScopeKey: Hashable {
        let file: URL
        let contentID: ContentID
    }

    private struct FoldOverrides {
        var forcedFolded: Set<FoldID> = []
        var forcedUnfolded: Set<FoldID> = []
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
    public var onViewportChange: (() -> Void)?
    package var onCaretChange: ((UInt32) -> Void)?
    private let backingTextStorage: NSTextStorage
    private var displayMap: DisplayMap?
    private var displayedDocument: ReaderDocument?
    private var theme: ReaderTheme
    private var diffMarkers: [Int: DiffCore.MarkerKind] = [:]
    private var declarationKindsByLine: [Int: OutlineKind] = [:]
    private weak var scrollView: NSScrollView?
    private weak var ruler: NSRulerView?
    private var lineNumbers = true
    private var wrapLines: Bool
    private var occurrenceSelectionByteOffset: UInt32?
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
    private var latentSelectionAnchor: LatentFoldAnchor?
    private var latentViewportAnchor: LatentFoldAnchor?
    private var foldGutterHovered = false
    private var navigationLandingLine: Int?
    private var navigationMarkerGeneration = 0
    private var nativeSelectedTextAttributes: [NSAttributedString.Key: Any] = [:]
    public private(set) var currentLineNumber: Int?
    public private(set) var occurrenceCount = 0
    public private(set) var primarySelectionRange: NSRange?
    public private(set) var visibleLineNumbers: [Int] = []
    public private(set) var visibleCurrentLineNumbers: [Int] = []
    public private(set) var visibleDeclarationMarkerLines: [Int] = []

    public init(settings: ReaderSettings = ReaderSettings()) {
        theme = ReaderTheme(settings: settings)
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
            self?.activate(atCharacterIndex: index)
            self?.onClick?(index, modifiers)
        }
        textView.sourceCopyHandler = { [weak self] range in
            self?.sourceText(forDisplaySelection: range)
        }
        textView.contextMenuHandler = { [weak self] index in
            self?.onContextMenu?(index)
        }
        textView.selectionHandler = { [weak self] index in
            guard let self,
                  let byteOffset = byteOffset(forCharacterIndex: index)
            else {
                return
            }
            updateCurrentLine(byteOffset: byteOffset)
            if let primarySelectionRange,
               view.selectedRange() != primarySelectionRange
            {
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
        textView.escapeHandler = { [weak self] in
            guard let self else { return false }
            if isFocusMode { return exitFocusMode() }
            guard occurrenceCount > 0 else { return false }
            clearOccurrences()
            return true
        }
        textView.backgroundHandler = { [weak self, weak textView] rect in
            guard let self, let textView else { return }
            self.drawCurrentLineBackground(in: textView, dirtyRect: rect)
            self.drawPrimarySelection(in: textView, dirtyRect: rect)
        }
        textView.viewportChanged = { [weak self] in
            guard let self,
                  let layoutManager = self.view.textLayoutManager
            else { return }
            self.validateVisibleRenderingAttributes(in: layoutManager)
            self.ruler?.needsDisplay = true
            self.onViewportChange?()
        }
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
                .contains("Collapsed, hides") == true
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
        let scope = FoldScopeKey(
            file: (fileURL ?? URL(fileURLWithPath: "/__codeinsight_memory__"))
                .standardizedFileURL,
            contentID: document.contentID
        )
        activeFoldScope = scope
        baselineFoldIDs = Self.baselineFoldIDs(
            for: readingHeightLevel,
            in: document.foldRegions
        )
        let overrides = foldOverridesByScope[scope] ?? FoldOverrides()
        foldOverridesByScope[scope] = overrides
        logicalFoldIDs = Self.logicalFoldIDs(
            overrides: overrides,
            baseline: baselineFoldIDs
        )
        renderedFoldIDs = Self.maximalFoldIDs(
            logicalFoldIDs,
            in: document.foldRegions
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

        displayMap = projection.map
        foldAttachments = projection.attachments
        displayedDocument = document
        refreshVisibleFoldRegions()
        diffMarkers = [:]
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
        latentSelectionAnchor = nil
        latentViewportAnchor = nil
        foldGutterHovered = false
        navigationLandingLine = nil
        navigationMarkerGeneration += 1
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
        installRenderingValidator(in: layoutManager)
        if let contentStorage = view.textContentStorage {
            contentStorage.performEditingTransaction {
                backingTextStorage.beginEditing()
                backingTextStorage.setAttributedString(projection.attributed)
                backingTextStorage.endEditing()
            }
        } else {
            backingTextStorage.setAttributedString(projection.attributed)
        }
        if renderingCoordinator.hasRenderingAttributes {
            validateVisibleRenderingAttributes(in: layoutManager)
        }
    }

    public func clear() {
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
        latentSelectionAnchor = nil
        latentViewportAnchor = nil
        foldGutterHovered = false
        navigationLandingLine = nil
        navigationMarkerGeneration += 1
        diffMarkers = [:]
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
        backingTextStorage.setAttributedString(NSAttributedString(string: ""))
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
              document.foldRegions.contains(where: { $0.id == id })
        else { return false }
        let shouldFold = !logicalFoldIDs.contains(id)
        return applyFoldMutation { overrides in
            Self.setFold(
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
              let region = visibleFoldRegions(in: document).first(where: {
                  document.lineTable.lineColumn(at: $0.headerRange.lowerBound)
                      .map { Int($0.line) == line } ?? false
              })
        else { return false }
        guard recursiveSiblings else { return toggleFold(id: region.id) }

        let shouldFold = !logicalFoldIDs.contains(region.id)
        let parent = document.foldRegions
            .filter {
                $0.id != region.id
                    && $0.bodyRange.lowerBound <= region.bodyRange.lowerBound
                    && region.bodyRange.upperBound <= $0.bodyRange.upperBound
            }
            .max { lhs, rhs in lhs.outlineDepth < rhs.outlineDepth }
        let siblings = document.foldRegions.filter { candidate in
            guard candidate.outlineDepth == region.outlineDepth else { return false }
            let candidateParent = document.foldRegions
                .filter {
                    $0.id != candidate.id
                        && $0.bodyRange.lowerBound <= candidate.bodyRange.lowerBound
                        && candidate.bodyRange.upperBound <= $0.bodyRange.upperBound
                }
                .max { lhs, rhs in lhs.outlineDepth < rhs.outlineDepth }
            return candidateParent?.id == parent?.id
        }
        let affected = document.foldRegions.filter { candidate in
            siblings.contains { sibling in
                sibling.bodyRange.lowerBound <= candidate.bodyRange.lowerBound
                    && candidate.bodyRange.upperBound <= sibling.bodyRange.upperBound
            }
        }.map(\.id)
        return applyFoldMutation { overrides in
            for id in affected {
                Self.setFold(
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
        guard let document = displayedDocument else { return [:] }
        return foldedDiffMarkers(in: document).reduce(into: [:]) {
            result, element in
            guard let region = document.foldRegions.first(where: {
                $0.id == element.key
            }), let line = document.lineTable.lineColumn(
                at: region.headerRange.lowerBound
            )?.line else { return }
            result[Int(line)] = element.value
        }
    }

    @discardableResult
    package func focusCurrentScope(at byteOffset: UInt32) -> Bool {
        guard focusState == nil,
              let document = displayedDocument,
              let target = Self.focusTarget(at: byteOffset, in: document)
        else { return false }
        let saved = FocusState(
            readingHeightLevel: readingHeightLevel,
            foldOverridesByScope: foldOverridesByScope,
            focusedFoldID: target.region.id,
            byteOffset: byteOffset
        )
        guard applyFoldProjection(
            Self.focusFoldIDs(around: target.facet, in: document)
        ) else { return false }
        focusState = saved
        return true
    }

    package func scopeHeaderFacets(at byteOffset: UInt32) -> [OutlineFacet] {
        guard let document = displayedDocument else { return [] }
        let facets = Self.enclosingAssociatedFacets(
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
            Self.baselineFoldIDs(
                for: focusState.readingHeightLevel,
                in: $0.foldRegions
            )
        } ?? []
        let restoredOverrides = activeFoldScope.flatMap {
            focusState.foldOverridesByScope[$0]
        } ?? FoldOverrides()
        let restoredLogical = Self.logicalFoldIDs(
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
        guard let target = Self.focusTarget(at: byteOffset, in: document) else {
            _ = exitFocusMode()
            return false
        }
        guard applyFoldProjection(
            Self.focusFoldIDs(around: target.facet, in: document)
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
                Self.baselineFoldIDs(for: level, in: $0.foldRegions)
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

    private static func logicalFoldIDs(
        overrides: FoldOverrides,
        baseline: Set<FoldID>
    ) -> Set<FoldID> {
        baseline.subtracting(overrides.forcedUnfolded)
            .union(overrides.forcedFolded)
    }

    private static func baselineFoldIDs(
        for level: ReadingHeightLevel,
        in regions: [FoldRegion]
    ) -> Set<FoldID> {
        guard level != .full else { return [] }
        return Set(
            regions.compactMap { region in
                guard region.summary.hiddenLineCount >= 2 else { return nil }
                switch region.kind {
                case .declaration, .imports, .cfgTest:
                    return region.id
                case .container:
                    return level == .overview ? region.id : nil
                case .comment:
                    return region.id
                case .block, .attributes:
                    return nil
                }
            })
    }

    private static func focusTarget(
        at byteOffset: UInt32,
        in document: ReaderDocument
    ) -> (facet: OutlineFacet, region: FoldRegion)? {
        let containing = document.outlineFacets.filter {
            $0.range.lowerBound <= byteOffset && byteOffset < $0.range.upperBound
        }
        let declarations = containing.filter {
            $0.kind == .fn || $0.kind == .method
        }
        let containers = containing.filter {
            switch $0.kind {
            case .struct, .enum, .trait, .impl, .mod, .class: true
            case .fn, .method, .const, .static, .typeAlias: false
            }
        }
        guard let facet = (declarations.isEmpty ? containers : declarations)
            .min(by: { lhs, rhs in
                let lhsLength = lhs.range.upperBound - lhs.range.lowerBound
                let rhsLength = rhs.range.upperBound - rhs.range.lowerBound
                if lhsLength != rhsLength { return lhsLength < rhsLength }
                return lhs.depth > rhs.depth
            })
        else { return nil }
        guard let region = document.foldRegions.filter({
            associatedFacet(for: $0, in: document.outlineFacets) == facet
        }).min(by: {
            ($0.bodyRange.upperBound - $0.bodyRange.lowerBound)
                < ($1.bodyRange.upperBound - $1.bodyRange.lowerBound)
        }) else { return nil }
        return (facet, region)
    }

    private static func enclosingAssociatedFacets(
        at byteOffset: UInt32,
        in document: ReaderDocument
    ) -> [OutlineFacet] {
        var result: [OutlineFacet] = []
        for region in document.foldRegions {
            guard let facet = associatedFacet(
                for: region,
                in: document.outlineFacets
            ), facetContainsCaret(
                byteOffset,
                facet: facet,
                in: document
            ),
                !result.contains(facet)
            else { continue }
            result.append(facet)
        }
        return result.sorted { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            if lhs.range.upperBound != rhs.range.upperBound {
                return lhs.range.upperBound > rhs.range.upperBound
            }
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.name < rhs.name
        }
    }

    private static func facetContainsCaret(
        _ byteOffset: UInt32,
        facet: OutlineFacet,
        in document: ReaderDocument
    ) -> Bool {
        if facet.range.lowerBound <= byteOffset,
           byteOffset < facet.range.upperBound
        {
            return true
        }
        guard let caretLine = document.lineTable.lineColumn(at: byteOffset)?.line,
              let firstLine = document.lineTable.lineColumn(
                  at: facet.range.lowerBound
              )?.line
        else { return false }
        let finalByte = facet.range.upperBound > facet.range.lowerBound
            ? facet.range.upperBound - 1
            : facet.range.lowerBound
        guard let lastLine = document.lineTable.lineColumn(at: finalByte)?.line
        else { return false }
        return firstLine <= caretLine && caretLine <= lastLine
    }

    private static func associatedFacet(
        for region: FoldRegion,
        in facets: [OutlineFacet]
    ) -> OutlineFacet? {
        facets.filter { facet in
            guard facet.range.lowerBound <= region.bodyRange.lowerBound,
                  region.bodyRange.upperBound <= facet.range.upperBound
            else { return false }
            switch (region.kind, facet.kind) {
            case (.declaration, .fn), (.declaration, .method):
                return true
            case (.container, .struct), (.container, .enum),
                (.container, .trait), (.container, .impl), (.container, .mod),
                (.cfgTest, .struct), (.cfgTest, .enum), (.cfgTest, .trait),
                (.cfgTest, .impl), (.cfgTest, .mod):
                return true
            default:
                return false
            }
        }.min { lhs, rhs in
            let lhsLength = lhs.range.upperBound - lhs.range.lowerBound
            let rhsLength = rhs.range.upperBound - rhs.range.lowerBound
            if lhsLength != rhsLength { return lhsLength < rhsLength }
            return lhs.depth > rhs.depth
        }
    }

    private static func focusFoldIDs(
        around facet: OutlineFacet,
        in document: ReaderDocument
    ) -> Set<FoldID> {
        Set(document.foldRegions.compactMap { region in
            guard region.summary.hiddenLineCount >= 2 else { return nil }
            let intersects = region.bodyRange.lowerBound < facet.range.upperBound
                && facet.range.lowerBound < region.bodyRange.upperBound
            return intersects ? nil : region.id
        })
    }

    private static func maximalFoldIDs(
        _ logical: Set<FoldID>,
        in regions: [FoldRegion]
    ) -> Set<FoldID> {
        let active = regions.filter { logical.contains($0.id) }.sorted {
            if $0.bodyRange.lowerBound != $1.bodyRange.lowerBound {
                return $0.bodyRange.lowerBound < $1.bodyRange.lowerBound
            }
            return $0.bodyRange.upperBound > $1.bodyRange.upperBound
        }
        var result: Set<FoldID> = []
        result.reserveCapacity(active.count)
        var maximalUpper: UInt32?
        for region in active {
            if let maximalUpper,
               region.bodyRange.upperBound <= maximalUpper
            {
                continue
            }
            result.insert(region.id)
            maximalUpper = region.bodyRange.upperBound
        }
        return result
    }

    private static func setFold(
        _ id: FoldID,
        folded: Bool,
        baseline: Set<FoldID>,
        overrides: inout FoldOverrides
    ) {
        if folded {
            overrides.forcedUnfolded.remove(id)
            if baseline.contains(id) {
                overrides.forcedFolded.remove(id)
            } else {
                overrides.forcedFolded.insert(id)
            }
        } else {
            overrides.forcedFolded.remove(id)
            if baseline.contains(id) {
                overrides.forcedUnfolded.insert(id)
            } else {
                overrides.forcedUnfolded.remove(id)
            }
        }
    }

    @discardableResult
    private func unfoldAncestors(containing byteOffset: UInt32) -> Bool {
        guard !isFocusMode, let document = displayedDocument else { return false }
        let ancestors = document.foldRegions.filter {
            logicalFoldIDs.contains($0.id) && $0.bodyRange.contains(byteOffset)
        }
        guard !ancestors.isEmpty else { return false }
        let unfolded = applyFoldMutation { overrides in
            for region in ancestors {
                Self.setFold(
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
        let logical = Self.logicalFoldIDs(
            overrides: overrides,
            baseline: baselineFoldIDs
        )
        guard applyFoldProjection(logical) else { return false }
        foldOverridesByScope[scope] = overrides
        return true
    }

    private func applyFoldProjection(_ logical: Set<FoldID>) -> Bool {
        guard let document = displayedDocument,
              let layoutManager = view.textLayoutManager
        else { return false }

        let selectionAnchor = sourceAnchor(
            atDisplayOffset: view.selectedRange().location,
            latent: latentSelectionAnchor
        )
        let viewportAnchor = latentViewportAnchor.flatMap { latent in
            renderedFoldIDs.contains(latent.foldID) ? latent.byteOffset : nil
        } ?? firstVisibleByteOffset()
        let rendered = Self.maximalFoldIDs(logical, in: document.foldRegions)
        guard let projection = Self.project(
            document: document,
            renderedFoldIDs: rendered,
            attributes: baseAttributes,
            theme: theme
        ) else { return false }

        logicalFoldIDs = logical
        renderedFoldIDs = rendered
        displayMap = projection.map
        foldAttachments = projection.attachments
        refreshVisibleFoldRegions()
        renderingCoordinator.update(
            document: document,
            map: projection.map,
            theme: theme
        )
        refreshOccurrenceRendering(in: document)
        layoutManager.renderingAttributesValidator = nil
        if let contentStorage = view.textContentStorage {
            contentStorage.performEditingTransaction {
                backingTextStorage.beginEditing()
                backingTextStorage.setAttributedString(projection.attributed)
                backingTextStorage.endEditing()
            }
        } else {
            backingTextStorage.setAttributedString(projection.attributed)
        }
        installRenderingValidator(in: layoutManager)
        restoreSelectionAnchor(selectionAnchor)
        restoreViewportAnchor(viewportAnchor, in: document)
        if let scrollView = view.enclosingScrollView ?? scrollView {
            configureGutter(in: scrollView, lineNumbers: lineNumbers)
        }
        updateRulerThickness()
        ruler?.needsDisplay = true
        validateVisibleRenderingAttributes(in: layoutManager)
        view.needsDisplay = true
        return true
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
            return displayedDocument?.foldRegions.first { $0.id == foldID }?
                .bodyRange.lowerBound
        }
    }

    private func restoreSelectionAnchor(
        _ byteOffset: UInt32?
    ) {
        guard let byteOffset,
              let position = displayMap?.displayPosition(ofByte: byteOffset)
        else { return }
        switch position {
        case .visible(let offset):
            view.setSelectedRange(NSRange(location: offset, length: 0))
            if latentSelectionAnchor?.byteOffset == byteOffset {
                latentSelectionAnchor = nil
            }
        case .hidden(let foldID):
            guard let placeholder = displayMap?.placeholderOffset(for: foldID) else {
                return
            }
            latentSelectionAnchor = LatentFoldAnchor(
                byteOffset: byteOffset,
                foldID: foldID
            )
            view.setSelectedRange(NSRange(location: placeholder, length: 0))
        }
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
            guard let region = document.foldRegions.first(where: {
                $0.id == foldID
            }) else { return }
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

    private func visibleFoldRegions(in document: ReaderDocument) -> [FoldRegion] {
        if document === displayedDocument { return visibleFoldRegionsCache }
        return Self.visibleFoldRegions(in: document, map: displayMap)
    }

    private func refreshVisibleFoldRegions() {
        guard let document = displayedDocument else {
            visibleFoldRegionsCache = []
            return
        }
        visibleFoldRegionsCache = Self.visibleFoldRegions(
            in: document,
            map: displayMap
        )
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
            displayedDocument?.contentID == document.contentID
        else { return }
        displayedDocument = document
        baselineFoldIDs = Self.baselineFoldIDs(
            for: readingHeightLevel,
            in: document.foldRegions
        )
        if var focusState,
           let target = Self.focusTarget(
               at: focusByteOffset ?? focusState.byteOffset,
               in: document
           )
        {
            logicalFoldIDs = Self.focusFoldIDs(
                around: target.facet,
                in: document
            )
            focusState.focusedFoldID = target.region.id
            focusState.byteOffset = focusByteOffset ?? focusState.byteOffset
            self.focusState = focusState
        } else if let focusState {
            readingHeightLevel = focusState.readingHeightLevel
            foldOverridesByScope = focusState.foldOverridesByScope
            baselineFoldIDs = Self.baselineFoldIDs(
                for: readingHeightLevel,
                in: document.foldRegions
            )
            logicalFoldIDs = Self.logicalFoldIDs(
                overrides: activeFoldScope.flatMap {
                    foldOverridesByScope[$0]
                } ?? FoldOverrides(),
                baseline: baselineFoldIDs
            )
            self.focusState = nil
        } else {
            logicalFoldIDs = Self.logicalFoldIDs(
                overrides: activeFoldScope.flatMap {
                    foldOverridesByScope[$0]
                } ?? FoldOverrides(),
                baseline: baselineFoldIDs
            )
        }
        renderedFoldIDs = Self.maximalFoldIDs(
            logicalFoldIDs,
            in: document.foldRegions
        )
        guard let projection = Self.project(
            document: document,
            renderedFoldIDs: renderedFoldIDs,
            attributes: baseAttributes,
            theme: theme
        ) else {
            layoutManager.renderingAttributesValidator = nil
            return
        }
        displayMap = projection.map
        foldAttachments = projection.attachments
        refreshVisibleFoldRegions()
        declarationKindsByLine = Self.declarationKindsByLine(in: document)
        renderingCoordinator.update(
            document: document,
            map: projection.map,
            theme: theme
        )
        refreshOccurrenceRendering(in: document)
        if let scrollView = view.enclosingScrollView ?? scrollView {
            configureGutter(in: scrollView, lineNumbers: lineNumbers)
        }
        updateRulerThickness()
        ruler?.needsDisplay = true
        let viewportRange = layoutManager.textViewportLayoutController.viewportRange
        layoutManager.renderingAttributesValidator = nil
        backingTextStorage.setAttributedString(projection.attributed)
        installRenderingValidator(in: layoutManager)
        if let viewportRange {
            layoutManager.invalidateRenderingAttributes(for: viewportRange)
        }
        view.needsDisplay = true
        DispatchQueue.main.async { [weak self, weak layoutManager] in
            guard let self, let layoutManager else { return }
            self.validateVisibleRenderingAttributes(in: layoutManager)
        }
    }

    public func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        lineNumbers = settings.lineNumbers
        wrapLines = settings.wrapLines
        applyThemeColors()
        if let scrollView = view.enclosingScrollView ?? scrollView {
            configureGutter(in: scrollView, lineNumbers: settings.lineNumbers)
        }
        ruler?.needsDisplay = true
        guard let document = displayedDocument,
              let layoutManager = view.textLayoutManager
        else { return }
        guard let projection = Self.project(
            document: document,
            renderedFoldIDs: renderedFoldIDs,
            attributes: baseAttributes,
            theme: theme
        ) else {
            layoutManager.renderingAttributesValidator = nil
            return
        }
        guard projectionMatchesStorage(projection.map) else {
            layoutManager.renderingAttributesValidator = nil
            return
        }

        displayMap = projection.map
        foldAttachments = projection.attachments
        refreshFoldExposures(in: document)
        renderingCoordinator.update(
            document: document,
            map: projection.map,
            theme: theme
        )
        let viewportRange = layoutManager.textViewportLayoutController.viewportRange
        layoutManager.renderingAttributesValidator = nil
        backingTextStorage.setAttributedString(projection.attributed)
        installRenderingValidator(in: layoutManager)
        if let viewportRange {
            layoutManager.invalidateRenderingAttributes(for: viewportRange)
            validateVisibleRenderingAttributes(in: layoutManager)
        }
        view.needsDisplay = true
    }

    public func reveal(byteOffset: UInt32) {
        _ = unfoldAncestors(containing: byteOffset)
        guard let location = visibleDisplayOffset(forByte: byteOffset),
              location <= backingTextStorage.length
        else { return }
        let lineRange = (backingTextStorage.string as NSString).lineRange(
            for: NSRange(location: location, length: 0)
        )
        updateCurrentLine(byteOffset: byteOffset)
        view.scrollRangeToVisible(lineRange)
        if let scrollView = view.enclosingScrollView {
            let clipView = scrollView.contentView
            if clipView.bounds.origin.x != 0 {
                clipView.scroll(to: NSPoint(x: 0, y: clipView.bounds.origin.y))
                scrollView.reflectScrolledClipView(clipView)
            }
        }
        view.showFindIndicator(for: lineRange)
    }

    public func restore(
        scrollByteOffset: UInt32?,
        selectionByteOffset: UInt32?
    ) {
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
                x: clipView.bounds.origin.x,
                y: lineRect.minY
            ))
            scrollView.reflectScrolledClipView(clipView)
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
            view.textContainerInset.width = 12
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
        scrollView.tile()
        configureWrapping(in: scrollView)
        activeRuler.needsDisplay = true
    }

    public func installDiffGutter(in scrollView: NSScrollView) {
        configureGutter(in: scrollView, lineNumbers: lineNumbers)
    }

    public func setDiffMarkers(_ markers: [Int: DiffCore.MarkerKind]) {
        diffMarkers = markers
        refreshFoldExposures()
        if let scrollView = view.enclosingScrollView ?? scrollView {
            configureGutter(in: scrollView, lineNumbers: lineNumbers)
        }
        updateRulerThickness()
        ruler?.needsDisplay = true
    }

    public var diffMarkerCounts: [DiffCore.MarkerKind: Int] {
        Dictionary(grouping: diffMarkers.values, by: { $0 }).mapValues(\.count)
    }

    public var rulerThickness: CGFloat {
        ruler?.ruleThickness ?? 0
    }

    package var foldGutterIsHovered: Bool { foldGutterHovered }

    package func setFoldGutterHoverForTesting(_ point: NSPoint?) {
        guard let ruler else { return }
        updateFoldHover(at: point, in: ruler)
    }

    public var gutterShowsLineNumbersAndDiff: Bool {
        lineNumbers && !diffMarkers.isEmpty && rulerThickness > diffColumnWidth
    }

    @discardableResult
    public func activate(atByteOffset byteOffset: UInt32) -> Int {
        _ = unfoldAncestors(containing: byteOffset)
        updateCurrentLine(byteOffset: byteOffset)
        guard let document = displayedDocument else {
            clearOccurrences()
            return 0
        }
        let occurrenceRanges = document.identifierOccurrences(at: byteOffset)
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
        refreshOccurrenceRendering()
        view.scrollRangeToVisible(displayRange)
        view.showFindIndicator(for: displayRange)
        return true
    }

    public func captureVisibleDecorationState() {
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
        guard line > 0,
              let document = displayedDocument,
              document.lineTable.lineStarts.indices.contains(line - 1)
        else { return false }
        let byteOffset = document.lineTable.lineStarts[line - 1]
        _ = unfoldAncestors(containing: byteOffset)
        guard let location = visibleDisplayOffset(forByte: byteOffset) else {
            return false
        }
        let range = (backingTextStorage.string as NSString).lineRange(
            for: NSRange(location: location, length: 0)
        )
        view.setSelectedRange(range)
        updateCurrentLine(line: line)
        view.scrollRangeToVisible(range)
        view.showFindIndicator(for: range)
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

    public func byteOffset(forCharacterIndex index: Int) -> UInt32? {
        sourceByteOffset(forDisplay: index)
    }

    public func firstVisibleByteOffset() -> UInt32? {
        guard let layoutManager = view.textLayoutManager,
              let content = layoutManager.textContentManager
        else { return nil }
        layoutManager.textViewportLayoutController.layoutViewport()
        guard let viewport = layoutManager.textViewportLayoutController.viewportRange else {
            return nil
        }
        let location = content.offset(
            from: content.documentRange.location,
            to: viewport.location
        )
        guard location != NSNotFound else { return nil }
        let lineStart = (backingTextStorage.string as NSString).lineRange(
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
        guard case .visible(let offset) = displayMap?.displayPosition(ofByte: byteOffset)
        else { return nil }
        return offset
    }

    private func sourceByteOffset(forDisplay displayOffset: Int) -> UInt32? {
        guard case .source(let offset) = displayMap?.sourcePosition(
            ofDisplay: displayOffset
        ) else { return nil }
        return offset
    }

    func sourceText(forDisplaySelection range: NSRange) -> String? {
        guard range.length > 0,
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
        logicalCount: Int? = nil
    ) {
        occurrenceCount = logicalCount ?? ranges.count
        renderingCoordinator.setOccurrences(
            ranges.filter { $0 != primarySelectionRange }
        )
        guard let layoutManager = view.textLayoutManager else { return }
        installRenderingValidator(in: layoutManager)
        if let viewportRange =
            layoutManager.textViewportLayoutController.viewportRange
        {
            layoutManager.invalidateRenderingAttributes(for: viewportRange)
            validateVisibleRenderingAttributes(in: layoutManager)
        }
        view.needsDisplay = true
    }

    private func refreshOccurrenceRendering(
        in document: ReaderDocument? = nil
    ) {
        guard let document = document ?? displayedDocument else {
            setOccurrences([])
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
            setOccurrences(visible, logicalCount: findMatchByteRanges.count)
            return
        }
        guard let occurrenceSelectionByteOffset else {
            refreshFoldExposures(in: document)
            setOccurrences([])
            return
        }
        let occurrenceRanges = document.identifierOccurrences(
            at: occurrenceSelectionByteOffset
        )
        let ranges = projectedOccurrenceNSRanges(occurrenceRanges)
        if occurrenceRanges.isEmpty { self.occurrenceSelectionByteOffset = nil }
        refreshFoldExposures(
            in: document,
            occurrenceRanges: occurrenceRanges
        )
        setOccurrences(ranges)
    }

    private func occurrenceNSRanges(
        in document: ReaderDocument,
        at byteOffset: UInt32
    ) -> [NSRange] {
        projectedOccurrenceNSRanges(
            document.identifierOccurrences(at: byteOffset)
        )
    }

    private func projectedOccurrenceNSRanges(
        _ ranges: [ByteRange]
    ) -> [NSRange] {
        guard let displayMap else { return [] }
        return ranges.flatMap {
            displayMap.project(byteRange: $0)?.visible ?? []
        }
    }

    private func refreshFoldExposures(
        in document: ReaderDocument? = nil,
        occurrenceRanges: [ByteRange]? = nil
    ) {
        guard let document = document ?? displayedDocument else { return }
        let matchCounts = foldedRangeCounts(
            findMatchByteRanges ?? [],
            in: document
        )
        let occurrenceRanges = occurrenceRanges ?? occurrenceSelectionByteOffset.map {
            document.identifierOccurrences(at: $0)
        } ?? []
        let occurrenceCounts = foldedRangeCounts(
            occurrenceRanges,
            in: document
        )
        let foldedDiff = foldedDiffMarkers(in: document)
        for (id, attachment) in foldAttachments {
            attachment.updateExposure(
                matchCount: matchCounts[id] ?? 0,
                hasDiff: foldedDiff[id] != nil,
                occurrenceCount: occurrenceCounts[id] ?? 0
            )
        }
    }

    private func foldedRangeCounts(
        _ ranges: [ByteRange],
        in document: ReaderDocument
    ) -> [FoldID: Int] {
        let regions = renderedRegions(in: document)
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
        let regions = renderedRegions(in: document)
        guard !regions.isEmpty, !diffMarkers.isEmpty else { return [:] }
        var result: [FoldID: DiffCore.MarkerKind] = [:]
        var regionIndex = 0
        for (line, kind) in diffMarkers.sorted(by: { $0.key < $1.key }) {
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

    private func renderedRegions(in document: ReaderDocument) -> [FoldRegion] {
        document.foldRegions.filter {
            renderedFoldIDs.contains($0.id)
        }.sorted {
            ($0.bodyRange.lowerBound, $0.bodyRange.upperBound)
                < ($1.bodyRange.lowerBound, $1.bodyRange.upperBound)
        }
    }

    private func installRenderingValidator(
        in layoutManager: NSTextLayoutManager
    ) {
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
    }

    private func updateRulerThickness() {
        guard let ruler else { return }
        ruler.ruleThickness = lineNumberColumnWidth
            + declarationColumnWidth
            + foldColumnWidth
            + diffColumnWidth
        view.textContainerInset.width = 12 + ruler.ruleThickness
        scrollView?.tile()
    }

    private var lineNumberColumnWidth: CGFloat {
        guard lineNumbers else { return 0 }
        let lineCount = displayedDocument?.lineTable.lineStarts.count ?? 1
        return max(34, CGFloat(String(lineCount).count * 7 + 12))
    }

    private var declarationColumnWidth: CGFloat {
        lineNumbers ? 7 : 0
    }

    private var diffColumnWidth: CGFloat {
        diffMarkers.isEmpty ? 0 : 7
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
                x: textView.visibleRect.minX + rulerThickness,
                y: fragmentRect.minY,
                width: max(0, textView.visibleRect.width - rulerThickness),
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
              range.length > 0,
              let window = textView.window
        else { return }
        let screenRect = textView.firstRect(
            forCharacterRange: range,
            actualRange: nil
        )
        guard !screenRect.isEmpty else { return }
        var rect = textView.convert(
            window.convertFromScreen(screenRect),
            from: nil
        )
        rect = NSRect(
            x: rect.minX - 1.5,
            y: rect.minY,
            width: rect.width + 3,
            height: rect.height
        )
        guard rect.intersects(dirtyRect) else { return }

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

    func drawRuler(
        in ruler: NSRulerView,
        dirtyRect: NSRect
    ) {
        theme.backgroundColor.setFill()
        dirtyRect.intersection(ruler.bounds).fill()
        var lines: [Int] = []
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: 10,
            weight: .regular
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let foldsByLine: [Int: FoldRegion]
        let foldedDiffByLine: [Int: DiffCore.MarkerKind]
        if let document = displayedDocument {
            var mapped: [Int: FoldRegion] = [:]
            for region in visibleFoldRegions(in: document) {
                guard let line = document.lineTable.lineColumn(
                    at: region.headerRange.lowerBound
                )?.line else { continue }
                mapped[Int(line)] = mapped[Int(line)] ?? region
            }
            foldsByLine = mapped
            let regionsByID = Dictionary(
                uniqueKeysWithValues: document.foldRegions.map { ($0.id, $0) }
            )
            foldedDiffByLine = foldedDiffMarkers(in: document).reduce(into: [:]) {
                result, element in
                guard let region = regionsByID[element.key],
                      let line = document.lineTable.lineColumn(
                        at: region.headerRange.lowerBound
                      )?.line
                else { return }
                result[Int(line)] = element.value
            }
        } else {
            foldsByLine = [:]
            foldedDiffByLine = [:]
        }
        enumerateVisibleLayoutFragments { fragment, line in
            let textRect = fragmentRectInTextView(fragment)
            let rulerRect = ruler.convert(textRect, from: view)
            guard rulerRect.intersects(dirtyRect) else { return }
            if lineNumbers {
                let labelRect = NSRect(
                    x: 2,
                    y: rulerRect.minY,
                    width: max(0, lineNumberColumnWidth - 6),
                    height: rulerRect.height
                )
                ("\(line)" as NSString).draw(
                    in: labelRect,
                    withAttributes: [
                        .font: font,
                        .foregroundColor: theme.lineNumberColor,
                        .paragraphStyle: paragraph,
                    ]
                )
                lines.append(line)
                if let kind = declarationKindsByLine[line] {
                    drawDeclarationMarker(
                        kind,
                        in: NSRect(
                            x: lineNumberColumnWidth + 1,
                            y: rulerRect.midY - 2,
                            width: 4,
                            height: 4
                        )
                    )
                }
            }
            if let fold = foldsByLine[line],
               foldGutterHovered
            {
                drawFoldChevron(
                    collapsed: renderedFoldIDs.contains(fold.id),
                    in: NSRect(
                        x: lineNumberColumnWidth + declarationColumnWidth,
                        y: rulerRect.minY,
                        width: foldColumnWidth,
                        height: rulerRect.height
                    )
                )
            }
            if navigationLandingLine == line {
                theme.accentColor.setFill()
                let markerHeight = min(8, max(3, rulerRect.height - 4))
                NSBezierPath(
                    roundedRect: NSRect(
                        x: lineNumberColumnWidth + declarationColumnWidth + 4,
                        y: rulerRect.midY - markerHeight / 2,
                        width: 4,
                        height: markerHeight
                    ),
                    xRadius: 2,
                    yRadius: 2
                ).fill()
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
                        + foldColumnWidth + 1,
                    y: rulerRect.minY,
                    width: max(2, diffColumnWidth - 2),
                    height: max(2, rulerRect.height)
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
        let foldX = lineNumberColumnWidth + declarationColumnWidth
        let next = point.map {
            foldColumnWidth > 0
                && $0.x >= foldX
                && $0.x <= foldX + foldColumnWidth
        } ?? false
        guard next != foldGutterHovered else { return }
        foldGutterHovered = next
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
              let document = displayedDocument
        else { return nil }
        var byLine: [Int: FoldRegion] = [:]
        for region in visibleFoldRegions(in: document) {
            guard let line = document.lineTable.lineColumn(
                at: region.headerRange.lowerBound
            )?.line else { continue }
            byLine[Int(line)] = byLine[Int(line)] ?? region
        }
        var match: FoldRegion?
        enumerateVisibleLayoutFragments { fragment, line in
            guard match == nil, let region = byLine[line] else { return }
            let rect = ruler.convert(fragmentRectInTextView(fragment), from: view)
            if rect.minY <= point.y, point.y <= rect.maxY {
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
        case .mod, .const, .static:
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
        }
        return color.withAlphaComponent(theme.declarationMarkerAlpha)
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = theme.lineHeightMultiple
        return [
            .font: NSFont.monospacedSystemFont(
                ofSize: theme.fontSize,
                weight: .regular
            ),
            .foregroundColor: theme.foregroundColor,
            .paragraphStyle: paragraph,
        ]
    }

    private func configure() {
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = true
        view.textContainerInset = NSSize(width: 12, height: 12)
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
        let width = scrollView.contentView.bounds.width
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
            width: wrapLines ? width : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.tile()
        view.textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    private func applyThemeColors() {
        view.backgroundColor = theme.backgroundColor
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
        guard let map = DisplayMap(
            document: document,
            renderedFoldIDs: renderedFoldIDs
        ) else { return nil }
        let attributed = NSMutableAttributedString(
            string: map.projectedString,
            attributes: attributes
        )
        applyTypography(
            document.highlightSpans,
            map: map,
            to: attributed,
            theme: theme
        )
        let regionsByID = Dictionary(
            uniqueKeysWithValues: document.foldRegions.map { ($0.id, $0) }
        )
        var attachments: [FoldID: FoldAttachment] = [:]
        attachments.reserveCapacity(map.foldPlaceholders.count)
        for placeholder in map.foldPlaceholders {
            guard let region = regionsByID[placeholder.id] else { return nil }
            let attachment = FoldAttachment(region: region, theme: theme)
            attributed.addAttribute(
                .attachment,
                value: attachment,
                range: NSRange(location: placeholder.offset, length: 1)
            )
            attachments[placeholder.id] = attachment
        }
        return (attributed, map, attachments)
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

    static func applyTypography(
        _ spans: [HighlightSpan],
        map: DisplayMap,
        to attributed: NSMutableAttributedString,
        theme: ReaderTheme
    ) {
        guard theme.syntaxFormatting else { return }

        func apply(_ span: HighlightSpan) {
            guard let projected = map.project(byteRange: span.range) else { return }
            for range in projected.visible {
                guard range.location >= 0, range.location < attributed.length else {
                    continue
                }
                let safeRange = NSRange(
                    location: range.location,
                    length: min(range.length, attributed.length - range.location)
                )
                guard safeRange.length > 0 else { continue }
                switch span.kind {
                case .functionName, .declarationTitle:
                    attributed.addAttributes([
                        .font: NSFont.monospacedSystemFont(
                            ofSize: theme.functionNameFontSize,
                            weight: NSFont.Weight(
                                rawValue: theme.functionDeclarationFontWeight
                            )
                        ),
                        .kern: 0.15,
                    ], range: safeRange)
                case .declarationEmphasis:
                    attributed.addAttribute(
                        .font,
                        value: NSFont.monospacedSystemFont(
                            ofSize: theme.fontSize,
                            weight: NSFont.Weight(
                                rawValue: theme.declarationEmphasisFontWeight
                            )
                        ),
                        range: safeRange
                    )
                case .comment where theme.humanistComments:
                    attributed.addAttribute(
                        .font,
                        value: NSFont.systemFont(ofSize: theme.fontSize),
                        range: safeRange
                    )
                default:
                    break
                }
            }
        }

        guard !map.renderedFoldIDs.isEmpty else {
            for span in spans { apply(span) }
            return
        }
        guard let visibleRanges = map.visibleSourceRanges(forDisplay: NSRange(
            location: 0,
            length: map.projectedUTF16Length
        )) else { return }

        // Highlight spans and visible source ranges are source ordered. Advance
        // through both once so fully hidden spans never pay projection cost.
        var spanIndex = 0
        for visible in visibleRanges {
            while spans.indices.contains(spanIndex),
                  spans[spanIndex].range.upperBound <= visible.lowerBound
            {
                spanIndex += 1
            }
            while spans.indices.contains(spanIndex),
                  spans[spanIndex].range.lowerBound < visible.upperBound
            {
                apply(spans[spanIndex])
                spanIndex += 1
            }
            guard spans.indices.contains(spanIndex) else { break }
        }
    }

    private func validateVisibleRenderingAttributes(in layoutManager: NSTextLayoutManager) {
        let controller = layoutManager.textViewportLayoutController
        controller.layoutViewport()
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
            guard fragment.layoutFragmentFrame.minY <= viewport.maxY else {
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
    nonisolated(unsafe) private weak var activeProvider: FoldAttachmentViewProvider?
    nonisolated let chipSize: NSSize
    nonisolated let bodyText: String
    nonisolated let accessibilityText: String
    nonisolated let theme: ReaderTheme
    nonisolated(unsafe) private(set) var matchCount = 0
    nonisolated(unsafe) private(set) var hasDiff = false
    nonisolated(unsafe) private(set) var occurrenceCount = 0

    nonisolated var visualExposureText: String {
        if matchCount > 999 { return " · 999" }
        if matchCount > 0 { return " · \(matchCount) matches" }
        if occurrenceCount > 999 { return " · 999" }
        if occurrenceCount > 0 { return " · \(occurrenceCount) occurrences" }
        return hasDiff ? " · diff" : ""
    }

    nonisolated var accessibilityExposureText: String {
        var values: [String] = []
        if matchCount > 0 { values.append("\(matchCount) matches") }
        if occurrenceCount > 0 { values.append("\(occurrenceCount) occurrences") }
        if hasDiff { values.append("diff") }
        return values.isEmpty ? "" : ", " + values.joined(separator: ", ")
    }

    init(region: FoldRegion, theme: ReaderTheme) {
        self.theme = theme
        bodyText = Self.bodyText(for: region)
        accessibilityText = Self.accessibilityText(for: region)
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let measured = (bodyText as NSString).size(withAttributes: [.font: font])
        let bodyWidth = min(180, ceil(measured.width))
        chipSize = NSSize(width: 5 + bodyWidth + 54 + 5, height: 22)
        super.init(data: nil, ofType: "com.codeinsight.fold-attachment")
        allowsTextAttachmentView = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        activeProvider = provider
        return provider
    }

    private static func bodyText(for region: FoldRegion) -> String {
        let summary = region.summary
        switch region.kind {
        case .declaration:
            return joined(
                summary.leadingText,
                "\(summary.hiddenLineCount) lines"
            )
        case .container:
            let members = orderedMembers(summary.memberCounts)
            return "⋯ " + (members + ["\(summary.hiddenLineCount) lines"])
                .joined(separator: " · ")
        case .imports:
            return "⋯ \(summary.itemCount ?? 0) imports"
        case .comment:
            return "⋯ \(summary.hiddenLineCount) comment lines"
        case .attributes:
            return "⋯ \(summary.itemCount ?? 0) attributes"
        case .cfgTest:
            let functionCount = (summary.memberCounts[.fn] ?? 0)
                + (summary.memberCounts[.method] ?? 0)
            return "⋯ tests · \(functionCount) fn · \(summary.hiddenLineCount) lines"
        case .block:
            if let itemCount = summary.itemCount {
                return "⋯ \(itemCount) arms"
            }
            return "⋯ \(summary.hiddenLineCount) lines"
        }
    }

    private static func accessibilityText(for region: FoldRegion) -> String {
        let members = orderedMembers(region.summary.memberCounts)
        let memberText = members.isEmpty ? "" : ", contains " + members.joined(separator: ", ")
        return "Collapsed, hides \(region.summary.hiddenLineCount) lines\(memberText)"
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
            .const, .static, .fn, .method,
        ]
        return order.compactMap { kind in
            guard let count = counts[kind], count > 0 else { return nil }
            return "\(count) \(kind.rawValue)"
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
        return CGRect(
            x: 0,
            y: -6,
            width: attachment.chipSize.width,
            height: attachment.chipSize.height
        )
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

    nonisolated func update() {
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated { provider.updateOnMainActor() }
    }

    @MainActor
    private func updateOnMainActor() {
        guard let attachment = textAttachment as? FoldAttachment,
              let chip = view as? FoldChipView
        else { return }
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

        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: attachment.theme.chipForegroundColor,
            .paragraphStyle: paragraph,
        ]
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
        // NSRulerView strokes its built-in edge hairline across the full dirty
        // rect. Since macOS 14 views no longer clip to bounds by default, that
        // hairline bleeds above the scroll view into sibling header views as a
        // short vertical line at x == ruleThickness. Clip to keep it inside.
        clipsToBounds = true
        ruleThickness = 7
        clientView = reader.view
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        reader?.drawRuler(in: self, dirtyRect: rect)
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
private final class ClickTextView: NSTextView {
    var clickHandler: ((Int, NSEvent.ModifierFlags) -> Void)?
    var sourceCopyHandler: ((NSRange) -> String?)?
    var contextMenuHandler: ((Int) -> Void)?
    var selectionHandler: ((Int) -> Void)?
    var viewportChanged: (() -> Void)?
    var escapeHandler: (() -> Bool)?
    var backgroundHandler: ((NSRect) -> Void)?
    private var viewportOrigin: NSPoint?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: nil
        )
        guard let clipView = enclosingScrollView?.contentView else { return }
        viewportOrigin = clipView.bounds.origin
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
    }

    override func mouseDown(with event: NSEvent) {
        let index = characterIndex(for: event)
        super.mouseDown(with: event)
        clickHandler?(index, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }

    override func writeSelection(
        to pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        guard type == .string,
              let source = sourceCopyHandler?(selectedRange())
        else {
            return super.writeSelection(to: pasteboard, type: type)
        }
        return pasteboard.setString(source, forType: .string)
    }

    override func copy(_ sender: Any?) {
        guard let source = sourceCopyHandler?(selectedRange()) else {
            super.copy(sender)
            return
        }
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

    @objc private func viewportDidChange(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView,
              clipView.bounds.origin != viewportOrigin
        else { return }
        viewportOrigin = clipView.bounds.origin
        viewportChanged?()
    }
}

@MainActor
private extension NSTextView {
    func characterIndex(for event: NSEvent) -> Int {
        characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
    }
}
