import AppKit
import CodeInsightAppModel
import Observation

@MainActor
final class SymbolSearchPanel: NSWindowController,
    NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate
{
    private let appModel: AppModel
    private let panelModel = SymbolSearchPanelModel()
    private let input = NSTextField()
    private let tableView = NSTableView()
    private let onOpen: (URL, UInt32) -> Void
    private var debounceTask: Task<Void, Never>?

    init(appModel: AppModel, onOpen: @escaping (URL, UInt32) -> Void) {
        self.appModel = appModel
        self.onOpen = onOpen
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        super.init(window: panel)
        configureView()
        observe()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(relativeTo owner: NSWindow?) {
        panelModel.reset()
        input.stringValue = ""
        guard let panel = window else { return }
        if let owner {
            let x = owner.frame.midX - panel.frame.width / 2
            let y = owner.frame.maxY - panel.frame.height - 72
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        refreshProjectState()
        panel.makeFirstResponder(input)
    }

    func refreshProjectState() {
        guard window?.isVisible == true else { return }
        panelModel.updateQuery(
            input.stringValue,
            projectState: appModel.projectState,
            currentPath: selectedProjectPath
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        panelModel.rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard panelModel.rows.indices.contains(row) else { return nil }
        switch panelModel.rows[row] {
        case let .placeholder(message):
            let label = NSTextField(labelWithString: message)
            label.textColor = .secondaryLabelColor
            return label
        case let .result(name, hit):
            let cell = NSTableCellView()
            let icon = NSImageView(image: symbolImage(for: String(describing: hit.facet.kind)))
            icon.translatesAutoresizingMaskIntoConstraints = false

            let nameLabel = NSTextField(labelWithAttributedString: styledName(
                name,
                ranges: hit.matchRanges
            ))
            nameLabel.lineBreakMode = .byTruncatingTail
            let pathLabel = NSTextField(
                labelWithString: "\(hit.path):\(hit.line):\(hit.column)"
            )
            pathLabel.textColor = .secondaryLabelColor
            pathLabel.font = .systemFont(ofSize: 11)
            let labels = NSStackView(views: [nameLabel, pathLabel])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 1
            labels.translatesAutoresizingMaskIntoConstraints = false

            cell.addSubview(icon)
            cell.addSubview(labels)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 18),
                icon.heightAnchor.constraint(equalToConstant: 18),
                labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        42
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if tableView.selectedRow >= 0 {
            panelModel.select(tableView.selectedRow)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        debounceTask?.cancel()
        let query = input.stringValue
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, let self else { return }
            self.panelModel.updateQuery(
                query,
                projectState: self.appModel.projectState,
                currentPath: self.selectedProjectPath
            )
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            panelModel.selectPrevious()
        case #selector(NSResponder.moveDown(_:)):
            panelModel.selectNext()
        case #selector(NSResponder.insertNewline(_:)):
            openSelection()
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
        default:
            return false
        }
        return true
    }

    private var selectedProjectPath: String? {
        guard let root = appModel.fileTree?.root,
              let file = appModel.selectedFile,
              file.pathComponents.starts(with: root.pathComponents)
        else { return nil }
        return file.pathComponents.dropFirst(root.pathComponents.count)
            .joined(separator: "/")
    }

    private func configureView() {
        input.placeholderString = "Open symbol"
        input.delegate = self
        input.font = .systemFont(ofSize: 15)
        input.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("Symbol"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowSizeStyle = .custom
        tableView.intercellSpacing = .zero

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(input)
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            input.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            input.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            input.heightAnchor.constraint(equalToConstant: 32),
            scrollView.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.contentView = content
    }

    private func observe() {
        withObservationTracking {
            _ = panelModel.rows
            _ = panelModel.selectedIndex
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tableView.reloadData()
                if let selected = self.panelModel.selectedIndex {
                    self.tableView.selectRowIndexes([selected], byExtendingSelection: false)
                    self.tableView.scrollRowToVisible(selected)
                } else {
                    self.tableView.deselectAll(nil)
                }
                self.observe()
            }
        }
    }

    private func openSelection() {
        guard let request = panelModel.openSelection(),
              let root = appModel.fileTree?.root
        else { return }
        let file = root.appendingPathComponent(request.path)
        dismiss()
        onOpen(file, request.byteOffset)
    }

    private func dismiss() {
        debounceTask?.cancel()
        panelModel.reset()
        window?.orderOut(nil)
    }

    private func styledName(_ name: String, ranges: [Range<Int>]) -> NSAttributedString {
        let value = NSMutableAttributedString(
            string: name,
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        )
        for range in ranges where range.lowerBound >= 0 && range.upperBound <= value.length {
            value.addAttribute(
                .font,
                value: NSFont.boldSystemFont(ofSize: 13),
                range: NSRange(location: range.lowerBound, length: range.count)
            )
        }
        return value
    }

    private func symbolImage(for kind: String) -> NSImage {
        let name: String
        switch kind {
        case "rustFn", "rustMethod": name = "function"
        case "rustStruct": name = "s.square"
        case "rustEnum": name = "list.bullet.rectangle"
        case "rustTrait": name = "t.square"
        case "rustField": name = "square.text.square"
        default: name = "circle"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: kind)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: kind)!
    }
}
