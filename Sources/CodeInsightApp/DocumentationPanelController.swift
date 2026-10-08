import AppKit
import CodeInsightAppModel
import CodeInsightReaderCore
import CodeInsightReaderUI
import Observation
import WebKit

/// The Documentation panel: a locked-down web view showing the page a
/// documentation source returned, or a line of text when there is none.
/// Page scripts are off, nothing is stored, and a content rule list only lets
/// loopback requests through.
@MainActor
final class DocumentationPanelController: NSViewController, WKNavigationDelegate {
    let model: DocumentationPanelModel
    private let header = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let candidatesButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let openInDashButton = NSButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var webView: WKWebView?
    private var theme = ReaderTheme(settings: ReaderSettings())
    /// The candidate the web view was last asked to load.
    private var loadedCandidate: DocumentationCandidate?
    /// Text shown instead of the page after it failed to load.
    private var loadProblem: String?
    private var shownCandidates: [DocumentationCandidate] = []

    /// Bump the version whenever the rules change: the store keeps the
    /// compiled list across launches.
    private static let ruleListIdentifier = "cairn-docs-dash-v1"
    private static let contentRules = """
    [
      {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "^http://127\\\\.0\\\\.0\\\\.1[:/]"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": ".*", "resource-type": ["script"]}, "action": {"type": "block"}},
      {"trigger": {"url-filter": ".*"}, "action": {"type": "css-display-none",
         "selector": "div.related, div.sphinxsidebar, div.footer, div.mobile-nav, nav.sidebar, .sidebar-resizer, rustdoc-search, .sub, #top-link, .theme-selection"}}
    ]
    """
    /// Compiled once per run; nothing loads before it is ready.
    private static let ruleList = Task<WKContentRuleList?, Never> { @MainActor in
        guard let store = WKContentRuleListStore.default() else { return nil }
        if let list = try? await store.contentRuleList(forIdentifier: ruleListIdentifier) { return list }
        return try? await store.compileContentRuleList(
            forIdentifier: ruleListIdentifier, encodedContentRuleList: contentRules)
    }

    init(model: DocumentationPanelModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        candidatesButton.controlSize = .small
        candidatesButton.font = .systemFont(ofSize: 11)
        candidatesButton.target = self
        candidatesButton.action = #selector(chooseCandidate(_:))
        candidatesButton.toolTip = localized("docs.results")
        candidatesButton.setAccessibilityLabel(localized("docs.results"))
        candidatesButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openInDashButton.isBordered = false
        openInDashButton.controlSize = .small
        openInDashButton.target = self
        openInDashButton.action = #selector(openInDash(_:))
        openInDashButton.setContentHuggingPriority(.required, for: .horizontal)

        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        titles.setHuggingPriority(.defaultLow, for: .horizontal)
        let topRow = NSStackView(views: [titles, openInDashButton])
        topRow.orientation = .horizontal
        topRow.spacing = 6
        header.setViews([topRow, candidatesButton], in: .leading)
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        header.wantsLayer = true
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 12)
        for view in [header, statusLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        topRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topRow.widthAnchor.constraint(equalTo: header.widthAnchor, constant: -18),
            candidatesButton.widthAnchor.constraint(lessThanOrEqualTo: header.widthAnchor, constant: -18),
            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            statusLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        view = root
        observeModel()
        render()
    }

    func apply(settings: ReaderSettings) {
        theme = ReaderTheme(settings: settings)
        view.appearance = cairnAppearance(for: settings.theme)
        view.layer?.backgroundColor = theme.backgroundColor.cgColor
        header.layer?.backgroundColor = theme.chromeColor.cgColor
        titleLabel.textColor = theme.foregroundColor
        subtitleLabel.textColor = theme.chromeSecondaryColor
        statusLabel.textColor = theme.chromeSecondaryColor
        openInDashButton.attributedTitle = NSAttributedString(
            string: "↗ " + localized("docs.open.in.dash"),
            attributes: [.foregroundColor: theme.accentColor, .font: NSFont.systemFont(ofSize: 11)]
        )
    }

    // MARK: - Rendering

    private func observeModel() {
        withObservationTracking {
            _ = model.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.render()
                self?.observeModel()
            }
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        var status: String?
        var candidate: DocumentationCandidate?
        var candidates: [DocumentationCandidate] = []
        switch model.state {
        case .idle:
            status = DashIntegration.isInstalled ? localized("docs.empty") : localized("docs.notInstalled")
        case let .unavailable(notice):
            status = text(for: notice)
        case let .searching(query):
            loadedCandidate = nil
            status = localizedFormat("docs.searching", query)
        case let .candidates(all):
            candidates = all
            status = localizedFormat("docs.choose", model.query)
        case let .showing(shown, all):
            candidate = shown
            candidates = all
        }
        if let candidate, candidate != loadedCandidate { load(candidate) }
        if candidate != nil, let loadProblem { status = loadProblem }
        header.isHidden = candidates.isEmpty
        renderHeader(candidate: candidate, candidates: candidates)
        statusLabel.stringValue = status ?? ""
        statusLabel.isHidden = status == nil
        webView?.isHidden = status != nil || candidate == nil
    }

    private func renderHeader(candidate: DocumentationCandidate?, candidates: [DocumentationCandidate]) {
        titleLabel.stringValue = candidate.map { "\($0.name) · \($0.kind)" } ?? model.query
        subtitleLabel.stringValue = candidate.map { "\($0.sourceName) · \($0.docset)" } ?? model.query
        subtitleLabel.isHidden = candidate == nil
        openInDashButton.isHidden = !DashIntegration.isInstalled
        candidatesButton.isHidden = candidates.count < 2
        shownCandidates = candidates
        // Menu items, not `addItem(withTitle:)`, which drops repeated titles.
        let menu = NSMenu()
        if candidate == nil {
            let placeholder = NSMenuItem(title: localized("docs.choose.placeholder"), action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        }
        for entry in candidates {
            menu.addItem(NSMenuItem(title: "\(entry.name) · \(entry.kind) · \(entry.docset)", action: nil, keyEquivalent: ""))
        }
        candidatesButton.menu = menu
        candidatesButton.selectItem(at: candidate.flatMap { candidates.firstIndex(of: $0) } ?? 0)
    }

    private func text(for notice: DocumentationPanelModel.Notice) -> String {
        switch notice {
        case .notInstalled: localized("docs.notInstalled")
        case .notRunning: localized("docs.notRunning")
        case .apiDisabled: localized("docs.apiDisabled")
        case .trialExpired: localized("docs.trialExpired")
        case .noResults: localizedFormat("docs.noResults", model.query)
        case let .failed(message): localizedFormat("docs.failed", message)
        }
    }

    @objc private func chooseCandidate(_ sender: NSPopUpButton) {
        let offset = shownCandidates.count == sender.numberOfItems ? 0 : 1
        let index = sender.indexOfSelectedItem - offset
        guard shownCandidates.indices.contains(index) else { return }
        // Picking the shown entry again reloads it.
        loadedCandidate = nil
        model.select(shownCandidates[index])
        render()
    }

    @objc private func openInDash(_ sender: Any?) {
        DashIntegration.open(query: model.query)
    }

    // MARK: - Loading

    private func load(_ candidate: DocumentationCandidate) {
        loadedCandidate = candidate
        loadProblem = nil
        // Only the source's own loopback server is ever loaded.
        guard candidate.loadURL.scheme == "http", candidate.loadURL.host == "127.0.0.1" else {
            loadProblem = localizedFormat("docs.failed", candidate.loadURL.absoluteString)
            return
        }
        Task { @MainActor [weak self] in
            let rules = await Self.ruleList.value
            guard let self, loadedCandidate == candidate else { return }
            guard let rules else {
                loadProblem = localizedFormat("docs.failed", localized("docs.rules.failed"))
                render()
                return
            }
            makeWebView(rules: rules).load(URLRequest(url: candidate.loadURL))
            render()
        }
    }

    private func makeWebView(rules: WKContentRuleList) -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(rules)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        // Pages render with their own light styles; dark themes invert them.
        webView.appearance = NSAppearance(named: .aqua)
        webView.underPageBackgroundColor = .white
        webView.setAccessibilityLabel(localized("panel.docs"))
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView, positioned: .below, relativeTo: statusLabel)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.webView = webView
        return webView
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        guard navigationResponse.isForMainFrame,
              let response = navigationResponse.response as? HTTPURLResponse,
              response.statusCode == 403, let url = response.url, url.host == "127.0.0.1"
        else { return .allow }
        // The body is not visible here; fetch it again to tell an expired
        // trial from other refusals.
        let body = (try? await URLSession(configuration: .ephemeral).data(from: url).0) ?? Data()
        showLoadProblem(DashDocumentationSource.isTrialExpired(status: 403, body: body)
            ? localized("docs.trialExpired")
            : localizedFormat("docs.failed", HTTPURLResponse.localizedString(forStatusCode: 403)))
        return .cancel
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    private func loadFailed(_ error: Error) {
        let error = error as NSError
        // A newer load replaced this one, or a policy decision cancelled it.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain", error.code == 102 { return }
        showLoadProblem(localizedFormat("docs.failed", error.localizedDescription))
    }

    private func showLoadProblem(_ text: String) {
        loadProblem = text
        render()
    }
}
