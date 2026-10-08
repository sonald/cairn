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
    private let backButton = NSButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var webView: WKWebView?
    private var theme = ReaderTheme(settings: ReaderSettings())
    /// The candidate the web view was last asked to load.
    private var loadedCandidate: DocumentationCandidate?
    /// Text shown instead of the page after it failed to load.
    private var loadProblem: String?
    private var shownCandidates: [DocumentationCandidate] = []
    private var webViewObservations: [NSKeyValueObservation] = []
    /// Whether the dark-theme stylesheet is installed in the web view.
    private var pageDark = false

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
    /// Dash's own dark-mode stylesheet: invert the page, turn images and
    /// video back. The root scrollbar is outside the filter, so it gets dark
    /// colors of its own. Injected by a user script, which runs although
    /// page scripts are off.
    private static let darkStyleSheet = [
        "html:not(.dash-ignore-dark-mode), html:not(.dash-ignore-dark-mode) body { background-image:none !important;}",
        "html:not(.dash-ignore-dark-mode) { filter: invert() hue-rotate(180deg) contrast(80%) brightness(120%) contrast(85%); }",
        "html img:not(picture > img):not([src*=\"svg\"]), html video, html .dash-ignore-dark-mode "
            + "{ filter: hue-rotate(180deg) invert() brightness(100%) contrast(100%); }",
        "::selection { background-color: lightsalmon; color: #000; }",
        "::-webkit-scrollbar { width: 12px; height: 12px; background-color: #262626; }",
        "::-webkit-scrollbar-track { background-color: #262626; }",
        "::-webkit-scrollbar-thumb { background-color: #5c5c5c; border-radius: 6px; border: 3px solid #262626; }",
    ].joined(separator: " ")
    private static let darkStyleScript = WKUserScript(
        source: "var s=document.createElement('style');s.textContent='\(darkStyleSheet)';"
            + "document.documentElement.appendChild(s);",
        injectionTime: .atDocumentEnd,
        forMainFrameOnly: true
    )
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
        let root = AppearanceTrackingView()
        root.wantsLayer = true
        root.onAppearanceChange = { [weak self] in self?.applyPageAppearance() }
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
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: localized("docs.back"))
        backButton.isBordered = false
        backButton.controlSize = .small
        backButton.toolTip = localized("docs.back")
        backButton.setAccessibilityLabel(localized("docs.back"))
        backButton.target = self
        backButton.action = #selector(goBack(_:))
        backButton.isEnabled = false
        backButton.setContentHuggingPriority(.required, for: .horizontal)

        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        titles.setContentHuggingPriority(.init(1), for: .horizontal)
        let topRow = NSStackView(views: [backButton, titles, openInDashButton])
        topRow.orientation = .horizontal
        topRow.spacing = 6
        topRow.distribution = .fill
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
        backButton.contentTintColor = theme.chromeSecondaryColor
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
        renderSubtitle()
        backButton.isHidden = candidate == nil
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

    /// The entry's docset, or the page title once the user followed a link
    /// to another page inside the panel.
    private func renderSubtitle() {
        guard let candidate = loadedCandidate else {
            subtitleLabel.isHidden = true
            return
        }
        subtitleLabel.isHidden = false
        func page(_ url: URL?) -> String? { url?.absoluteString.split(separator: "#").first.map(String.init) }
        if let webView, let url = webView.url, page(url) != page(candidate.loadURL),
           let title = webView.title, !title.isEmpty {
            subtitleLabel.stringValue = title
        } else {
            subtitleLabel.stringValue = "\(candidate.sourceName) · \(candidate.docset)"
        }
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

    @objc private func goBack(_ sender: Any?) {
        webView?.goBack()
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
        // Same-page anchor jumps never call didFinish; the header follows
        // the web view's own properties instead.
        webViewObservations = [
            webView.observe(\.canGoBack) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.backButton.isEnabled = self?.webView?.canGoBack == true }
            },
            webView.observe(\.title) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.renderSubtitle() }
            },
            webView.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.renderSubtitle() }
            },
        ]
        view.addSubview(webView, positioned: .below, relativeTo: statusLabel)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.webView = webView
        applyPageAppearance()
        return webView
    }

    private var isDark: Bool {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Dark Cairn themes (and Auto in dark mode) invert the page; a change
    /// reloads the current page so the stylesheet applies or goes away.
    private func applyPageAppearance() {
        guard let webView else { return }
        let dark = isDark
        // Tiles WebKit has not painted yet show the view's own background;
        // in dark themes let the panel's dark background through instead.
        webView.underPageBackgroundColor = dark ? theme.backgroundColor : .white
        webView.setValue(!dark, forKey: "drawsBackground")
        guard dark != pageDark else { return }
        pageDark = dark
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        if dark { controller.addUserScript(Self.darkStyleScript) }
        if webView.url != nil { webView.reload() }
    }

    /// Loopback links stay in the panel; other web links go to the default
    /// browser, as in the hover card. Nothing else navigates.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == "http", url.host == "127.0.0.1" {
            // A `target=_blank` link would otherwise go nowhere.
            guard navigationAction.targetFrame == nil else { return .allow }
            webView.load(navigationAction.request)
            return .cancel
        }
        if navigationAction.navigationType == .linkActivated, url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return .cancel
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

/// Reports appearance changes, including Auto following the system.
private final class AppearanceTrackingView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
