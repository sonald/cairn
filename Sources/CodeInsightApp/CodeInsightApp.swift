import AppKit
import CodeInsightAppModel
import CodeInsightReaderCore
import CodeInsightReaderUI
import Darwin

private enum SelfTestBudgets {
    static let coldStartMS = 500.0
    static let idleFootprintMB = 100.0
    static let regularFirstVisibleMS = 100.0
    static let hugeFirstVisibleMS = 2_500.0
    static let hugeStyledFragments = 500
    static let projectTreeVisibleMS = 1_000.0
    static let projectIndexReadyMS = 2_000.0
}

@main
private struct CodeInsightApplication {
    @MainActor
    static func main() {
        let startedAt = ContinuousClock.now
        let arguments = Array(CommandLine.arguments.dropFirst())
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(startedAt: startedAt)
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            if let index = arguments.firstIndex(of: "--self-test-open"),
               arguments.indices.contains(index + 1)
            {
                delegate.runOpenSelfTest(file: URL(
                    fileURLWithPath: arguments[index + 1]
                ))
            } else if let index = arguments.firstIndex(of: "--self-test-project"),
               arguments.indices.contains(index + 1)
            {
                delegate.runProjectSelfTest(root: URL(
                    fileURLWithPath: arguments[index + 1],
                    isDirectory: true
                ))
            } else if arguments.contains("--self-test") {
                delegate.runSelfTest()
            } else {
                app.run()
            }
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let startedAt: ContinuousClock.Instant
    private let model = AppModel()
    private var windowController: MainWindowController?

    init(startedAt: ContinuousClock.Instant) {
        self.startedAt = startedAt
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launch(offscreen: false)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func runSelfTest() {
        launch(offscreen: true)
        let coldStartMS = milliseconds(since: startedAt)
        guard windowController?.window?.isVisible == true else {
            Darwin.exit(1)
        }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        Self.finishSelfTest(coldStartMS: coldStartMS)
    }

    func runProjectSelfTest(root: URL) {
        launch(offscreen: true)
        let projectStartedAt = ContinuousClock.now
        windowController?.openProject(root: root)
        let treeVisibleMS = milliseconds(since: projectStartedAt)
        let fileCount = model.fileTree?.fileCount ?? 0
        let deadline = Date(timeIntervalSinceNow: 30)
        var ready = false
        while Date() < deadline {
            switch model.projectState {
            case .ready:
                ready = true
            case .failed:
                Self.finishProjectSelfTest(
                    treeVisibleMS: treeVisibleMS,
                    indexReadyMS: milliseconds(since: projectStartedAt),
                    fileCount: fileCount,
                    ready: false
                )
            default:
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            if ready { break }
        }
        Self.finishProjectSelfTest(
            treeVisibleMS: treeVisibleMS,
            indexReadyMS: milliseconds(since: projectStartedAt),
            fileCount: fileCount,
            ready: ready
        )
    }

    func runOpenSelfTest(file: URL) {
        let textView = ReaderTextView()
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 1024, height: 768)
        )
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView.view
        textView.view.frame = scrollView.contentView.bounds
        let window = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        let openedAt = ContinuousClock.now
        let state = OpenSelfTestState(
            openedAt: openedAt,
            textView: textView,
            window: window
        )

        do {
            let loader = DocumentLoader()
            let loaded = try loader.load(file: file)
            state.tier = loaded.tier
            state.textView.display(document: loaded.document)
            state.textView.view.textLayoutManager?
                .textViewportLayoutController.layoutViewport()
            guard
                let fragment = state.textView.view.textLayoutManager?
                    .textLayoutFragment(for: .zero),
                !fragment.textLineFragments.isEmpty
            else { Darwin.exit(1) }
            state.firstVisibleMS = milliseconds(since: openedAt)
            if loaded.tier == .regular {
                state.syntaxVisibleMS = state.firstVisibleMS
            } else {
                loader.loadSyntax(for: loaded.document) { result in
                    Task { @MainActor in
                        switch result {
                        case let .success(document):
                            state.textView.updateSyntax(document: document)
                            try? await Task.sleep(for: .milliseconds(10))
                            state.textView.view.textLayoutManager?
                                .textViewportLayoutController.layoutViewport()
                            state.window.displayIfNeeded()
                            state.syntaxVisibleMS = milliseconds(since: state.openedAt)
                        case .failure:
                            state.failed = true
                        }
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }

        let deadline = Date(timeIntervalSinceNow: 30)
        while state.syntaxVisibleMS == nil, !state.failed, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard
            let tier = state.tier,
            let firstVisibleMS = state.firstVisibleMS,
            let syntaxVisibleMS = state.syntaxVisibleMS,
            !state.failed
        else { Darwin.exit(1) }
        Self.finishOpenSelfTest(
            tier: tier,
            firstVisibleMS: firstVisibleMS,
            syntaxVisibleMS: syntaxVisibleMS,
            styledFragments: state.textView.renderingCoordinator.styledFragmentCount
        )
    }

    private func launch(offscreen: Bool) {
        NSApplication.shared.mainMenu = makeMainMenu()
        let windowController = MainWindowController(model: model, offscreen: offscreen)
        self.windowController = windowController
        windowController.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    @objc private func openProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        if panel.runModal() == .OK, let root = panel.url {
            windowController?.openProject(root: root)
        }
    }

    @objc private func openSymbol(_ sender: Any?) {
        windowController?.showSymbolSearch()
    }

    @objc private func previousContextCandidate(_ sender: Any?) {
        windowController?.selectPreviousContextCandidate(sender)
    }

    @objc private func nextContextCandidate(_ sender: Any?) {
        windowController?.selectNextContextCandidate(sender)
    }

    @objc private func goBack(_ sender: Any?) {
        windowController?.goBack(sender)
    }

    @objc private func goForward(_ sender: Any?) {
        windowController?.goForward(sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)):
            model.navigationHistory.canGoBack
        case #selector(goForward(_:)):
            model.navigationHistory.canGoForward
        default:
            true
        }
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "CodeInsight")
        let quitItem = NSMenuItem(
            title: "Quit CodeInsight",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApplication.shared
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let openItem = NSMenuItem(
            title: "Open Project…",
            action: #selector(openProject(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        fileMenu.addItem(openItem)
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Without an Edit menu, Cmd+C/Cmd+A have no key-equivalent route in a
        // programmatic menu bar (found by interactive walkthrough T3.4).
        // Actions target nil so the responder chain (reader text view, search
        // field) handles them.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        let symbolItem = NSMenuItem(
            title: "Open Symbol…",
            action: #selector(openSymbol(_:)),
            keyEquivalent: "t"
        )
        symbolItem.target = self
        goMenu.addItem(symbolItem)
        goMenu.addItem(.separator())
        let backItem = NSMenuItem(
            title: "Back",
            action: #selector(goBack(_:)),
            keyEquivalent: "\u{F702}"
        )
        backItem.keyEquivalentModifierMask = [.command, .control]
        backItem.target = self
        goMenu.addItem(backItem)
        let forwardItem = NSMenuItem(
            title: "Forward",
            action: #selector(goForward(_:)),
            keyEquivalent: "\u{F703}"
        )
        forwardItem.keyEquivalentModifierMask = [.command, .control]
        forwardItem.target = self
        goMenu.addItem(forwardItem)
        let alternateBackItem = NSMenuItem(
            title: "Back",
            action: #selector(goBack(_:)),
            keyEquivalent: "["
        )
        alternateBackItem.keyEquivalentModifierMask = .command
        alternateBackItem.target = self
        alternateBackItem.isHidden = true
        alternateBackItem.allowsKeyEquivalentWhenHidden = true
        goMenu.addItem(alternateBackItem)
        let alternateForwardItem = NSMenuItem(
            title: "Forward",
            action: #selector(goForward(_:)),
            keyEquivalent: "]"
        )
        alternateForwardItem.keyEquivalentModifierMask = .command
        alternateForwardItem.target = self
        alternateForwardItem.isHidden = true
        alternateForwardItem.allowsKeyEquivalentWhenHidden = true
        goMenu.addItem(alternateForwardItem)
        goMenu.addItem(.separator())
        let previousCandidate = NSMenuItem(
            title: "Previous Context Candidate",
            action: #selector(previousContextCandidate(_:)),
            keyEquivalent: "\u{F702}"
        )
        previousCandidate.keyEquivalentModifierMask = [.command, .option]
        previousCandidate.target = self
        goMenu.addItem(previousCandidate)
        let nextCandidate = NSMenuItem(
            title: "Next Context Candidate",
            action: #selector(nextContextCandidate(_:)),
            keyEquivalent: "\u{F703}"
        )
        nextCandidate.keyEquivalentModifierMask = [.command, .option]
        nextCandidate.target = self
        goMenu.addItem(nextCandidate)
        goItem.submenu = goMenu
        mainMenu.addItem(goItem)

        return mainMenu
    }

    private static func finishSelfTest(coldStartMS: Double) {
        do {
            guard let footprint = physicalFootprintBytes() else { Darwin.exit(1) }
            let idleFootprintMB = Double(footprint) / 1_048_576
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "coldStartMS": coldStartMS,
                    "idleFootprintMB": idleFootprintMB,
                ],
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            Darwin.exit(
                coldStartMS < SelfTestBudgets.coldStartMS
                    && idleFootprintMB < SelfTestBudgets.idleFootprintMB
                    ? 0 : 1
            )
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func finishProjectSelfTest(
        treeVisibleMS: Double,
        indexReadyMS: Double,
        fileCount: Int,
        ready: Bool
    ) -> Never {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "treeVisibleMS": treeVisibleMS,
                    "indexReadyMS": indexReadyMS,
                    "fileCount": fileCount,
                ],
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            Darwin.exit(
                ready
                    && treeVisibleMS < SelfTestBudgets.projectTreeVisibleMS
                    && indexReadyMS < SelfTestBudgets.projectIndexReadyMS
                    ? 0 : 1
            )
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
    }

    private static func finishOpenSelfTest(
        tier: FileTier,
        firstVisibleMS: Double,
        syntaxVisibleMS: Double,
        styledFragments: Int
    ) -> Never {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: [
                    "tier": tier.rawValue,
                    "firstVisibleMS": firstVisibleMS,
                    "syntaxVisibleMS": syntaxVisibleMS,
                    "styledFragments": styledFragments,
                ],
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
            let withinBudget = tier == .regular
                ? firstVisibleMS < SelfTestBudgets.regularFirstVisibleMS
                    && styledFragments > 0
                : tier != .huge
                    || (
                        firstVisibleMS < SelfTestBudgets.hugeFirstVisibleMS
                            && styledFragments < SelfTestBudgets.hugeStyledFragments
                    )
            Darwin.exit(withinBudget ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
    }
}

@MainActor
private final class OpenSelfTestState {
    let openedAt: ContinuousClock.Instant
    let textView: ReaderTextView
    let window: NSWindow
    var tier: FileTier?
    var firstVisibleMS: Double?
    var syntaxVisibleMS: Double?
    var failed = false

    init(
        openedAt: ContinuousClock.Instant,
        textView: ReaderTextView,
        window: NSWindow
    ) {
        self.openedAt = openedAt
        self.textView = textView
        self.window = window
    }
}

private func physicalFootprintBytes() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
}

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}
