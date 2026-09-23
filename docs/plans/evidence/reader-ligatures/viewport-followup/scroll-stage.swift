import AppKit

@MainActor final class ProbeTextView: NSTextView {
    var draws = 0
    override func draw(_ dirtyRect: NSRect) { draws += 1; super.draw(dirtyRect) }
}

@MainActor final class LayoutProbe: NSObject, @preconcurrency NSTextLayoutManagerDelegate {
    var fragments: [NSTextLayoutFragment] = []
    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
        fragments.append(fragment)
        return fragment
    }
}

@main struct Probe {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let source = try String(contentsOfFile: "/Users/siancao/work/ai/vibecoding/codeinsight/fixtures/wrap/f1-ordinary.rs", encoding: .utf8)
        let text = source as NSString
        var starts = [0]
        for i in 0..<text.length where text.character(at: i) == 10 { starts.append(i + 1) }
        let targetLine = Int(CommandLine.arguments[1])!
        let strategy = CommandLine.arguments[2]
        let font = NSFont(name: "FiraCodeRoman-Regular", size: 13)!
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 560, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        scroll.hasVerticalScroller = true
        let view = ProbeTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainerInset = NSSize(width: 10, height: 12)
        view.autoresizingMask = [.width]
        view.frame = scroll.contentView.bounds
        view.textContainer!.widthTracksTextView = true
        view.textContainer!.containerSize = NSSize(width: 560, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        window.contentView = scroll
        let manager = view.textLayoutManager!
        let metrics = LayoutProbe()
        manager.delegate = metrics
        let content = view.textContentStorage!
        let controller = manager.textViewportLayoutController
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.3
        content.performEditingTransaction {
            view.textStorage!.setAttributedString(NSAttributedString(string: source, attributes: [.font:font,.paragraphStyle:style,.ligature:1]))
        }
        window.orderFront(nil)
        func settle() {
            for _ in 0..<3 {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
                controller.layoutViewport()
                view.needsDisplay = true
                window.displayIfNeeded()
            }
        }
        func lineAt(_ offset: Int) -> Int { starts.partitioningIndex { $0 > offset } }
        func snapshot() -> [String:Any] {
            var data: [String:Any] = ["frame":NSStringFromRect(view.frame),"clip":NSStringFromRect(scroll.contentView.bounds),"usage":NSStringFromRect(manager.usageBoundsForTextContainer),"draws":view.draws]
            if let range = controller.viewportRange {
                let low = content.offset(from: content.documentRange.location, to: range.location)
                let high = content.offset(from: content.documentRange.location, to: range.endLocation)
                data["viewportUTF16"] = [low,high]
                data["viewportLines"] = [lineAt(low),lineAt(high)]
                data["containsTarget"] = low <= starts[targetLine-1] && high > starts[targetLine-1]
                var fragments = 0
                manager.enumerateTextLayoutFragments(from: range.location, options: []) { fragment in
                    if fragment.rangeInElement.location.compare(range.endLocation) != .orderedAscending { return false }
                    fragments += 1
                    return true
                }
                data["visibleFragments"] = fragments
            } else { data["viewportUTF16"] = [] }
            return data
        }
        settle()
        let target = content.location(content.documentRange.location, offsetBy: starts[targetLine-1])!
        let wrappedAnchor = controller.relocateViewport(to: target)
        scroll.contentView.scroll(to: NSPoint(x:0,y:wrappedAnchor))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        let wrappedSecond = controller.relocateViewport(to: target)
        scroll.contentView.scroll(to: NSPoint(x:0,y:wrappedSecond))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        let before = snapshot()
        metrics.fragments.removeAll()
        let started = Date()
        var stages: [String:Double] = [:]
        func mark(_ label: String) { stages[label] = Date().timeIntervalSince(started)*1000 }
        scroll.hasHorizontalScroller = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.autoresizingMask.remove(.width)
        view.textContainer!.widthTracksTextView = false
        view.textContainer!.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if strategy != "natural" { manager.invalidateLayout(for: content.documentRange) }
        mark("containerAndInvalidation")
        var relocated: CGFloat? = nil
        if strategy != "usage" { relocated = controller.relocateViewport(to: target) }
        mark("firstRelocate")
        let usage = manager.usageBoundsForTextContainer
        mark("usageBounds")
        if !usage.isEmpty, !usage.isNull {
            // Probe: retain existing frame, isolate native resize work.
        }
        scroll.tile()
        mark("tile")
        if let relocated {
            scroll.contentView.scroll(to:NSPoint(x:0,y:relocated))
            mark("clipScroll")
            scroll.reflectScrolledClipView(scroll.contentView)
            mark("reflect")
        }
        mark("resizeScroll")
        let immediate = snapshot()
        mark("immediateSnapshot")
        if strategy == "twice" || strategy == "natural" {
            settle()
            relocated = controller.relocateViewport(to: target)
            scroll.contentView.scroll(to: NSPoint(x:0,y:relocated!))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        settle()
        var result: [String:Any] = ["strategy":strategy,"targetLine":targetLine,"font":font.fontName,"wrappedRelocateReturn":wrappedAnchor,"before":before,"immediate":immediate,"after":snapshot(),"ms":Date().timeIntervalSince(started)*1000]
        result["stagesMs"] = stages
        result["createdFragments"] = metrics.fragments.count
        result["fragmentStates"] = Dictionary(grouping: metrics.fragments, by: {String($0.state.rawValue)}).mapValues(\.count)
        result["unwrappedRelocateReturn"] = relocated as Any?
        let data = try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
        window.close()
    }
}

extension Array where Element == Int {
    func partitioningIndex(where predicate:(Int)->Bool) -> Int {
        var low=0, high=count
        while low<high { let mid=(low+high)/2; if predicate(self[mid]) { high=mid } else { low=mid+1 } }
        return low
    }
}
