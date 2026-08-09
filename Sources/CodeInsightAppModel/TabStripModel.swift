import CodeInsightReaderCore
import Foundation

@MainActor
public final class TabStripModel {
    public struct Tab {
        package fileprivate(set) var content: TabContent
        public var fileURL: URL? { content.fileURL }
        public fileprivate(set) var scrollByteOffset: UInt32?
        public fileprivate(set) var selectionByteOffset: UInt32?
        package fileprivate(set) var readingSetScrollOffset: Double?
        package fileprivate(set) var readingSetSkippedReasons: [String]

        package var title: String { content.title }

        fileprivate var lastActivated: UInt64
    }

    public private(set) var tabs: [Tab] = []
    public private(set) var activeIndex: Int?
    public private(set) var activeDocument: ReaderDocument?
    public let maximumCount: Int

    public var activeTab: Tab? {
        guard let activeIndex else { return nil }
        return tabs[activeIndex]
    }

    private var activationClock: UInt64 = 0

    public init(maximumCount: Int = 10) {
        precondition(maximumCount > 0)
        self.maximumCount = maximumCount
    }

    public func reset() {
        tabs.removeAll(keepingCapacity: true)
        activeIndex = nil
        activeDocument = nil
        activationClock = 0
    }

    public func open(
        _ file: URL,
        inNewTab: Bool,
        selectionByteOffset: UInt32? = nil
    ) {
        let file = file.standardizedFileURL
        if let existing = tabs.firstIndex(where: {
            $0.fileURL?.standardizedFileURL == file
        }) {
            activate(existing)
            if let selectionByteOffset {
                tabs[existing].selectionByteOffset = selectionByteOffset
            }
            return
        }

        activationClock &+= 1
        let tab = Tab(
            content: .file(file),
            scrollByteOffset: nil,
            selectionByteOffset: selectionByteOffset,
            readingSetScrollOffset: nil,
            readingSetSkippedReasons: [],
            lastActivated: activationClock
        )
        install(tab, inNewTab: inNewTab)
    }

    package func openReadingSet(
        title: String,
        excerpts: [ReadingSetExcerpt],
        skippedReasons: [String] = []
    ) {
        activationClock &+= 1
        let tab = Tab(
            content: .readingSet(title: title, excerpts: excerpts),
            scrollByteOffset: nil,
            selectionByteOffset: nil,
            readingSetScrollOffset: nil,
            readingSetSkippedReasons: skippedReasons,
            lastActivated: activationClock
        )
        install(tab, inNewTab: true)
    }

    private func install(_ tab: Tab, inNewTab: Bool) {
        activeDocument = nil
        if tabs.isEmpty {
            tabs = [tab]
            activeIndex = 0
        } else if inNewTab {
            if tabs.count == maximumCount {
                let lru = tabs.indices.min {
                    tabs[$0].lastActivated < tabs[$1].lastActivated
                }!
                tabs.remove(at: lru)
                if let activeIndex, lru < activeIndex {
                    self.activeIndex = activeIndex - 1
                }
            }
            tabs.append(tab)
            activeIndex = tabs.count - 1
        } else if let activeIndex {
            tabs[activeIndex] = tab
        }
    }

    public func activate(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        if index != activeIndex { activeDocument = nil }
        activationClock &+= 1
        tabs[index].lastActivated = activationClock
        activeIndex = index
    }

    @discardableResult
    public func close(_ index: Int) -> Tab? {
        guard tabs.indices.contains(index), let activeIndex else {
            return activeTab
        }
        tabs.remove(at: index)
        if tabs.isEmpty {
            self.activeIndex = nil
            activeDocument = nil
        } else if index == activeIndex {
            activeDocument = nil
            let next = min(index, tabs.count - 1)
            self.activeIndex = next
            activate(next)
        } else if index < activeIndex {
            self.activeIndex = activeIndex - 1
        }
        return activeTab
    }

    public func selectRelative(_ delta: Int) {
        guard let activeIndex, tabs.count > 1 else { return }
        activate(
            (activeIndex + (delta % tabs.count) + tabs.count) % tabs.count
        )
    }

    public func updateActiveAnchors(
        scrollByteOffset: UInt32?,
        selectionByteOffset: UInt32?
    ) {
        guard let activeIndex else { return }
        tabs[activeIndex].scrollByteOffset = scrollByteOffset
        tabs[activeIndex].selectionByteOffset = selectionByteOffset
    }

    public func updateActiveScroll(_ byteOffset: UInt32?) {
        guard let activeIndex else { return }
        tabs[activeIndex].scrollByteOffset = byteOffset
    }

    public func updateActiveSelection(_ byteOffset: UInt32?) {
        guard let activeIndex else { return }
        tabs[activeIndex].selectionByteOffset = byteOffset
    }

    package func updateActiveReadingSetScroll(_ offset: Double?) {
        guard let activeIndex,
              case .readingSet = tabs[activeIndex].content
        else { return }
        tabs[activeIndex].readingSetScrollOffset = offset
    }

    package func updateActiveReadingSetExcerpt(
        at index: Int,
        to excerpt: ReadingSetExcerpt
    ) {
        guard let activeIndex,
              case .readingSet(let title, var excerpts) = tabs[activeIndex].content,
              excerpts.indices.contains(index)
        else { return }
        excerpts[index] = excerpt
        tabs[activeIndex].content = .readingSet(title: title, excerpts: excerpts)
    }

    public func setActiveDocument(
        _ document: ReaderDocument?,
        for file: URL
    ) {
        guard let activeFile = activeTab?.fileURL else { return }
        if activeFile.standardizedFileURL != file.standardizedFileURL {
            return
        }
        activeDocument = document
    }
}
