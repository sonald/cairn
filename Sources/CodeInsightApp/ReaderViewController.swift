import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import Observation
import PDFKit
import WebKit

/// Reader click gesture dispatch through the key binding table (K0a) instead
/// of hardcoded modifier checks. Empty modifiers are the plain click;
/// combinations no gesture is bound to do nothing (pre-table behavior for
/// e.g. ⌃+click).
enum ReaderClickGesture {
    enum Action: Equatable {
        case plain
        case definition
        case typeDefinition
        case symbolDoc
    }

    static func action(
        for modifiers: NSEvent.ModifierFlags,
        table: KeyBindingTable
    ) -> Action? {
        if modifiers.isEmpty { return .plain }
        let chordModifiers = Set<KeyChord.Modifier>(modifiers)
        let bound = table.commands(boundTo: .click(chordModifiers))
        switch bound.first {
        case .readerGestureDefinition: return .definition
        case .readerGestureTypeDefinition: return .typeDefinition
        case .readerGestureSymbolDoc: return .symbolDoc
        default: return nil
        }
    }
}

@MainActor
private final class TabStripView: NSView {
    private weak var model: TabStripModel?
    private var onActivate: ((Int) -> Void)?
    private var onClose: ((Int) -> Void)?
    var onOpenToSide: ((URL) -> Void)?
    private let scrollView = NSScrollView()
    private let tabs = NSStackView()
    private var displayedKeys: [String] = []
    private var displayedActiveIndex: Int?
    private var previousClipSize = NSSize.zero
    private var theme = ReaderTheme(settings: ReaderSettings())

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel(localized("main.open.files"))
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        tabs.orientation = .horizontal
        tabs.alignment = .centerY
        tabs.spacing = 1
        tabs.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tabs
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            tabs.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            tabs.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            tabs.heightAnchor.constraint(equalTo: heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ model: TabStripModel, onActivate: @escaping (Int) -> Void,
                   onClose: @escaping (Int) -> Void) {
        self.model = model
        self.onActivate = onActivate
        self.onClose = onClose
        refresh()
    }

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        displayedKeys = []
        refresh()
    }

    var activeTitle: String { model?.activeTab?.title ?? "" }

    override func layout() {
        super.layout()
        let size = scrollView.contentView.bounds.size
        guard size != previousClipSize else { return }
        previousClipSize = size
        revealActiveTab()
    }

    func refresh() {
        guard let model else { return }
        isHidden = model.tabs.isEmpty
        setAccessibilityValue(activeTitle)
        let keys = model.tabs.map {
            ($0.fileURL?.path ?? "") + "\n" + $0.title + "\n" + String($0.isPreview)
        }
        guard keys != displayedKeys || model.activeIndex != displayedActiveIndex else { return }
        displayedKeys = keys
        displayedActiveIndex = model.activeIndex
        for tab in tabs.arrangedSubviews {
            tabs.removeArrangedSubview(tab)
            tab.removeFromSuperview()
        }
        for (index, tab) in model.tabs.enumerated() {
            let active = index == model.activeIndex
            var title = tab.title
            if model.tabs.filter({ $0.title == title }).count > 1, let file = tab.fileURL {
                let peers = model.tabs.compactMap { $0.title == tab.title ? $0.fileURL : nil }
                let components = file.pathComponents
                for length in 2...components.count {
                    let suffix = components.suffix(length).joined(separator: "/")
                    if peers.filter({ $0.pathComponents.suffix(length).joined(separator: "/") == suffix }).count == 1 {
                        title = suffix
                        break
                    }
                }
            }
            let button = NSButton(title: title, target: self, action: #selector(activate(_:)))
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 12, weight: active ? .semibold : .regular)
            if tab.isPreview, let font = button.font {
                button.font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            button.alignment = .left
            button.lineBreakMode = .byTruncatingMiddle
            button.contentTintColor = active ? theme.foregroundColor : theme.chromeSecondaryColor
            button.toolTip = tab.fileURL?.path ?? tab.title
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityValue(active ? 1 : 0)
            button.setAccessibilityLabel(localizedFormat("main.tab.title", title, tab.isPreview ? localized("main.preview.suffix") : ""))
            let help = (tab.fileURL?.path ?? tab.title)
                + (tab.isPreview ? localized("main.preview.tip") : "")
            button.setAccessibilityHelp(help)
            let menu = NSMenu(title: title)
            menu.autoenablesItems = false
            let keepOpen = NSMenuItem(title: localized("main.keep.open"), action: #selector(keepTabOpen(_:)), keyEquivalent: "")
            keepOpen.target = self
            keepOpen.tag = index
            keepOpen.isEnabled = tab.isPreview
            menu.addItem(keepOpen)
            let toSide = NSMenuItem(title: localized("main.open.to.side"), action: #selector(openTabToSide(_:)), keyEquivalent: "")
            toSide.target = self
            toSide.tag = index
            toSide.isEnabled = tab.fileURL != nil && onOpenToSide != nil
            menu.addItem(toSide)
            button.menu = menu
            let close = NSButton(title: "", target: self, action: #selector(closeTab(_:)))
            close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
            close.tag = index
            close.isBordered = false
            close.controlSize = .small
            close.contentTintColor = theme.chromeSecondaryColor
            close.setAccessibilityLabel(localizedFormat("main.close.tab", title))
            close.toolTip = localizedFormat("main.close.tab", tab.title)
            let row = NSStackView(views: [button, close])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 4)
            row.wantsLayer = true
            row.layer?.backgroundColor = (active ? theme.backgroundColor : theme.chromeHeaderColor).cgColor
            row.menu = menu
            let width = min(220, max(110, button.intrinsicContentSize.width + 42))
            tabs.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalToConstant: width),
                row.heightAnchor.constraint(equalTo: heightAnchor),
                close.widthAnchor.constraint(equalToConstant: 22),
                close.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
        layoutSubtreeIfNeeded()
        revealActiveTab()
    }

    private func revealActiveTab() {
        if let active = model?.activeIndex, tabs.arrangedSubviews.indices.contains(active) {
            tabs.scrollToVisible(tabs.arrangedSubviews[active].frame)
        }
    }

    @objc private func activate(_ sender: NSButton) { onActivate?(sender.tag) }
    @objc private func closeTab(_ sender: NSButton) { onClose?(sender.tag) }
    @objc private func keepTabOpen(_ sender: NSMenuItem) {
        model?.keepOpen(sender.tag)
        refresh()
    }

    @objc private func openTabToSide(_ sender: NSMenuItem) {
        guard let tabs = model?.tabs, tabs.indices.contains(sender.tag),
              let file = tabs[sender.tag].fileURL else { return }
        onOpenToSide?(file)
    }
}

@MainActor
private final class ReadingHeightControl: NSSegmentedControl {
    private let segmentWidths: [CGFloat] = [48, 76, 72]

    init() {
        super.init(frame: .zero)
        segmentCount = ReadingHeightLevel.allCases.count
        trackingMode = .selectOne
        segmentStyle = .texturedRounded
        controlSize = .small
        font = .systemFont(ofSize: 11)
        for level in ReadingHeightLevel.allCases {
            setLabel(level.title, forSegment: level.rawValue)
        }
        selectedSegment = ReadingHeightLevel.full.rawValue
        for (index, width) in segmentWidths.enumerated() {
            setWidth(width, forSegment: index)
        }
        setAccessibilityLabel(localized("main.reading.height"))
        toolTip = localized("main.reading.height.0.1.2")
        setToolTip(
            localized("main.height.full.help"),
            forSegment: ReadingHeightLevel.full.rawValue
        )
        setToolTip(
            localized("main.structure.folds.function.bodies.and.keeps.signatures.visible"),
            forSegment: ReadingHeightLevel.structure.rawValue
        )
        setToolTip(
            localized("main.height.overview.help"),
            forSegment: ReadingHeightLevel.overview.rawValue
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var level: ReadingHeightLevel {
        ReadingHeightLevel(rawValue: selectedSegment) ?? .full
    }

    func set(level: ReadingHeightLevel) {
        selectedSegment = level.rawValue
        needsDisplay = true
    }

    func apply(settings: ReaderSettings) {
        needsDisplay = true
    }

}

/// Intercepts the native autoresize before TextKit discards the old line geometry.
@MainActor
private final class PlainTextPreviewView: NSTextView {
    private(set) var backgroundDrawCount = 0
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        backgroundDrawCount += 1
    }

    var onWidthChange: ((CGFloat) -> Void)?
    var isReflowing = false

    override func setFrameSize(_ newSize: NSSize) {
        if !isReflowing, newSize.width != frame.width, let onWidthChange {
            onWidthChange(newSize.width)
        } else {
            super.setFrameSize(newSize)
        }
    }
}

/// An identifier under the pointer in one reader, with the document it was
/// read from.
struct ReaderHoverRequest {
    let file: URL
    let document: ReaderDocument
    let target: ReaderHoverTarget
}

@MainActor
final class ReaderViewController: NSViewController, NSSearchFieldDelegate,
    NSTextViewDelegate, WKNavigationDelegate
{
    var onTokenClick: ((UInt32, Bool) -> Void)?
    /// ⌘⇧+click: jump to the type definition of the binding under the click.
    var onTypeDefinitionClick: ((UInt32) -> Void)?
    /// R4: USER caret movement (mouse selection, arrow keys) drives the lens;
    /// programmatic navigation/restores do not (the owner debounces).
    var onCaretFollow: ((UInt32) -> Void)?
    /// The identifier under the pointer, or `nil` over anything else.
    var onHover: ((ReaderHoverRequest?) -> Void)?
    /// ⌥-click: show documentation now.
    var onHoverRequest: ((ReaderHoverRequest) -> Void)?
    var onHoverDismiss: (() -> Void)?
    var onHoverEscape: (() -> Bool)?
    var onShowRelation: ((UInt32, RelationTreeModel.Direction) -> Void)?
    var onOutlineChange: (([OutlineFacet]) -> Void)?
    var onReadingPositionChange: ((UInt32) -> Void)?
    var onOutlineFollowPositionChange: ((UInt32) -> Void)?
    var onLiveScroll: (() -> Void)?
    var onFocusNotice: ((String) -> Void)?
    var onSelectionChange: ((UInt32) -> Void)?
    var onOpenScope: ((UInt32) -> Void)?
    var onRevealPath: ((URL) -> Void)?
    var projectRoot: URL?
    var onDocumentChange: ((URL, ReaderDocument?) -> Void)?
    var onOpenPreviewLink: ((URL) -> Void)?
    var onReadingSetScrollChange: ((Double) -> Void)?
    var onCopyPathLine: ((URL, UInt32) -> Void)?
    var onRevealInFinder: ((URL) -> Void)?
    var onOpenReadingSetExcerpt: ((Int) -> Void)?
    var onExpandReadingSetExcerpt: ((Int) -> Void)?
    var onViewReadingSetEvidence: ((Int) -> Void)?
    var onChooseCompareVersion: (() -> Void)?
    var onCloseComparison: (() -> Void)?
    /// Tab menu “Open to the Side”.
    var onOpenToSide: ((URL) -> Void)? {
        get { tabStripView.onOpenToSide }
        set { tabStripView.onOpenToSide = newValue }
    }
    /// Split reference mode: the compare controls give way to the file path.
    private(set) var isReferenceMode = false
    private let referenceTitleLabel = NSTextField(labelWithString: "")
    private let compareCloseButton = NSButton()
    private var summaryHeightConstraint: NSLayoutConstraint?
    private let focusBar = NSView()
    var onPreviousDiffHunk: (() -> Void)?
    var onNextDiffHunk: (() -> Void)?
    var onFunctionChange: ((DiffCore.FunctionChange) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let textView: ReaderTextView
    private let readingSetView = ReadingSetView()
    private let previewArea = NSView()
    private let loader = DocumentLoader()
    private let showsCompareControls: Bool
    private let compareVersionButton = NSButton()
    private let previousHunkButton = NSButton()
    private let nextHunkButton = NSButton()
    private let functionSummaryStack = NSStackView()
    private var displayedFunctionChanges: [DiffCore.FunctionChange] = []
    private var functionSummaryStatus: String?
    private let readerArea = NSView()
    private let tabStripView = TabStripView()
    private let readerHeader = NSView()
    private let readerHeaderDivider = NSView()
    private let pathControl = NSPathControl()
    /// A historical snapshot says so beside the path: the past is read-only.
    private lazy var snapshotBadge = CairnBadgeView(
        style: .commit,
        text: localized("main.snapshot.readonly"),
        theme: readerTheme
    )
    /// The open file is outside the index because of the project's own rules.
    private lazy var exclusionBadge = CairnBadgeView(
        style: .limited,
        text: localized("main.rules.fileExcluded"),
        theme: readerTheme
    )
    private lazy var pathRow: NSStackView = {
        let row = NSStackView(views: [pathControl, snapshotBadge, exclusionBadge])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        // Paint the chrome itself instead of letting the window background
        // show through: offscreen captures have no window background.
        row.wantsLayer = true
        snapshotBadge.isHidden = true
        snapshotBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        snapshotBadge.setContentHuggingPriority(.required, for: .horizontal)
        exclusionBadge.isHidden = true
        exclusionBadge.toolTip = localized("main.rules.fileExcluded.help")
        exclusionBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        exclusionBadge.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }()
    private let scopeHeader = NSView()
    private let scopeHeaderContent = NSStackView()
    private let scopeHeaderDivider = NSView()
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let readingHeightControl = ReadingHeightControl()
    private let readingHeightShortcutLabel = NSTextField(
        labelWithString: "⌥⌘0/1/2"
    )
    private let findBar = NSView()
    private let findBarDivider = NSView()
    private let findField = NSSearchField()
    private let findCaseButton = NSButton()
    private let findWordButton = NSButton()
    private let findPreviousButton = NSButton()
    private let findNextButton = NSButton()
    private let findStatusLabel = NSTextField(labelWithString: "")
    private let findCloseButton = NSButton()
    private weak var scrollView: NSScrollView?
    private var overviewRulerWidth: NSLayoutConstraint?
    private var showsOverviewRuler = true
    private(set) var displayedFile: URL?
    private var displayedSnapshotID: SnapshotID?
    private var displayedLanguageMode: LanguageMode?
    private var displayedDocument: ReaderDocument?

    /// P3.2: caret-follow reads the currently displayed document.
    var caretDocument: ReaderDocument? { displayedDocument }

    var hasFocusedText: Bool {
        view.window?.firstResponder === textView.view
    }

    /// The identifier at the caret or the start of the selection.
    func hoverRequestAtSelection() -> ReaderHoverRequest? {
        hoverRequest(textView.hoverTargetAtSelection())
    }

    private func hoverRequest(_ target: ReaderHoverTarget?) -> ReaderHoverRequest? {
        guard let target, let file = displayedFile, let document = displayedDocument,
              previewView == nil
        else { return nil }
        return ReaderHoverRequest(file: file, document: document, target: target)
    }

    private var displayedReadingSetKey: String?
    private var previewView: NSView?
    private var previewKind: String?
    private enum TextPreviewKind { case plainText, markdown }
    private var textPreviewKind: TextPreviewKind?
    /// Rebuilds the text preview's attributes for a new theme; the string
    /// itself never changes, so selection and scroll survive a restyle.
    private var previewRestyle: ((ReaderTheme) -> NSAttributedString?)?
    private var previewWrapLines = ReaderSettings().wrapLines
    private var previewUnwrappedX: CGFloat = 0
    private var previewRenderedText: String?
    private var previewLinkCount = 0
    private var previewAccessibilityLabel: String?
    private var previewHTMLJavaScriptEnabled: Bool?
    private var previewHTMLDataStorePersistent: Bool?
    private var previewHTMLContentSecurityPolicy: String?
    private var previewPDFPageCount: Int?
    private var previewImageSize: NSSize?
    private var previewHTMLSource: String?
    private var previewHTMLBaseURL: URL?
    private var previewHTMLFinished = false
    private var previewHTMLLoadError: String?
    private var htmlInitialNavigationAllowed = false
    private var loadGeneration: UInt64 = 0
    private var isClosing = false
    private var syntaxLoadPending = false
    /// Large-file syntax work; cancelled whenever the displayed load changes.
    /// Publication is still fenced by `loadGeneration`.
    private var syntaxTask: Task<Void, Never>?
    private var pendingFocusNavigationOffset: UInt32?
    private var findTask: Task<Void, Never>?
    private var findWorker: Task<[ByteRange], Error>?
    private var findRequestID: UInt64 = 0
    private var savedSymbolOccurrenceByteOffset: UInt32?
    private var findWrapped = false
    private var findScanDelayForTesting = Duration.zero
    private(set) var findCancelledWorkerCountForTesting = 0
    private var contextMenuOffset: UInt32?

    @objc private func jumpToTypeDefinitionFromMenu(_ sender: Any?) {
        guard let offset = contextMenuOffset else { return }
        onTypeDefinitionClick?(offset)
    }
    private var readingPositionTask: Task<Void, Never>?
    private var emptyStateView: EmptyStateView?
    private var readerTheme = ReaderTheme(settings: ReaderSettings())
    private var scopeHeaderByteOffset: UInt32?
    nonisolated(unsafe) private var liveScrollObserver: NSObjectProtocol?

    init(showsCompareControls: Bool = false, derivedDataStore: ReaderDerivedDataStore = ReaderDerivedDataStore()) {
        textView = ReaderTextView(derivedDataStore: derivedDataStore)
        self.showsCompareControls = showsCompareControls
        super.init(nibName: nil, bundle: nil)
        findBar.isHidden = true
        textView.onIdentifierPreparationChanged = { [weak self] state in
            let notice = readerIdentifierPreparationNotice(state)
            self?.textView.view.setAccessibilityHelp(notice)
            self?.textView.view.toolTip = notice
            self?.onIdentifierPreparationChanged?()
        }
    }

    var onIdentifierPreparationChanged: (() -> Void)?
    var identifierPreparationNotice: String? {
        readerIdentifierPreparationNotice(textView.identifierPreparationState)
    }

    /// Context menu: toggle a name's highlight, or give it a chosen color slot.
    var onToggleHighlightName: ((String) -> Void)?
    var onAssignHighlightColor: ((String, UInt8) -> Void)?

    func setHighlightedNames(_ names: [String: UInt8]) {
        textView.setHighlightedNames(names)
    }

    var identifierAtCaret: String? { textView.identifierAtCaret }

    func occurrenceCount(ofName name: String) -> Int? {
        textView.occurrenceCount(ofName: name)
    }

    @discardableResult
    func revealOccurrence(ofName name: String, backwards: Bool) -> Bool {
        textView.revealOccurrence(ofName: name, backwards: backwards)
    }

    @discardableResult
    func jumpToMatchingBracket() -> Bool { textView.jumpToMatchingBracket() }

    @discardableResult
    func selectInsideBrackets() -> Bool { textView.selectInsideBrackets() }

    @objc private func toggleHighlightFromMenu(_ sender: Any?) {
        guard let offset = contextMenuOffset, let name = textView.identifier(atByteOffset: offset) else { return }
        onToggleHighlightName?(name)
    }

    @objc private func assignHighlightColorFromMenu(_ sender: NSMenuItem) {
        guard let offset = contextMenuOffset, let name = textView.identifier(atByteOffset: offset),
              let slot = UInt8(exactly: sender.tag) else { return }
        onAssignHighlightColor?(name, slot)
    }

    private func cancelSyntaxLoad() {
        syntaxLoadPending = false
        syntaxTask?.cancel()
        syntaxTask = nil
    }

    /// Terminal window teardown, not a temporary pause. Preserve text for the final checkpoint.
    func cancelDerivedDataSubscription() {
        isClosing = true
        loadGeneration &+= 1
        cancelSyntaxLoad()
        pendingFocusNavigationOffset = nil
        readingPositionTask?.cancel()
        readingPositionTask = nil
        textView.stopPendingReaderWork()
        readingSetView.stopPendingLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        findTask?.cancel()
        findWorker?.cancel()
        if let liveScrollObserver {
            NotificationCenter.default.removeObserver(liveScrollObserver)
        }
    }

    override func loadView() {
        let scrollView = NSScrollView()
        self.scrollView = scrollView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView.view
        textView.view.frame = scrollView.contentView.bounds
        textView.configureGutter(in: scrollView, lineNumbers: true)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        liveScrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.textView.didLiveScrollWhileFocused()
                self?.onLiveScroll?()
            }
        }

        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        readerArea.addSubview(scrollView)
        let overviewRuler = textView.overviewRuler
        overviewRuler.translatesAutoresizingMaskIntoConstraints = false
        readerArea.addSubview(overviewRuler)
        let overviewRulerWidth = overviewRuler.widthAnchor.constraint(equalToConstant: ReaderTextView.overviewRulerWidth)
        self.overviewRulerWidth = overviewRulerWidth
        readerArea.addSubview(readingSetView)
        readerArea.addSubview(previewArea)
        readerArea.addSubview(label)
        previewArea.translatesAutoresizingMaskIntoConstraints = false
        previewArea.wantsLayer = true
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: readerArea.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: overviewRuler.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: readerArea.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: readerArea.bottomAnchor),
            overviewRuler.trailingAnchor.constraint(equalTo: readerArea.trailingAnchor),
            overviewRuler.topAnchor.constraint(equalTo: readerArea.topAnchor),
            overviewRuler.bottomAnchor.constraint(equalTo: readerArea.bottomAnchor),
            overviewRulerWidth,
            readingSetView.leadingAnchor.constraint(equalTo: readerArea.leadingAnchor),
            readingSetView.trailingAnchor.constraint(equalTo: readerArea.trailingAnchor),
            readingSetView.topAnchor.constraint(equalTo: readerArea.topAnchor),
            readingSetView.bottomAnchor.constraint(equalTo: readerArea.bottomAnchor),
            previewArea.leadingAnchor.constraint(equalTo: readerArea.leadingAnchor),
            previewArea.trailingAnchor.constraint(equalTo: readerArea.trailingAnchor),
            previewArea.topAnchor.constraint(equalTo: readerArea.topAnchor),
            previewArea.bottomAnchor.constraint(equalTo: readerArea.bottomAnchor),
            label.centerXAnchor.constraint(equalTo: readerArea.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: readerArea.centerYAnchor),
        ])
        readingSetView.isHidden = true
        previewArea.isHidden = true
        readingSetView.onOpen = { [weak self] in
            self?.onOpenReadingSetExcerpt?($0)
        }
        readingSetView.onExpand = { [weak self] in
            self?.onExpandReadingSetExcerpt?($0)
        }
        readingSetView.onViewEvidence = { [weak self] in
            self?.onViewReadingSetEvidence?($0)
        }
        readingSetView.onScroll = { [weak self] offset in
            self?.onReadingSetScrollChange?(offset)
        }
        if showsCompareControls {
            view = compareContainer(readerView: readerArea)
        } else {
            tabStripView.isHidden = true
            configureReaderHeader()
            pathControl.pathStyle = .standard
            pathControl.controlSize = .small
            pathControl.isEditable = false
            pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pathControl.target = self
            pathControl.action = #selector(revealBreadcrumb(_:))
            pathControl.setAccessibilityLabel(localized("main.file.path"))
            pathControl.isHidden = true
            configureScopeHeader()
            configureFindBar()
            pathRow.isHidden = true
            let stack = NSStackView(views: [
                readerHeader,
                findBar,
                pathRow,
                readerArea,
            ])
            stack.orientation = .vertical
            stack.alignment = .width
            stack.distribution = .fill
            stack.spacing = 0
            NSLayoutConstraint.activate([
                readerArea.widthAnchor.constraint(equalTo: stack.widthAnchor),
                readerHeader.heightAnchor.constraint(equalToConstant: 32),
                findBar.heightAnchor.constraint(equalToConstant: 31),
                pathRow.heightAnchor.constraint(equalToConstant: 24),
                pathRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
            view = stack
        }
        focusBar.wantsLayer = true
        focusBar.isHidden = true
        focusBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(focusBar)
        NSLayoutConstraint.activate([
            focusBar.topAnchor.constraint(equalTo: view.topAnchor),
            focusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            focusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            focusBar.heightAnchor.constraint(equalToConstant: 2),
        ])
        textView.onClick = { [weak self] characterIndex, modifiers in
            guard let self,
                  let offset = self.textView.byteOffset(
                    forCharacterIndex: characterIndex
                  )
            else { return }
            self.onSelectionChange?(offset)
            let meaningful = modifiers.intersection([.command, .option, .control, .shift])
            // The symbol-documentation gesture keeps hover alive; anything
            // else dismisses it (same condition as the pre-table dispatch).
            let table = appKeyBindingTable()
            if meaningful != table.symbolDocClickFlags { self.onHoverDismiss?() }
            switch ReaderClickGesture.action(for: meaningful, table: table) {
            case .plain:
                self.onTokenClick?(offset, false)
            case .definition:
                self.onTokenClick?(offset, true)
            case .typeDefinition:
                self.onTypeDefinitionClick?(offset)
            case .symbolDoc:
                if let request = self.hoverRequest(self.textView.hoverTarget(atByteOffset: offset)) {
                    self.onHoverRequest?(request)
                }
            case nil:
                break
            }
        }
        textView.onHover = { [weak self] target in
            guard let self else { return }
            self.onHover?(self.hoverRequest(target))
        }
        textView.onHoverDismiss = { [weak self] in self?.onHoverDismiss?() }
        textView.onHoverEscape = { [weak self] in self?.onHoverEscape?() ?? false }
        textView.onViewportChange = { [weak self] in
            self?.scheduleReadingPositionChange()
        }
        textView.onCaretChange = { [weak self] byteOffset in
            self?.renderScopeHeader(at: byteOffset)
            self?.onSelectionChange?(byteOffset)
        }
        textView.onUserCaretChange = { [weak self] byteOffset in
            self?.onCaretFollow?(byteOffset)
        }
        textView.onBlockEndAnnotationActivate = { [weak self] byteOffset in
            guard let self else { return }
            if let onOpenScope { onOpenScope(byteOffset) } else { textView.reveal(byteOffset: byteOffset) }
        }

        let relationMenu = NSMenu(title: localized("main.relations"))
        relationMenu.autoenablesItems = false
        relationMenu.addItem(NSMenuItem(
            title: localized("main.type.definition"),
            action: #selector(jumpToTypeDefinitionFromMenu(_:)),
            keyEquivalent: ""
        ))
        relationMenu.addItem(.separator())
        relationMenu.addItem(NSMenuItem(
            title: localized("main.show.callers"),
            action: #selector(showCallers(_:)),
            keyEquivalent: ""
        ))
        relationMenu.addItem(NSMenuItem(
            title: localized("main.show.calls"),
            action: #selector(showCalls(_:)),
            keyEquivalent: ""
        ))
        relationMenu.addItem(NSMenuItem(
            title: localized("main.show.implementations"),
            action: #selector(showImplementations(_:)),
            keyEquivalent: ""
        ))
        relationMenu.addItem(NSMenuItem(
            title: localized("main.show.references"),
            action: #selector(showReferences(_:)),
            keyEquivalent: ""
        ))
        relationMenu.addItem(.separator())
        relationMenu.addItem(NSMenuItem(
            title: localized("main.highlight.toggle"),
            action: #selector(toggleHighlightFromMenu(_:)),
            keyEquivalent: ""
        ))
        let colorItem = NSMenuItem(title: localized("main.highlight.color"), action: nil, keyEquivalent: "")
        let colorMenu = NSMenu(title: localized("main.highlight.color"))
        colorMenu.autoenablesItems = false
        for slot in 1...Int(ReaderTheme.highlightSlotCount) {
            let item = NSMenuItem(
                title: localizedFormat("main.highlight.color.slot", Int64(slot)),
                action: #selector(assignHighlightColorFromMenu(_:)),
                keyEquivalent: ""
            )
            item.tag = slot
            item.target = self
            colorMenu.addItem(item)
        }
        colorItem.submenu = colorMenu
        relationMenu.addItem(colorItem)
        relationMenu.addItem(.separator())
        relationMenu.addItem(NSMenuItem(
            title: localized("main.copy.path.line"),
            action: #selector(copyPathLine(_:)),
            keyEquivalent: ""
        ))
        relationMenu.addItem(NSMenuItem(
            title: localized("main.reveal.in.finder"),
            action: #selector(revealInFinder(_:)),
            keyEquivalent: ""
        ))
        for item in relationMenu.items { item.target = self }
        textView.view.menu = relationMenu
        textView.onContextMenu = { [weak self] characterIndex in
            guard let self else { return }
            contextMenuOffset = displayedDocument == nil
                ? nil
                : textView.byteOffset(forCharacterIndex: characterIndex)
            let location = contextMenuLocation()
            let highlightName = contextMenuOffset.flatMap { textView.identifier(atByteOffset: $0) }
            for item in textView.view.menu?.items ?? [] where item.submenu != nil {
                for colorItem in item.submenu?.items ?? [] {
                    colorItem.image = highlightSwatch(slot: UInt8(colorItem.tag))
                }
            }
            for item in textView.view.menu?.items ?? [] where !item.isSeparatorItem {
                item.isEnabled = if item.action == #selector(toggleHighlightFromMenu(_:)) || item.submenu != nil {
                    highlightName != nil
                } else if item.action == #selector(revealInFinder(_:)) {
                    location.map {
                        FileManager.default.fileExists(atPath: $0.file.path)
                    } ?? false
                } else {
                    location != nil
                }
            }
        }
    }

    private func configureReaderHeader() {
        readerHeader.wantsLayer = true
        readerHeader.translatesAutoresizingMaskIntoConstraints = false
        fileNameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        fileNameLabel.cell?.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal)
        fileNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabStripView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabStripView.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        readingHeightShortcutLabel.font = .systemFont(ofSize: 10)
        readingHeightShortcutLabel.isHidden = true
        readingHeightControl.target = self
        readingHeightControl.action = #selector(changeReadingHeight(_:))

        let row = NSStackView(views: [
            fileNameLabel,
            tabStripView,
            readingHeightShortcutLabel,
            readingHeightControl,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        readerHeaderDivider.wantsLayer = true
        readerHeaderDivider.translatesAutoresizingMaskIntoConstraints = false
        readerHeader.addSubview(row)
        readerHeader.addSubview(readerHeaderDivider)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(
                equalTo: readerHeader.leadingAnchor,
                constant: 13),
            row.trailingAnchor.constraint(
                equalTo: readerHeader.trailingAnchor,
                constant: -13),
            row.centerYAnchor.constraint(
                equalTo: readerHeader.centerYAnchor,
                constant: -0.5),
            readingHeightControl.widthAnchor.constraint(equalToConstant: 196),
            readingHeightControl.heightAnchor.constraint(equalToConstant: 24),
            tabStripView.heightAnchor.constraint(equalToConstant: 30),
            readerHeaderDivider.leadingAnchor.constraint(
                equalTo: readerHeader.leadingAnchor
            ),
            readerHeaderDivider.trailingAnchor.constraint(
                equalTo: readerHeader.trailingAnchor
            ),
            readerHeaderDivider.bottomAnchor.constraint(
                equalTo: readerHeader.bottomAnchor
            ),
            readerHeaderDivider.heightAnchor.constraint(equalToConstant: 1),
        ])
        readerHeader.setAccessibilityElement(false)
        fileNameLabel.setAccessibilityLabel(localized("main.current.file"))
        applyReaderHeaderTheme(ReaderSettings())
    }

    private func configureScopeHeader() {
        scopeHeader.wantsLayer = true
        scopeHeader.translatesAutoresizingMaskIntoConstraints = false
        scopeHeader.isHidden = true
        scopeHeaderContent.orientation = .horizontal
        scopeHeaderContent.alignment = .centerY
        scopeHeaderContent.spacing = 8
        scopeHeaderContent.translatesAutoresizingMaskIntoConstraints = false
        scopeHeaderDivider.wantsLayer = true
        scopeHeaderDivider.translatesAutoresizingMaskIntoConstraints = false
        readerArea.addSubview(scopeHeader)
        scopeHeader.addSubview(scopeHeaderContent)
        scopeHeader.addSubview(scopeHeaderDivider)
        NSLayoutConstraint.activate([
            scopeHeader.leadingAnchor.constraint(equalTo: readerArea.leadingAnchor),
            // The overview ruler stays uncovered: its top marks the file's start.
            scopeHeader.trailingAnchor.constraint(equalTo: textView.overviewRuler.leadingAnchor),
            scopeHeader.topAnchor.constraint(equalTo: readerArea.topAnchor),
            scopeHeader.heightAnchor.constraint(equalToConstant: 26),
            scopeHeaderContent.leadingAnchor.constraint(
                equalTo: scopeHeader.leadingAnchor,
                constant: 13
            ),
            scopeHeaderContent.trailingAnchor.constraint(
                lessThanOrEqualTo: scopeHeader.trailingAnchor,
                constant: -13
            ),
            scopeHeaderContent.centerYAnchor.constraint(
                equalTo: scopeHeader.centerYAnchor,
                constant: -0.5
            ),
            scopeHeaderDivider.leadingAnchor.constraint(
                equalTo: scopeHeader.leadingAnchor
            ),
            scopeHeaderDivider.trailingAnchor.constraint(
                equalTo: scopeHeader.trailingAnchor
            ),
            scopeHeaderDivider.bottomAnchor.constraint(
                equalTo: scopeHeader.bottomAnchor
            ),
            scopeHeaderDivider.heightAnchor.constraint(equalToConstant: 1),
        ])
        scopeHeader.setAccessibilityElement(true)
        scopeHeader.setAccessibilityLabel(localized("main.current.scope"))
        applyScopeHeaderTheme()
    }

    private func renderScopeHeader(at byteOffset: UInt32?) {
        scopeHeaderByteOffset = byteOffset
        guard !showsCompareControls,
              let byteOffset,
              let file = displayedFile,
              let document = displayedDocument
        else {
            hideScopeHeader()
            return
        }
        let facets = textView.scopeHeaderFacets(at: byteOffset)
        guard !facets.isEmpty,
              let line = document.lineTable.lineColumn(at: byteOffset)?.line
        else {
            hideScopeHeader()
            return
        }

        for arranged in scopeHeaderContent.arrangedSubviews {
            scopeHeaderContent.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        for (index, facet) in facets.enumerated() {
            if index > 0 {
                scopeHeaderContent.addArrangedSubview(scopeLabel(
                    "▸",
                    color: readerTheme.chromeTertiaryColor
                ))
            }
            scopeHeaderContent.addArrangedSubview(scopeLabel(
                Self.scopeKindTitle(facet.kind),
                color: readerTheme.color(for: .keyword)
            ))
            let button = NSButton(title: facet.name, target: self, action: #selector(openScope(_:)))
            button.isBordered = false
            button.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            button.contentTintColor = readerTheme.foregroundColor
            button.tag = Int(facet.nameRange.lowerBound)
            button.toolTip = localizedFormat("main.go.to", facet.name)
            button.setAccessibilityLabel(localizedFormat("main.go.to", facet.name))
            scopeHeaderContent.addArrangedSubview(button)
        }
        let location = "\(file.lastPathComponent):\(line)"
        scopeHeaderContent.addArrangedSubview(scopeLabel(
            location,
            color: readerTheme.chromeSecondaryColor
        ))
        scopeHeader.isHidden = false
        let scopes = facets.map {
            "\(Self.scopeKindTitle($0.kind)) \($0.name)"
        }.joined(separator: ", ")
        scopeHeader.setAccessibilityElement(false)
        scopeHeader.setAccessibilityLabel(
            localizedFormat("main.scope.description", scopes, file.lastPathComponent, Int64(line))
        )
    }

    private func hideScopeHeader() {
        scopeHeader.isHidden = true
        scopeHeader.setAccessibilityLabel(localized("main.current.scope"))
    }

    @objc private func openScope(_ sender: NSButton) {
        guard let offset = UInt32(exactly: sender.tag) else { return }
        if let onOpenScope { onOpenScope(offset) }
        else { _ = textView.activate(atByteOffset: offset) }
    }

    @objc private func revealBreadcrumb(_ sender: NSPathControl) {
        guard let url = sender.clickedPathItem?.url else { return }
        onRevealPath?(url)
    }

    private func updatePathControl() {
        guard !showsCompareControls else { return }
        pathControl.isHidden = displayedFile == nil
        pathRow.isHidden = pathControl.isHidden
        guard let file = displayedFile else { pathControl.pathItems = []; return }
        pathControl.url = file
        pathControl.toolTip = file.path
        if let root = projectRoot,
           let index = pathControl.pathItems.firstIndex(where: { $0.url?.standardizedFileURL == root.standardizedFileURL }) {
            pathControl.pathItems = Array(pathControl.pathItems.dropFirst(index))
        }
    }

    private func scopeLabel(_ title: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityElement(false)
        return label
    }

    private static func scopeKindTitle(_ kind: OutlineKind) -> String {
        switch kind {
        case .fn: localized("main.scope.kind.fn")
        case .method: localized("main.scope.kind.method")
        case .struct: localized("main.scope.kind.struct")
        case .class: localized("main.scope.kind.class")
        case .enum: localized("main.scope.kind.enum")
        case .trait: localized("main.scope.kind.trait")
        case .impl: localized("main.scope.kind.impl")
        case .mod: localized("main.scope.kind.mod")
        case .const: localized("main.scope.kind.const")
        case .static: localized("main.scope.kind.static")
        case .typeAlias: localized("main.scope.kind.typeAlias")
        case .field: localized("main.scope.kind.field")
        case .enumMember: localized("main.scope.kind.enumMember")
        }
    }

    private func applyScopeHeaderTheme() {
        scopeHeader.layer?.backgroundColor = readerTheme.chromeColor.cgColor
        scopeHeaderDivider.layer?.backgroundColor =
            readerTheme.chromeDividerColor.cgColor
        renderScopeHeader(at: scopeHeaderByteOffset)
    }

    private func configureFindBar() {
        findBar.wantsLayer = true
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        findField.placeholderString = localized("main.find.in.file")
        findField.sendsSearchStringImmediately = true
        findField.sendsWholeSearchString = false
        findField.delegate = self
        findField.setAccessibilityLabel(localized("main.find.in.file"))

        findCaseButton.title = "Aa"
        findCaseButton.setButtonType(.toggle)
        findCaseButton.bezelStyle = .texturedRounded
        findCaseButton.target = self
        findCaseButton.action = #selector(toggleFindCase(_:))
        findCaseButton.toolTip = localized("main.match.case")
        findCaseButton.setAccessibilityLabel(localized("main.match.case"))

        findWordButton.setButtonType(.toggle)
        findWordButton.bezelStyle = .texturedRounded
        findWordButton.attributedTitle = NSAttributedString(string: "ab", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .regular)),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        findWordButton.target = self
        findWordButton.action = #selector(toggleFindCase(_:))
        findWordButton.toolTip = localized("main.match.word")
        findWordButton.setAccessibilityLabel(localized("main.match.word"))

        findPreviousButton.title = "↑"
        findPreviousButton.bezelStyle = .inline
        findPreviousButton.target = self
        findPreviousButton.action = #selector(findPrevious(_:))
        findPreviousButton.setAccessibilityLabel(localized("main.previous.match"))

        findNextButton.title = "↓"
        findNextButton.bezelStyle = .inline
        findNextButton.target = self
        findNextButton.action = #selector(findNext(_:))
        findNextButton.setAccessibilityLabel(localized("main.next.match"))

        findStatusLabel.font = .systemFont(ofSize: 11)
        findStatusLabel.alignment = .right
        findStatusLabel.setContentCompressionResistancePriority(
            .defaultHigh,
            for: .horizontal
        )
        findStatusLabel.setAccessibilityLabel(localized("main.find.result"))

        findCloseButton.title = "×"
        findCloseButton.bezelStyle = .inline
        findCloseButton.target = self
        findCloseButton.action = #selector(closeFind(_:))
        findCloseButton.setAccessibilityLabel(localized("main.close.find.bar"))

        findField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        findField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [
            findField,
            findCaseButton,
            findWordButton,
            findPreviousButton,
            findNextButton,
            findStatusLabel,
            findCloseButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        findBarDivider.wantsLayer = true
        findBarDivider.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(row)
        findBar.addSubview(findBarDivider)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: 13),
            row.trailingAnchor.constraint(equalTo: findBar.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: findBar.centerYAnchor, constant: -0.5),
            findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
            findField.heightAnchor.constraint(equalToConstant: 22),
            findCaseButton.widthAnchor.constraint(equalToConstant: 34),
            findWordButton.widthAnchor.constraint(equalToConstant: 34),
            findPreviousButton.widthAnchor.constraint(equalToConstant: 24),
            findNextButton.widthAnchor.constraint(equalToConstant: 24),
            findCloseButton.widthAnchor.constraint(equalToConstant: 24),
            findBarDivider.leadingAnchor.constraint(equalTo: findBar.leadingAnchor),
            findBarDivider.trailingAnchor.constraint(equalTo: findBar.trailingAnchor),
            findBarDivider.bottomAnchor.constraint(equalTo: findBar.bottomAnchor),
            findBarDivider.heightAnchor.constraint(equalToConstant: 1),
        ])
        findBar.setAccessibilityElement(false)
        applyFindBarTheme(ReaderSettings())
    }

    @objc private func changeReadingHeight(_ sender: ReadingHeightControl) {
        _ = setReadingHeightLevel(sender.level)
    }

    @objc private func toggleFindCase(_ sender: NSButton) {
        scheduleFind()
    }

    @objc private func findPrevious(_ sender: Any?) {
        navigateFind(by: -1)
    }

    @objc private func findNext(_ sender: Any?) {
        navigateFind(by: 1)
    }

    @objc private func closeFind(_ sender: Any?) {
        closeFindBar()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === findField else { return }
        scheduleFind()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === findField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            navigateFind(by: NSEvent.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeFindBar()
            return true
        default:
            return false
        }
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let file = displayedFile,
              let resolved = resolvedPreviewLink(link, relativeTo: file)
        else { return true }
        onOpenPreviewLink?(resolved)
        return true
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let result = htmlNavigationDecision(
            for: navigationAction.request.url,
            navigationAction.navigationType,
            isMainFrame: navigationAction.targetFrame?.isMainFrame != false
        )
        decisionHandler(result.policy)
        if let callback = result.callback {
            onOpenPreviewLink?(callback)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard (previewView as? WKWebView) === webView else { return }
        previewHTMLFinished = true
        previewHTMLLoadError = nil
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard (previewView as? WKWebView) === webView else { return }
        previewHTMLFinished = false
        previewHTMLLoadError = error.localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard (previewView as? WKWebView) === webView else { return }
        previewHTMLFinished = false
        previewHTMLLoadError = error.localizedDescription
    }

    private func htmlNavigationDecision(
        for url: URL?,
        _ navigationType: WKNavigationType,
        isMainFrame: Bool
    ) -> (policy: WKNavigationActionPolicy, callback: URL?) {
        guard isMainFrame else { return (.cancel, nil) }
        if navigationType == .other,
           htmlInitialNavigationAllowed
        {
            htmlInitialNavigationAllowed = false
            return (.allow, nil)
        }
        guard navigationType == .linkActivated,
              let file = displayedFile,
              let url,
              let resolved = resolvedPreviewLink(url, relativeTo: file)
        else { return (.cancel, nil) }
        let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: true
        )
        let hasFragment = components?.fragment != nil
        let hasQuery = components?.query != nil
        if hasFragment,
           !hasQuery,
           resolved.standardizedFileURL == file.standardizedFileURL
        {
            return (.allow, nil)
        }
        return (.cancel, resolved)
    }

    private func htmlNavigationPolicy(
        for navigationType: WKNavigationType,
        isMainFrame: Bool
    ) -> WKNavigationActionPolicy {
        htmlNavigationDecision(
            for: nil,
            navigationType,
            isMainFrame: isMainFrame
        ).policy
    }

    func selfTestHTMLNavigationPolicy(
        for navigationType: WKNavigationType,
        initialLoad: Bool = false
    ) -> WKNavigationActionPolicy {
        if initialLoad { htmlInitialNavigationAllowed = true }
        return htmlNavigationPolicy(for: navigationType, isMainFrame: true)
    }

    func selfTestHTMLNavigationPolicy(
        for url: URL,
        navigationType: WKNavigationType,
        initialLoad: Bool = false
    ) -> WKNavigationActionPolicy {
        if initialLoad { htmlInitialNavigationAllowed = true }
        let result = htmlNavigationDecision(
            for: url,
            navigationType,
            isMainFrame: true
        )
        if let callback = result.callback {
            onOpenPreviewLink?(callback)
        }
        return result.policy
    }

    var selfTestReaderHTMLFinished: Bool { previewHTMLFinished }
    var selfTestReaderHTMLLoadError: String? { previewHTMLLoadError }

    func selfTestActivatePreviewLink(at index: Int) -> Bool {
        guard index >= 0,
              let previewTextView = (previewView as? NSScrollView)?
                  .documentView as? NSTextView,
              let storage = previewTextView.textStorage
        else { return false }
        var ordinal = 0
        var value: Any?
        storage.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: storage.length)
        ) { attribute, _, stop in
            guard attribute != nil else { return }
            if ordinal == index {
                value = attribute
                stop.pointee = true
            }
            ordinal += 1
        }
        guard let value else { return false }
        return textView(
            previewTextView,
            clickedOnLink: value,
            at: 0
        )
    }

    private func resolvedPreviewLink(_ value: Any, relativeTo file: URL) -> URL? {
        let resolved: URL?
        if let url = value as? URL {
            resolved = URL(string: url.absoluteString, relativeTo: file)?.absoluteURL
        } else if let string = value as? String {
            resolved = URL(string: string, relativeTo: file)?.absoluteURL
        } else {
            resolved = nil
        }
        guard let resolved else { return nil }
        guard resolved.isFileURL,
              resolved.host == nil
                || resolved.host?.isEmpty == true
                || resolved.host?.caseInsensitiveCompare("localhost") == .orderedSame
        else { return nil }
        var components = URLComponents(
            url: resolved,
            resolvingAgainstBaseURL: true
        )
        components?.query = nil
        components?.fragment = nil
        return components?.url?.standardizedFileURL
    }

    private func applyReaderHeaderTheme(_ settings: ReaderSettings) {
        readerTheme = ReaderTheme(settings: settings)
        readerHeader.layer?.backgroundColor = readerTheme.chromeHeaderColor.cgColor
        readerHeaderDivider.layer?.backgroundColor =
            readerTheme.chromeDividerColor.cgColor
        pathRow.layer?.backgroundColor = readerTheme.chromeColor.cgColor
        fileNameLabel.textColor = readerTheme.foregroundColor
        readingHeightShortcutLabel.textColor = readerTheme.chromeTertiaryColor
        readingHeightControl.apply(settings: settings)
        applyScopeHeaderTheme()
        applyFindBarTheme(settings)
    }

    private func applyFindBarTheme(_ settings: ReaderSettings) {
        let theme = ReaderTheme(settings: settings)
        findBar.layer?.backgroundColor = theme.chromeHeaderColor.cgColor
        findBarDivider.layer?.backgroundColor = theme.chromeDividerColor.cgColor
        findStatusLabel.textColor = theme.chromeSecondaryColor
    }

    private func compareContainer(readerView: NSView) -> NSView {
        compareVersionButton.title = localized("main.choose.comparison.version")
        compareVersionButton.bezelStyle = .rounded
        compareVersionButton.target = self
        compareVersionButton.action = #selector(chooseCompareVersion(_:))
        compareVersionButton.setAccessibilityLabel(localized("main.comparison.version"))
        compareVersionButton.lineBreakMode = .byTruncatingMiddle
        compareVersionButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        previousHunkButton.title = "↑"
        previousHunkButton.bezelStyle = .inline
        previousHunkButton.target = self
        previousHunkButton.action = #selector(previousDiffHunk(_:))
        previousHunkButton.setAccessibilityLabel(localized("main.previous.diff.hunk"))
        nextHunkButton.title = "↓"
        nextHunkButton.bezelStyle = .inline
        nextHunkButton.target = self
        nextHunkButton.action = #selector(nextDiffHunk(_:))
        nextHunkButton.setAccessibilityLabel(localized("main.next.diff.hunk"))

        let closeButton = compareCloseButton
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeComparison(_:))
        closeButton.toolTip = localized("main.close.comparison.w")
        closeButton.setAccessibilityLabel(localized("main.close.comparison"))
        let spacer = NSView()
        referenceTitleLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        referenceTitleLabel.lineBreakMode = .byTruncatingHead
        referenceTitleLabel.isHidden = true
        referenceTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [
            compareVersionButton, referenceTitleLabel, spacer, previousHunkButton, nextHunkButton, closeButton,
        ])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 6
        controls.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        functionSummaryStack.orientation = .horizontal
        functionSummaryStack.alignment = .centerY
        functionSummaryStack.spacing = 8
        functionSummaryStack.translatesAutoresizingMaskIntoConstraints = false
        let summaryScroll = NSScrollView()
        summaryScroll.documentView = functionSummaryStack
        summaryScroll.hasHorizontalScroller = true
        summaryScroll.drawsBackground = false
        summaryScroll.borderType = .noBorder
        summaryScroll.translatesAutoresizingMaskIntoConstraints = false

        readerView.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(controls)
        container.addSubview(summaryScroll)
        container.addSubview(readerView)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            controls.heightAnchor.constraint(equalToConstant: 28),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),
            summaryScroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 2),
            summaryScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            summaryScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            {
                let height = summaryScroll.heightAnchor.constraint(equalToConstant: 30)
                summaryHeightConstraint = height
                return height
            }(),
            functionSummaryStack.leadingAnchor.constraint(
                equalTo: summaryScroll.contentView.leadingAnchor
            ),
            functionSummaryStack.topAnchor.constraint(
                equalTo: summaryScroll.contentView.topAnchor
            ),
            functionSummaryStack.bottomAnchor.constraint(
                equalTo: summaryScroll.contentView.bottomAnchor
            ),
            readerView.topAnchor.constraint(equalTo: summaryScroll.bottomAnchor, constant: 2),
            readerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            readerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            readerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    @objc private func chooseCompareVersion(_ sender: Any?) {
        onChooseCompareVersion?()
    }

    @objc private func closeComparison(_ sender: Any?) {
        onCloseComparison?()
    }

    @objc private func previousDiffHunk(_ sender: Any?) {
        onPreviousDiffHunk?()
    }

    @objc private func nextDiffHunk(_ sender: Any?) {
        onNextDiffHunk?()
    }

    @objc private func openFunctionChange(_ sender: NSButton) {
        guard displayedFunctionChanges.indices.contains(sender.tag) else { return }
        onFunctionChange?(displayedFunctionChanges[sender.tag])
    }

    private static func title(_ kind: DiffCore.FunctionChange.Kind) -> String {
        switch kind {
        case .added: localized("main.added")
        case .removed: localized("main.removed")
        case .signatureChanged: localized("main.signature")
        case .bodyChanged: localized("main.body")
        }
    }

    func setHistoricalSnapshot(_ historical: Bool) {
        textView.historicalSnapshot = historical
        snapshotBadge.isHidden = !historical
    }

    func setExcludedByRules(_ excluded: Bool) {
        exclusionBadge.isHidden = !excluded
    }

    /// The 2pt accent edge that marks which reader drives Context and Outline.
    func setFocusIndicator(_ visible: Bool) {
        loadViewIfNeeded()
        focusBar.isHidden = !visible
        focusBar.layer?.backgroundColor = readerTheme.accentColor.cgColor
    }

    /// Switches the right-hand reader between Compare and the split
    /// reference pane, whose header shows the file path and a close button.
    func setReferenceMode(_ enabled: Bool, title: String = "") {
        guard showsCompareControls else { return }
        loadViewIfNeeded()
        isReferenceMode = enabled
        referenceTitleLabel.stringValue = title
        referenceTitleLabel.toolTip = title
        referenceTitleLabel.isHidden = !enabled
        compareVersionButton.isHidden = enabled
        previousHunkButton.isHidden = enabled
        nextHunkButton.isHidden = enabled
        functionSummaryStack.superview?.superview?.isHidden = enabled
        summaryHeightConstraint?.constant = enabled ? 0 : 30
        let closeTitle = enabled ? localized("app.menu.close.split") : localized("main.close.comparison")
        compareCloseButton.toolTip = enabled ? closeTitle : localized("main.close.comparison.w")
        compareCloseButton.setAccessibilityLabel(closeTitle)
    }

    var selfTestSnapshotBadge: (text: String, style: CairnBadgeView.Style, visible: Bool) {
        view.layoutSubtreeIfNeeded()
        return (
            snapshotBadge.text,
            snapshotBadge.style,
            snapshotBadge.window != nil && !snapshotBadge.isHiddenOrHasHiddenAncestor
                && snapshotBadge.frame.width > 0
        )
    }

    var selfTestHistoricalSnapshot: (flag: Bool, background: NSColor?) {
        (textView.historicalSnapshot, textView.view.backgroundColor)
    }

    func apply(settings: ReaderSettings) {
        loadViewIfNeeded()
        let previewWrapChanged = previewWrapLines != settings.wrapLines
        previewWrapLines = settings.wrapLines
        let previousTheme = readerTheme
        readerTheme = ReaderTheme(settings: settings)
        snapshotBadge.update(style: .commit, text: localized("main.snapshot.readonly"), theme: readerTheme)
        exclusionBadge.update(style: .limited, text: localized("main.rules.fileExcluded"), theme: readerTheme)
        if showsCompareControls { renderFunctionSummary() }
        textView.apply(settings: settings)
        showsOverviewRuler = settings.overviewRuler
        updateOverviewRulerVisibility()
        readingSetView.apply(settings: settings)
        emptyStateView?.apply(theme: readerTheme)
        previewArea.layer?.backgroundColor = readerTheme.backgroundColor.cgColor
        if let previewTextView = (previewView as? NSScrollView)?.documentView as? NSTextView {
            previewTextView.backgroundColor = readerTheme.backgroundColor
            previewTextView.linkTextAttributes?[.foregroundColor] = readerTheme.accentColor
            let restyled = previousTheme != readerTheme
                && restylePreviewText(previewTextView)
            if textPreviewKind == .plainText, previewWrapChanged || restyled,
               let previewScrollView = previewView as? NSScrollView {
                configurePlainTextPreview(previewTextView, in: previewScrollView)
            }
        }
        if let pdfView = previewView as? PDFView {
            pdfView.backgroundColor = readerTheme.backgroundColor
        }
        if let webView = previewView as? WKWebView,
           let html = previewHTMLSource,
           let baseURL = previewHTMLBaseURL
        {
            webView.underPageBackgroundColor = readerTheme.backgroundColor
            previewHTMLFinished = false
            previewHTMLLoadError = nil
            htmlInitialNavigationAllowed = true
            webView.loadHTMLString(htmlPreviewMarkup(html), baseURL: baseURL)
        }
        if !showsCompareControls {
            tabStripView.apply(settings: settings)
            applyReaderHeaderTheme(settings)
        }
    }

    func configureTabs(
        _ model: TabStripModel,
        onActivate: @escaping (Int) -> Void,
        onClose: @escaping (Int) -> Void
    ) {
        guard !showsCompareControls else { return }
        loadViewIfNeeded()
        tabStripView.configure(
            model,
            onActivate: onActivate,
            onClose: onClose
        )
        readingSetView.onScroll = { [weak model] offset in
            model?.updateActiveReadingSetScroll(offset)
        }
    }

    func refreshTabs() {
        guard !showsCompareControls else { return }
        loadViewIfNeeded()
        tabStripView.refresh()
        fileNameLabel.stringValue = tabStripView.activeTitle
        fileNameLabel.isHidden = !tabStripView.isHidden
    }

    func showEmptyState(
        recentPaths: [String],
        recentLanguages: [String: String] = [:],
        recentStatus: (trusted: Set<String>, lastRead: [String: Date]) = ([], [:]),
        failed: Bool,
        failureReason: String? = nil,
        onChooseProject: @escaping () -> Void,
        onOpenRecent: @escaping (URL) -> Void,
        onOpenDropped: @escaping (URL) -> Void,
        onRetry: @escaping () -> Void
    ) {
        loadViewIfNeeded()
        pathControl.isHidden = true
        pathRow.isHidden = true
        readingHeightControl.isEnabled = false
        label.isHidden = true
        setCodeViewHidden(true)
        if let emptyStateView {
            emptyStateView.updateRecentLanguages(recentLanguages)
            emptyStateView.updateRecentStatus(trusted: recentStatus.trusted, lastRead: recentStatus.lastRead)
            emptyStateView.update(
                recentPaths: recentPaths,
                failed: failed,
                reason: failureReason
            )
            return
        }
        let emptyStateView = EmptyStateView(
            recentPaths: recentPaths,
            failed: failed,
            onChooseProject: onChooseProject,
            onOpenRecent: onOpenRecent,
            onOpenDropped: onOpenDropped,
            onRetry: onRetry
        )
        emptyStateView.updateRecentLanguages(recentLanguages)
        emptyStateView.updateRecentStatus(trusted: recentStatus.trusted, lastRead: recentStatus.lastRead)
        emptyStateView.update(
            recentPaths: recentPaths,
            failed: failed,
            reason: failureReason
        )
        emptyStateView.apply(theme: readerTheme)
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        readerArea.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.leadingAnchor.constraint(equalTo: readerArea.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: readerArea.trailingAnchor),
            emptyStateView.topAnchor.constraint(equalTo: readerArea.topAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: readerArea.bottomAnchor),
        ])
        self.emptyStateView = emptyStateView
    }

    /// The overview ruler belongs to the code view and hides with it.
    private func setCodeViewHidden(_ hidden: Bool) {
        scrollView?.isHidden = hidden
        updateOverviewRulerVisibility()
    }

    private func updateOverviewRulerVisibility() {
        let hidden = !showsOverviewRuler || scrollView?.isHidden != false
        textView.overviewRuler.isHidden = hidden
        overviewRulerWidth?.constant = hidden ? 0 : ReaderTextView.overviewRulerWidth
    }

    func removeEmptyState(placeholder: String) {
        emptyStateView?.removeFromSuperview()
        emptyStateView = nil
        guard displayedReadingSetKey == nil else { return }
        setCodeViewHidden(false)
        readingHeightControl.isEnabled = displayedDocument != nil
        if displayedFile == nil {
            label.stringValue = placeholder
            label.isHidden = false
        }
    }

    var selfTestEmptyStateExists: Bool { emptyStateView != nil }
    var selfTestEmptyStateTexts: [String] {
        emptyStateView?.selfTestTextValues ?? []
    }
    var selfTestEmptyStateButtonTitles: [String] {
        emptyStateView?.selfTestButtonTitles ?? []
    }
    var selfTestEmptyStateFailureReason: String? {
        emptyStateView?.selfTestFailureReason
    }
    var selfTestEmptyStateReasonIsSelectable: Bool {
        emptyStateView?.selfTestReasonIsSelectable == true
    }
    var selfTestEmptyStateChooseFolderActionAvailable: Bool {
        emptyStateView?.selfTestChooseFolderActionAvailable == true
    }
    var selfTestEmptyStateAttachedToWindow: Bool {
        emptyStateView?.selfTestAttachedToWindow == true
    }
    var selfTestEmptyStateUnhidden: Bool {
        emptyStateView?.selfTestUnhidden == true
    }
    var selfTestEmptyStateFrameVisibleInWindow: Bool {
        emptyStateView?.selfTestFrameVisibleInWindow == true
    }
    var selfTestEmptyStateMarkVisibleInWindow: Bool {
        emptyStateView?.selfTestMarkVisibleInWindow == true
    }
    var selfTestEmptyStateMarkIs48Square: Bool {
        emptyStateView?.selfTestMarkIs48Square == true
    }
    var selfTestEmptyStateMarkUsesCairnDrawing: Bool {
        emptyStateView?.selfTestMarkUsesCairnDrawing == true
    }
    var selfTestEmptyStateNotCoveredByReader: Bool {
        emptyStateView?.superview === readerArea && scrollView?.isHidden == true
    }
    var selfTestEmptyStateTitleVisibleInWindow: Bool {
        emptyStateView?.selfTestTitleVisibleInWindow == true
    }
    var selfTestEmptyStateButtonVisibleInWindow: Bool {
        emptyStateView?.selfTestButtonVisibleInWindow == true
    }
    var selfTestEmptyStateOpenButtonIsVisibleDefaultAction: Bool {
        emptyStateView?.selfTestOpenButtonIsVisibleDefaultAction == true
    }
    var selfTestReaderDocumentVisibleInWindow: Bool {
        guard let scrollView else { return false }
        return !scrollView.isHiddenOrHasHiddenAncestor
            && scrollView.window != nil
            && scrollView.bounds.width > 0
            && scrollView.bounds.height > 0
            && !textView.view.isHiddenOrHasHiddenAncestor
            && textView.view.window != nil
            && textView.view.bounds.width > 0
            && textView.view.bounds.height > 0
            && textView.view.visibleRect.width > 0
            && textView.view.visibleRect.height > 0
    }
    var selfTestPreviewState: (
        kind: String?,
        renderedText: String?,
        linkCount: Int,
        editable: Bool,
        selectable: Bool,
        visible: Bool,
        sourceVisible: Bool,
        previewVisible: Bool,
        accessibilityLabel: String?,
        htmlJavaScriptEnabled: Bool?,
        htmlDataStorePersistent: Bool?,
        htmlContentSecurityPolicy: String?,
        pdfPageCount: Int?,
        imageSize: NSSize?
    ) {
        let previewTextView = (previewView as? NSScrollView)?.documentView as? NSTextView
        return (
            previewKind,
            previewRenderedText,
            previewLinkCount,
            previewTextView?.isEditable ?? false,
            previewTextView?.isSelectable ?? false,
            previewView != nil && !previewArea.isHidden,
            scrollView?.isHidden == false,
            !previewArea.isHidden,
            previewAccessibilityLabel,
            previewHTMLJavaScriptEnabled,
            previewHTMLDataStorePersistent,
            previewHTMLContentSecurityPolicy,
            previewPDFPageCount,
            previewImageSize
        )
    }
    func selfTestPreviewFont(at substring: String) -> NSFont? {
        selfTestPreviewAttribute(.font, at: substring) as? NSFont
    }

    func selfTestPreviewParagraphStyle(at substring: String) -> NSParagraphStyle? {
        selfTestPreviewAttribute(.paragraphStyle, at: substring) as? NSParagraphStyle
    }

    func selfTestPreviewAttribute(_ key: NSAttributedString.Key, at substring: String) -> Any? {
        guard !substring.isEmpty,
              let previewTextView = (previewView as? NSScrollView)?
                  .documentView as? NSTextView,
              let storage = previewTextView.textStorage
        else { return nil }
        let range = (storage.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return storage.attribute(key, at: range.location, effectiveRange: nil)
    }
    var selfTestPlaceholderText: String? {
        label.isHidden ? nil : label.stringValue
    }
    var selfTestPlaceholderVisible: Bool {
        !label.isHiddenOrHasHiddenAncestor
            && label.window != nil
            && label.frame.width > 0
            && label.frame.height > 0
    }
    var selfTestTabGeometry: (
        stripFrame: NSRect,
        headerFrame: NSRect,
        controlFrame: NSRect,
        scopeFrame: NSRect,
        readerFrame: NSRect,
        containerFrame: NSRect,
        stripHidden: Bool,
        scopeHidden: Bool,
        stripHiddenOrHasHiddenAncestor: Bool
    ) {
        (
            tabStripView.convert(tabStripView.bounds, to: nil),
            readerHeader.convert(readerHeader.bounds, to: nil),
            readingHeightControl.superview?.convert(
                readingHeightControl.alignmentRect(
                    forFrame: readingHeightControl.frame
                ),
                to: nil
            ) ?? .zero,
            scopeHeader.convert(scopeHeader.bounds, to: nil),
            readerArea.convert(readerArea.bounds, to: nil),
            readerArea.convert(readerArea.bounds, to: nil),
            tabStripView.isHidden,
            scopeHeader.isHidden,
            tabStripView.isHiddenOrHasHiddenAncestor
        )
    }

    var readingHeightLevel: ReadingHeightLevel { textView.readingHeightLevel }
    var isFindBarVisible: Bool { !findBar.isHidden }
    var canFindInFile: Bool { displayedDocument != nil && !showsCompareControls }

    @discardableResult
    func showFindBar() -> Bool {
        loadViewIfNeeded()
        guard canFindInFile else { return false }
        if findBar.isHidden {
            savedSymbolOccurrenceByteOffset = textView.symbolOccurrenceByteOffset
            findBar.isHidden = false
            scheduleFind(immediate: true)
        }
        view.window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
        return true
    }

    @discardableResult
    func closeFindBar() -> Bool {
        guard !findBar.isHidden else { return false }
        invalidateFind()
        findBar.isHidden = true
        textView.clearFindMatches(
            restoringSymbolAt: savedSymbolOccurrenceByteOffset
        )
        savedSymbolOccurrenceByteOffset = nil
        findWrapped = false
        findStatusLabel.stringValue = ""
        view.window?.makeFirstResponder(textView.view)
        return true
    }

    func findNextMatch() {
        if findBar.isHidden { _ = showFindBar() }
        navigateFind(by: 1)
    }

    func findPreviousMatch() {
        if findBar.isHidden { _ = showFindBar() }
        navigateFind(by: -1)
    }

    private func scheduleFind(immediate: Bool = false) {
        invalidateFind()
        findWrapped = false
        let query = findField.stringValue
        guard !findBar.isHidden,
              let file = displayedFile?.standardizedFileURL,
              let document = displayedDocument
        else { return }
        guard !query.isEmpty else {
            textView.setFindMatches([], selectedIndex: nil)
            renderFindStatus()
            return
        }
        guard !query.contains("\n"), !query.contains("\r") else {
            textView.setFindMatches([], selectedIndex: nil)
            findStatusLabel.stringValue = localized("main.line.breaks.are.not.supported")
            findPreviousButton.isEnabled = false
            findNextButton.isEnabled = false
            return
        }

        let requestID = findRequestID
        let contentID = document.contentID
        let bytes = document.bytes
        let pattern = Array(query.utf8)
        let caseSensitive = findCaseButton.state == .on
        let wholeWord = findWordButton.state == .on
        let wordBoundary = wholeWord
            ? WordBoundary(allowsDollar: document.languageMode.language == .typescript) : nil
        let selectedRange = textView.selectedFindMatchRange
        let scanDelay = findScanDelayForTesting
        findStatusLabel.stringValue = localized("main.searching")
        findPreviousButton.isEnabled = false
        findNextButton.isEnabled = false
        findTask = Task { [weak self] in
            if !immediate {
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }
            }
            guard let self, requestID == self.findRequestID else { return }
            let worker = Task.detached(priority: .userInitiated) {
                if scanDelay != .zero {
                    try await Task.sleep(for: scanDelay)
                }
                return try literalRanges(
                    pattern,
                    in: bytes,
                    caseSensitive: caseSensitive,
                    wordBoundary: wordBoundary
                )
            }
            self.findWorker = worker
            do {
                let ranges = try await worker.value
                guard requestID == self.findRequestID,
                      !self.findBar.isHidden,
                      self.displayedFile?.standardizedFileURL == file,
                      self.displayedDocument?.contentID == contentID,
                      self.findField.stringValue == query,
                      (self.findCaseButton.state == .on) == caseSensitive,
                      (self.findWordButton.state == .on) == wholeWord
                else { return }
                self.findWorker = nil
                let selectedIndex = selectedRange.flatMap { ranges.firstIndex(of: $0) }
                    ?? (ranges.isEmpty ? nil : 0)
                self.textView.setFindMatches(
                    ranges,
                    selectedIndex: selectedIndex
                )
                if let selectedIndex {
                    _ = self.textView.revealFindMatch(at: selectedIndex)
                }
                self.renderFindStatus()
            } catch is CancellationError {
                self.findCancelledWorkerCountForTesting += 1
                return
            } catch {
                guard requestID == self.findRequestID else { return }
                self.findStatusLabel.stringValue = localized("main.search.failed")
            }
        }
    }

    private func invalidateFind() {
        findRequestID &+= 1
        findTask?.cancel()
        findTask = nil
        findWorker?.cancel()
        findWorker = nil
    }

    private func navigateFind(by delta: Int) {
        let count = textView.findMatchCount
        guard count > 0 else { return }
        let previous = textView.selectedFindMatchIndex ?? (delta > 0 ? -1 : 0)
        let unwrapped = previous + delta
        let next = (unwrapped % count + count) % count
        findWrapped = unwrapped < 0 || unwrapped >= count
        _ = textView.revealFindMatch(at: next)
        renderFindStatus()
    }

    private func renderFindStatus() {
        let count = textView.findMatchCount
        findPreviousButton.isEnabled = count > 0
        findNextButton.isEnabled = count > 0
        guard count > 0, let selected = textView.selectedFindMatchIndex else {
            findStatusLabel.stringValue = localized("main.0.matches")
            return
        }
        findStatusLabel.stringValue = "\(selected + 1) / \(count)"
            + (findWrapped ? localized("main.wrapped") : "")
    }
    var isFocusMode: Bool { textView.isFocusMode }
    var canFocusCurrentScope: Bool { displayedDocument != nil }
    /// Byte offset of the Reader's current selection or caret, when a
    /// source document is displayed. Drives surface-scoped relation
    /// commands alongside the context menu.
    var currentSelectionByteOffset: UInt32? {
        guard displayedDocument != nil, displayedFile != nil else { return nil }
        let range = textView.view.selectedRange()
        guard range.location != NSNotFound,
              let byteOffset = textView.byteOffset(
                  forCharacterIndex: range.location
              ),
              let offset = UInt32(exactly: byteOffset)
        else { return nil }
        return offset
    }
    @discardableResult
    func setReadingHeightLevel(_ level: ReadingHeightLevel) -> Bool {
        loadViewIfNeeded()
        let changed = textView.setReadingHeightLevel(level)
        readingHeightControl.set(level: textView.readingHeightLevel)
        return changed
    }
    @discardableResult
    func toggleFocusCurrentScope() -> Bool {
        if textView.isFocusMode { return textView.exitFocusMode() }
        guard let byteOffset = textView.byteOffset(
            forCharacterIndex: textView.view.selectedRange().location
        ), textView.focusCurrentScope(at: byteOffset)
        else {
            onFocusNotice?(localized("main.no.enclosing.scope.to.focus"))
            return false
        }
        return true
    }
    @discardableResult
    func toggleFoldAtSelection() -> Bool {
        guard let document = displayedDocument,
            let byteOffset = textView.byteOffset(
                forCharacterIndex: textView.view.selectedRange().location
            ),
            let line = document.lineTable.lineColumn(at: byteOffset)?.line
        else { return false }
        return textView.toggleFold(atLine: Int(line))
    }
    var canToggleFoldAtSelection: Bool {
        guard let document = displayedDocument,
            let byteOffset = textView.byteOffset(
                forCharacterIndex: textView.view.selectedRange().location
            ),
            let line = document.lineTable.lineColumn(at: byteOffset)?.line
        else { return false }
        return textView.canToggleFold(atLine: Int(line))
    }
    var selfTestReadingHeightHeader:
        (
            fileName: String,
            level: ReadingHeightLevel,
            labels: [String],
            frame: NSRect,
            controlFrame: NSRect,
            shortcut: String,
            accessibilityLabel: String,
            hidden: Bool,
            enabled: Bool
        )
    {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        return (
            fileNameLabel.stringValue,
            readingHeightControl.level,
            (0..<readingHeightControl.segmentCount).compactMap {
                readingHeightControl.label(forSegment: $0)
            },
            readerHeader.convert(readerHeader.bounds, to: nil),
            readingHeightControl.superview?.convert(
                readingHeightControl.alignmentRect(
                    forFrame: readingHeightControl.frame
                ),
                to: nil
            ) ?? .zero,
            readingHeightShortcutLabel.stringValue,
            readingHeightControl.accessibilityLabel() ?? "",
            readingHeightControl.isHidden,
            readingHeightControl.isEnabled
        )
    }
    var selfTestPathBar: (hidden: Bool, frame: NSRect, titles: [String]) {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        return (
            pathRow.isHidden,
            pathRow.convert(pathRow.bounds, to: view),
            pathControl.pathItems.map(\.title)
        )
    }
    var selfTestScopeHeader: (
        hidden: Bool,
        frame: NSRect,
        readerFrame: NSRect,
        labels: [String],
        labelFrames: [NSRect],
        fontNames: [String],
        accessibilityLabel: String
    ) {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        let labels = scopeHeaderContent.arrangedSubviews.compactMap { $0 as? NSControl }
        return (
            scopeHeader.isHidden,
            scopeHeader.convert(scopeHeader.bounds, to: nil),
            readerArea.convert(readerArea.bounds, to: nil),
            labels.map { ($0 as? NSButton)?.title ?? $0.stringValue },
            labels.map { label in
                guard let parent = label.superview else { return .zero }
                return parent.convert(
                    label.alignmentRect(forFrame: label.frame),
                    to: nil
                )
            },
            labels.compactMap { $0.font?.fontName },
            scopeHeader.accessibilityLabel() ?? ""
        )
    }

    func configureCompareControls(
        versionTitle: String,
        functionChanges: [DiffCore.FunctionChange],
        selectedHunkIndex: Int?,
        hunkCount: Int,
        truncated: Bool,
        errorMessage: String?
    ) {
        guard showsCompareControls else { return }
        loadViewIfNeeded()
        compareVersionButton.title = versionTitle
        compareVersionButton.toolTip = versionTitle
        previousHunkButton.isEnabled = hunkCount > 0
        nextHunkButton.isEnabled = hunkCount > 0
        previousHunkButton.toolTip = hunkCount == 0
            ? localized("main.no.diff.hunks")
            : localized("main.previous.hunk")
        nextHunkButton.toolTip = hunkCount == 0
            ? localized("main.no.diff.hunks")
            : localized("main.next.hunk")
        if let selectedHunkIndex {
            nextHunkButton.title = "↓ \(selectedHunkIndex + 1)/\(hunkCount)"
        } else {
            nextHunkButton.title = "↓"
        }
        displayedFunctionChanges = functionChanges
        functionSummaryStatus = errorMessage
            ?? (truncated ? localized("main.large.diff.side.by.side.only") : nil)
        renderFunctionSummary()
    }

    /// Changed functions as theme chips: the kind in its diff color, then the name.
    private func renderFunctionSummary() {
        functionSummaryStack.arrangedSubviews.forEach {
            functionSummaryStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let message = functionSummaryStatus
            ?? (displayedFunctionChanges.isEmpty ? localized("main.no.function.changes") : nil)
        if let message {
            let label = NSTextField(labelWithString: message)
            label.textColor = readerTheme.chromeSecondaryColor
            functionSummaryStack.addArrangedSubview(label)
            return
        }
        for (index, change) in displayedFunctionChanges.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(openFunctionChange(_:)))
            button.isBordered = false
            button.attributedTitle = functionChangeTitle(change)
            button.setAccessibilityLabel("\(Self.title(change.kind)) · \(change.displayName)")
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            button.layer?.backgroundColor = readerTheme.chipBackgroundColor.cgColor
            button.tag = index
            functionSummaryStack.addArrangedSubview(button)
        }
    }

    private func functionChangeTitle(_ change: DiffCore.FunctionChange) -> NSAttributedString {
        let marker: DiffCore.MarkerKind = switch change.kind {
        case .added: .added
        case .removed: .removed
        case .signatureChanged, .bodyChanged: .changed
        }
        let title = NSMutableAttributedString(string: "  \(Self.title(change.kind))", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: readerTheme.color(for: marker),
        ])
        title.append(NSAttributedString(string: "  \(change.displayName)  ", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: readerTheme.foregroundColor,
        ]))
        return title
    }

    var selfTestFunctionChips: [(title: String, kindColor: NSColor?, background: CGColor?)] {
        functionSummaryStack.arrangedSubviews.compactMap { $0 as? NSButton }.map { button in
            let title = button.attributedTitle
            let color = title.length > 2
                ? title.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
                : nil
            return (title.string.trimmingCharacters(in: .whitespaces), color, button.layer?.backgroundColor)
        }
    }

    func setDiffMarkers(_ markers: [Int: DiffCore.MarkerKind]) {
        loadViewIfNeeded()
        if !markers.isEmpty,
           scrollView?.verticalRulerView == nil,
           let scrollView
        {
            textView.installDiffGutter(in: scrollView)
        }
        textView.setDiffMarkers(markers)
    }

    func setBookmarkMarkers(_ markers: [Int: [String]]) {
        loadViewIfNeeded()
        textView.setBookmarkMarkers(markers)
    }

    var selectedSourceText: String? { textView.selectedSourceText }
    func focusText() { view.window?.makeFirstResponder(textView.view) }
    func revealProjectSearchMatch(_ range: ByteRange, expectedContentID: ContentID?) {
        guard let expectedContentID, displayedDocument?.contentID == expectedContentID else { return }
        textView.revealSearchMatch(range: range)
    }
    var displayedContentID: ContentID? { displayedDocument?.contentID }
    func setQueryHits(_ hits: [(range: ByteRange, condition: Int)], contentID: ContentID?) {
        loadViewIfNeeded()
        textView.setQueryHits(hits, contentID: contentID)
    }

    var displayedBytes: [UInt8]? { textView.displayedBytes }
    var bookmarkMarkerLines: [Int] { textView.bookmarkMarkerLines }
    var bookmarkMarkerAccessibilityLabel: String? {
        textView.bookmarkMarkerAccessibilityLabel
    }
    var isEditable: Bool { textView.view.isEditable }
    var diffMarkerCounts: [DiffCore.MarkerKind: Int] { textView.diffMarkerCounts }
    var gutterShowsLineNumbersAndDiff: Bool {
        textView.gutterShowsLineNumbersAndDiff
    }
    var selectedDiffLine: Int? { textView.selectedLineNumber }
    var selfTestOccurrenceCount: Int { textView.occurrenceCount }
    var selfTestFindState: (
        visible: Bool,
        query: String,
        status: String,
        count: Int,
        selectedIndex: Int?,
        previousEnabled: Bool,
        nextEnabled: Bool,
        barFrame: NSRect,
        fieldFrame: NSRect,
        caseFrame: NSRect,
        closeFrame: NSRect
    ) {
        loadViewIfNeeded()
        view.layoutSubtreeIfNeeded()
        return (
            !findBar.isHidden,
            findField.stringValue,
            findStatusLabel.stringValue,
            textView.findMatchCount,
            textView.selectedFindMatchIndex,
            findPreviousButton.isEnabled,
            findNextButton.isEnabled,
            findBar.frame,
            findField.frame,
            findCaseButton.frame,
            findCloseButton.frame
        )
    }
    func selfTestSetFind(
        _ query: String,
        caseSensitive: Bool = false,
        delay: Duration = .zero
    ) {
        findScanDelayForTesting = delay
        findCaseButton.state = caseSensitive ? .on : .off
        findField.stringValue = query
        scheduleFind(immediate: true)
        findScanDelayForTesting = .zero
    }
    func selfTestNavigateFind(by delta: Int) {
        navigateFind(by: delta)
    }
    var selfTestFindWorkerActive: Bool { findWorker != nil }
    var selfTestCurrentLineNumber: Int? { textView.currentLineNumber }
    var selfTestStyledFragmentCount: Int {
        textView.renderingCoordinator.styledFragmentCount
    }
    var selfTestReferenceStyledFragmentCount: Int {
        textView.renderingCoordinator.referenceStyledFragmentCount
    }
    var selfTestReferenceAttributeRunCount: Int {
        textView.renderingCoordinator.referenceAttributeRunCount
    }
    var selfTestReferenceScannedCount: Int {
        textView.renderingCoordinator.referenceScannedCount
    }
    func selfTestFontName(at byteOffset: UInt32) -> String? {
        textView.font(atByteOffset: byteOffset)?.fontName
    }
    func selfTestFontSize(at byteOffset: UInt32) -> CGFloat? {
        textView.font(atByteOffset: byteOffset)?.pointSize
    }
    var selfTestVisibleLineNumbers: [Int] {
        textView.captureVisibleDecorationState()
        return textView.visibleLineNumbers
    }
    var selfTestVisibleCurrentLineNumbers: [Int] {
        textView.captureVisibleDecorationState()
        return textView.visibleCurrentLineNumbers
    }
    var selfTestReaderDrawCount: Int { textView.backgroundDrawCount }
    var selfTestPlainTextDrawCount: Int {
        ((previewView as? NSScrollView)?.documentView as? PlainTextPreviewView)?.backgroundDrawCount ?? 0
    }
    var selfTestReadingSetDrawCount: Int { readingSetView.selfTestDrawCount }
    var selfTestReadingSetSurface: NSView { readingSetView }
    var selfTestReadingSetTextViews: [NSTextView] { readingSetView.selfTestTextViews }
    var selfTestSyntaxLoadPending: Bool { syntaxLoadPending }
    func selfTestWaitForIdentifierPreparation() async {
        await textView.waitForIdentifierPreparation()
    }
    var selfTestIdentifierPreparationState: ReaderIdentifierState {
        textView.identifierPreparationState
    }
    func selfTestActivate(at byteOffset: UInt32) -> Int {
        textView.activate(atByteOffset: byteOffset)
    }
    var selfTestPrimarySelectionRange: NSRange? {
        textView.primarySelectionRange
    }
    var selfTestReaderCaretByteOffset: UInt32? {
        textView.byteOffset(forCharacterIndex: textView.view.selectedRange().location)
    }
    func selfTestEmitOutlineFollow(at byteOffset: UInt32) {
        onOutlineFollowPositionChange?(byteOffset)
    }
    func selfTestPostLiveScroll() {
        guard let scrollView else { return }
        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
    }
    var selfTestReadingGeometry: (
        scrollFrame: NSRect,
        clipFrame: NSRect,
        contentFrame: NSRect,
        rulerFrame: NSRect,
        hasRuler: Bool,
        rulerThickness: CGFloat,
        firstGlyphGap: CGFloat?
    ) {
        loadViewIfNeeded()
        guard let scrollView else {
            return (.zero, .zero, .zero, .zero, false, 0, nil)
        }
        let ruler = scrollView.verticalRulerView
        let rulerFrame = ruler?.convert(ruler?.bounds ?? .zero, to: nil) ?? .zero
        let clipFrame = scrollView.contentView.convert(scrollView.contentView.bounds, to: nil)
        let visible = textView.view.convert(textView.view.visibleRect, to: nil)
            .intersection(clipFrame)
        let textMinX = rulerFrame.intersects(visible)
            ? max(visible.minX, rulerFrame.maxX) : visible.minX
        let contentFrame = NSRect(
            x: textMinX, y: visible.minY,
            width: max(0, visible.maxX - textMinX), height: visible.height
        )
        let firstGlyphGap: CGFloat?
        if let window = textView.view.window, !textView.view.string.isEmpty {
            let glyph = window.convertFromScreen(textView.view.firstRect(
                forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil
            ))
            firstGlyphGap = glyph.isEmpty ? nil : glyph.minX - contentFrame.minX
        } else {
            firstGlyphGap = nil
        }
        return (
            scrollView.convert(scrollView.bounds, to: nil),
            clipFrame,
            contentFrame,
            rulerFrame,
            scrollView.hasVerticalRuler,
            ruler?.ruleThickness ?? 0,
            firstGlyphGap
        )
    }
    var compareVersionAnchor: NSView {
        loadViewIfNeeded()
        return compareVersionButton
    }

    @discardableResult
    func revealDiffLine(_ line: Int) -> Bool {
        textView.revealDiffLine(line)
    }

    func display(
        _ content: TabContent?,
        snapshotID: SnapshotID? = nil,
        source: DocumentLoader.ContentSource? = nil,
        languageMode: LanguageMode? = LanguageMode(language: .rust),
        readingSetAvailability: [(open: Bool, expand: Bool)]? = nil,
        readingSetSkippedReasons: [String] = []
    ) {
        switch content {
        case .file(let file):
            display(
                file,
                snapshotID: snapshotID,
                source: source,
                languageMode: languageMode
            )
        case .readingSet(let title, let excerpts):
            displayReadingSet(
                title: title,
                excerpts: excerpts,
                actionAvailability: readingSetAvailability,
                skippedReasons: readingSetSkippedReasons
            )
        case nil:
            display(
                URL?.none,
                snapshotID: snapshotID,
                source: source,
                languageMode: languageMode
            )
        }
    }

    private func displayReadingSet(
        title: String,
        excerpts: [ReadingSetExcerpt],
        actionAvailability: [(open: Bool, expand: Bool)]?,
        skippedReasons: [String]
    ) {
        loadViewIfNeeded()
        let key = title + excerpts.map {
            "\($0.contentID.bytes)-\($0.byteRange.lowerBound)-\($0.byteRange.upperBound)"
        }.joined(separator: "|") + (actionAvailability?.map {
            "\($0.open)-\($0.expand)"
        }.joined(separator: "|") ?? "") + skippedReasons.joined(separator: "|")
        guard key != displayedReadingSetKey else { return }
        findTask?.cancel()
        findWorker?.cancel()
        readingPositionTask?.cancel()
        loadGeneration &+= 1
        cancelSyntaxLoad()
        displayedFile = nil
        updatePathControl()
        displayedSnapshotID = nil
        displayedLanguageMode = nil
        displayedDocument = nil
        displayedReadingSetKey = key
        contextMenuOffset = nil
        onOutlineChange?([])
        hideScopeHeader()
        findBar.isHidden = true
        label.isHidden = true
        clearPreview()
        textView.clear()
        setCodeViewHidden(true)
        readingSetView.isHidden = false
        readingHeightControl.isHidden = true
        readingHeightControl.isEnabled = false
        readingHeightShortcutLabel.isHidden = true
        fileNameLabel.stringValue = localizedFormat("main.reading.set", title)
        readingSetView.display(
            title: title,
            excerpts: excerpts,
            canOpen: onOpenReadingSetExcerpt != nil,
            canExpand: onExpandReadingSetExcerpt != nil,
            canViewEvidence: onViewReadingSetEvidence != nil,
            openAvailability: actionAvailability?.map(\.open),
            expandAvailability: actionAvailability?.map(\.expand),
            skippedReasons: skippedReasons
        )
    }

    private static let previewContentSecurityPolicy =
        "default-src 'none'; style-src 'unsafe-inline'; img-src data:; "
            + "object-src 'none'; frame-src 'none'; connect-src 'none'; "
            + "media-src 'none'; base-uri 'none'; form-action 'none'"

    private func clearPreview() {
        if let webView = previewView as? WKWebView {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        previewView?.removeFromSuperview()
        previewView = nil
        previewKind = nil
        textPreviewKind = nil
        previewRestyle = nil
        previewUnwrappedX = 0
        previewRenderedText = nil
        previewLinkCount = 0
        previewAccessibilityLabel = nil
        previewHTMLJavaScriptEnabled = nil
        previewHTMLDataStorePersistent = nil
        previewHTMLContentSecurityPolicy = nil
        previewPDFPageCount = nil
        previewImageSize = nil
        previewHTMLSource = nil
        previewHTMLBaseURL = nil
        previewHTMLFinished = false
        previewHTMLLoadError = nil
        htmlInitialNavigationAllowed = false
        previewArea.isHidden = true
    }

    private func installPreview(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        previewArea.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: previewArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: previewArea.trailingAnchor),
            view.topAnchor.constraint(equalTo: previewArea.topAnchor),
            view.bottomAnchor.constraint(equalTo: previewArea.bottomAnchor),
        ])
        previewView = view
        previewArea.layer?.backgroundColor = readerTheme.backgroundColor.cgColor
        previewArea.isHidden = false
        setCodeViewHidden(true)
        label.isHidden = true
        readingSetView.isHidden = true
    }

    private func displayPreview(
        _ file: URL,
        source: DocumentLoader.ContentSource?
    ) {
        findBar.isHidden = true
        invalidateFind()
        savedSymbolOccurrenceByteOffset = nil
        textView.clear()
        readingHeightControl.isHidden = true
        readingHeightControl.isEnabled = false
        readingHeightShortcutLabel.isHidden = true
        cancelSyntaxLoad()
        pendingFocusNavigationOffset = nil
        displayedDocument = nil
        onDocumentChange?(file, nil)
        clearPreview()

        let bytes: [UInt8]
        do {
            if let source {
                bytes = try source(file)
            } else {
                bytes = Array(try Data(contentsOf: file, options: .mappedIfSafe))
            }
        } catch {
            displayPreviewError(localizedFormat("main.open.failure", file.lastPathComponent))
            return
        }

        let extensionName = file.pathExtension.lowercased()
        if extensionName == "pdf" {
            guard let document = PDFDocument(data: Data(bytes)) else {
                displayPreviewError(localized("main.could.not.open.pdf"))
                return
            }
            let pdfView = PDFView()
            pdfView.document = document
            pdfView.autoScales = true
            pdfView.displayMode = .singlePageContinuous
            pdfView.displaysPageBreaks = true
            pdfView.backgroundColor = readerTheme.backgroundColor
            pdfView.setAccessibilityLabel(localized("main.pdf.preview"))
            previewKind = "PDF"
            previewAccessibilityLabel = localized("main.pdf.preview")
            previewPDFPageCount = document.pageCount
            installPreview(pdfView)
            return
        }

        if let image = NSImage(data: Data(bytes)) {
            let imageView = NSImageView()
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
            imageView.setContentCompressionResistancePriority(
                .defaultLow,
                for: .horizontal
            )
            imageView.setContentCompressionResistancePriority(
                .defaultLow,
                for: .vertical
            )
            imageView.setAccessibilityLabel(localized("main.image.preview"))
            previewKind = "Image"
            previewAccessibilityLabel = localized("main.image.preview")
            previewImageSize = image.size
            installPreview(imageView)
            return
        }

        guard let string = String(bytes: bytes, encoding: .utf8) else {
            displayPreviewError(localized("main.unsupported.binary"))
            return
        }
        if extensionName == "md" || extensionName == "markdown" || extensionName == "mdx" {
            let render = { (theme: ReaderTheme) in
                MarkdownPreviewRenderer(theme: theme, baseURL: file).render(string)
            }
            guard let attributed = render(readerTheme) else {
                displayPreviewError(localized("main.unsupported.binary"))
                return
            }
            displayPreviewText(
                attributed,
                kind: .markdown,
                accessibilityLabel: localized("main.markdown.preview")
            )
            previewRestyle = render
            return
        }
        if extensionName == "html" || extensionName == "htm" {
            displayPreviewHTML(string, file: file)
            return
        }
        let firstLine = string.prefix(200).split(separator: "\n", maxSplits: 1).first.map(String.init)
        let format = TextFormat.detect(fileName: file.lastPathComponent, firstLine: firstLine)
        if format == nil, Self.isProsePreview(file) {
            displayPreviewText(
                NSAttributedString(string: string),
                kind: .plainText,
                accessibilityLabel: localized("main.plain.text.preview")
            )
            return
        }
        // Configuration, templates, scripts and unsupported source read as
        // code: the reader's font, line height and syntax palette.
        let render = { (theme: ReaderTheme) -> NSAttributedString? in
            CodeTextPreviewStyler.attributedString(string, format: format, theme: theme)
        }
        displayPreviewText(
            render(readerTheme) ?? NSAttributedString(string: string),
            kind: .plainText,
            kindName: format?.displayName,
            accessibilityLabel: format.map {
                localizedFormat("main.code.text.preview", $0.displayName)
            } ?? localized("main.plain.text.preview")
        )
        previewRestyle = render
    }

    /// Prose documents keep the proportional reading font.
    private static func isProsePreview(_ file: URL) -> Bool {
        let name = file.lastPathComponent
        let extensionName = file.pathExtension.lowercased()
        if ["txt", "text", "rst", "adoc", "asciidoc", "org"].contains(extensionName) { return true }
        return extensionName.isEmpty
            && name.contains(where: \.isLetter)
            && name.allSatisfy { $0.isUppercase || $0 == "_" || $0 == "-" }
    }

    private func displayPreviewText(
        _ attributed: NSAttributedString,
        kind: TextPreviewKind,
        kindName: String? = nil,
        accessibilityLabel: String
    ) {
        let styled = NSMutableAttributedString(attributedString: attributed)
        if styled.length > 0 {
            let fullRange = NSRange(location: 0, length: styled.length)
            styled.enumerateAttribute(.font, in: fullRange) { value, range, _ in
                guard value == nil else { return }
                styled.addAttribute(
                    .font,
                    value: NSFont.systemFont(ofSize: 14),
                    range: range
                )
            }
            styled.enumerateAttribute(.foregroundColor, in: fullRange) {
                value, range, _ in
                guard value == nil else { return }
                styled.addAttribute(
                    .foregroundColor,
                    value: readerTheme.foregroundColor,
                    range: range
                )
            }
        }
        let textView = kind == .plainText ? PlainTextPreviewView() : MarkdownPreviewTextView()
        textView.linkTextAttributes = [
            .foregroundColor: readerTheme.accentColor,
            .cursor: NSCursor.pointingHand,
        ]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = readerTheme.backgroundColor
        if kind == .plainText {
            textView.textContainerInset = NSSize(width: 24, height: 24)
        }
        textView.textStorage?.setAttributedString(styled)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel(accessibilityLabel)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        var linkCount = 0
        if styled.length > 0 {
            styled.enumerateAttribute(
                .link,
                in: NSRange(location: 0, length: styled.length)
            ) { value, _, _ in
                if value != nil { linkCount += 1 }
            }
        }
        textPreviewKind = kind
        previewKind = kindName ?? (kind == .plainText ? "Plain text" : "Markdown")
        previewRenderedText = textView.string
        previewLinkCount = linkCount
        previewAccessibilityLabel = accessibilityLabel
        installPreview(scrollView)
        view.layoutSubtreeIfNeeded()
        if kind == .plainText {
            configurePlainTextPreview(textView, in: scrollView)
            (textView as? PlainTextPreviewView)?.onWidthChange = { [weak self, weak textView, weak scrollView] width in
                guard let self, let textView, let scrollView else { return }
                self.configurePlainTextPreview(textView, in: scrollView, width: width)
            }
        }
    }

    private func restylePreviewText(_ textView: NSTextView) -> Bool {
        guard let restyle = previewRestyle,
              let storage = textView.textStorage,
              let styled = restyle(readerTheme),
              styled.string == storage.string
        else { return false }
        let selection = textView.selectedRanges
        let origin = textView.enclosingScrollView?.contentView.bounds.origin
        storage.setAttributedString(styled)
        textView.setSelectedRanges(selection, affinity: textView.selectionAffinity, stillSelecting: false)
        if let origin, let scrollView = textView.enclosingScrollView {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        return true
    }

    private func configurePlainTextPreview(
        _ textView: NSTextView, in scrollView: NSScrollView, width: CGFloat? = nil
    ) {
        guard let container = textView.textContainer,
              let layout = textView.layoutManager else { return }
        let plainTextView = textView as? PlainTextPreviewView
        plainTextView?.isReflowing = true
        defer { plainTextView?.isReflowing = false }
        let selection = textView.selectedRanges
        let affinity = textView.selectionAffinity
        let oldOrigin = scrollView.contentView.bounds.origin
        let wasUnwrapped = textView.isHorizontallyResizable
        if wasUnwrapped { previewUnwrappedX = oldOrigin.x }

        // Keep a local UTF-16 character at the same vertical viewport offset.
        // This preview uses TextKit 1; source/fold projection state does not apply.
        layout.ensureLayout(for: container)
        let point = NSPoint(
            x: max(0, oldOrigin.x - textView.textContainerOrigin.x),
            y: max(0, oldOrigin.y - textView.textContainerOrigin.y)
        )
        let glyph = layout.glyphIndex(for: point, in: container)
        let character = glyph < layout.numberOfGlyphs
            ? layout.characterIndexForGlyph(at: glyph) : nil
        let anchorY = character.map { _ in
            layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                + textView.textContainerOrigin.y
        }

        scrollView.hasHorizontalScroller = !previewWrapLines
        scrollView.tile()
        var viewport = scrollView.contentSize
        if let width { viewport.width = width }
        textView.isHorizontallyResizable = !previewWrapLines
        textView.autoresizingMask = previewWrapLines ? [.width] : []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        container.widthTracksTextView = previewWrapLines
        textView.setFrameSize(NSSize(width: viewport.width, height: textView.frame.height))
        container.containerSize = NSSize(
            width: previewWrapLines
                ? max(1, viewport.width - 2 * textView.textContainerInset.width)
                : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        )
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        textView.setFrameSize(NSSize(
            width: previewWrapLines ? viewport.width
                : max(viewport.width, ceil(used.maxX) + 2 * textView.textContainerInset.width),
            height: max(viewport.height, ceil(used.maxY) + 2 * textView.textContainerInset.height)
        ))
        textView.setSelectedRanges(selection, affinity: affinity, stillSelecting: false)
        var y = oldOrigin.y
        if let character, let anchorY {
            let newGlyph = layout.glyphIndexForCharacter(at: character)
            y += layout.lineFragmentRect(forGlyphAt: newGlyph, effectiveRange: nil).minY
                + textView.textContainerOrigin.y - anchorY
        }
        let restored = NSPoint(
            x: previewWrapLines ? 0 : min(previewUnwrappedX, max(0, textView.frame.width - viewport.width)),
            y: min(max(0, y), max(0, textView.frame.height - viewport.height))
        )
        scrollView.contentView.scroll(to: restored)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func displayPreviewHTML(_ html: String, file: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = readerTheme.backgroundColor
        webView.setAccessibilityLabel(localized("main.html.preview"))
        previewKind = "HTML"
        previewAccessibilityLabel = localized("main.html.preview")
        previewHTMLJavaScriptEnabled = configuration
            .defaultWebpagePreferences.allowsContentJavaScript
        previewHTMLDataStorePersistent = false
        previewHTMLContentSecurityPolicy = Self.previewContentSecurityPolicy
        previewHTMLSource = html
        previewHTMLBaseURL = file
        previewHTMLFinished = false
        previewHTMLLoadError = nil
        installPreview(webView)
        htmlInitialNavigationAllowed = true
        webView.loadHTMLString(
            htmlPreviewMarkup(html),
            baseURL: file
        )
    }

    private func htmlPreviewMarkup(_ html: String) -> String {
        let style = "<style>body { color: \(cssColor(readerTheme.foregroundColor)); "
            + "background-color: \(cssColor(readerTheme.backgroundColor)); "
            + "font-family: -apple-system, BlinkMacSystemFont, sans-serif; }</style>"
        let meta = "<meta http-equiv=\"Content-Security-Policy\" content=\""
            + Self.previewContentSecurityPolicy + "\">"
        guard let headStart = html.range(
            of: "<head",
            options: [.caseInsensitive]
        ), let headEnd = html[headStart.upperBound...].firstIndex(of: ">") else {
            return "<head>\(meta)\(style)</head>\(html)"
        }
        let insertion = html.index(after: headEnd)
        return String(html[..<insertion]) + meta + style + String(html[insertion...])
    }

    private func cssColor(_ color: NSColor) -> String {
        let resolved = color.usingColorSpace(.deviceRGB) ?? .black
        return String(
            format: "#%02x%02x%02x",
            Int(resolved.redComponent * 255),
            Int(resolved.greenComponent * 255),
            Int(resolved.blueComponent * 255)
        )
    }

    private func displayPreviewError(_ message: String) {
        let errorLabel = NSTextField(labelWithString: message)
        errorLabel.alignment = .center
        errorLabel.textColor = readerTheme.chromeSecondaryColor
        errorLabel.setAccessibilityLabel(localizedFormat("main.preview.failure", message))
        previewKind = "Error"
        previewRenderedText = message
        previewAccessibilityLabel = localizedFormat("main.preview.failure", message)
        installPreview(errorLabel)
    }

    var currentReadingSetScrollOffset: Double? {
        displayedReadingSetKey == nil ? nil : readingSetView.scrollOffset
    }

    func setReadingSetScrollOffsetForSelfTest(_ offset: Double) {
        readingSetView.restoreScrollOffset(offset)
    }

    var selfTestReadingSetState: (
        visible: Bool,
        title: String,
        subtitle: String,
        emptyVisible: Bool,
        cardCount: Int,
        cardFrames: [NSRect],
        cardAccessibility: [(String, String)],
        code: [(String, Bool, Bool)],
        codeGeometry: [(String, Bool, Bool)],
        actions: [[(String, Bool, Bool)]]
    ) {
        (
            !readingSetView.isHidden,
            readingSetView.selfTestTitle,
            readingSetView.selfTestSubtitle,
            readingSetView.selfTestEmptyVisible,
            readingSetView.selfTestCardCount,
            readingSetView.selfTestCardFrames,
            readingSetView.selfTestCardAccessibility,
            readingSetView.selfTestCodeState,
            readingSetView.selfTestCodeGeometry,
            readingSetView.selfTestActionState
        )
    }

    func restoreReadingSetScrollOffset(_ offset: Double?) {
        guard displayedReadingSetKey != nil else { return }
        readingSetView.restoreScrollOffset(offset)
    }

    func display(
        _ file: URL?,
        snapshotID: SnapshotID? = nil,
        source: DocumentLoader.ContentSource? = nil,
        languageMode: LanguageMode? = LanguageMode(language: .rust)
    ) {
        guard !isClosing else { return }
        loadViewIfNeeded()
        guard file != displayedFile
                || snapshotID != displayedSnapshotID
                || languageMode != displayedLanguageMode
        else { return }
        // A new snapshot with the same bytes (index refresh, a version that
        // did not touch this file) keeps the reader as it is: redisplaying
        // resets the caret and the laid-out geometry, so the viewport could
        // only come back line-aligned over estimated positions.
        if let file, file == displayedFile, languageMode == displayedLanguageMode,
           let contentID = displayedDocument?.contentID,
           let bytes = try? source.map({ try $0(file) })
               ?? Array(Data(contentsOf: file, options: .mappedIfSafe)),
           ContentID.sha256(of: bytes) == contentID
        {
            displayedSnapshotID = snapshotID
            return
        }
        displayedReadingSetKey = nil
        readingSetView.isHidden = true
        setCodeViewHidden(false)
        readingHeightControl.isHidden = false
        readingHeightControl.isEnabled = false
        readingHeightShortcutLabel.isHidden = true
        let rerunFind = !findBar.isHidden
        if rerunFind {
            invalidateFind()
            savedSymbolOccurrenceByteOffset = nil
            textView.setFindMatches([], selectedIndex: nil)
        }
        displayedFile = file
        updatePathControl()
        if !showsCompareControls {
            fileNameLabel.stringValue = file?.lastPathComponent ?? ""
        }
        displayedSnapshotID = snapshotID
        displayedLanguageMode = languageMode
        contextMenuOffset = nil
        readingPositionTask?.cancel()
        readingPositionTask = nil
        cancelSyntaxLoad()
        pendingFocusNavigationOffset = nil
        loadGeneration &+= 1
        let generation = loadGeneration
        onOutlineChange?([])
        scopeHeaderByteOffset = nil
        hideScopeHeader()

        guard let file else {
            findBar.isHidden = true
            findStatusLabel.stringValue = ""
            displayedDocument = nil
            clearPreview()
            label.stringValue = localized("main.select.a.file.to.read.p.to.open")
            label.isHidden = false
            textView.clear()
            hideScopeHeader()
            // No file displayed: the source-only reading height controls
            // leave with it (§3.1 no-project surface).
            readingHeightControl.isHidden = true
            readingHeightShortcutLabel.isHidden = true
            return
        }

        guard let languageMode else {
            displayPreview(file, source: source)
            return
        }

        clearPreview()
        do {
            let activeLoader = source.map { DocumentLoader(source: $0) } ?? loader
            let loaded = try activeLoader.load(
                file: file,
                languageMode: languageMode
            )
            displayedDocument = loaded.document
            readingHeightControl.isEnabled = true
            onDocumentChange?(file, loaded.document)
            label.isHidden = true
            // NSTextView already tracks its clip. Forcing the frame to the clip
            // left a same-content redisplay one screen tall whenever TextKit saw
            // no content-size change, so the next restore clamped to the top.
            view.layoutSubtreeIfNeeded()
            textView.display(document: loaded.document, fileURL: file)
            renderScopeHeader(at: textView.byteOffset(
                forCharacterIndex: textView.view.selectedRange().location
            ))
            if rerunFind { scheduleFind(immediate: true) }
            onOutlineChange?(loaded.document.outlineFacets)
            textView.view.textLayoutManager?
                .textViewportLayoutController.layoutViewport()
            if loaded.tier != .regular {
                syntaxLoadPending = true
                syntaxTask = activeLoader.loadSyntax(for: loaded.document) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.loadGeneration == generation,
                              self.displayedLanguageMode == languageMode
                        else { return }
                        self.syntaxLoadPending = false
                        switch result {
                        case let .success(document):
                            self.displayedDocument = document
                            self.onDocumentChange?(file, document)
                            let wasFocused = self.textView.isFocusMode
                            let focusOffset = self.pendingFocusNavigationOffset
                            self.pendingFocusNavigationOffset = nil
                            self.textView.updateSyntax(
                                document: document,
                                focusByteOffset: focusOffset
                            )
                            self.renderScopeHeader(at: self.textView.byteOffset(
                                forCharacterIndex:
                                    self.textView.view.selectedRange().location
                            ))
                            if wasFocused,
                               let focusOffset,
                               self.textView.isFocusMode
                            {
                                _ = self.textView.followFocusForExplicitNavigation(
                                    to: focusOffset
                                )
                            }
                            if wasFocused && !self.textView.isFocusMode {
                                self.onFocusNotice?(localized("main.focus.ended.no.enclosing.scope"))
                            }
                            self.onOutlineChange?(document.outlineFacets)
                        case .failure:
                            self.pendingFocusNavigationOffset = nil
                            if self.textView.isFocusMode {
                                _ = self.textView.exitFocusMode()
                                self.onFocusNotice?(localized("main.focus.ended.syntax.unavailable"))
                            }
                            self.label.stringValue = localized("main.syntax.highlighting.failed")
                            self.label.isHidden = false
                            self.hideScopeHeader()
                        }
                    }
                }
            }
        } catch {
            if rerunFind {
                textView.setFindMatches([], selectedIndex: nil)
                renderFindStatus()
            }
            displayedDocument = nil
            onDocumentChange?(file, nil)
            label.stringValue = localizedFormat("main.open.failure", file.lastPathComponent)
            label.isHidden = false
            textView.clear()
            hideScopeHeader()
        }
    }

    func navigate(
        to file: URL,
        byteOffset: UInt32,
        snapshotID: SnapshotID? = nil,
        source: DocumentLoader.ContentSource? = nil,
        languageMode: LanguageMode? = LanguageMode(language: .rust)
    ) {
        display(
            file,
            snapshotID: snapshotID,
            source: source,
            languageMode: languageMode
        )
        if textView.isFocusMode {
            if syntaxLoadPending {
                pendingFocusNavigationOffset = byteOffset
            } else if !textView.followFocusForExplicitNavigation(to: byteOffset) {
                onFocusNotice?(localized("main.focus.ended.no.enclosing.scope"))
            }
        }
        textView.reveal(byteOffset: byteOffset)
        _ = textView.activate(atByteOffset: byteOffset)
        onSelectionChange?(byteOffset)
        onReadingPositionChange?(byteOffset)
    }

    func restoreReadingPosition(
        scrollByteOffset: UInt32?,
        selectionByteOffset: UInt32?
    ) {
        let generation = loadGeneration
        let languageMode = displayedLanguageMode
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  loadGeneration == generation,
                  displayedLanguageMode == languageMode
            else { return }
            // Already at that line (an index refresh that kept the document):
            // keep the exact offset instead of re-aligning the line to the top.
            let line = { (offset: UInt32?) in
                offset.flatMap { self.displayedDocument?.lineTable.lineColumn(at: $0)?.line }
            }
            let keepsViewport = scrollByteOffset != nil
                && line(scrollByteOffset) == line(textView.firstVisibleByteOffset())
            textView.restore(
                scrollByteOffset: keepsViewport ? nil : scrollByteOffset,
                selectionByteOffset: selectionByteOffset
            )
        }
    }

    func currentReadingPosition(fallbackByteOffset: UInt32? = nil) -> (
        file: URL,
        contentID: ContentID,
        byteOffset: UInt32,
        line: UInt32,
        column: UInt32,
        symbolAnchor: String?
    )? {
        guard displayedFile != nil,
              let document = displayedDocument
        else { return nil }
        let byteOffset = min(
            textView.firstVisibleByteOffset() ?? fallbackByteOffset ?? 0,
            UInt32(clamping: document.bytes.count)
        )
        return readingPosition(at: byteOffset)
    }

    func readingPosition(at byteOffset: UInt32?) -> (
        file: URL,
        contentID: ContentID,
        byteOffset: UInt32,
        line: UInt32,
        column: UInt32,
        symbolAnchor: String?
    )? {
        guard let byteOffset,
              let file = displayedFile,
              let document = displayedDocument,
              document.byteUTF16Map.utf16Offset(forByte: Int(byteOffset)) != nil
        else { return nil }
        guard let coordinate = document.lineTable.lineColumn(at: byteOffset) else {
            return nil
        }
        return (
            file: file,
            contentID: document.contentID,
            byteOffset: byteOffset,
            line: coordinate.line,
            column: coordinate.column,
            symbolAnchor: document.symbolAnchor(at: byteOffset)
        )
    }

    private func scheduleReadingPositionChange() {
        guard readingPositionTask == nil else { return }
        readingPositionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            readingPositionTask = nil
            guard let offset = currentReadingPosition()?.byteOffset else { return }
            onReadingPositionChange?(offset)
            if let anchor = textView.followAnchorByteOffset() {
                onOutlineFollowPositionChange?(anchor)
            }
        }
    }

    @objc private func showCallers(_ sender: Any?) {
        showRelation(.callers)
    }

    @objc private func showCalls(_ sender: Any?) {
        showRelation(.calls)
    }

    @objc private func showImplementations(_ sender: Any?) {
        showRelation(.implementations)
    }

    @objc private func showReferences(_ sender: Any?) {
        showRelation(.references)
    }

    @objc private func copyPathLine(_ sender: Any?) {
        guard let location = contextMenuLocation() else { return }
        onCopyPathLine?(location.file, location.line)
    }

    @objc private func revealInFinder(_ sender: Any?) {
        guard let location = contextMenuLocation(),
              FileManager.default.fileExists(atPath: location.file.path)
        else { return }
        onRevealInFinder?(location.file)
    }

    private func highlightSwatch(slot: UInt8) -> NSImage {
        let fill = readerTheme.highlightColor(slot: slot)
        let stroke = readerTheme.chromeDividerColor
        return NSImage(size: NSSize(width: 14, height: 12), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            fill.setFill()
            path.fill()
            stroke.setStroke()
            path.stroke()
            return true
        }
    }

    private func contextMenuLocation() -> (file: URL, line: UInt32)? {
        guard let contextMenuOffset,
              let file = displayedFile,
              let document = displayedDocument,
              let line = document.lineTable.lineColumn(
                  at: contextMenuOffset
              )?.line
        else { return nil }
        return (file, line)
    }

    private func showRelation(_ direction: RelationTreeModel.Direction) {
        guard let contextMenuOffset else { return }
        onShowRelation?(contextMenuOffset, direction)
    }

}
