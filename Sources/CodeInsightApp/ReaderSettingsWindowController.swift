import AppKit
import CodeInsightAppModel
import CodeInsightReaderCore
import CodeInsightReaderUI
import CodeInsightExact
import Observation
import SwiftUI

/// Application-level trust list state for the Settings window: reads the
/// one shared registry instead of pinning some window's ExactCoordinator
/// (§6.4). The AppDelegate refreshes it after grant/revoke.
@MainActor
@Observable
final class TrustListModel {
    private(set) var repositories: [TrustedRepository] = []

    func refresh(from registry: TrustRegistry) async {
        repositories = await registry.trustedRepositories()
    }

    /// Synchronous replacement from a coordinator's already-refreshed
    /// snapshot.
    func replace(coordinator: ExactCoordinator) {
        repositories = coordinator.trustedRepositories
    }

    /// Synchronous replacement from an explicit list (self-test paths).
    func replace(_ repositories: [TrustedRepository]) {
        self.repositories = repositories
    }
}

/// Result of the app-level materialized-cache clear (§8.4).
enum MaterializedCacheClearOutcome: Equatable {
    case cleared
    case failed(String)

    var message: String? {
        switch self {
        case .cleared: localized("settings.cache.cleared")
        case .failed(let reason): reason
        }
    }
}

@MainActor
final class ReaderSettingsWindowController: NSWindowController {
    private let hostingController: NSHostingController<SettingsView>
    private let trustModel: TrustListModel
    private let onRevoke: @MainActor (URL) async -> Void
    private let onClearCache: @MainActor () async -> MaterializedCacheClearOutcome
    private let onChange: @MainActor (ReaderSettings) -> Void
    private(set) var currentSettings: ReaderSettings

    /// Production initializer: global operations stay application-owned.
    init(
        settings: ReaderSettings,
        trustModel: TrustListModel,
        onRevoke: @escaping @MainActor (URL) async -> Void,
        onClearCache: @escaping @MainActor () async -> MaterializedCacheClearOutcome,
        onChange: @escaping @MainActor (ReaderSettings) -> Void
    ) {
        currentSettings = settings
        self.trustModel = trustModel
        self.onRevoke = onRevoke
        self.onClearCache = onClearCache
        self.onChange = onChange
        hostingController = NSHostingController(
            rootView: SettingsView(
                settings: settings,
                trustModel: trustModel,
                onRevoke: onRevoke,
                onClearCache: onClearCache,
                onChange: onChange
            )
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = localized("settings.title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    /// Test/single-coordinator initializer kept for existing coverage.
    /// The list seeds synchronously from the coordinator's in-memory
    /// snapshot; revoke/clear refresh it from the registry afterwards.
    convenience init(
        settings: ReaderSettings,
        exactCoordinator: ExactCoordinator,
        onRevoke: @escaping @MainActor (URL) async -> Void,
        onChange: @escaping @MainActor (ReaderSettings) -> Void
    ) {
        let trustModel = TrustListModel()
        trustModel.replace(coordinator: exactCoordinator)
        self.init(
            settings: settings,
            trustModel: trustModel,
            onRevoke: { url in
                await onRevoke(url)
                await trustModel.refresh(from: exactCoordinator.trustRegistry)
            },
            onClearCache: {
                do {
                    try await exactCoordinator.clearMaterializedCache()
                    return .cleared
                } catch {
                    return .failed(error.localizedDescription)
                }
            },
            onChange: onChange
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        ReaderFontResolver.shared.refreshIfNeeded()
        super.showWindow(sender)
    }

    func update(settings: ReaderSettings) {
        currentSettings = settings
        hostingController.rootView = SettingsView(
            settings: settings,
            trustModel: trustModel,
            onRevoke: onRevoke,
            onClearCache: onClearCache,
            onChange: onChange
        )
    }

    var selfTestVisualControlGeometry: (
        frames: [NSRect],
        existingFrames: [NSRect],
        visibleFrame: NSRect
    ) {
        guard let contentView = window?.contentView else {
            return ([], [], .zero)
        }
        func collect(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(collect)
        }
        // SwiftUI can expose virtual AX sliders without NSSlider subviews.
        // AX frames are screen coordinates; keep all geometry in content coordinates.
        func frame(_ element: AnyObject) -> NSRect {
            guard let window, let screenFrame = element.accessibilityFrame?() else {
                return .zero
            }
            return contentView.convert(window.convertFromScreen(screenFrame), from: nil)
        }
        let elements = selfTestReaderAccessibilityElements
        let visualSliders = elements.filter {
            $0.accessibilityRole?() == .slider
                && $0.accessibilityLabel?() != localized("settings.lineHeight")
        }
        let controlRoles: Set<NSAccessibility.Role> = [
            .slider, .button, .checkBox, .radioButton, .popUpButton, .incrementor, .textField,
        ]
        let existingControls = elements.filter { element in
            guard let role = element.accessibilityRole?(), controlRoles.contains(role) else {
                return false
            }
            return !visualSliders.contains { $0 === element }
        }
        let frames = visualSliders.map(frame)
        let visibleFrame = collect(contentView).compactMap { $0 as? NSScrollView }
            .map { $0.contentView.convert($0.contentView.bounds, to: contentView) }
            .first { visible in frames.first.map { visible.intersects($0) } ?? false }
            ?? contentView.bounds
        return (frames, existingControls.map(frame), visibleFrame)
    }

    var selfTestReaderToggleCount: Int {
        guard let contentView = window?.contentView else { return 0 }
        func collect(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(collect)
        }
        return collect(contentView).count { view in
            String(describing: type(of: view)) == "PlatformSwitch"
        }
    }

    static func selfTestEnableAccessibility() {
        NSApplication.shared.accessibilitySetValue(
            true, forAttribute: .init(rawValue: "AXEnhancedUserInterface")
        )
    }

    var selfTestReaderAccessibilityElements: [AnyObject] {
        // SwiftUI's virtual nodes implement the AX selectors without
        // declaring NSAccessibilityProtocol conformance.
        func collect(_ element: AnyObject) -> [AnyObject] {
            [element] + (element.accessibilityChildren?() ?? [])
                .flatMap { collect($0 as AnyObject) }
        }
        guard let contentView = window?.contentView else { return [] }
        return collect(contentView)
    }

    @discardableResult
    func selfTestPressReaderControl(_ label: String) -> Bool {
        let identifier = switch label {
        case "Advanced typography": "advancedTypography"
        case "Restore Reader Defaults": "restoreReaderDefaults"
        default: label
        }
        return selfTestReaderAccessibilityElements.filter {
            $0.accessibilityIdentifier?() == identifier
                || $0.accessibilityLabel?() == label || $0.accessibilityTitle?() == label
        }.contains { $0.accessibilityPerformPress?() ?? false }
    }
}

private struct SettingsView: View {
    let settings: ReaderSettings
    let trustModel: TrustListModel
    let onRevoke: @MainActor (URL) async -> Void
    let onClearCache: @MainActor () async -> MaterializedCacheClearOutcome
    let onChange: @MainActor (ReaderSettings) -> Void
    @State private var cacheMessage: String? = nil
    @State private var confirmsCacheClear = false

    var body: some View {
        TabView {
            ReaderSettingsView(settings: settings, onChange: onChange)
                .tabItem { Label(localized("settings.reader"), systemImage: "textformat") }
            VStack(spacing: 12) {
                TrustSettingsView(
                    trustModel: trustModel,
                    onRevoke: onRevoke
                )
                Divider()
                HStack {
                    Text(cacheMessage ?? localized("settings.cache.description"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(localized("settings.cache.clear")) {
                        confirmsCacheClear = true
                    }
                    .confirmationDialog(
                        localized("settings.cache.confirm"),
                        isPresented: $confirmsCacheClear,
                        titleVisibility: .visible
                    ) {
                        Button(localized("settings.clear"), role: .destructive) {
                            Task {
                                // App-level clear: stops every project's
                                // Exact work before deleting (§8.4).
                                cacheMessage = await onClearCache().message
                            }
                        }
                        Button(localized("settings.cancel"), role: .cancel) {}
                    } message: {
                        Text(
                            localized("settings.cache.warning")
                        )
                    }
                }
            }
            .tabItem { Label(localized("settings.exact"), systemImage: "checkmark.shield") }
        }
        .padding()
        .frame(width: 600, height: 620)
    }
}

private struct ReaderSettingsView: View {
    let suppliedSettings: ReaderSettings
    @State private var settings: ReaderSettings
    @State private var showsAdvancedTypography = false
    @State private var fontNames: [String] = []
    @State private var fontEnvironmentRevision: UInt64 = 0
    let onChange: @MainActor (ReaderSettings) -> Void

    init(
        settings: ReaderSettings,
        onChange: @escaping @MainActor (ReaderSettings) -> Void
    ) {
        suppliedSettings = settings
        _settings = State(initialValue: settings)
        self.onChange = onChange
    }

    var body: some View {
        VStack(spacing: 12) {
            ScrollViewReader { proxy in
                Form {
                    Picker(localized("settings.theme"), selection: $settings.theme) {
                        ForEach(ReaderSettings.Theme.allCases, id: \.self) { theme in
                            Text(localized("settings.theme.\(theme.rawValue)")).tag(theme)
                        }
                    }
                    Stepper(
                        localizedFormat("settings.fontSize", settings.fontSize),
                        value: $settings.fontSize,
                        in: ReaderSettings.fontSizeRange,
                        step: 1
                    )
                    valueControl(
                        localized("settings.lineHeight"),
                        value: $settings.lineHeightMultiple,
                        range: ReaderSettings.lineHeightRange,
                        step: 0.05
                    )
                    Toggle(localized("settings.wrap"), isOn: $settings.wrapLines)
                    Toggle(localized("settings.lineNumbers"), isOn: $settings.lineNumbers)
                    fontControls

                    DisclosureGroup(localized("settings.advanced"), isExpanded: $showsAdvancedTypography) {
                        Stepper(
                            localizedFormat("settings.functionSize", settings.functionNameDelta),
                            value: $settings.functionNameDelta,
                            in: ReaderSettings.functionNameDeltaRange,
                            step: 1
                        )
                        valueControl(
                            localized("settings.parameterOpacity"),
                            value: $settings.parameterReferenceAlpha,
                            range: ReaderSettings.parameterReferenceAlphaRange,
                            step: 0.01
                        )
                        valueControl(
                            localized("settings.gutterOpacity"),
                            value: $settings.declarationMarkerAlpha,
                            range: ReaderSettings.declarationMarkerAlphaRange,
                            step: 0.01
                        )
                        valueControl(
                            localized("settings.functionWeight"),
                            value: $settings.functionDeclarationFontWeight,
                            range: ReaderSettings.functionDeclarationFontWeightRange,
                            step: 0.05
                        )
                        valueControl(
                            localized("settings.constantWeight"),
                            value: $settings.declarationEmphasisFontWeight,
                            range: ReaderSettings.declarationEmphasisFontWeightRange,
                            step: 0.05
                        )
                        Toggle(localized("settings.syntax"), isOn: $settings.syntaxFormatting)
                        Toggle(localized("settings.comments"), isOn: $settings.humanistComments)
                    }
                    .accessibilityIdentifier("advancedTypography")
                    .accessibilityLabel(localized("settings.advanced"))
                    .accessibilityAction { showsAdvancedTypography.toggle() }
                    .id("advancedTypography")
                }
                .formStyle(.grouped)
                .onChange(of: showsAdvancedTypography) { _, expanded in
                    if expanded { proxy.scrollTo("advancedTypography", anchor: .top) }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(localized("settings.preview")).font(.headline)
                    Spacer()
                    Text(localized("settings.preview.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ReaderSettingsPreview(settings: settings, fontEnvironmentRevision: fontEnvironmentRevision)
                    .frame(height: 180)
                    .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            }
            HStack {
                Spacer()
                Button(localized("settings.restore")) { settings = ReaderSettings() }
                    .accessibilityIdentifier("restoreReaderDefaults")
                    .disabled(settings == ReaderSettings())
            }
        }
        .padding(12)
        .onAppear {
            ReaderFontResolver.shared.refreshIfNeeded()
            updateFontList()
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerFontEnvironmentDidChange)) { _ in
            updateFontList()
        }
        .onChange(of: suppliedSettings) { _, value in settings = value }
        .onChange(of: settings) { _, value in
            if value != suppliedSettings { onChange(value) }
        }
    }

    private var fontControls: some View {
        // Reading the revision makes diagnostics refresh even when settings are unchanged.
        let _ = fontEnvironmentRevision
        let resolved = ReaderFontResolver.shared.resolve(theme: ReaderTheme(settings: settings))
        return Section {
            Picker(localized("settings.codeFont"), selection: $settings.codeFont) {
                Text(localized("settings.codeFont.system")).tag(CodeFontSelection.systemMonospaced)
                ForEach(fontNames, id: \.self) { name in
                    Text(NSFont(name: name, size: 13)?.displayName ?? name)
                        .tag(CodeFontSelection.postScriptName(name))
                }
                if case .postScriptName(let name) = settings.codeFont, !fontNames.contains(name) {
                    Text(name).tag(CodeFontSelection.postScriptName(name))
                }
            }
            .accessibilityIdentifier("codeFont")
            .accessibilityLabel(localized("settings.codeFont"))
            Picker(localized("settings.codeLigatures"), selection: $settings.codeLigatures) {
                ForEach(CodeLigatureMode.allCases, id: \.self) { mode in
                    Text(localized("settings.codeLigatures.\(mode.rawValue)")).tag(mode)
                }
            }
            .accessibilityIdentifier("codeLigatures")
            .accessibilityLabel(localized("settings.codeLigatures"))
            Text(localizedFormat("settings.codeFont.actual", resolved.actualPostScriptName))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("resolvedCodeFont")
            if resolved.fallbackReason != nil, let requested = resolved.requestedPostScriptName {
                Text(localizedFormat("settings.codeFont.missing", requested))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(localized("settings.codeLigatures.unverified"))
                .font(.caption).foregroundStyle(.secondary)
            Button(localized("settings.codeFont.refresh")) {
                ReaderFontResolver.shared.refresh()
            }
            .accessibilityIdentifier("refreshCodeFonts")
        }
    }

    private func updateFontList() {
        fontNames = (NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
            .filter { NSFont(name: $0, size: 13) != nil }
            .sorted { lhs, rhs in
                (NSFont(name: lhs, size: 13)?.displayName ?? lhs)
                    .localizedStandardCompare(NSFont(name: rhs, size: 13)?.displayName ?? rhs) == .orderedAscending
            }
        fontEnvironmentRevision = ReaderFontResolver.shared.fontEnvironmentRevision
    }

    private func valueControl(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        HStack {
            Text(label)
                .frame(width: 190, alignment: .leading)
                .accessibilityHidden(true)
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(label)
                .accessibilityValue(value.wrappedValue.formatted(
                    .number.precision(.fractionLength(2))
                ))
            Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ReaderSettingsPreview: NSViewRepresentable {
    let settings: ReaderSettings
    let fontEnvironmentRevision: UInt64
    private static let document: ReaderDocument = {
        let plain = ReaderDocument(bytes: Array("""
            // Operators: != !== -> => <= >= :: .. ... ===
            const MAX_VISITS: usize = 3;
            struct NameCache { names: Vec<String> }

            fn greet(name: &str, count: usize) -> String {
                let message = format!("Hello, {} — welcome back to your reading workspace", name);
                if count != MAX_VISITS && count <= 3 { println!("{} != !== -> => <= >= :: .. ... ===", message); }
                message
            }
            """.utf8))
        return (try? DocumentLoader().loadSyntax(for: plain)) ?? plain
    }()

    func makeNSView(context: Context) -> ReaderSettingsPreviewScrollView {
        ReaderSettingsPreviewScrollView(settings: settings, document: Self.document)
    }

    func updateNSView(_ scrollView: ReaderSettingsPreviewScrollView, context: Context) {
        scrollView.apply(settings: settings)
    }
}

private final class ReaderSettingsPreviewScrollView: NSScrollView {
    private let reader: ReaderTextView
    private let document: ReaderDocument
    private var settings: ReaderSettings
    private var displayed = false

    init(settings: ReaderSettings, document: ReaderDocument) {
        reader = ReaderTextView(settings: settings)
        self.settings = settings
        self.document = document
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        documentView = reader.view
        reader.view.setAccessibilityLabel(localized("settings.preview.accessibility"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !displayed, window != nil, !contentView.bounds.isEmpty else { return }
        displayed = true
        // Finish the first AppKit layout before installing TextKit's viewport styles.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reader.view.frame = NSRect(origin: .zero, size: contentView.bounds.size)
            reader.configureGutter(in: self, lineNumbers: settings.lineNumbers)
            reader.display(document: document)
            scrollToBeginning()
            reader.view.textLayoutManager?.textViewportLayoutController.layoutViewport()
            reader.apply(settings: settings)
        }
    }

    func apply(settings: ReaderSettings) {
        self.settings = settings
        guard displayed else { return }
        let wasAtBeginning = abs(contentView.bounds.minX + contentView.contentInsets.left) < 0.5
            && abs(contentView.bounds.minY + contentView.contentInsets.top) < 0.5
        reader.apply(settings: settings)
        if wasAtBeginning { scrollToBeginning() }
    }

    private func scrollToBeginning() {
        contentView.scroll(to: NSPoint(
            x: -contentView.contentInsets.left,
            y: -contentView.contentInsets.top
        ))
        reflectScrolledClipView(contentView)
    }
}

struct TrustSettingsView: View {
    @Bindable var trustModel: TrustListModel
    let onRevoke: @MainActor (URL) async -> Void
    @State private var confirmRevokeRepository: TrustedRepository? = nil

    var body: some View {
        Group {
            if trustModel.repositories.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(localized("settings.trust.empty"))
                        .font(.headline)
                    Text(localized("settings.trust.hint"))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(trustModel.repositories) { repository in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(repository.path)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(2)
                            Text(repository.grantedAt, format: .dateTime
                                .year().month().day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(localized("settings.trust.revoke")) {
                            confirmRevokeRepository = repository
                        }
                        .confirmationDialog(
                            localized("settings.trust.confirm"),
                            isPresented: Binding(
                                get: { confirmRevokeRepository == repository },
                                set: { if !$0 { confirmRevokeRepository = nil } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button(localized("settings.trust.revoke"), role: .destructive) {
                                Task {
                                    await onRevoke(URL(
                                        fileURLWithPath: repository.path,
                                        isDirectory: true
                                    ))
                                }
                            }
                            Button(localized("settings.cancel"), role: .cancel) {}
                        } message: {
                            Text(
                                localizedFormat("settings.trust.warning", repository.path)
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
