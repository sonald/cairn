import AppKit
import CodeInsightReaderCore

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

@MainActor
public final class ReaderTextView {
    public let view: NSTextView
    public let renderingCoordinator = RenderingAttributesCoordinator()
    public var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    public var onContextMenu: ((Int) -> Void)?
    public var onViewportChange: (() -> Void)?
    private let backingTextStorage: NSTextStorage
    private var displayMap: DisplayMap?
    private var displayedDocument: ReaderDocument?
    private var theme: ReaderTheme
    private var diffMarkers: [Int: DiffCore.MarkerKind] = [:]
    private var declarationKindsByLine: [Int: OutlineKind] = [:]
    private weak var scrollView: NSScrollView?
    private weak var ruler: NSRulerView?
    private var lineNumbers = true
    private var occurrenceSelectionByteOffset: UInt32?
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
            guard let self, occurrenceCount > 0 else { return false }
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

    public func display(document: ReaderDocument) {
        guard
            let projection = Self.project(
                document: document,
                renderedFoldIDs: [],
                attributes: baseAttributes,
                theme: theme
            ),
            let layoutManager = view.textLayoutManager
        else { return }

        displayMap = projection.map
        displayedDocument = document
        diffMarkers = [:]
        declarationKindsByLine = Self.declarationKindsByLine(in: document)
        occurrenceSelectionByteOffset = nil
        primarySelectionRange = nil
        view.selectedTextAttributes = nativeSelectedTextAttributes
        currentLineNumber = nil
        occurrenceCount = 0
        visibleLineNumbers = []
        visibleCurrentLineNumbers = []
        visibleDeclarationMarkerLines = []
        renderingCoordinator.setOccurrences([])
        ruler?.needsDisplay = true
        renderingCoordinator.update(
            document: document,
            map: projection.map,
            theme: theme
        )
        updateRulerThickness()
        installRenderingValidator(in: layoutManager)
        backingTextStorage.setAttributedString(projection.attributed)
        if renderingCoordinator.hasRenderingAttributes {
            validateVisibleRenderingAttributes(in: layoutManager)
        }
    }

    public func clear() {
        view.textLayoutManager?.renderingAttributesValidator = nil
        displayedDocument = nil
        displayMap = nil
        diffMarkers = [:]
        declarationKindsByLine = [:]
        occurrenceSelectionByteOffset = nil
        primarySelectionRange = nil
        view.selectedTextAttributes = nativeSelectedTextAttributes
        currentLineNumber = nil
        occurrenceCount = 0
        visibleLineNumbers = []
        visibleCurrentLineNumbers = []
        visibleDeclarationMarkerLines = []
        renderingCoordinator.clear()
        backingTextStorage.setAttributedString(NSAttributedString(string: ""))
        updateRulerThickness()
        ruler?.needsDisplay = true
        view.needsDisplay = true
    }

    public func updateSyntax(document: ReaderDocument) {
        guard
            let layoutManager = view.textLayoutManager
        else { return }
        guard let projection = Self.project(
            document: document,
            renderedFoldIDs: [],
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
        displayedDocument = document
        declarationKindsByLine = Self.declarationKindsByLine(in: document)
        renderingCoordinator.update(
            document: document,
            map: projection.map,
            theme: theme
        )
        if let occurrenceSelectionByteOffset {
            let ranges = occurrenceNSRanges(
                in: document,
                at: occurrenceSelectionByteOffset
            )
            if ranges.isEmpty { self.occurrenceSelectionByteOffset = nil }
            occurrenceCount = ranges.count
            renderingCoordinator.setOccurrences(
                ranges.filter { $0 != primarySelectionRange }
            )
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
            renderedFoldIDs: [],
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
        guard let location = visibleDisplayOffset(forByte: byteOffset),
              location <= backingTextStorage.length
        else { return }
        let lineRange = (backingTextStorage.string as NSString).lineRange(
            for: NSRange(location: location, length: 0)
        )
        updateCurrentLine(byteOffset: byteOffset)
        view.scrollRangeToVisible(lineRange)
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
        guard needsRuler else {
            scrollView.hasVerticalRuler = false
            scrollView.rulersVisible = false
            scrollView.verticalRulerView = nil
            ruler = nil
            view.textContainerInset.width = 12
            scrollView.tile()
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
        activeRuler.needsDisplay = true
    }

    public func installDiffGutter(in scrollView: NSScrollView) {
        configureGutter(in: scrollView, lineNumbers: lineNumbers)
    }

    public func setDiffMarkers(_ markers: [Int: DiffCore.MarkerKind]) {
        diffMarkers = markers
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

    public var gutterShowsLineNumbersAndDiff: Bool {
        lineNumbers && !diffMarkers.isEmpty && rulerThickness > diffColumnWidth
    }

    @discardableResult
    public func activate(atByteOffset byteOffset: UInt32) -> Int {
        updateCurrentLine(byteOffset: byteOffset)
        guard let document = displayedDocument else {
            clearOccurrences()
            return 0
        }
        let ranges = occurrenceNSRanges(in: document, at: byteOffset)
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
        return ranges.count
    }

    public func clearOccurrences() {
        occurrenceSelectionByteOffset = nil
        primarySelectionRange = nil
        view.selectedTextAttributes = nativeSelectedTextAttributes
        view.setSelectedRange(NSRange(location: view.selectedRange().location, length: 0))
        setOccurrences([])
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
              document.lineTable.lineStarts.indices.contains(line - 1),
              let location = visibleDisplayOffset(
                  forByte: document.lineTable.lineStarts[line - 1]
              )
        else { return false }
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

    private func activate(atCharacterIndex index: Int) {
        guard let byteOffset = byteOffset(forCharacterIndex: index) else {
            clearOccurrences()
            return
        }
        activate(atByteOffset: byteOffset)
    }

    private func setOccurrences(_ ranges: [NSRange]) {
        occurrenceCount = ranges.count
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

    private func occurrenceNSRanges(
        in document: ReaderDocument,
        at byteOffset: UInt32
    ) -> [NSRange] {
        guard let displayMap else { return [] }
        return document.identifierOccurrences(at: byteOffset).flatMap {
            displayMap.project(byteRange: $0)?.visible ?? []
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
            if let kind = diffMarkers[line] {
                theme.color(for: kind).setFill()
                NSRect(
                    x: lineNumberColumnWidth + declarationColumnWidth + 1,
                    y: rulerRect.minY,
                    width: max(2, diffColumnWidth - 2),
                    height: max(2, rulerRect.height)
                ).fill()
            }
        }
        visibleLineNumbers = lineNumbers ? lines : []
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
        case .struct, .enum, .trait, .typeAlias:
            rect.fill()
        }
    }

    func declarationMarkerColor(for kind: OutlineKind) -> NSColor {
        let color: NSColor
        switch kind {
        case .fn, .method:
            color = theme.color(for: .functionName)
        case .struct, .enum, .trait, .typeAlias:
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

    private func applyThemeColors() {
        view.backgroundColor = theme.backgroundColor
    }

    private static func project(
        document: ReaderDocument,
        renderedFoldIDs: Set<FoldID>,
        attributes: [NSAttributedString.Key: Any],
        theme: ReaderTheme
    ) -> (attributed: NSMutableAttributedString, map: DisplayMap)? {
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
        return (attributed, map)
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
        for span in spans {
            guard let projected = map.project(byteRange: span.range) else { continue }
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
private final class ReaderRulerView: NSRulerView {
    private weak var reader: ReaderTextView?

    init(scrollView: NSScrollView, reader: ReaderTextView) {
        self.reader = reader
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        ruleThickness = 7
        clientView = reader.view
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        reader?.drawRuler(in: self, dirtyRect: rect)
    }
}

@MainActor
private final class ClickTextView: NSTextView {
    var clickHandler: ((Int, NSEvent.ModifierFlags) -> Void)?
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
