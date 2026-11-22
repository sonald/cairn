import AppKit
import CodeInsightAI
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightReaderCore
import CodeInsightReaderUI
import Observation
import WebKit

/// The guide panel: the saved guide of the file in front, or a button that
/// writes one. While it is written, one line shows what the model reads.
@MainActor
final class GuidePanelController: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {
    let guides: AIGuideModel
    private let appModel: AppModel
    /// Project-relative path of a file URL, nil outside the project.
    var projectPath: ((URL) -> String?)?
    /// Opens a project file at byte `start` and marks up to `end`; `playing`
    /// is a step of ▶, which should not pile up history or take focus.
    var onOpen: ((URL, _ start: UInt32?, _ end: UInt32?, _ playing: Bool) -> Void)?
    var onAsk: ((String) -> Void)?
    var onShowSettings: (() -> Void)?

    private var theme = ReaderTheme(settings: ReaderSettings())
    private let header = NSStackView()
    private let fileLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let actionButton = NSButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let settingsButton = NSButton()
    private var webView: WKWebView!
    private var shownFile: (url: URL?, snapshot: SnapshotID?)?
    private var renderedKey: String?
    private var updateScheduled = false

    init(guides: AIGuideModel, appModel: AppModel) {
        self.guides = guides
        self.appModel = appModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = VisibilityView()
        root.wantsLayer = true
        root.onShown = { [weak self] in self?.update() }
        // Auto themes change with the system; the page's colors are fixed when built.
        root.onAppearanceChange = { [weak self] in
            self?.renderedKey = nil
            self?.update()
        }

        fileLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        actionButton.bezelStyle = .recessed
        actionButton.controlSize = .small
        actionButton.font = .systemFont(ofSize: 11)
        actionButton.target = self
        actionButton.action = #selector(act(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        header.setViews([fileLabel, spacer, spinner, actionButton], in: .leading)
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        header.wantsLayer = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 6
        statusLabel.cell?.truncatesLastVisibleLine = true
        settingsButton.title = localized("ai.openSettings")
        settingsButton.bezelStyle = .rounded
        settingsButton.controlSize = .small
        settingsButton.target = self
        settingsButton.action = #selector(showSettings(_:))
        let statusRow = NSStackView(views: [statusLabel, settingsButton])
        statusRow.orientation = .vertical
        statusRow.alignment = .leading
        statusRow.spacing = 6
        statusRow.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        // A wrapping label in a stack view stays one line unless its width is bound.
        statusLabel.widthAnchor.constraint(equalTo: statusRow.widthAnchor, constant: -24).isActive = true

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(WeakHandler(self), name: "cairn")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel(localized("panel.guide"))

        let column = NSStackView(views: [header, statusRow, webView])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        for view in [header, statusRow, webView] as [NSView] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        webView.setContentHuggingPriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        applyTheme()
        observe()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        update()
    }

    @objc private func windowBecameKey(_ note: Notification) {
        guard (note.object as? NSWindow) === view.window else { return }
        update()
    }

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        guard isViewLoaded else { return }
        applyTheme()
        renderedKey = nil
        update()
    }

    private func applyTheme() {
        view.appearance = cairnAppearance(for: theme.variant)
        view.layer?.backgroundColor = theme.backgroundColor.cgColor
        header.layer?.backgroundColor = theme.chromeColor.cgColor
        fileLabel.textColor = theme.chromeSecondaryColor
        statusLabel.textColor = theme.chromeSecondaryColor
    }

    // MARK: Model

    private func observe() {
        withObservationTracking {
            _ = guides.path
            _ = guides.guide
            _ = guides.isStale
            _ = guides.state
            _ = guides.steps
            _ = guides.runningStep
            _ = guides.runningPath
            _ = appModel.selectedFile
            _ = appModel.currentSnapshotID
            _ = appModel.fileTree
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleUpdate()
                self?.observe()
            }
        }
    }

    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.updateScheduled = false
            self?.update()
        }
    }

    /// A hidden panel does no work; showing it catches up with the file in front.
    private var isShowing: Bool { view.window != nil && !view.isHiddenOrHasHiddenAncestor }

    private func update() {
        guard isViewLoaded, isShowing else { return }
        followSelectedFile()
        let path = guides.path
        fileLabel.stringValue = path.map { ($0 as NSString).lastPathComponent } ?? ""
        fileLabel.toolTip = path

        let blocker = guides.blocker(project: appModel.projectRoot)
        let runningHere = guides.isRunningHere
        let runningElsewhere = guides.runningPath != nil && !runningHere
        var status: String?
        var showsSettings = false
        switch blocker {
        case .noProject: status = localized("ai.empty.noProject")
        case .needsSettings, .needsKey:
            status = localized("ai.empty.needsSettings")
            showsSettings = true
        case .helperMissing: status = localized("ai.helper.missing")
        case .needsConsent(let host):
            status = localizedFormat("guide.consent.message", host)
        case nil: break
        }
        if path == nil { status = localized("guide.noFile") }
        if blocker == nil || runningHere {
            if runningHere {
                status = guides.runningStep.map { AITurnView.describe($0, running: true) }
                    ?? guides.steps.last.map { AITurnView.describe($0) }
                    ?? localized("ai.status.thinking")
            } else if runningElsewhere, let other = guides.runningPath {
                status = localizedFormat("guide.otherFile", (other as NSString).lastPathComponent)
            } else if guides.statePath == path, case .failed(let message) = guides.state {
                let reason = switch message {
                case "roundLimit": localizedFormat("ai.error.roundLimit", AIGuide.maxRounds)
                case "contextLimit": localized("ai.error.contextLimit")
                case "noDraft": localized("guide.error.noDraft")
                case "helperMissing": localized("ai.helper.missing")
                case "chatgptSignIn", "chatgptPlanNotShared": AISettingsView.describe(message)
                case let usage where usage.contains("subscription_sharing_usage_limit_exceeded"): localized("ai.error.chatgptUsageLimit")
                case AIHelper.exitedMessage: localized("ai.error.helperExited")
                default: message
                }
                status = localized("ai.status.failed") + " " + reason
            } else if guides.statePath == path, guides.state == .cancelled {
                status = localized("ai.status.stopped")
            } else if let guide = guides.guide {
                status = guides.isStale ? localized("guide.stale") : localizedFormat(
                    "guide.written", guide.model,
                    guide.createdAt.formatted(date: .abbreviated, time: .shortened))
            } else if path != nil {
                status = localized("guide.empty")
            }
        }
        statusLabel.stringValue = status ?? ""
        statusLabel.superview?.isHidden = status == nil
        settingsButton.isHidden = !showsSettings

        if runningHere { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let title: String
        if runningHere { title = localized("guide.stop") }
        else if case .needsConsent = blocker { title = localized("guide.allow") }
        else { title = localized(guides.guide == nil ? "guide.generate" : "guide.regenerate") }
        actionButton.title = title
        actionButton.setAccessibilityLabel(title)
        actionButton.isEnabled = path != nil && !runningElsewhere
            && (runningHere || blocker == nil || { if case .needsConsent = blocker { true } else { false } }())
        render()
    }

    /// Shows the guide of the file in front, from the snapshot it is read in.
    private func followSelectedFile() {
        let url = appModel.selectedFile?.standardizedFileURL
        let snapshotID = appModel.currentSnapshotID
        guard shownFile?.url != url || shownFile?.snapshot != snapshotID else { return }
        guard let url, let path = projectPath?(url), let snapshot = AISnapshot(model: appModel) else {
            shownFile = nil
            if guides.path != nil { guides.showNothing() }
            return
        }
        shownFile = (url, snapshotID)
        guides.show(path: path, in: snapshot)
    }

    /// Rebuilds the page only when the guide or the theme changed.
    private func render() {
        let guide = guides.guide
        let key = guide.map { "\($0.path)|\($0.createdAt.timeIntervalSince1970)" } ?? ""
        guard key != renderedKey else { return }
        renderedKey = key
        guard let guide, let snapshot = guides.snapshot else {
            webView.loadHTMLString("", baseURL: nil)
            return
        }
        let file = try? GuideFile(path: guide.path, in: snapshot)
        let draft = file.map { GuideDraft.check(guide.draft, in: $0).draft }
        var html = ""
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            html = draft.map {
                GuideHTML.page($0, resolve: { text in
                    if case .target(let target) = file?.resolve(text) { target } else { nil }
                }, theme: theme)
            } ?? ""
        }
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: Actions

    @objc private func act(_ sender: Any?) {
        if guides.isRunningHere { return guides.cancel() }
        if case .needsConsent = guides.blocker(project: appModel.projectRoot),
           let root = guides.snapshot?.root ?? appModel.projectRoot {
            guides.allowSending(project: root)
        }
        guard guides.blocker(project: appModel.projectRoot) == nil else { return update() }
        let zh = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        guides.generate(language: zh ? "Simplified Chinese" : "English")
        update()
    }

    @objc private func showSettings(_ sender: Any?) { onShowSettings?() }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        let question = body?["ask"] as? String
        let path = body?["path"] as? String
        let start = (body?["start"] as? NSNumber)?.intValue
        let end = (body?["end"] as? NSNumber)?.intValue
        let playing = body?["play"] as? Bool ?? false
        MainActor.assumeIsolated {
            if let question {
                onAsk?(question)
                return
            }
            // The page is the model's text: only snapshot files open.
            guard let path, let start, let end, let snapshot = guides.snapshot,
                  let path = snapshot.resolve(cited: path)
            else { return }
            let current = snapshot.id == appModel.currentSnapshotID
            // Following the guide's own links keeps the guide in front.
            shownFile = (snapshot.url(of: path).standardizedFileURL, appModel.currentSnapshotID)
            onOpen?(snapshot.url(of: path),
                    current ? snapshot.byteOffset(of: path, line: start) : nil,
                    current ? snapshot.byteOffset(of: path, line: end + 1) : nil, playing)
        }
    }

    /// The page is a string we wrote; nothing navigates away from it.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }
}

/// WebKit keeps its message handler strongly.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

private final class VisibilityView: NSView {
    var onShown: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onShown?() }
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        onShown?()
    }
}
