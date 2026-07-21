import AppKit
import CodeInsightReaderCore
import SwiftUI

@MainActor
final class ReaderSettingsWindowController: NSWindowController {
    init(
        settings: ReaderSettings,
        onChange: @escaping @MainActor (ReaderSettings) -> Void
    ) {
        let hostingController = NSHostingController(
            rootView: ReaderSettingsView(settings: settings, onChange: onChange)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Reader Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        .frame(width: 440, height: 300)
        .onChange(of: settings) { _, value in
            onChange(value)
        }
    }
}
