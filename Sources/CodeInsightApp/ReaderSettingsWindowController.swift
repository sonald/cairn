import AppKit
import CodeInsightAppModel
import CodeInsightReaderCore
import SwiftUI

@MainActor
final class ReaderSettingsWindowController: NSWindowController {
    init(
        settings: ReaderSettings,
        exactCoordinator: ExactCoordinator,
        onRevoke: @escaping @MainActor (URL) async -> Void,
        onChange: @escaping @MainActor (ReaderSettings) -> Void
    ) {
        let hostingController = NSHostingController(
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
        func isVisible(_ view: NSView) -> Bool {
            var current: NSView? = view
            while let candidate = current {
                if candidate.isHidden { return false }
                current = candidate.superview
            }
            return view.window === window && !view.bounds.isEmpty
        }
        let controls = collect(contentView).compactMap { $0 as? NSControl }
            .filter(isVisible)
        let sliders = controls.compactMap { $0 as? NSSlider }
        guard sliders.count == 5 else {
            return ([], [], contentView.bounds)
        }
        let visualSliders = Array(sliders.dropFirst())
        let visualIdentities = Set(visualSliders.map(ObjectIdentifier.init))
        func frame(_ view: NSView) -> NSRect {
            view.convert(view.bounds, to: contentView)
        }
        return (
            visualSliders.map(frame),
            controls.filter {
                !visualIdentities.contains(ObjectIdentifier($0))
            }.map(frame),
            contentView.bounds
        )
    }
}

private struct SettingsView: View {
    let settings: ReaderSettings
    let exactCoordinator: ExactCoordinator
    let onRevoke: @MainActor (URL) async -> Void
    let onChange: @MainActor (ReaderSettings) -> Void
    @State private var cacheMessage: String? = nil

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
                        Task {
                            do {
                                try await exactCoordinator.clearMaterializedCache()
                                cacheMessage = "Materialized cache cleared."
                            } catch {
                                cacheMessage = error.localizedDescription
                            }
                        }
                    }
                }
            }
            .tabItem { Label("Exact", systemImage: "checkmark.shield") }
        }
        .padding()
        .frame(width: 560, height: 520)
    }
}

private struct ReaderSettingsView: View {
    @State private var settings: ReaderSettings
    let onChange: @MainActor (ReaderSettings) -> Void

    init(
        settings: ReaderSettings,
        onChange: @escaping @MainActor (ReaderSettings) -> Void
    ) {
        _settings = State(initialValue: settings)
        self.onChange = onChange
    }

    var body: some View {
        Form {
            Picker("Theme", selection: $settings.theme) {
                ForEach(ReaderSettings.Theme.allCases, id: \.self) { theme in
                    Text(theme.rawValue).tag(theme)
                }
            }

            LabeledContent("Line height") {
                HStack {
                    Slider(
                        value: $settings.lineHeightMultiple,
                        in: ReaderSettings.lineHeightRange,
                        step: 0.05
                    )
                    Text(settings.lineHeightMultiple, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }

            Stepper(
                "Font size: \(settings.fontSize, specifier: "%.0f") pt",
                value: $settings.fontSize,
                in: ReaderSettings.fontSizeRange,
                step: 1
            )
            Stepper(
                "Function name: +\(settings.functionNameDelta, specifier: "%.0f") pt",
                value: $settings.functionNameDelta,
                in: ReaderSettings.functionNameDeltaRange,
                step: 1
            )
            valueControl(
                "Parameter reference opacity",
                value: $settings.parameterReferenceAlpha,
                range: ReaderSettings.parameterReferenceAlphaRange,
                step: 0.01
            )
            valueControl(
                "Declaration marker opacity",
                value: $settings.declarationMarkerAlpha,
                range: ReaderSettings.declarationMarkerAlphaRange,
                step: 0.01
            )
            valueControl(
                "Function / declaration title weight",
                value: $settings.functionDeclarationFontWeight,
                range: ReaderSettings.functionDeclarationFontWeightRange,
                step: 0.05
            )
            valueControl(
                "Declaration emphasis weight",
                value: $settings.declarationEmphasisFontWeight,
                range: ReaderSettings.declarationEmphasisFontWeightRange,
                step: 0.05
            )
            Toggle("Syntax formatting", isOn: $settings.syntaxFormatting)
            Toggle("Use humanist font for comments", isOn: $settings.humanistComments)
            Toggle("Show line numbers", isOn: $settings.lineNumbers)
        }
        .formStyle(.grouped)
        .padding()
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
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

struct TrustSettingsView: View {
    @Bindable var coordinator: ExactCoordinator
    let onRevoke: @MainActor (URL) async -> Void

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
                            Task {
                                await onRevoke(URL(
                                    fileURLWithPath: repository.path,
                                    isDirectory: true
                                ))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task { await coordinator.refreshTrust() }
    }
}
