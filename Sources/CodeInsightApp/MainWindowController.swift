import AppKit

@MainActor
final class MainWindowController: NSWindowController {
    init(offscreen: Bool) {
        let content = NSSplitViewController()
        content.splitView.isVertical = false

        let readerSplit = NSSplitViewController()
        readerSplit.splitView.isVertical = true
        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: SidebarViewController()
        )
        sidebarItem.minimumThickness = 180
        readerSplit.addSplitViewItem(sidebarItem)
        readerSplit.addSplitViewItem(
            NSSplitViewItem(viewController: ReaderViewController())
        )

        content.addSplitViewItem(NSSplitViewItem(viewController: readerSplit))
        let contextItem = NSSplitViewItem(
            viewController: ContextWindowViewController()
        )
        contextItem.minimumThickness = 120
        contextItem.maximumThickness = 280
        content.addSplitViewItem(contextItem)

        let frame = NSRect(x: offscreen ? -10_000 : 0, y: 0, width: 1100, height: 760)
        let window = NSWindow(
            contentRect: frame,
            styleMask: offscreen
                ? [.borderless]
                : [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CodeInsight"
        window.contentViewController = content
        if !offscreen { window.center() }
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class SidebarViewController: NSViewController {
    override func loadView() {
        view = placeholderView(text: "No project open")
    }
}

@MainActor
final class ReaderViewController: NSViewController {
    override func loadView() {
        view = placeholderView(text: "Open a project to begin")
    }
}

@MainActor
final class ContextWindowViewController: NSViewController {
    override func loadView() {
        view = placeholderView(text: "Select a symbol to see context")
    }
}

@MainActor
private func placeholderView(text: String) -> NSView {
    let container = NSView()
    let label = NSTextField(labelWithString: text)
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    NSLayoutConstraint.activate([
        label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    return container
}
