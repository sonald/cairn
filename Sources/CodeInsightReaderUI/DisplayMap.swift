import CodeInsightCore
import CodeInsightReaderCore
import Foundation

internal typealias DisplayPosition = ReaderProjection.DisplayPosition
internal typealias SourcePosition = ReaderProjection.SourcePosition

/// ReaderUI compatibility surface; source geometry lives in ReaderCore.
internal struct DisplayMap: Sendable {
    internal let projection: ReaderProjection
    internal var projectedString: String { projection.materialize() }
    internal var projectedUTF16Length: Int { projection.projectedUTF16Length }
    internal var renderedFoldIDs: Set<FoldID> { projection.renderedFoldIDs }
    internal var foldPlaceholders: [(id: FoldID, offset: Int)] { projection.foldPlaceholders }

    internal init?(document: ReaderDocument, renderedFoldIDs: Set<FoldID>) {
        guard let projection = ReaderProjection(document: document, renderedFoldIDs: renderedFoldIDs) else { return nil }
        self.projection = projection
    }

    internal func foldPlaceholders(in range: NSRange) -> [(id: FoldID, offset: Int)]? {
        projection.foldPlaceholders(in: range)
    }
    internal func placeholderOffset(for id: FoldID) -> Int? { projection.placeholderOffset(for: id) }
    internal func displayPosition(ofByte byteOffset: UInt32) -> DisplayPosition? { projection.displayPosition(ofByte: byteOffset) }
    internal func project(byteRange: ByteRange) -> (visible: [NSRange], folds: [FoldID])? { projection.project(byteRange: byteRange) }
    internal func sourcePosition(ofDisplay displayOffset: Int) -> SourcePosition? { projection.sourcePosition(ofDisplay: displayOffset) }
    internal func sourceRanges(forDisplay range: NSRange) -> [ByteRange]? { projection.sourceRanges(forDisplay: range) }
    internal func visibleSourceRanges(forDisplay range: NSRange) -> [ByteRange]? { projection.visibleSourceRanges(forDisplay: range) }
}
