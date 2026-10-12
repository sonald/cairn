import AppKit
import Foundation

// Standalone TextKit 2 probe for inline hints and between-line cards.
// It is NOT Cairn's ReaderTextView: no projection, no rendering-attribute
// validator, no viewport restore. It answers NSTextView/TextKit questions only.

setbuf(stdout, nil)
let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}
let outDir = option("--out") ?? FileManager.default.currentDirectoryPath
let mode = arguments.count > 1 ? arguments[1] : "all"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
if mode != "demo" {
    DispatchQueue.global().asyncAfter(deadline: .now() + 180) { fputs("TIMEOUT\n", stderr); exit(3) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
let hintFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
let lineHeightMultiple: CGFloat = 1.3 // Cairn's default
var results: [String: Any] = [:]

func ms(_ body: () -> Void) -> Double {
    let start = ContinuousClock.now
    body()
    let d = start.duration(to: .now).components
    return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
}
func r(_ v: CGFloat) -> Double { (Double(v) * 100).rounded() / 100 }
func spin(_ seconds: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

final class ProbeTextView: NSTextView {
    var backgroundDraw: ((NSRect) -> Void)?
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        backgroundDraw?(rect)
    }
}

/// One window with a TextKit 2 text view configured like Cairn's reader.
final class Host {
    let window: NSWindow
    let scroll: NSScrollView
    let text: ProbeTextView
    var layout: NSTextLayoutManager { text.textLayoutManager! }
    var content: NSTextContentManager { layout.textContentManager! }

    init(_ string: NSAttributedString, wrap: Bool, size: NSSize = NSSize(width: 900, height: 600)) {
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        text = ProbeTextView(usingTextLayoutManager: true)
        precondition(text.textLayoutManager != nil, "TextKit 2 expected")
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.textContainer!.lineFragmentPadding = 0
        text.isVerticallyResizable = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.frame = NSRect(origin: .zero, size: scroll.contentSize)
        if wrap {
            text.autoresizingMask = [.width]
            text.textContainer!.widthTracksTextView = true
        } else {
            scroll.hasHorizontalScroller = true
            text.isHorizontallyResizable = true
            text.textContainer!.widthTracksTextView = false
            text.textContainer!.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                              height: CGFloat.greatestFiniteMagnitude)
        }
        scroll.documentView = text
        window.contentView = scroll
        text.textStorage!.setAttributedString(string)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        settle()
    }

    func settle() {
        layout.textViewportLayoutController.layoutViewport()
        window.displayIfNeeded()
        spin(0.02)
    }

    func textRange(_ range: NSRange) -> NSTextRange? {
        guard let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length) else { return nil }
        return NSTextRange(location: start, end: end)
    }

    /// Segment frames in text-view coordinates.
    func rects(_ range: NSRange, type: NSTextLayoutManager.SegmentType = .standard) -> [NSRect] {
        guard let tr = textRange(range) else { return [] }
        layout.ensureLayout(for: tr)
        var out: [NSRect] = []
        layout.enumerateTextSegments(in: tr, type: type, options: []) { _, frame, _, _ in
            out.append(frame.offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y))
            return true
        }
        return out
    }

    func fragment(at index: Int) -> NSTextLayoutFragment? {
        guard let loc = content.location(content.documentRange.location, offsetBy: index) else { return nil }
        layout.ensureLayout(for: NSTextRange(location: loc))
        return layout.textLayoutFragment(for: loc)
    }

    /// Top of the layout fragment holding `index`, in text-view coordinates.
    func lineTop(_ index: Int) -> CGFloat? {
        fragment(at: index).map { $0.layoutFragmentFrame.minY + text.textContainerOrigin.y }
    }

    /// Visual line (0-based within its paragraph) that contains `index`.
    func visualLine(_ index: Int) -> Int? {
        guard let f = fragment(at: index) else { return nil }
        let start = content.offset(from: content.documentRange.location, to: f.rangeInElement.location)
        return f.textLineFragments.firstIndex { NSLocationInRange(index - start, $0.characterRange) }
            ?? (index - start >= (f.textLineFragments.last.map { NSMaxRange($0.characterRange) } ?? 0)
                ? f.textLineFragments.count - 1 : nil)
    }

    /// Exact top: lay out from the document start so no estimate is involved.
    func exactLineTop(_ index: Int) -> CGFloat? {
        guard let loc = content.location(content.documentRange.location, offsetBy: index),
              let range = NSTextRange(location: content.documentRange.location, end: loc) else { return nil }
        layout.ensureLayout(for: range)
        return lineTop(index)
    }

    func toWindow(_ p: NSPoint) -> NSPoint { text.convert(p, to: nil) }

    func mouse(_ type: NSEvent.EventType, _ viewPoint: NSPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: toWindow(viewPoint), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// A real click: the queued mouse-up ends NSTextView's tracking loop.
    func click(_ p: NSPoint) {
        app.postEvent(mouse(.leftMouseUp, p), atStart: false)
        window.sendEvent(mouse(.leftMouseDown, p))
        spin(0.01)
    }

    /// A real drag: queued drags and mouse-up, then the mouse-down that starts tracking.
    func drag(_ a: NSPoint, _ b: NSPoint) {
        for i in 1...10 {
            let t = CGFloat(i) / 10
            app.postEvent(mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)), atStart: false)
        }
        app.postEvent(mouse(.leftMouseUp, b), atStart: false)
        window.sendEvent(mouse(.leftMouseDown, a))
        spin(0.01)
    }

    func png(_ name: String, rect: NSRect? = nil) {
        settle()
        let view = window.contentView!
        let area = rect.map { text.convert($0, to: view) } ?? view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: area) else { return }
        view.cacheDisplay(in: area, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    }

    func close() { window.close() }
}

func codeAttributes(_ font: NSFont = codeFont) -> [NSAttributedString.Key: Any] {
    let style = NSMutableParagraphStyle()
    style.lineHeightMultiple = lineHeightMultiple
    return [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: style]
}

// MARK: - 1. Inline hints

let inlineSource = """
fn main() {
    let items = load();
    let total = compute(items, 42);
    println!("{}", total);
}

"""
/// (UTF-16 offset in source, hint text). The hint sits before that offset.
func inlineHints(_ source: String) -> [(Int, String)] {
    let s = source as NSString
    let line = s.range(of: "let total = compute(items, 42);")
    return [
        (line.location + 9, ": usize"),                                   // after `total`
        (s.range(of: "items, 42", range: NSRange(location: line.location, length: line.length)).location, "values:"),
        (s.range(of: "42);").location, "limit:"),
    ]
}
/// The kerned char's segment ends mid-gap (measured), so place the hint after its own advance.
func kernHintBox(_ host: Host, anchor d: Int, hint: String) -> NSRect? {
    guard let seg = host.rects(NSRange(location: d, length: 1)).first,
          let font = host.text.textStorage!.attribute(.font, at: d, effectiveRange: nil) as? NSFont else { return nil }
    let glyph = ((host.text.string as NSString).substring(with: NSRange(location: d, length: 1)) as NSString)
        .size(withAttributes: [.font: font]).width
    let baseline = baselineY(host, d) ?? seg.maxY
    return NSRect(x: seg.minX + glyph, y: baseline - hintFont.ascender - 2,
                  width: hintWidth(hint), height: hintFont.ascender - hintFont.descender + 4)
}
/// Baseline of the visual line holding display index `d`, in text-view coordinates.
func baselineY(_ host: Host, _ d: Int) -> CGFloat? {
    guard let f = host.fragment(at: d) else { return nil }
    let start = host.content.offset(from: host.content.documentRange.location, to: f.rangeInElement.location)
    guard let line = f.textLineFragments.first(where: { NSLocationInRange(d - start, $0.characterRange) })
            ?? f.textLineFragments.last else { return nil }
    return f.layoutFragmentFrame.minY + line.typographicBounds.minY + line.glyphOrigin.y + host.text.textContainerOrigin.y
}
func drawHint(_ hint: String, in box: NSRect) {
    NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
    NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0), xRadius: 3, yRadius: 3).fill()
    (hint as NSString).draw(at: NSPoint(x: box.minX + 3, y: box.minY + 2),
                            withAttributes: [.font: hintFont, .foregroundColor: NSColor.secondaryLabelColor])
}
func hintWidth(_ hint: String) -> CGFloat {
    ceil((hint as NSString).size(withAttributes: [.font: hintFont]).width) + 6
}

final class HintView: NSView {
    static var passesClicksThrough = true
    let hint: String
    init(hint: String) { self.hint = hint; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        // Opaque base: TextKit draws the default attachment icon under a translucent view.
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 1), xRadius: 3, yRadius: 3).fill()
        (hint as NSString).draw(at: NSPoint(x: 3, y: (bounds.height - hintFont.ascender + hintFont.descender) / 2 - 1),
                                withAttributes: [.font: hintFont, .foregroundColor: NSColor.secondaryLabelColor])
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        HintView.passesClicksThrough ? nil : super.hitTest(point)
    }
}

final class HintAttachment: NSTextAttachment {
    let hint: String
    init(hint: String) {
        self.hint = hint
        super.init(data: nil, ofType: "probe.hint")
        allowsTextAttachmentView = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewProvider(for parentView: NSView?, location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let p = HintProvider(textAttachment: self, parentView: parentView,
                             textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class HintProvider: NSTextAttachmentViewProvider {
    override func loadView() { view = HintView(hint: (textAttachment as! HintAttachment).hint) }
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        let h = ceil(hintFont.ascender - hintFont.descender) + 4
        return CGRect(x: 0, y: codeFont.descender - 1, width: hintWidth((textAttachment as! HintAttachment).hint), height: h)
    }
}

enum InlineVariant: String { case kern, attachment }

/// Display string plus display→source offset mapping for one variant.
struct InlineDocument {
    let attributed: NSAttributedString
    let placeholders: [Int] // display offsets of inserted U+FFFC (attachment variant)
    let gapAnchors: [(display: Int, hint: String)] // kern variant: char carrying the gap

    func source(ofDisplay d: Int) -> Int { d - placeholders.filter { $0 < d }.count }
    func display(ofSource s: Int) -> Int {
        var d = s
        for p in placeholders where p <= d { d += 1 }
        return d
    }
    func sourceString(_ display: NSRange) -> String {
        (attributed.string as NSString).substring(with: display).replacingOccurrences(of: "\u{FFFC}", with: "")
    }
}

func makeInline(_ variant: InlineVariant, font: NSFont = codeFont) -> InlineDocument {
    let hints = inlineHints(inlineSource)
    let out = NSMutableAttributedString(string: inlineSource, attributes: codeAttributes(font))
    switch variant {
    case .kern:
        for (offset, hint) in hints {
            out.addAttribute(.kern, value: hintWidth(hint), range: NSRange(location: offset - 1, length: 1))
        }
        return InlineDocument(attributed: out, placeholders: [], gapAnchors: hints.map { ($0.0 - 1, $0.1) })
    case .attachment:
        var placeholders: [Int] = []
        for (offset, hint) in hints.sorted(by: { $0.0 > $1.0 }) {
            let a = NSMutableAttributedString(attachment: HintAttachment(hint: hint))
            a.addAttributes(codeAttributes(font), range: NSRange(location: 0, length: 1))
            out.insert(a, at: offset)
            placeholders.append(offset)
        }
        // Earlier insertions shift later ones; recompute display offsets.
        let display = (out.string as NSString)
        var found: [Int] = []
        var i = 0
        while i < display.length {
            if display.character(at: i) == 0xFFFC { found.append(i) }
            i += 1
        }
        return InlineDocument(attributed: out, placeholders: found, gapAnchors: [])
    }
}

func runInline() {
    var report: [String: Any] = [:]
    let sourceNS = inlineSource as NSString
    let hints = inlineHints(inlineSource)
    let anchorHint = hints[1] // "values:" between `(` and `items`
    for variant in [InlineVariant.kern, .attachment] {
        var v: [String: Any] = [:]
        let doc = makeInline(variant)
        let host = Host(doc.attributed, wrap: false)
        if variant == .kern {
            host.text.backgroundDraw = { _ in
                for (d, hint) in doc.gapAnchors {
                    guard let box = kernHintBox(host, anchor: d, hint: hint) else { continue }
                    drawHint(hint, in: box)
                }
            }
        }
        host.settle()

        // Gap geometry: where is the hint box, and how wide is the anchor char.
        let gapDisplay: NSRange
        switch variant {
        case .kern: gapDisplay = NSRange(location: anchorHint.0 - 1, length: 1)
        case .attachment: gapDisplay = NSRange(location: doc.display(ofSource: anchorHint.0) - 1, length: 1)
        }
        guard let gapRect = host.rects(gapDisplay).first else { continue }
        let hintBox = variant == .kern ? kernHintBox(host, anchor: gapDisplay.location, hint: anchorHint.1)! : gapRect
        v["anchorSegmentWidth"] = r(gapRect.width)
        // Where a range that starts at the hinted boundary (the word `items`) begins.
        let itemsDisplay = NSRange(location: doc.display(ofSource: anchorHint.0), length: 5)
        if let itemsRect = host.rects(itemsDisplay).first {
            v["nextWordRangeMinX"] = r(itemsRect.minX)
            v["nextWordGlyphMinX"] = r(hintBox.maxX)
        }
        v["hintBox"] = [r(hintBox.minX), r(hintBox.minY), r(hintBox.width), r(hintBox.height)]

        // Insertion index and real clicks across the hint box.
        var samples: [[String: Any]] = []
        for t in [0.1, 0.3, 0.5, 0.7, 0.9] {
            let p = NSPoint(x: hintBox.minX + hintBox.width * t, y: hintBox.midY)
            let insertion = host.text.characterIndexForInsertion(at: p)
            let hitView = host.window.contentView!.hitTest(host.toWindow(p))
            samples.append([
                "x%": Int(t * 100),
                "insertionSource": doc.source(ofDisplay: insertion),
                "hitView": hitView.map { String(describing: type(of: $0)) } ?? "nil",
            ])
        }
        v["boundary"] = ["before": anchorHint.0 - 1, "after": anchorHint.0,
                         "meaning": "source offsets: \(anchorHint.0 - 1) is before `(`... \(anchorHint.0) is `items`"]
        v["clicks"] = samples

        if variant == .attachment {
            // Default NSView hit testing over the attachment view.
            HintView.passesClicksThrough = false
            let p = NSPoint(x: hintBox.midX, y: hintBox.midY)
            let hit = host.window.contentView!.hitTest(host.toWindow(p))
            v["withoutHitTestOverride"] = ["hitView": hit.map { String(describing: type(of: $0)) } ?? "nil"]
            HintView.passesClicksThrough = true
        }

        // Real drag from inside `compute` to inside `42`.
        let line = sourceNS.range(of: "compute(items, 42)")
        let startD = doc.display(ofSource: line.location + 3)
        let endD = doc.display(ofSource: NSMaxRange(line) - 2)
        if let a = host.rects(NSRange(location: startD, length: 1)).first,
           let b = host.rects(NSRange(location: endD, length: 1)).first {
            // A drag selects between the insertion indexes of its two end points.
            let i0 = host.text.characterIndexForInsertion(at: NSPoint(x: a.minX + 1, y: a.midY))
            let i1 = host.text.characterIndexForInsertion(at: NSPoint(x: b.minX + 1, y: b.midY))
            let sel = NSRange(location: min(i0, i1), length: abs(i1 - i0))
            host.window.makeFirstResponder(host.text)
            host.text.setSelectedRange(sel)
            v["drag"] = [
                "displaySelection": [sel.location, sel.length],
                "nativeString": (doc.attributed.string as NSString).substring(with: sel)
                    .replacingOccurrences(of: "\u{FFFC}", with: "<U+FFFC>"),
                "sourceMappedString": doc.sourceString(sel),
            ]
            host.png("inline-\(variant.rawValue)-drag", rect: NSRect(x: 0, y: 0, width: 520, height: 140))
        }

        // Soft wrap around the `: usize` hint after `total`.
        let totalHint = hints[0]
        var wraps: [[String: Any]] = []
        let baseline = Host(NSAttributedString(string: inlineSource, attributes: codeAttributes()), wrap: false)
        let anchorEndX = baseline.rects(NSRange(location: totalHint.0 - 1, length: 1)).first!.maxX
            - baseline.text.textContainerOrigin.x
        let charW = baseline.rects(NSRange(location: totalHint.0 - 1, length: 1)).first!.width
        baseline.close()
        let tw = hintWidth(totalHint.1)
        for (name, width) in [("hintFits", anchorEndX + tw + charW * 0.5), ("hintDoesNotFit", anchorEndX + tw * 0.5)] {
            let wrapHost = Host(doc.attributed, wrap: true)
            if variant == .kern { wrapHost.text.backgroundDraw = host.text.backgroundDraw.map { _ in { rect in
                for (d, hint) in doc.gapAnchors {
                    guard let box = kernHintBox(wrapHost, anchor: d, hint: hint) else { continue }
                    NSColor.systemOrange.withAlphaComponent(0.35).setFill()
                    box.fill()
                }
            } } }
            wrapHost.text.textContainer!.widthTracksTextView = false
            wrapHost.text.textContainer!.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            wrapHost.layout.invalidateLayout(for: wrapHost.content.documentRange)
            wrapHost.settle()
            let tStart = doc.display(ofSource: sourceNS.range(of: "total =").location)
            let afterGap = doc.display(ofSource: totalHint.0)
            var entry: [String: Any] = [
                "containerWidth": r(width),
                "anchorWordLine": wrapHost.visualLine(tStart) ?? -1,
                "charAfterHintLine": wrapHost.visualLine(afterGap) ?? -1,
            ]
            if variant == .attachment {
                entry["attachmentLine"] = wrapHost.visualLine(afterGap - 1) ?? -1
            } else if let box = kernHintBox(wrapHost, anchor: totalHint.0 - 1, hint: totalHint.1) {
                entry["hintBoxMaxX"] = r(box.maxX - wrapHost.text.textContainerOrigin.x)
                entry["exceedsContainer"] = box.maxX - wrapHost.text.textContainerOrigin.x > width + 0.5
            }
            wraps.append([name: entry])
            wrapHost.png("inline-\(variant.rawValue)-wrap-\(name)", rect: NSRect(x: 0, y: 0, width: 420, height: 160))
            wrapHost.close()
        }
        v["wrap"] = wraps

        // Font change: kern is in points, so a stale gap no longer fits the hint.
        let bigger = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
        host.text.textStorage!.addAttribute(.font, value: bigger,
            range: NSRange(location: 0, length: host.text.textStorage!.length))
        host.settle()
        if let seg = host.rects(gapDisplay).first {
            v["afterFontSize16"] = ["anchorSegmentWidth": r(seg.width),
                                    "kernStillPresent": host.text.textStorage!.attribute(.kern, at: gapDisplay.location, effectiveRange: nil) != nil]
        }
        host.png("inline-\(variant.rawValue)-font16", rect: NSRect(x: 0, y: 0, width: 620, height: 160))
        host.close()
        report[variant.rawValue] = v
    }
    results["inline"] = report
}

// MARK: - 2. Between-line cards

let peekSource = (0..<60).map { "    let peek_\(String(format: "%02d", $0)) = definition_line(\($0));" }.joined(separator: "\n")
let cardDocSource = (0..<300).map { i in
    i % 20 == 0 ? "fn function_\(i)() {" : (i % 20 == 19 ? "}" : "    let value_\(String(format: "%03d", i)) = compute(\(i));")
}.joined(separator: "\n") + "\n"
let anchorLine = 120

/// The card: a bordered panel holding its own scrollable, selectable text view.
final class CardView: NSView {
    let scroll = NSScrollView()
    let inner = NSTextView(usingTextLayoutManager: true)
    static var created = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        CardView.created += 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.5).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6
        scroll.hasVerticalScroller = true
        scroll.frame = bounds.insetBy(dx: 6, dy: 6)
        scroll.autoresizingMask = [.width, .height]
        inner.isEditable = false
        inner.isSelectable = true
        inner.isVerticallyResizable = true
        inner.autoresizingMask = [.width]
        inner.frame = NSRect(origin: .zero, size: scroll.contentSize)
        inner.textContainer!.widthTracksTextView = true
        inner.textStorage!.setAttributedString(NSAttributedString(string: peekSource, attributes: codeAttributes()))
        scroll.documentView = inner
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError() }
    // Autoresizing from a collapsed (1pt) start leaves the scroll view empty,
    // so wheel events hit the card and fall through to the outer view.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        scroll.frame = bounds.insetBy(dx: 6, dy: 6)
    }
}

final class CardAttachment: NSTextAttachment {
    var size: NSSize
    var cachedView: CardView?
    var reuseView = false
    var providers = 0
    init(size: NSSize) {
        self.size = size
        super.init(data: nil, ofType: "probe.card")
        allowsTextAttachmentView = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewProvider(for parentView: NSView?, location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        providers += 1
        let p = CardProvider(textAttachment: self, parentView: parentView,
                             textLayoutManager: textContainer?.textLayoutManager, location: location)
        p.tracksTextAttachmentViewBounds = true
        return p
    }
}

final class CardProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        let a = textAttachment as! CardAttachment
        if a.reuseView, let v = a.cachedView { view = v; return }
        let v = CardView(frame: NSRect(origin: .zero, size: a.size))
        a.cachedView = v
        view = v
    }
    override func attachmentBounds(for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation,
                                   textContainer: NSTextContainer?, proposedLineFragment: CGRect,
                                   position: CGPoint) -> CGRect {
        CGRect(origin: .zero, size: (textAttachment as! CardAttachment).size)
    }
}

enum CardVariant: String { case gap, attachment }

/// Common driver over the two card variants.
final class CardHarness {
    let variant: CardVariant
    let host: Host
    var height: CGFloat
    let width: CGFloat = 640
    let margin: CGFloat = 8
    var overlay: CardView?          // gap variant
    var attachment: CardAttachment? // attachment variant
    let anchorParagraph: NSRange    // display range of the anchor line, incl. newline
    let lineAfterCard: Int          // display offset of the first code line after the card

    init(_ variant: CardVariant, height: CGFloat = 200) {
        self.variant = variant
        self.height = height
        let ns = cardDocSource as NSString
        var lineStart = 0
        for _ in 0..<anchorLine { lineStart = NSMaxRange(ns.lineRange(for: NSRange(location: lineStart, length: 0))) }
        let anchor = ns.lineRange(for: NSRange(location: lineStart, length: 0))
        anchorParagraph = anchor
        let doc = NSMutableAttributedString(string: cardDocSource, attributes: codeAttributes())
        switch variant {
        case .gap:
            lineAfterCard = NSMaxRange(anchor)
            host = Host(doc, wrap: true)
        case .attachment:
            let a = CardAttachment(size: NSSize(width: width, height: height))
            attachment = a
            let card = NSMutableAttributedString(attachment: a)
            card.append(NSAttributedString(string: "\n"))
            let style = NSMutableParagraphStyle() // the card line must not get 1.3x height
            style.paragraphSpacingBefore = margin
            style.paragraphSpacing = margin
            style.firstLineHeadIndent = 24
            card.addAttributes([.font: codeFont, .paragraphStyle: style], range: NSRange(location: 0, length: card.length))
            doc.insert(card, at: NSMaxRange(anchor))
            lineAfterCard = NSMaxRange(anchor) + 2
            host = Host(doc, wrap: true)
        }
        if variant == .gap { applyGap() }
        host.settle()
    }

    /// Gap variant: paragraph spacing under the anchor line, card view placed in it.
    func applyGap() {
        let storage = host.text.textStorage!
        let base = storage.attribute(.paragraphStyle, at: anchorParagraph.location, effectiveRange: nil) as! NSParagraphStyle
        let style = base.mutableCopy() as! NSMutableParagraphStyle
        style.paragraphSpacing = height + 2 * margin
        storage.addAttribute(.paragraphStyle, value: style, range: anchorParagraph)
        host.layout.textViewportLayoutController.layoutViewport()
        placeOverlay()
    }

    /// Must run after every layout that can move the anchor line.
    func placeOverlay() {
        guard let f = host.fragment(at: anchorParagraph.location) else { return }
        let bottom = f.layoutFragmentFrame.minY + (f.textLineFragments.last?.typographicBounds.maxY ?? 0)
        let frame = NSRect(x: host.text.textContainerOrigin.x + 24,
                           y: bottom + host.text.textContainerOrigin.y + margin, width: width, height: height)
        if overlay == nil {
            overlay = CardView(frame: frame)
            host.text.addSubview(overlay!)
        }
        overlay!.frame = frame
    }

    func setHeight(_ h: CGFloat) {
        height = h
        switch variant {
        case .gap: applyGap()
        case .attachment:
            attachment!.size.height = h
            let range = NSRange(location: NSMaxRange(anchorParagraph), length: 1)
            host.layout.invalidateLayout(for: host.textRange(range)!)
            host.layout.textViewportLayoutController.layoutViewport()
        }
        host.window.displayIfNeeded()
    }

    var cardView: CardView? { variant == .gap ? overlay : attachment?.cachedView }

    /// Card frame in text-view coordinates.
    var cardFrame: NSRect? {
        guard let v = cardView, v.superview != nil, v.window != nil else { return nil }
        return v.convert(v.bounds, to: host.text)
    }
}

func scrollWheel(_ host: Host, at viewPoint: NSPoint, lines: Int32) -> String {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)!
    let event = NSEvent(cgEvent: cg)!
    // AppKit routes wheel events to the view under the pointer.
    guard let target = host.window.contentView!.hitTest(host.toWindow(viewPoint)) else { return "nil" }
    target.scrollWheel(with: event)
    spin(0.03)
    return String(describing: type(of: target))
}

func runCards() {
    var report: [String: Any] = [:]
    for variant in [CardVariant.gap, .attachment] {
        var v: [String: Any] = [:]
        CardView.created = 0
        let c = CardHarness(variant)
        let host = c.host
        // Bring the card into view.
        let anchorTop = host.lineTop(c.anchorParagraph.location)!
        host.text.scroll(NSPoint(x: 0, y: max(0, anchorTop - 120)))
        host.settle()
        if variant == .gap { c.placeOverlay() }

        let card = c.cardFrame ?? .zero
        let nextTop = host.lineTop(c.lineAfterCard)!
        v["initial"] = ["cardFrame": [r(card.minY), r(card.height)], "nextLineTop": r(nextTop),
                        "cardOverlapsNextLine": card.maxY > nextTop + 0.5,
                        "anchorFragmentHeight": r(host.fragment(at: c.anchorParagraph.location)!.layoutFragmentFrame.height)]
        host.png("card-\(variant.rawValue)-initial")

        // a. Dynamic height 200 → 320.
        let before = host.lineTop(c.lineAfterCard)!
        let t = ms { c.setHeight(320) }
        if variant == .gap { c.placeOverlay() }
        host.settle()
        let after = host.lineTop(c.lineAfterCard)!
        let grown = c.cardFrame ?? .zero
        v["heightChange"] = ["nextLineShift": r(after - before), "expected": 120, "ms": (t * 100).rounded() / 100,
                             "cardHeight": r(grown.height), "cardOverlapsNextLine": grown.maxY > after + 0.5]
        host.png("card-\(variant.rawValue)-grown")

        // b. Reading position: card above the viewport, change its height by -120pt.
        // Measured by the source line at the top of the visible area.
        let refIndex = c.lineAfterCard + 60 * 30 // ~50 lines below the card
        host.text.scroll(NSPoint(x: 0, y: host.lineTop(refIndex)! - 40))
        host.settle()
        func topIndex() -> Int {
            host.text.characterIndexForInsertion(at: NSPoint(x: host.text.textContainerOrigin.x + 2,
                                                             y: host.text.visibleRect.minY + 4))
        }
        func lineNumber(_ i: Int) -> Int {
            (host.text.string as NSString).substring(to: i).filter { $0 == "\n" }.count
                - (variant == .attachment && i > c.anchorParagraph.location ? 1 : 0)
        }
        let anchorIndex = topIndex()
        let anchorOffset = (host.lineTop(anchorIndex) ?? 0) - host.text.visibleRect.minY
        let line0 = lineNumber(anchorIndex)
        host.png("card-\(variant.rawValue)-reading-before", rect: host.text.visibleRect)
        let tShrink = ms {
            c.setHeight(200)
            if variant == .gap { c.placeOverlay() }
        }
        host.settle()
        let line1 = lineNumber(topIndex())
        host.png("card-\(variant.rawValue)-reading-after", rect: host.text.visibleRect)
        // Anchor restore with TextKit's own primitive.
        let controller = host.layout.textViewportLayoutController
        let location = host.content.location(host.content.documentRange.location, offsetBy: anchorIndex)!
        let tRestore = ms {
            let y = controller.relocateViewport(to: location)
            host.text.scroll(NSPoint(x: 0, y: y - anchorOffset))
            controller.layoutViewport()
        }
        host.settle()
        let line2 = lineNumber(topIndex())
        let offset2 = (host.lineTop(topIndex()) ?? 0) - host.text.visibleRect.minY
        host.png("card-\(variant.rawValue)-reading-restored", rect: host.text.visibleRect)
        // Scroll back to the card: did the off-screen shrink apply cleanly?
        host.text.scroll(NSPoint(x: 0, y: max(0, host.lineTop(c.anchorParagraph.location)! - 120)))
        host.settle()
        if variant == .gap { c.placeOverlay() }
        let afterTop = host.lineTop(c.lineAfterCard)!
        let cardNow = c.cardFrame ?? .zero
        v["readingPosition"] = ["topLineBefore": line0, "topLineAfterShrink": line1,
                                "topLineAfterRelocate": line2, "anchorOffsetBefore": r(anchorOffset),
                                "anchorOffsetAfterRelocate": r(offset2),
                                "shrinkMs": (tShrink * 100).rounded() / 100, "relocateMs": (tRestore * 100).rounded() / 100,
                                "cardHeightWhenBack": r(cardNow.height),
                                "cardOverlapsNextLineWhenBack": cardNow.maxY > afterTop + 0.5]

        // c. Focus: click into the card's own text view.
        host.text.scroll(NSPoint(x: 0, y: max(0, host.lineTop(c.anchorParagraph.location)! - 120)))
        host.settle()
        if variant == .gap { c.placeOverlay() }
        host.text.setSelectedRange(NSRange(location: c.anchorParagraph.location + 4, length: 3))
        let outerSelection = host.text.selectedRange()
        if let frame = c.cardFrame, let cv = c.cardView {
            let p = NSPoint(x: frame.minX + 60, y: frame.minY + 30)
            let hit = host.window.contentView!.hitTest(host.toWindow(p))
            // Synthesized clicks are not trusted (see inline); a mouse-down on a
            // selectable text view makes it first responder, so do that directly.
            host.window.makeFirstResponder(cv.inner)
            let firstResponderIsInner = host.window.firstResponder === cv.inner
            let innerBefore = cv.inner.selectedRange()
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: host.window.windowNumber, context: nil,
                                        characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                                        charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                                        isARepeat: false, keyCode: 125)!
            host.window.sendEvent(down)
            spin(0.02)
            // Control: the same synthesized key on the outer view.
            host.window.makeFirstResponder(host.text)
            let outerBefore = host.text.selectedRange()
            host.window.sendEvent(down)
            spin(0.02)
            let outerMoved = host.text.selectedRange() != outerBefore
            host.text.setSelectedRange(outerSelection)
            v["focus"] = [
                "controlOuterCaretMovedByArrow": outerMoved,
                "hitView": hit.map { String(describing: type(of: $0)) } ?? "nil",
                "hitIsInsideCard": hit.map { $0.isDescendant(of: cv) } ?? false,
                "firstResponderIsInnerText": firstResponderIsInner,
                "outerSelectionUnchanged": host.text.selectedRange() == outerSelection,
                "innerCaretMovedByArrow": cv.inner.selectedRange() != innerBefore,
            ]

            // d. Internal scroll: wheel over the card, then past its end.
            let innerClip = cv.scroll.contentView
            let outerY0 = host.text.visibleRect.minY
            let target = scrollWheel(host, at: p, lines: -3)
            let innerY1 = innerClip.bounds.minY
            let outerY1 = host.text.visibleRect.minY
            for _ in 0..<40 { _ = scrollWheel(host, at: p, lines: -5) }
            let innerAtEnd = innerClip.bounds.minY
            let outerAtEnd = host.text.visibleRect.minY
            _ = scrollWheel(host, at: p, lines: -5)
            v["innerScroll"] = [
                "wheelTarget": target,
                "innerMovedOnFirstWheel": innerY1 > 0, "outerMovedOnFirstWheel": outerY1 != outerY0,
                "innerMaxReached": r(innerAtEnd), "outerMovedWhileInnerScrolling": outerAtEnd != outerY0,
                "outerMovedAfterInnerEnd": host.text.visibleRect.minY != outerAtEnd,
            ]
            host.png("card-\(variant.rawValue)-focused")
        }

        // e. Scroll far away and back: is the card view kept?
        let innerOffsetBefore = c.cardView?.scroll.contentView.bounds.minY ?? -1
        let viewBefore = c.cardView.map { ObjectIdentifier($0) }
        host.text.scroll(NSPoint(x: 0, y: host.text.bounds.maxY))
        host.settle()
        let attachedWhileAway = c.cardView?.window != nil
        host.text.scroll(NSPoint(x: 0, y: max(0, host.lineTop(c.anchorParagraph.location)! - 120)))
        host.settle()
        if variant == .gap { c.placeOverlay() }
        v["scrollAwayAndBack"] = [
            "cardViewInWindowWhileAway": attachedWhileAway,
            "sameCardViewAfterReturn": c.cardView.map { ObjectIdentifier($0) } == viewBefore,
            "cardViewsCreated": CardView.created,
            "innerOffsetBefore": r(innerOffsetBefore),
            "innerOffsetAfter": r(c.cardView?.scroll.contentView.bounds.minY ?? -1),
            "providersCreated": c.attachment?.providers ?? 0,
        ]

        // f. Outer selection across the card.
        let selStart = host.text.textStorage!.string.utf16.count > 0 ? c.anchorParagraph.location : 0
        let selEnd = c.lineAfterCard + 20
        host.text.window?.makeFirstResponder(host.text)
        host.text.setSelectedRange(NSRange(location: selStart, length: selEnd - selStart))
        let selected = (host.text.string as NSString).substring(with: host.text.selectedRange())
        v["selectionAcross"] = ["containsPlaceholder": selected.contains("\u{FFFC}"),
                                "selectionSegments": host.rects(host.text.selectedRange(), type: .selection).map { [r($0.minY), r($0.height)] }]
        host.png("card-\(variant.rawValue)-selection")
        host.close()
        report[variant.rawValue] = v
    }
    results["cards"] = report
}

// MARK: - 2b. shouldEnumerate hiding (WWDC-style card as a real paragraph)

final class HideDelegate: NSObject, NSTextContentStorageDelegate {
    var hidden: NSRange?
    var calls = 0
    func textContentManager(_ textContentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement,
                            options: NSTextContentManager.EnumerationOptions = []) -> Bool {
        calls += 1
        guard let hidden, let range = textElement.elementRange else { return true }
        let start = textContentManager.offset(from: textContentManager.documentRange.location, to: range.location)
        return start != hidden.location
    }
}

func runEnumerate() {
    var v: [String: Any] = [:]
    let ns = cardDocSource as NSString
    var lineStart = 0
    for _ in 0..<anchorLine { lineStart = NSMaxRange(ns.lineRange(for: NSRange(location: lineStart, length: 0))) }
    let anchor = ns.lineRange(for: NSRange(location: lineStart, length: 0))
    let cardText = "    ┆ peek: fn compute(values: &[u32], limit: usize) -> usize\n"
    let doc = NSMutableAttributedString(string: cardDocSource, attributes: codeAttributes())
    doc.insert(NSAttributedString(string: cardText, attributes: codeAttributes()), at: NSMaxRange(anchor))
    let cardRange = NSRange(location: NSMaxRange(anchor), length: (cardText as NSString).length)
    let host = Host(doc, wrap: true)
    let delegate = HideDelegate()
    let storage = host.text.textContentStorage!
    let previousDelegate = storage.delegate
    storage.delegate = delegate
    v["textViewHadContentStorageDelegate"] = previousDelegate != nil

    host.text.scroll(NSPoint(x: 0, y: max(0, host.exactLineTop(anchor.location)! - 120)))
    host.settle()
    let afterIndex = NSMaxRange(cardRange)
    /// Distance from the anchor line's top to the following code line's top,
    /// both read from the same viewport layout pass.
    func anchorToNext() -> CGFloat? {
        let controller = host.layout.textViewportLayoutController
        guard let viewport = controller.viewportRange else { return nil }
        var anchorTop: CGFloat?, nextTop: CGFloat?
        host.layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { f in
            let start = host.content.offset(from: host.content.documentRange.location, to: f.rangeInElement.location)
            if start == anchor.location { anchorTop = f.layoutFragmentFrame.minY }
            if start == afterIndex { nextTop = f.layoutFragmentFrame.minY; return false }
            return start < afterIndex
        }
        guard let a = anchorTop, let n = nextTop else { return nil }
        return n - a
    }
    let shown = anchorToNext() ?? .nan
    let cardTop = host.exactLineTop(cardRange.location)!

    delegate.hidden = cardRange
    delegate.calls = 0
    let tWhole = ms {
        host.layout.invalidateLayout(for: host.content.documentRange)
        host.layout.textViewportLayoutController.layoutViewport()
        host.window.displayIfNeeded()
    }
    host.settle()
    let hidden = anchorToNext() ?? .nan
    let probe = NSPoint(x: host.text.textContainerOrigin.x + 40, y: cardTop + 4)
    let insertion = host.text.characterIndexForInsertion(at: probe)
    host.text.setSelectedRange(NSRange(location: anchor.location, length: NSMaxRange(cardRange) + 10 - anchor.location))
    let selection = (host.text.string as NSString).substring(with: host.text.selectedRange())
    host.png("enumerate-hidden-selection")
    v["hide"] = [
        "delegateCalls": delegate.calls,
        "anchorToNextShown": r(shown), "anchorToNextHidden": r(hidden),
        "invalidateWholeDocMs": (tWhole * 100).rounded() / 100,
        "insertionIndexInsideHidden": NSLocationInRange(insertion, cardRange),
        "selectionContainsHiddenText": selection.contains("peek:"),
    ]
    // Arrow-key navigation across the hidden paragraph.
    host.text.setSelectedRange(NSRange(location: anchor.location + 4, length: 0))
    host.window.makeFirstResponder(host.text)
    let beforeArrow = host.text.selectedRange().location
    host.text.moveDown(nil)
    host.text.moveDown(nil)
    let afterArrow = host.text.selectedRange().location
    v["moveDownTwice"] = ["moved": afterArrow != beforeArrow,
                          "landedInsideHidden": NSLocationInRange(afterArrow, cardRange),
                          "landedLine": (host.text.string as NSString).substring(to: afterArrow).filter { $0 == "\n" }.count]

    delegate.hidden = nil
    let tShow = ms {
        if let r = host.textRange(cardRange) { host.layout.invalidateLayout(for: r) }
        host.layout.textViewportLayoutController.layoutViewport()
        host.window.displayIfNeeded()
    }
    host.settle()
    v["showAgain"] = ["invalidateOnlyCardRangeMs": (tShow * 100).rounded() / 100,
                      "anchorToNext": r(anchorToNext() ?? .nan), "expected": r(shown)]
    host.close()
    results["shouldEnumerate"] = v
}

// MARK: - 3. Live animation (standalone comparison of the two card variants)

func runAnimate() {
    var report: [String: Any] = [:]
    for variant in [CardVariant.gap, .attachment] {
        let c = CardHarness(variant, height: 1)
        let host = c.host
        host.text.scroll(NSPoint(x: 0, y: max(0, host.lineTop(c.anchorParagraph.location)! - 120)))
        host.settle()
        if variant == .gap { c.placeOverlay() }
        var work: [Double] = []
        var stamps: [Double] = []
        let frames = 18 // 0.3 s at 60 Hz
        var frame = 0
        let done = DispatchSemaphore(value: 0)
        _ = done
        var finished = false
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
            frame += 1
            let p = Double(frame) / Double(frames)
            let eased = 1 - pow(1 - p, 3)
            stamps.append(ProcessInfo.processInfo.systemUptime * 1000)
            work.append(ms {
                c.setHeight(max(1, CGFloat(eased) * 240))
                if variant == .gap { c.placeOverlay() }
            })
            if frame >= frames { t.invalidate(); finished = true }
        }
        RunLoop.main.add(timer, forMode: .common)
        while !finished { spin(0.01) }
        let intervals = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let sorted = work.sorted()
        report[variant.rawValue] = [
            "frames": frames,
            "workMedianMs": (sorted[sorted.count / 2] * 100).rounded() / 100,
            "workMaxMs": ((sorted.last ?? 0) * 100).rounded() / 100,
            "intervalMaxMs": ((intervals.max() ?? 0) * 100).rounded() / 100,
            "intervalsOver20ms": intervals.filter { $0 > 20 }.count,
            "finalCardHeight": r(c.cardFrame?.height ?? -1),
        ]
        host.png("animate-\(variant.rawValue)-final")
        host.close()
    }
    results["animate"] = report
}

// MARK: - 2c. Hit routing after growing from collapsed (the demo path)

func runScrollRoute() {
    var report: [String: Any] = [:]
    for variant in [CardVariant.gap, .attachment] {
        // Mirror the demo: start collapsed, then grow to 240 in steps.
        let c = CardHarness(variant, height: 1)
        let host = c.host
        host.text.scroll(NSPoint(x: 0, y: max(0, host.lineTop(c.anchorParagraph.location)! - 120)))
        host.settle()
        for h in stride(from: 16.0, through: 240, by: 16) {
            c.setHeight(CGFloat(h))
            if variant == .gap { c.placeOverlay() }
        }
        host.settle()
        guard let frame = c.cardFrame, let cv = c.cardView else { continue }
        let p = NSPoint(x: frame.minX + 60, y: frame.midY)
        let hit = host.window.contentView!.hitTest(host.toWindow(p))
        let siblings = host.text.subviews.map { String(describing: type(of: $0)) }
        let cardIndex = host.text.subviews.firstIndex { cv.isDescendant(of: $0) }
        var v: [String: Any] = [
            "hitView": hit.map { String(describing: type(of: $0)) } ?? "nil",
            "hitIsInsideCard": hit.map { $0.isDescendant(of: cv) } ?? false,
            "textViewSubviews": siblings,
            "cardSubviewIndex": cardIndex ?? -1,
        ]
        // Line wheel through AppKit's responder chain from the view actually hit.
        let (i0, o0) = (cv.scroll.contentView.bounds.minY, host.text.visibleRect.minY)
        _ = scrollWheel(host, at: p, lines: -3)
        v["wheelFromHitView"] = ["innerDelta": r(cv.scroll.contentView.bounds.minY - i0),
                                 "outerDelta": r(host.text.visibleRect.minY - o0)]
        report[variant.rawValue] = v
        host.png("scrollroute-\(variant.rawValue)")
        host.close()
    }
    results["scrollRoute"] = report
}

// MARK: - Demo window for hands-on checks

func runDemo() {
    let which = option("--variant") ?? "gap"
    switch which {
    case "kern", "attachment":
        let doc = makeInline(InlineVariant(rawValue: which)!)
        let host = Host(doc.attributed, wrap: true, size: NSSize(width: 700, height: 300))
        if which == "kern" {
            host.text.backgroundDraw = { _ in
                for (d, hint) in doc.gapAnchors {
                    guard let box = kernHintBox(host, anchor: d, hint: hint) else { continue }
                    drawHint(hint, in: box)
                }
            }
        }
        // A read-only NSTextView (like Cairn's reader) draws no insertion point;
        // mark the caret and name its source offset so clicks can be judged.
        let marker = NSView()
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.systemRed.cgColor
        host.text.addSubview(marker)
        let source = inlineSource as NSString
        let update = {
            let sel = host.text.selectedRange()
            var actual = NSRange()
            let screen = host.text.firstRect(forCharacterRange: NSRange(location: sel.location, length: 0), actualRange: &actual)
            let rect = host.text.convert(host.window.convertFromScreen(screen), from: nil)
            marker.frame = NSRect(x: rect.minX - 1, y: rect.minY, width: 2, height: max(rect.height, 16))
            marker.isHidden = sel.length > 0
            let at = doc.source(ofDisplay: sel.location)
            let before = source.substring(with: NSRange(location: max(0, at - 6), length: min(6, at)))
            let after = source.substring(with: NSRange(location: at, length: min(6, source.length - at)))
            host.window.title = "\(which): caret at source \(at)  \"\(before)|\(after)\""
                .replacingOccurrences(of: "\n", with: "⏎") + (sel.length > 0 ? "  selection \(sel.length)" : "")
        }
        NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: host.text,
                                               queue: .main) { _ in MainActor.assumeIsolated { update() } }
        host.window.makeFirstResponder(host.text)
        update()
    default:
        let c = CardHarness(CardVariant(rawValue: which) ?? .gap, height: 1)
        c.host.window.title = "card: \(which) — press the button to animate"
        let button = NSButton(title: "Toggle card", target: nil, action: nil)
        let toggler = DemoToggler(c)
        button.target = toggler
        button.action = #selector(DemoToggler.toggle)
        button.frame = NSRect(x: 10, y: 10, width: 120, height: 30)
        c.host.window.contentView!.addSubview(button)
        objc_setAssociatedObject(button, "toggler", toggler, .OBJC_ASSOCIATION_RETAIN)
        c.host.text.scroll(NSPoint(x: 0, y: max(0, c.host.lineTop(c.anchorParagraph.location)! - 120)))
        if c.variant == .gap {
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: c.host.text,
                                                   queue: .main) { _ in MainActor.assumeIsolated { c.placeOverlay() } }
        }
    }
    app.run()
}

final class DemoToggler: NSObject {
    let card: CardHarness
    var open = false
    init(_ card: CardHarness) { self.card = card }
    @objc func toggle() {
        open.toggle()
        let from = card.height, to: CGFloat = open ? 240 : 1
        var frame = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { t in
            frame += 1
            let p = min(1, Double(frame) / 18)
            let eased = 1 - pow(1 - p, 3)
            MainActor.assumeIsolated {
                self.card.setHeight(from + (to - from) * CGFloat(eased))
                if self.card.variant == .gap { self.card.placeOverlay() }
            }
            if p >= 1 { t.invalidate() }
        }
    }
}

// MARK: - Main

switch mode {
case "demo": runDemo()
case "inline": runInline()
case "cards": runCards()
case "enumerate": runEnumerate()
case "animate": runAnimate()
case "scrollroute": runScrollRoute()
default:
    runInline(); runCards(); runScrollRoute(); runEnumerate(); runAnimate()
}
results["environment"] = [
    "os": ProcessInfo.processInfo.operatingSystemVersionString,
    "font": codeFont.fontName, "lineHeightMultiple": lineHeightMultiple,
    "date": ISO8601DateFormatter().string(from: Date()),
]
let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
try data.write(to: URL(fileURLWithPath: "\(outDir)/results.json"))
print(String(data: data, encoding: .utf8)!)
exit(0)
