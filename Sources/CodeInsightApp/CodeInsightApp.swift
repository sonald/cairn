import AppKit
import CodeInsightAppModel
import CodeInsightReaderUI
import Darwin

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
            if let index = arguments.firstIndex(of: "--self-test-project"),
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
private final class AppDelegate: NSObject, NSApplicationDelegate {
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

    @objc private func placeholderAction(_ sender: Any?) {}

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

        let goItem = NSMenuItem()
        let goMenu = NSMenu(title: "Go")
        let symbolItem = NSMenuItem(
            title: "Open Symbol…",
            action: #selector(placeholderAction(_:)),
            keyEquivalent: "t"
        )
        symbolItem.target = self
        goMenu.addItem(symbolItem)
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
            Darwin.exit(coldStartMS < 500 && idleFootprintMB < 100 ? 0 : 1)
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
            Darwin.exit(ready && treeVisibleMS < 1_000 ? 0 : 1)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Darwin.exit(1)
        }
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
