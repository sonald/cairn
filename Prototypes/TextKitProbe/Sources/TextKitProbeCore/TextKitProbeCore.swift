import AppKit
import Darwin
import Foundation
import TreeSitterKit

@_silgen_name("tree_sitter_rust")
private func treeSitterRust() -> OpaquePointer?

public enum HighlightMode: String, Sendable {
    case lazy
    case eager
}

public struct ProbeOptions: Sendable {
    public var mode: HighlightMode
    public var fontDelta: Int
    public var commentFont: Bool

    public init(mode: HighlightMode, fontDelta: Int, commentFont: Bool) {
        self.mode = mode
        self.fontDelta = fontDelta
        self.commentFont = commentFont
    }
}

public struct ProbeMetrics: Codable, Sendable {
    public let mode: String
    public let file: String
    public let bytes: Int
    public let utf16Units: Int
    public let lines: Int
    public let fontDelta: Int
    public let commentFont: Bool
    public let fileReadMS: Double
    public let parseMS: Double
    public let parseHasError: Bool
    public let highlightIndexMS: Double
    public let attributeApplyMS: Double
    public let firstVisibleTextMS: Double
    public let stableFootprintMB: Double
    public let highlightSpans: Int
    public let lazyStyledFragments: Int
    public let lazyValidatedFragments: Int
    public let sampledMappingRoundTrips: Int
}

private enum HighlightKind: UInt8 {
    case keyword, comment, string, number, function
}

private struct HighlightSpan {
    let lowerByte: UInt32
    let upperByte: UInt32
    let kind: HighlightKind
}

private struct ParsedSource {
    let tree: Tree
    let spans: [HighlightSpan]
}

@MainActor
public final class ProbeSession {
    public let scrollView: NSScrollView
    fileprivate let tree: Tree
    fileprivate let provider: LazyRenderingProvider?
    fileprivate let offscreenWindow: NSWindow

    fileprivate init(
        scrollView: NSScrollView,
        tree: Tree,
        provider: LazyRenderingProvider?,
        offscreenWindow: NSWindow
    ) {
        self.scrollView = scrollView
        self.tree = tree
        self.provider = provider
        self.offscreenWindow = offscreenWindow
    }
}

@MainActor
public enum TextKitProbe {
    public static func measure(
        fileURL: URL,
        options: ProbeOptions
    ) throws -> (ProbeMetrics, ProbeSession) {
        let openedAt = ContinuousClock.now
        let readAt = ContinuousClock.now
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        let bytes = Array(data)
        guard let source = String(bytes: bytes, encoding: .utf8) else {
            throw ProbeError.invalidUTF8
        }
        let fileReadMS = milliseconds(since: readAt)
        let map = ByteUTF16Map(validUTF8: bytes)

        guard let language = treeSitterRust(), let parser = Parser(language: language) else {
            throw ProbeError.parserUnavailable
        }
        let parseAt = ContinuousClock.now
        guard let tree = parser.parse(bytes) else { throw ProbeError.parseFailed }
        let parseMS = milliseconds(since: parseAt)

        let indexAt = ContinuousClock.now
        let parsed = ParsedSource(tree: tree, spans: collectHighlights(tree.rootNode))
        let highlightIndexMS = milliseconds(since: indexAt)
        let mappingSamples = try assertSampledRoundTrips(parsed.spans, map: map)

        let styles = Styles(options: options)
        let textView = NSTextView(usingTextLayoutManager: true)
        configure(textView: textView)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = textView
        textView.frame = scrollView.contentView.bounds
        let offscreenWindow = NSWindow(
            contentRect: scrollView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        offscreenWindow.contentView = scrollView

        guard
            let contentStorage = textView.textContentStorage,
            let layoutManager = textView.textLayoutManager
        else { throw ProbeError.textKit2Unavailable }

        let base = NSAttributedString(
            string: source,
            attributes: [
                .font: styles.baseFont,
                .foregroundColor: NSColor.textColor,
            ]
        )
        let attributeAt = ContinuousClock.now
        let provider: LazyRenderingProvider?
        switch options.mode {
        case .lazy:
            contentStorage.attributedString = base
            let lazyProvider = LazyRenderingProvider(
                spans: parsed.spans,
                map: map,
                styles: styles
            )
            provider = lazyProvider
            layoutManager.renderingAttributesValidator = { manager, fragment in
                lazyProvider.style(fragment: fragment, in: manager)
            }
        case .eager:
            provider = nil
            let attributed = NSMutableAttributedString(attributedString: base)
            apply(spans: parsed.spans, to: attributed, map: map, styles: styles)
            contentStorage.attributedString = attributed
        }
        let attributeApplyMS = milliseconds(since: attributeAt)
        layoutManager.textViewportLayoutController.layoutViewport()
        guard
            let firstFragment = layoutManager.textLayoutFragment(for: .zero),
            !firstFragment.textLineFragments.isEmpty
        else { throw ProbeError.noVisibleText }
        let firstVisibleTextMS = milliseconds(since: openedAt)

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        let footprint = try physicalFootprintBytes()
        let metrics = ProbeMetrics(
            mode: options.mode.rawValue,
            file: fileURL.path,
            bytes: bytes.count,
            utf16Units: map.utf16Count,
            lines: source.reduce(into: 0) { if $1 == "\n" { $0 += 1 } },
            fontDelta: options.fontDelta,
            commentFont: options.commentFont,
            fileReadMS: fileReadMS,
            parseMS: parseMS,
            parseHasError: tree.rootNode.hasError,
            highlightIndexMS: highlightIndexMS,
            attributeApplyMS: attributeApplyMS,
            firstVisibleTextMS: firstVisibleTextMS,
            stableFootprintMB: Double(footprint) / 1_048_576,
            highlightSpans: parsed.spans.count,
            lazyStyledFragments: provider?.styledFragments ?? 0,
            lazyValidatedFragments: provider?.validatedFragments ?? 0,
            sampledMappingRoundTrips: mappingSamples
        )
        return (metrics, ProbeSession(
            scrollView: scrollView,
            tree: tree,
            provider: provider,
            offscreenWindow: offscreenWindow
        ))
    }

    public static func generate(lines: Int = 100_000, destination: URL? = nil) throws -> URL {
        guard lines > 0 else { throw ProbeError.invalidLineCount }
        let output: URL
        if let destination {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            output = destination
        } else {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TextKitProbe-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            output = directory.appendingPathComponent("synthetic-\(lines).rs")
        }

        var source = ""
        source.reserveCapacity(lines * 45)
        for line in 0..<lines {
            let block = line / 10
            switch line % 10 {
            case 0: source += "fn generated_\(block)() -> usize {\n"
            case 1: source += "    // 人文注释：视口高亮与 emoji 🦀🚀 block=\(block)\n"
            case 2: source += "    let label = \"CodeInsight 世界 🌍 \(block)\";\n"
            case 3:
                let tail = block.isMultiple(of: 997) ? String(repeating: "long_line_", count: 300) : "normal"
                source += "    let long_value = \"\(tail)\";\n"
            case 4:
                let expression = block.isMultiple(of: 31) ? String(repeating: "(", count: 64) + "42" + String(repeating: ")", count: 64) : "42"
                source += "    let nested = \(expression);\n"
            case 5: source += "    if nested > 0 {\n"
            case 6: source += "        label.len() + long_value.len() + nested\n"
            case 7: source += "    } else {\n"
            case 8: source += "        0 }\n"
            default: source += "}\n"
            }
        }
        try source.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    private static func configure(textView: NSTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }
}

@MainActor
private final class LazyRenderingProvider {
    let spans: [HighlightSpan]
    let map: ByteUTF16Map
    let styles: Styles
    var styledFragments = 0
    var validatedFragments = 0

    init(
        spans: [HighlightSpan],
        map: ByteUTF16Map,
        styles: Styles
    ) {
        self.spans = spans
        self.map = map
        self.styles = styles
    }

    func style(fragment: NSTextLayoutFragment, in manager: NSTextLayoutManager) {
        validatedFragments += 1
        let viewport = manager.textViewportLayoutController.viewportBounds
            .insetBy(dx: 0, dy: -manager.textViewportLayoutController.viewportBounds.height * 2)
        guard fragment.layoutFragmentFrame.intersects(viewport) else { return }
        guard let content = manager.textContentManager else { return }
        let fragmentRange = fragment.rangeInElement
        let start = content.offset(
            from: content.documentRange.location,
            to: fragmentRange.location
        )
        let endOffset = content.offset(
            from: content.documentRange.location,
            to: fragmentRange.endLocation
        )
        guard start != NSNotFound, endOffset != NSNotFound else { return }
        styledFragments += 1
        let range = NSRange(location: start, length: endOffset - start)
        let end = range.location + range.length
        var index = firstSpan(endingAfter: range.location)
        while index < spans.count {
            let span = spans[index]
            guard let global = map.nsRange(
                byteLowerBound: Int(span.lowerByte),
                byteUpperBound: Int(span.upperByte)
            ) else { break }
            if global.location >= end { break }
            let intersection = NSIntersectionRange(global, range)
            if intersection.length > 0,
               let lower = content.location(
                   content.documentRange.location,
                   offsetBy: intersection.location
               ),
               let upper = content.location(lower, offsetBy: intersection.length),
               let textRange = NSTextRange(location: lower, end: upper) {
                manager.setRenderingAttributes(
                    styles.attributes(for: span.kind),
                    for: textRange
                )
            }
            index += 1
        }
    }

    private func firstSpan(endingAfter utf16Offset: Int) -> Int {
        var low = 0
        var high = spans.count
        while low < high {
            let middle = (low + high) / 2
            let end = map.utf16Offset(forByte: Int(spans[middle].upperByte)) ?? 0
            if end <= utf16Offset { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

@MainActor
private struct Styles {
    let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let keywordFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    let functionFont: NSFont
    let commentFont: NSFont

    init(options: ProbeOptions) {
        functionFont = NSFont.monospacedSystemFont(
            ofSize: 13 + CGFloat(options.fontDelta),
            weight: .semibold
        )
        commentFont = options.commentFont
            ? NSFont.systemFont(ofSize: 13)
            : baseFont
    }

    func attributes(for kind: HighlightKind) -> [NSAttributedString.Key: Any] {
        switch kind {
        case .keyword: [.foregroundColor: NSColor.systemPink, .font: keywordFont]
        case .comment: [.foregroundColor: NSColor.systemGreen, .font: commentFont]
        case .string: [.foregroundColor: NSColor.systemRed]
        case .number: [.foregroundColor: NSColor.systemPurple]
        case .function: [.foregroundColor: NSColor.systemBlue, .font: functionFont]
        }
    }
}

private func collectHighlights(_ root: Node) -> [HighlightSpan] {
    let keywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "else",
        "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop",
        "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
        "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while",
    ]
    let comments: Set<String> = ["line_comment", "block_comment"]
    let strings: Set<String> = ["string_literal", "raw_string_literal", "char_literal"]
    let numbers: Set<String> = ["integer_literal", "float_literal", "boolean_literal"]
    var spans: [HighlightSpan] = []
    var stack = [root]
    while let node = stack.popLast() {
        let kind = node.kind
        let style: HighlightKind?
        if comments.contains(kind) { style = .comment }
        else if strings.contains(kind) { style = .string }
        else if numbers.contains(kind) { style = .number }
        else if !node.isNamed && keywords.contains(kind) { style = .keyword }
        else { style = nil }

        if let style {
            let range = node.byteRange
            spans.append(HighlightSpan(
                lowerByte: range.lowerBound,
                upperByte: range.upperBound,
                kind: style
            ))
            continue
        }
        if kind == "function_item",
           let name = node.namedChildren.first(where: { $0.kind == "identifier" }) {
            let range = name.byteRange
            spans.append(HighlightSpan(
                lowerByte: range.lowerBound,
                upperByte: range.upperBound,
                kind: .function
            ))
        }
        for index in (0..<node.childCount).reversed() {
            if let child = node.child(at: index) { stack.append(child) }
        }
    }
    spans.sort { ($0.lowerByte, $0.upperByte) < ($1.lowerByte, $1.upperByte) }
    return spans
}

@MainActor
private func apply(
    spans: [HighlightSpan],
    to attributed: NSMutableAttributedString,
    map: ByteUTF16Map,
    styles: Styles
) {
    for span in spans {
        guard let range = map.nsRange(
            byteLowerBound: Int(span.lowerByte),
            byteUpperBound: Int(span.upperByte)
        ) else { continue }
        attributed.addAttributes(styles.attributes(for: span.kind), range: range)
    }
}

private func assertSampledRoundTrips(
    _ spans: [HighlightSpan],
    map: ByteUTF16Map
) throws -> Int {
    guard !spans.isEmpty else { return 0 }
    let step = max(1, spans.count / 200)
    var count = 0
    for index in Swift.stride(from: 0, to: spans.count, by: step) {
        let span = spans[index]
        for byte in [Int(span.lowerByte), Int(span.upperByte)] {
            guard
                let utf16 = map.utf16Offset(forByte: byte),
                map.byteOffset(forUTF16: utf16) == byte
            else { throw ProbeError.mappingRoundTripFailed(byte) }
            count += 1
        }
    }
    return count
}

private func physicalFootprintBytes() throws -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { throw ProbeError.footprintUnavailable(result) }
    return info.phys_footprint
}

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

public enum ProbeError: Error, CustomStringConvertible {
    case invalidUTF8
    case invalidLineCount
    case parserUnavailable
    case parseFailed
    case textKit2Unavailable
    case noVisibleText
    case mappingRoundTripFailed(Int)
    case footprintUnavailable(kern_return_t)

    public var description: String {
        switch self {
        case .invalidUTF8: "input is not valid UTF-8"
        case .invalidLineCount: "line count must be positive"
        case .parserUnavailable: "Rust tree-sitter parser is unavailable"
        case .parseFailed: "tree-sitter parse failed"
        case .textKit2Unavailable: "NSTextView did not create a TextKit 2 stack"
        case .noVisibleText: "TextKit 2 produced no visible layout fragment"
        case let .mappingRoundTripFailed(byte): "byte/UTF-16 round trip failed at byte \(byte)"
        case let .footprintUnavailable(code): "task_info failed with \(code)"
        }
    }
}
