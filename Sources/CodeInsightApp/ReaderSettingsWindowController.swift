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
        .frame(width: 560, height: 360)
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
            Toggle("Use humanist font for comments", isOn: $settings.humanistComments)
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: settings) { _, value in
            onChange(value)
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
