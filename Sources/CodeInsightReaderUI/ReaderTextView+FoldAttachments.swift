@preconcurrency import AppKit
import CodeInsightReaderCore
import os

@MainActor
final class FoldAttachment: NSTextAttachment, @unchecked Sendable {
    private weak var activeProvider: FoldAttachmentViewProvider?
    private nonisolated let measuredSize: OSAllocatedUnfairLock<NSSize>
    nonisolated var chipSize: NSSize { measuredSize.withLock { $0 } }
    private let kind: FoldKind
    private let summary: FoldSummary
    nonisolated let bodyText: String
    nonisolated let accessibilityText: String
    private(set) var theme: ReaderTheme
    private(set) var chipFont: NSFont
    private(set) var chipAttributes: [NSAttributedString.Key: Any]
    private(set) var matchCount = 0
    private(set) var hasDiff = false
    private(set) var occurrenceCount = 0

    var visualExposureText: String {
        if matchCount > 999 { return " · 999" }
        if matchCount > 0 { return " · " + localizedFormat("reader.matches", Int64(matchCount)) }
        if occurrenceCount > 999 { return " · 999" }
        if occurrenceCount > 0 { return " · " + localizedFormat("reader.occurrences", Int64(occurrenceCount)) }
        return hasDiff ? " · " + localized("reader.diff") : ""
    }

    var accessibilityExposureText: String {
        var values: [String] = []
        if matchCount > 0 { values.append(localizedFormat("reader.matches", Int64(matchCount))) }
        if occurrenceCount > 0 { values.append(localizedFormat("reader.occurrences", Int64(occurrenceCount))) }
        if hasDiff { values.append(localized("reader.diff")) }
        return values.isEmpty ? "" : ", " + values.joined(separator: ", ")
    }

    init(region: FoldRegion, theme: ReaderTheme) {
        self.theme = theme
        kind = region.kind
        summary = region.summary
        bodyText = Self.bodyText(for: region)
        accessibilityText = Self.accessibilityText(for: region)
        let resolved = ReaderFontResolver.shared.resolve(
            theme: theme, size: max(8, theme.fontSize * 10 / 13), weight: .medium
        )
        chipFont = resolved.font
        chipAttributes = resolved.attributes
        measuredSize = OSAllocatedUnfairLock(initialState: Self.measure(
            bodyText, font: resolved.font, attributes: resolved.attributes
        ))
        super.init(data: nil, ofType: "com.codeinsight.fold-attachment")
        allowsTextAttachmentView = true
    }

    private static func measure(_ text: String, font: NSFont,
                                attributes: [NSAttributedString.Key: Any]) -> NSSize {
        let width = min(180, ceil((text as NSString).size(withAttributes: attributes).width))
        return NSSize(width: 5 + width + 54 + 5,
                      height: max(22, ceil(font.ascender - font.descender) + 8))
    }

    func matches(_ region: FoldRegion) -> Bool { kind == region.kind && summary == region.summary }

    func updateTypography(_ theme: ReaderTheme) {
        self.theme = theme
        let resolved = ReaderFontResolver.shared.resolve(
            theme: theme, size: max(8, theme.fontSize * 10 / 13), weight: .medium
        )
        chipFont = resolved.font
        chipAttributes = resolved.attributes
        let size = Self.measure(bodyText, font: resolved.font, attributes: resolved.attributes)
        measuredSize.withLock { $0 = size }
        activeProvider?.update()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateTheme(_ theme: ReaderTheme) {
        self.theme = theme
        activeProvider?.update()
    }

    func setMatchCount(_ count: Int) {
        updateExposure(
            matchCount: count,
            hasDiff: hasDiff,
            occurrenceCount: occurrenceCount
        )
    }

    func updateExposure(
        matchCount: Int,
        hasDiff: Bool,
        occurrenceCount: Int
    ) {
        let matchCount = max(0, matchCount)
        let occurrenceCount = max(0, occurrenceCount)
        guard self.matchCount != matchCount
                || self.hasDiff != hasDiff
                || self.occurrenceCount != occurrenceCount
        else { return }
        self.matchCount = matchCount
        self.hasDiff = hasDiff
        self.occurrenceCount = occurrenceCount
        activeProvider?.update()
    }

    @preconcurrency override func viewProvider(
        for parentView: NSView?,
        location: any NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = FoldAttachmentViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        // AppKit invokes this nonisolated SDK hook on its main UI thread.
        nonisolated(unsafe) let owner = self
        nonisolated(unsafe) let created = provider
        MainActor.assumeIsolated { owner.activeProvider = created }
        return provider
    }

    private static func bodyText(for region: FoldRegion) -> String {
        let summary = region.summary
        switch region.kind {
        case .declaration:
            return joined(
                summary.leadingText,
                localizedFormat("reader.lines", Int64(summary.hiddenLineCount))
            )
        case .container:
            let members = orderedMembers(summary.memberCounts)
            return "⋯ " + (members + [localizedFormat("reader.lines", Int64(summary.hiddenLineCount))])
                .joined(separator: " · ")
        case .imports:
            return localizedFormat("reader.imports", Int64(summary.itemCount ?? 0))
        case .comment:
            return localizedFormat("reader.comments", Int64(summary.hiddenLineCount))
        case .attributes:
            return localizedFormat("reader.attributes", Int64(summary.itemCount ?? 0))
        case .cfgTest:
            let functionCount = (summary.memberCounts[.fn] ?? 0)
                + (summary.memberCounts[.method] ?? 0)
            return localizedFormat("reader.tests", localizedFormat("reader.member.fn", Int64(functionCount)), localizedFormat("reader.lines", Int64(summary.hiddenLineCount)))
        case .block:
            if let itemCount = summary.itemCount {
                return localizedFormat("reader.arms", Int64(itemCount))
            }
            return "⋯ " + localizedFormat("reader.lines", Int64(summary.hiddenLineCount))
        }
    }

    private static func accessibilityText(for region: FoldRegion) -> String {
        let members = orderedMembers(region.summary.memberCounts)
        let hidden = localizedFormat("reader.collapsed.lines", Int64(region.summary.hiddenLineCount))
        return members.isEmpty ? hidden : localizedFormat("reader.collapsed.members", hidden, members.joined(separator: ", "))
    }

    private static func joined(_ leading: String?, _ trailing: String) -> String {
        ["⋯", leading, trailing]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    private static func orderedMembers(
        _ counts: [OutlineKind: Int]
    ) -> [String] {
        let order: [OutlineKind] = [
            .mod, .trait, .impl, .struct, .class, .enum, .typeAlias,
            .const, .static, .fn, .method, .field, .enumMember,
        ]
        return order.compactMap { kind in
            guard let count = counts[kind], count > 0 else { return nil }
            return localizedFormat("reader.member.\(kind.rawValue)", Int64(count))
        }
    }
}

private final class FoldAttachmentViewProvider:
    NSTextAttachmentViewProvider,
    @unchecked Sendable
{
    nonisolated override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        guard let attachment = textAttachment as? FoldAttachment else {
            return super.attachmentBounds(
                for: attributes,
                location: location,
                textContainer: textContainer,
                proposedLineFragment: proposedLineFragment,
                position: position
            )
        }
        let size = attachment.chipSize
        return CGRect(x: 0, y: -6, width: size.width, height: size.height)
    }

    nonisolated override func loadView() {
        // AppKit invokes this nonisolated SDK hook on its main UI thread.
        nonisolated(unsafe) let provider = self
        MainActor.assumeIsolated {
            guard let attachment = provider.textAttachment as? FoldAttachment else {
                provider.view = NSView(frame: .zero)
                return
            }
            provider.view = FoldChipView(attachment: attachment)
            provider.updateOnMainActor()
        }
    }

    @MainActor
    func update() { updateOnMainActor() }

    @MainActor
    private func updateOnMainActor() {
        guard let attachment = textAttachment as? FoldAttachment,
              let chip = view as? FoldChipView
        else { return }
        let size = attachment.chipSize
        if chip.frame.size != size { chip.setFrameSize(size) }
        chip.exposureText = attachment.visualExposureText
        chip.setAccessibilityLabel(
            attachment.accessibilityText + attachment.accessibilityExposureText
        )
        chip.needsDisplay = true
    }
}

private final class FoldChipView: NSView {
    let attachment: FoldAttachment
    var exposureText = ""

    init(attachment: FoldAttachment) {
        self.attachment = attachment
        super.init(frame: NSRect(origin: .zero, size: attachment.chipSize))
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let borderRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let border = NSBezierPath(roundedRect: borderRect, xRadius: 4, yRadius: 4)
        border.lineWidth = 1
        attachment.theme.chromeDividerColor.setStroke()
        border.stroke()

        let font = attachment.chipFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes = attachment.chipAttributes
        attributes[.foregroundColor] = attachment.theme.chipForegroundColor
        attributes[.paragraphStyle] = paragraph
        let countWidth: CGFloat = 54
        let textY = floor((bounds.height - font.ascender + font.descender) / 2)
        (attachment.bodyText as NSString).draw(
            in: NSRect(
                x: 5,
                y: textY,
                width: max(0, bounds.width - countWidth - 10),
                height: ceil(font.ascender - font.descender)
            ),
            withAttributes: attributes
        )
        (exposureText as NSString).draw(
            in: NSRect(
                x: bounds.width - countWidth - 5,
                y: textY,
                width: countWidth,
                height: ceil(font.ascender - font.descender)
            ),
            withAttributes: attributes
        )
    }
}
