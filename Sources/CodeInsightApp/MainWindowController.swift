import AppKit
import CodeInsightAppModel
import Observation

@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private static let projectItemIdentifier = NSToolbarItem.Identifier("Project")
    private static let indexItemIdentifier = NSToolbarItem.Identifier("IndexStatus")

    let model: AppModel
    private let sidebarController = SidebarViewController()
    private let readerController = ReaderViewController()
    private let projectLabel = NSTextField(labelWithString: "CodeInsight")
    private let indexLabel = NSTextField(labelWithString: "")
    private var displayedGeneration: UInt64?

    init(model: AppModel, offscreen: Bool) {
        self.model = model
        let content = NSSplitViewController()
        content.splitView.isVertical = false

        let readerSplit = NSSplitViewController()
        readerSplit.splitView.isVertical = true
        let sidebarItem = NSSplitViewItem(
            sidebarWithViewController: sidebarController
        )
        sidebarItem.minimumThickness = 180
        readerSplit.addSplitViewItem(sidebarItem)
        readerSplit.addSplitViewItem(
            NSSplitViewItem(viewController: readerController)
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
        let toolbar = NSToolbar(identifier: "MainToolbar")
        window.toolbar = toolbar
        if !offscreen { window.center() }
        super.init(window: window)
        toolbar.delegate = self
        sidebarController.onOpenFile = { [weak model] url in
            model?.selectFile(url)
        }
        render()
        observe()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func openProject(root: URL) {
        model.openProject(root: root)
        render()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.projectItemIdentifier, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.projectItemIdentifier, Self.indexItemIdentifier, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case Self.projectItemIdentifier:
            item.view = projectLabel
        case Self.indexItemIdentifier:
            item.view = indexLabel
        default:
            return nil
        }
        return item
    }

    private func observe() {
        withObservationTracking {
            _ = model.projectState
            _ = model.generation
            _ = model.fileTree
            _ = model.selectedFile
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.render()
                self?.observe()
            }
        }
    }

    private func render() {
        if displayedGeneration != model.generation {
            sidebarController.display(model.fileTree)
            displayedGeneration = model.generation
        }
        readerController.display(model.selectedFile)
        projectLabel.stringValue = model.fileTree?.root.lastPathComponent ?? "CodeInsight"

        guard let toolbar = window?.toolbar else { return }
        switch model.projectState {
        case .indexing:
            indexLabel.stringValue = "Indexing \(model.fileTree?.fileCount ?? 0) files…"
            if toolbar.items.allSatisfy({ $0.itemIdentifier != Self.indexItemIdentifier }) {
                toolbar.insertItem(
                    withItemIdentifier: Self.indexItemIdentifier,
                    at: toolbar.items.count
                )
            }
        default:
            if let index = toolbar.items.firstIndex(where: {
                $0.itemIdentifier == Self.indexItemIdentifier
            }) {
                toolbar.removeItem(at: index)
            }
        }
    }
}

@MainActor
final class SidebarViewController: NSViewController,
    NSOutlineViewDataSource, NSOutlineViewDelegate
{
    var onOpenFile: ((URL) -> Void)?
    private let outlineView = NSOutlineView()
    private var tree: FileTreeModel?

    override func loadView() {
        let column = NSTableColumn(identifier: .init("File"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        view = scrollView
    }

    func display(_ tree: FileTreeModel?) {
        self.tree = tree
        loadViewIfNeeded()
        outlineView.reloadData()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        (item as? FileTreeNode)?.children.count ?? tree?.children.count ?? 0
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        (item as? FileTreeNode)?.children[index] ?? tree!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileTreeNode)?.isDirectory == true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileTreeCell")
        if let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView
        {
            cell.textField?.stringValue = node.name
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: node.name)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard outlineView.selectedRow >= 0,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? FileTreeNode,
              !node.isDirectory
        else { return }
        onOpenFile?(node.url)
    }
}

@MainActor
final class ReaderViewController: NSViewController {
    private let label = NSTextField(labelWithString: "Open a project to begin")

    override func loadView() {
        let container = NSView()
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }

    func display(_ file: URL?) {
        loadViewIfNeeded()
        label.stringValue = file?.path ?? "Open a project to begin"
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
