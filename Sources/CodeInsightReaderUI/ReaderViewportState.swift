import AppKit
import CodeInsightCore
import CodeInsightReaderCore

/// Short-lived reading-surface state captured around a pure reflow so the
/// same character keeps its viewport offset across wrap, font, and width
/// changes (reader-wrap design D3.1–D3.5).
///
/// The state is owned by one `ReaderTextView` instance and only ever applies
/// to the same content: `contentID` plus the reading-surface file identity
/// guard against stale restores onto a new document, and `projectionRevision`
/// guards against applying display offsets captured under a different fold
/// projection.
@MainActor
struct ReaderViewportState {
    /// What the viewport is pinned to. `.source` identifies a concrete
    /// character by byte offset; fold chips anchor to their placeholder so a
    /// reflow never expands a fold just to find a position (D3.2).
    enum Anchor: Equatable {
        case source(UInt32)
        case foldPlaceholder(FoldID)
        case documentStart
        case documentEnd
    }

    /// Horizontal bookkeeping (D3.5): the current legal clip origin plus the
    /// x captured while wrap was off, restored when wrap turns back off.
    struct HorizontalState {
        var clipOriginX: CGFloat
        var stashedUnwrappedX: CGFloat?
    }

    var contentID: ContentID
    var surfaceFileURL: URL?
    var projectionRevision: Int
    var anchor: Anchor
    /// UTF-16 display offset of the anchored character under the projection
    /// identified by `projectionRevision`.
    var anchorDisplayLocation: Int
    /// Distance from the anchor row's reference point (top of its first
    /// visual row) to the top of the visible viewport, in text view points
    /// (D3.2). Positive when the anchor sits below the viewport top.
    var offsetFromViewportTop: CGFloat
    /// Complete display selection captured before the reflow (D3.4), with
    /// the selection affinity so soft-wrap boundary ownership and Shift
    /// extension direction survive the restore.
    var selectedRanges: [NSRange]
    var selectionAffinity: NSSelectionAffinity
    /// Primary selection (symbol occurrence / find hit) identity so the
    /// custom emphasis can be re-established after the restore.
    var primarySelectionRange: NSRange?
    var findSelectionIndex: Int?
    /// Source byte offset of the current-line marker, so the highlighted
    /// logical line survives the reflow regardless of how it was set
    /// (click, reveal, or keyboard caret).
    var currentLineByteOffset: UInt32?
    var horizontal: HorizontalState
}

/// Helpers for anchoring to a concrete character inside the visible layout.
@MainActor
enum ReaderViewportGeometry {
    static func fragment(
        containingDisplayLocation location: Int, in textView: NSTextView
    ) -> NSTextLayoutFragment? {
        guard let manager = textView.textLayoutManager,
              let content = manager.textContentManager,
              let position = content.location(content.documentRange.location, offsetBy: location)
        else { return nil }
        if let fragment = manager.textLayoutFragment(for: position) { return fragment }
        // End-of-document has no containing character. Its extra empty row
        // belongs to the preceding fragment, not to a new text element.
        guard location > 0, location == textView.textStorage?.length,
              let previous = content.location(position, offsetBy: -1) else { return nil }
        return manager.textLayoutFragment(for: previous)
    }

    /// Rect of a single character's text segment in text view coordinates,
    /// via TextKit 2 segment enumeration. `firstRect(forCharacterRange:)`
    /// returns empty rects on wide unwrapped rows, so every geometry path
    /// that must work in both wrap states uses this instead (D2.4).
    static func characterRect(
        displayLocation location: Int,
        in textView: NSTextView
    ) -> NSRect? {
        let string = textView.string as NSString
        guard location >= 0, location <= string.length else { return nil }
        // Geometry must not ask TextKit to shape half a surrogate or grapheme.
        // This does not change the caller's source selection/search range.
        let query = location < string.length
            ? string.rangeOfComposedCharacterSequence(at: location)
            : NSRange(location: location, length: 0)
        guard let manager = textView.textLayoutManager,
              let content = manager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: query.location),
              let end = content.location(start, offsetBy: query.length),
              let range = NSTextRange(location: start, end: end)
        else { return nil }
        let origin = textView.textContainerOrigin
        var result: NSRect?
        manager.enumerateTextSegments(
            in: range,
            type: .standard,
            options: []
        ) { _, frame, _, _ in
            result = frame.offsetBy(dx: origin.x, dy: origin.y)
            return false
        }
        return result
    }

    /// Rect of the FIRST visual row of a layout fragment, in text view
    /// coordinates (D2.1): fragment origin + the first row's typographic
    /// bounds + textContainerOrigin. Gutter decorations belong to the first
    /// visual row of each logical line; continuation rows carry none.
    static func firstVisualRowRect(
        ofFragment fragment: NSTextLayoutFragment,
        in textView: NSTextView
    ) -> NSRect? {
        guard let row = fragment.textLineFragments.first else { return nil }
        let origin = textView.textContainerOrigin
        return NSRect(
            x: fragment.layoutFragmentFrame.minX
                + row.typographicBounds.minX + origin.x,
            y: fragment.layoutFragmentFrame.minY
                + row.typographicBounds.minY + origin.y,
            width: row.typographicBounds.width,
            height: row.typographicBounds.height
        )
    }

    /// All visible text segments of a display range, in text view
    /// coordinates (D2.4): TextKit 2 segment enumeration restricted to the
    /// range and clipped to the viewport, so a find hit that wraps across
    /// visual rows is drawn as one box per visible fragment instead of a
    /// single first-line rect.
    static func visibleRects(
        forDisplayRange range: NSRange,
        in textView: NSTextView,
        clipTo clipRect: NSRect? = nil
    ) -> [NSRect] {
        guard let manager = textView.textLayoutManager,
              let content = manager.textContentManager,
              let start = content.location(
                  content.documentRange.location,
                  offsetBy: range.location
              )
        else { return [] }
        let end = content.location(start, offsetBy: max(range.length, 0))
        guard let textRange = NSTextRange(
            location: start,
            end: end ?? start
        ) else { return [] }
        let origin = textView.textContainerOrigin
        let clip = clipRect ?? textView.visibleRect
        var rects: [NSRect] = []
        manager.enumerateTextSegments(
            in: textRange,
            type: .standard,
            options: []
        ) { _, frame, _, _ in
            let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
            let clipped = rect.intersection(clip)
            if !clipped.isNull { rects.append(clipped) }
            return true
        }
        return rects
    }

    /// Reference rect for the visual row containing `location`, in the text
    /// view's coordinate system (D2.1 composition: fragment origin +
    /// typographic bounds + textContainerOrigin).
    static func rowRect(
        containingDisplayLocation location: Int,
        in textView: NSTextView
    ) -> NSRect? {
        guard let manager = textView.textLayoutManager,
              let content = manager.textContentManager
        else { return nil }
        guard let fragment = fragment(containingDisplayLocation: location, in: textView)
        else { return nil }
        let containerOrigin = textView.textContainerOrigin
        // Local offset of the character inside the fragment.
        let fragmentStart = content.offset(
            from: content.documentRange.location,
            to: fragment.rangeInElement.location
        )
        guard fragmentStart != NSNotFound else { return nil }
        let local = location - fragmentStart
        for row in fragment.textLineFragments {
            if local >= row.characterRange.location,
               local < NSMaxRange(row.characterRange)
            {
                return NSRect(
                    x: fragment.layoutFragmentFrame.minX
                        + row.typographicBounds.minX + containerOrigin.x,
                    y: fragment.layoutFragmentFrame.minY
                        + row.typographicBounds.minY + containerOrigin.y,
                    width: row.typographicBounds.width,
                    height: row.typographicBounds.height
                )
            }
        }
        // Location at the very end of the fragment: use its last row.
        guard let last = fragment.textLineFragments.last else { return nil }
        return NSRect(
            x: fragment.layoutFragmentFrame.minX
                + last.typographicBounds.minX + containerOrigin.x,
            y: fragment.layoutFragmentFrame.minY
                + last.typographicBounds.minY + containerOrigin.y,
            width: last.typographicBounds.width,
            height: last.typographicBounds.height
        )
    }
}
