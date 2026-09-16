import AppKit
import CodeInsightAppModel
import CodeInsightReaderCore
import CodeInsightReaderUI
import CodeInsightExact
import SwiftUI

@MainActor
final class ReaderSettingsWindowController: NSWindowController {
    private let hostingController: NSHostingController<SettingsView>
    private let exactCoordinator: ExactCoordinator
    private let onRevoke: @MainActor (URL) async -> Void
    private let onChange: @MainActor (ReaderSettings) -> Void
    private(set) var currentSettings: ReaderSettings

    init(
        settings: ReaderSettings,
        exactCoordinator: ExactCoordinator,
        onRevoke: @escaping @MainActor (URL) async -> Void,
        onChange: @escaping @MainActor (ReaderSettings) -> Void
    ) {
        currentSettings = settings
        self.exactCoordinator = exactCoordinator
        self.onRevoke = onRevoke
        self.onChange = onChange
        hostingController = NSHostingController(
            rootView: SettingsView(
                settings: settings,
                exactCoordinator: exactCoordinator,
                onRevoke: onRevoke,
                onChange: onChange
            )
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(settings: ReaderSettings) {
        currentSettings = settings
        hostingController.rootView = SettingsView(
            settings: settings,
            exactCoordinator: exactCoordinator,
            onRevoke: onRevoke,
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
                && $0.accessibilityLabel?() != "Line height"
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
        selfTestReaderAccessibilityElements.filter {
            $0.accessibilityLabel?() == label || $0.accessibilityTitle?() == label
        }.contains { $0.accessibilityPerformPress?() ?? false }
    }
}

private struct SettingsView: View {
    let settings: ReaderSettings
    let exactCoordinator: ExactCoordinator
    let onRevoke: @MainActor (URL) async -> Void
    let onChange: @MainActor (ReaderSettings) -> Void
    @State private var cacheMessage: String? = nil
    @State private var confirmsCacheClear = false

    var body: some View {
        TabView {
            ReaderSettingsView(settings: settings, onChange: onChange)
                .tabItem { Label("Reader", systemImage: "textformat") }
            VStack(spacing: 12) {
                TrustSettingsView(
                    coordinator: exactCoordinator,
                    onRevoke: onRevoke
                )
                Divider()
                HStack {
                    Text(cacheMessage ?? "Historical Exact snapshots use a 2 GB cache.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Materialized Cache") {
                        confirmsCacheClear = true
                    }
                    .confirmationDialog(
                        "Clear Materialized Cache?",
                        isPresented: $confirmsCacheClear,
                        titleVisibility: .visible
                    ) {
                        Button("Clear", role: .destructive) {
                            Task {
                                do {
                                    try await exactCoordinator.clearMaterializedCache()
                                    cacheMessage = "Materialized cache cleared."
                                } catch {
                                    cacheMessage = error.localizedDescription
                                }
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(
                            "Deletes all historical Exact snapshots. They will be rebuilt on demand."
                        )
                    }
                }
            }
            .tabItem { Label("Exact", systemImage: "checkmark.shield") }
        }
        .padding()
        .frame(width: 600, height: 620)
    }
}

private struct ReaderSettingsView: View {
    let suppliedSettings: ReaderSettings
    @State private var settings: ReaderSettings
    @State private var showsAdvancedTypography = false
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
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(ReaderSettings.Theme.allCases, id: \.self) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }
                    Stepper(
                        "Font size: \(settings.fontSize, specifier: "%.0f") pt",
                        value: $settings.fontSize,
                        in: ReaderSettings.fontSizeRange,
                        step: 1
                    )
                    valueControl(
                        "Line height",
                        value: $settings.lineHeightMultiple,
                        range: ReaderSettings.lineHeightRange,
                        step: 0.05
                    )
                    Toggle("Wrap lines", isOn: $settings.wrapLines)
                    Toggle("Show line numbers", isOn: $settings.lineNumbers)

                    DisclosureGroup("Advanced typography", isExpanded: $showsAdvancedTypography) {
                        Stepper(
                            "Function and type size: +\(settings.functionNameDelta, specifier: "%.0f") pt",
                            value: $settings.functionNameDelta,
                            in: ReaderSettings.functionNameDeltaRange,
                            step: 1
                        )
                        valueControl(
                            "Parameter use opacity",
                            value: $settings.parameterReferenceAlpha,
                            range: ReaderSettings.parameterReferenceAlphaRange,
                            step: 0.01
                        )
                        valueControl(
                            "Gutter marker opacity",
                            value: $settings.declarationMarkerAlpha,
                            range: ReaderSettings.declarationMarkerAlphaRange,
                            step: 0.01
                        )
                        valueControl(
                            "Function and type weight",
                            value: $settings.functionDeclarationFontWeight,
                            range: ReaderSettings.functionDeclarationFontWeightRange,
                            step: 0.05
                        )
                        valueControl(
                            "Constant and module weight",
                            value: $settings.declarationEmphasisFontWeight,
                            range: ReaderSettings.declarationEmphasisFontWeightRange,
                            step: 0.05
                        )
                        Toggle("Syntax formatting", isOn: $settings.syntaxFormatting)
                        Toggle("Proportional comment font", isOn: $settings.humanistComments)
                    }
                    .accessibilityLabel("Advanced typography")
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
                    Text("Preview").font(.headline)
                    Spacer()
                    Text("Rust · updates as you change settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ReaderSettingsPreview(settings: settings)
                    .frame(height: 180)
                    .overlay(Rectangle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            }
            HStack {
                Spacer()
                Button("Restore Reader Defaults") { settings = ReaderSettings() }
                    .disabled(settings == ReaderSettings())
            }
        }
        .padding(12)
        .onChange(of: suppliedSettings) { _, value in settings = value }
        .onChange(of: settings) { _, value in
            onChange(value)
        }
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
    private static let document: ReaderDocument = {
        let plain = ReaderDocument(bytes: Array("""
            // A small cache for names returned by the service.
            const MAX_VISITS: usize = 3;
            struct NameCache { names: Vec<String> }

            fn greet(name: &str, count: usize) -> String {
                let message = format!("Hello, {} — welcome back to your reading workspace", name);
                println!("{} visits: {}", count, message);
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
        reader.view.setAccessibilityLabel("Reader settings preview")
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
    @Bindable var coordinator: ExactCoordinator
    let onRevoke: @MainActor (URL) async -> Void
    @State private var confirmRevokeRepository: TrustedRepository? = nil

    var body: some View {
        Group {
            if coordinator.trustedRepositories.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No Trusted Repositories")
                        .font(.headline)
                    Text("Repositories you trust will appear here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(coordinator.trustedRepositories) { repository in
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
                        Button("Revoke") {
                            confirmRevokeRepository = repository
                        }
                        .confirmationDialog(
                            "Revoke Trust?",
                            isPresented: Binding(
                                get: { confirmRevokeRepository == repository },
                                set: { if !$0 { confirmRevokeRepository = nil } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button("Revoke", role: .destructive) {
                                Task {
                                    await onRevoke(URL(
                                        fileURLWithPath: repository.path,
                                        isDirectory: true
                                    ))
                                }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(
                                "Exact analysis will stop trusting \(repository.path)."
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task { await coordinator.refreshTrust() }
    }
}
