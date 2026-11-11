import CTreeSitterGo
import CodeInsightCore
import Foundation
import TreeSitterKit

public struct GoExtractor: LanguageExtractor, Sendable {
    public static let grammarVersion: UInt32 = 1
    public static let extractorVersion: UInt32 = 1

    public init() {}

    public var language: LanguageID { .go }
    public var grammarVersion: UInt32 { Self.grammarVersion }
    public var extractorVersion: UInt32 { Self.extractorVersion }

    public func extractWithDiagnostics(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner: ExtractionInterners
    ) throws -> (index: ContentIndex, containsErrorNodes: Bool) {
        throw CocoaError(.featureUnsupported, userInfo: [
            NSLocalizedFailureReasonErrorKey: "GoExtractor is not implemented yet",
        ])
    }

    public func identifierRanges(
        named name: String,
        in bytes: [UInt8],
        mode: LanguageMode
    ) throws -> [CodeInsightCore.ByteRange] {
        []
    }

    /// The grammar handle, so a link failure shows up in the first test.
    public static var grammarIsAvailable: Bool { tree_sitter_go() != nil }
}
