import AppKit
import CryptoKit
import Foundation

// NSTextContentManager.h:50-51 specifies the PRECEDING element for reverse
// enumeration, including when the location lies inside an element.
private func chunkEnumerationStart(_ ranges: [NSRange], offset: Int, length: Int, reverse: Bool) -> Int {
    var low = 0, high = ranges.count
    while low < high {
        let middle = (low + high) / 2
        if NSMaxRange(ranges[middle]) <= offset { low = middle + 1 }
        else { high = middle }
    }
    return reverse ? low - 1 : (length == 0 ? 0 : low)
}

private func checkEnumerationBoundaries() {
    let ranges = [NSRange(location: 0, length: 4), NSRange(location: 4, length: 4), NSRange(location: 8, length: 4)]
    // -1 / count are intentional sentinels: no element can be yielded.
    let cases: [(offset: Int, forward: Int, reverse: Int)] = [
        (0, 0, -1), (2, 0, -1), (4, 1, 0), (6, 1, 0), (8, 2, 1), (10, 2, 1), (12, 3, 2)
    ]
    for item in cases {
        precondition(chunkEnumerationStart(ranges, offset: item.offset, length: 12, reverse: false) == item.forward)
        precondition(chunkEnumerationStart(ranges, offset: item.offset, length: 12, reverse: true) == item.reverse)
    }
    // This provider deliberately represents an empty document with one empty
    // paragraph; either enumeration direction may yield that sentinel element.
    let empty = [NSRange(location: 0, length: 0)]
    precondition(chunkEnumerationStart(empty, offset: 0, length: 0, reverse: false) == 0)
    precondition(chunkEnumerationStart(empty, offset: 0, length: 0, reverse: true) == 0)
    print("PASS: 7 nonempty boundary cases and the empty-document sentinel; no native window created")
}

/// Explicit public paragraph ranges: storage's factory does not populate them
/// for elements returned by this custom provider (see ranges-factory.json).
final class ChunkParagraph: NSTextParagraph {
    private let contentRange: NSTextRange
    private let separatorRange: NSTextRange
    override var paragraphContentRange: NSTextRange? { contentRange }
    override var paragraphSeparatorRange: NSTextRange? { separatorRange }

    init?(text: NSAttributedString, range: NSTextRange, manager: NSTextContentManager) {
        var contentLength = 0
        (text.string as NSString).getParagraphStart(nil, end: nil, contentsEnd: &contentLength,
                                                    for: NSRange(location: 0, length: text.length))
        guard let end = manager.location(range.location, offsetBy: contentLength),
              let content = NSTextRange(location: range.location, end: end),
              let separator = NSTextRange(location: end, end: range.endLocation) else { return nil }
        contentRange = content
        separatorRange = separator
        super.init(attributedString: text)
        textContentManager = manager
        elementRange = range
    }
}

/// Experimental provider, confined to this standalone probe.
/// Chunk boundaries never insert characters. Runtime geometry equivalence is NOT assumed.
final class ChunkedStorage: NSTextContentStorage {
    let chunkUnits: Int
    private(set) var ranges: [NSRange] = []
    private var paragraphs: [Int: NSTextParagraph] = [:]
    private(set) var enumerationCalls = 0
    private(set) var elementsReturned = 0
    private(set) var materializedUnits = 0

    init(text: NSAttributedString, chunkUnits: Int) {
        self.chunkUnits = chunkUnits
        super.init()
        textStorage = NSTextStorage(attributedString: text)
        let string = text.string as NSString
        var offset = 0
        while offset < string.length {
            let naturalEnd = NSMaxRange(string.paragraphRange(for: NSRange(location: offset, length: 0)))
            let nominalEnd = min(naturalEnd, offset + chunkUnits)
            let end = NSMaxRange(string.rangeOfComposedCharacterSequence(at: nominalEnd - 1))
            ranges.append(NSRange(location: offset, length: end - offset))
            offset = end
        }
        if ranges.isEmpty { ranges = [NSRange(location: 0, length: 0)] }
    }

    required init?(coder: NSCoder) { fatalError("Probe does not archive content") }

    func discardAfterInvalidation() { paragraphs.removeAll() }

    override func enumerateTextElements(from location: (any NSTextLocation)?,
                                       options: NSTextContentManager.EnumerationOptions = [],
                                       using block: (NSTextElement) -> Bool) -> (any NSTextLocation)? {
        enumerationCalls += 1
        let reverse = options.contains(.reverse)
        let offset = location.map { self.offset(from: documentRange.location, to: $0) }
            ?? (reverse ? textStorage!.length : 0)
        guard offset != NSNotFound, offset >= 0, offset <= textStorage!.length else { return nil }
        var index = chunkEnumerationStart(ranges, offset: offset, length: textStorage!.length, reverse: reverse)
        var edge: (any NSTextLocation)?
        while ranges.indices.contains(index) {
            let range = ranges[index]
            guard let start = self.location(documentRange.location, offsetBy: range.location),
                  let end = self.location(start, offsetBy: range.length),
                  let elementRange = NSTextRange(location: start, end: end) else { break }
            let paragraph: NSTextParagraph
            if let cached = paragraphs[index] { paragraph = cached }
            else {
                guard let created = ChunkParagraph(text: textStorage!.attributedSubstring(from: range),
                                                   range: elementRange, manager: self) else { break }
                paragraph = created
                paragraphs[index] = paragraph
                materializedUnits += range.length
            }
            elementsReturned += 1
            edge = reverse ? start : end
            if !block(paragraph) { break }
            index += reverse ? -1 : 1
        }
        return edge
    }
}

@MainActor
func run() throws {
    let arguments = CommandLine.arguments
    func option(_ name: String, default value: String? = nil) -> String? {
        guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return value }
        return arguments[i + 1]
    }
    guard let mode = option("--mode"), ["ordinary", "chunked"].contains(mode),
          let path = option("--fixture"), let output = option("--out") else {
        throw NSError(domain: "Probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "--mode ordinary|chunked --fixture PATH --out JSON [--chunk-units 4096] [--keep-open yes]"])
    }
    let chunkUnits = max(16, Int(option("--chunk-units", default: "4096")!) ?? 4096)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let source = String(data: bytes, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
    let string = source as NSString
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let attributed = NSAttributedString(string: source, attributes: [.font: font, .ligature: 1])
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let firstStart = ContinuousClock.now
    let storage: NSTextContentStorage
    if mode == "chunked" { storage = ChunkedStorage(text: attributed, chunkUnits: chunkUnits) }
    else { storage = NSTextContentStorage(); storage.textStorage = NSTextStorage(attributedString: attributed) }
    if option("--diagnose-elements") == "yes" {
        var rows: [[String: Any]] = []
        storage.enumerateTextElements(from: nil) { element in
            let paragraph = element as? NSTextParagraph
            rows.append(["element": String(describing: element.elementRange),
                         "content": String(describing: paragraph?.paragraphContentRange),
                         "separator": String(describing: paragraph?.paragraphSeparatorRange),
                         "utf16": paragraph?.attributedString.length ?? -1])
            return rows.count < 5
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
        return
    }
    let manager = NSTextLayoutManager()
    let container = NSTextContainer(size: NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude))
    storage.addTextLayoutManager(manager)
    storage.primaryTextLayoutManager = manager
    manager.textContainer = container
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), textContainer: container)
    view.isEditable = false
    view.isSelectable = true
    view.isVerticallyResizable = true
    view.isHorizontallyResizable = false
    view.minSize = NSSize(width: 0, height: 0)
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    container.heightTracksTextView = false
    container.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
    view.autoresizingMask = [NSView.AutoresizingMask.width]
    container.widthTracksTextView = true
    let scroll = NSScrollView(frame: view.frame)
    scroll.hasVerticalScroller = true
    scroll.documentView = view
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "S8a \(mode): standalone fixture"
    window.contentView = scroll
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)

    func paint() {
        window.layoutIfNeeded()
        manager.textViewportLayoutController.layoutViewport()
        window.displayIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) {
            view.cacheDisplay(in: view.visibleRect, to: bitmap)
        }
    }
    paint()
    let firstDuration = firstStart.duration(to: .now)
    let fontStart = ContinuousClock.now
    storage.performEditingTransaction {
        manager.invalidateLayout(for: storage.documentRange)
        (storage as? ChunkedStorage)?.discardAfterInvalidation()
        storage.textStorage!.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 17, weight: .regular),
                                          range: NSRange(location: 0, length: string.length))
    }
    paint()
    let fontDuration = fontStart.duration(to: .now)
    func milliseconds(_ value: Duration) -> Double {
        let c = value.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    // Same boundary samples for both modes; correctness probes run AFTER timing.
    var boundaries: [Int] = []
    var offset = 0
    while offset < string.length {
        let end = NSMaxRange(string.rangeOfComposedCharacterSequence(at: min(string.length, offset + chunkUnits) - 1))
        if end < string.length { boundaries.append(end) }
        offset = end
    }
    let sampled = Array(boundaries.prefix(4))
    var selectionChecks: [[String: Any]] = []
    var positions = [0, string.length]
    for boundary in sampled {
        let proposed = NSRange(location: max(0, boundary - 4), length: min(string.length, boundary + 4) - max(0, boundary - 4))
        let range = string.rangeOfComposedCharacterSequences(for: proposed)
        view.setSelectedRange(range)
        let pasteboard = NSPasteboard.withUniqueName()
        let writable = view.writablePasteboardTypes
        pasteboard.declareTypes(writable, owner: nil)
        let copied = view.writeSelection(to: pasteboard, types: writable)
        let expected = string.substring(with: range)
        let actual = pasteboard.string(forType: .string)
        selectionChecks.append(["range": [range.location, range.length],
                                "writableTypes": writable.map(\.rawValue),
                                "writeReturned": copied,
                                "copiedUTF8Bytes": actual.map { Array($0.utf8) } ?? [],
                                "expectedUTF8Bytes": Array(expected.utf8),
                                "nativeCopyMatches": copied && actual == expected,
                                "axSelectedTextMatches": view.accessibilitySelectedText() == expected,
                                "axStringForRangeMatches": view.accessibilityString(for: range) == expected])
        positions += [range.location, boundary, NSMaxRange(range)]
    }
    var geometry: [[String: Any]] = []
    for index in Set(positions).sorted() {
        let characterRange = string.length == 0 ? NSRange(location: 0, length: 0)
            : string.rangeOfComposedCharacterSequence(at: min(index, string.length - 1))
        guard let location = storage.location(storage.documentRange.location, offsetBy: characterRange.location),
              let end = storage.location(location, offsetBy: characterRange.length),
              let range = NSTextRange(location: location, end: end) else { continue }
        manager.ensureLayout(for: range)
        let selection = NSRange(location: index, length: 0)
        view.setSelectedRange(selection)
        view.scrollRangeToVisible(selection)
        var local = NSRect.zero
        let deadline = Date(timeIntervalSinceNow: 1)
        repeat {
            paint()
            let rect = view.firstRect(forCharacterRange: selection, actualRange: nil)
            local = view.convert(window.convertFromScreen(rect), from: nil)
            if local.height > 0, view.visibleRect.intersects(local.insetBy(dx: -1, dy: 0)) { break }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
        } while Date() < deadline
        geometry.append(["utf16": index, "rect": [local.minX, local.minY, local.width, local.height],
                         "visible": view.visibleRect.intersects(local.insetBy(dx: -1, dy: 0)),
                         "clip": [scroll.contentView.bounds.minX, scroll.contentView.bounds.minY],
                         "documentSize": [view.frame.width, view.frame.height],
                         "containerSize": [container.size.width, container.size.height],
                         "usageBounds": [manager.usageBoundsForTextContainer.width, manager.usageBoundsForTextContainer.height]])
    }
    view.setSelectedRange(NSRange(location: string.length, length: 0))
    let result: [String: Any] = [
        "status": "measured_candidate_not_accepted", "mode": mode,
        "fixtureSHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
        "sourceUTF16": string.length, "chunkUnits": chunkUnits,
        "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        "font": font.fontName, "viewport": [scroll.contentView.bounds.width, scroll.contentView.bounds.height],
        "sourceUnchanged": view.string == source, "textKit2Present": view.textLayoutManager != nil,
        "expectedContentManager": manager.textContentManager === storage,
        "eofSelectionMatches": view.selectedRange() == NSRange(location: string.length, length: 0),
        "axCharacterCountMatches": view.accessibilityNumberOfCharacters() == string.length,
        "crossChunkSelections": selectionChecks, "geometry": geometry,
        "initialSetupAndDrawMs": milliseconds(firstDuration), "fontAndDrawMs": milliseconds(fontDuration),
        "enumerationCalls": (storage as? ChunkedStorage)?.enumerationCalls ?? NSNull(),
        "elementsReturned": (storage as? ChunkedStorage)?.elementsReturned ?? NSNull(),
        "materializedElementUTF16": (storage as? ChunkedStorage)?.materializedUnits ?? NSNull(),
        "manualDragShiftVoiceOver": "not_run", "performanceAcceptance": "not_run"
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output), options: .atomic)
    if option("--keep-open") == "yes" { app.run() }
    window.close()
}
if CommandLine.arguments.contains("--check-enumeration") {
    checkEnumerationBoundaries()
} else {
    MainActor.assumeIsolated {
        do { try run() }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
}
