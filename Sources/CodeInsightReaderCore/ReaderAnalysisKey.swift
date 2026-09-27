import CodeInsightCore
import Foundation

/// Loader-produced analyses share keys; manually supplied analyses are isolated by default.
package struct ReaderAnalysisKey: Hashable, Sendable {
    package enum Phase: Hashable, Sendable {
        case plain
        case syntax
        case custom(UUID)
    }

    package static let currentReaderVersion: UInt32 = 1
    package let contentID: ContentID
    package let languageMode: LanguageMode
    package let readerVersion: UInt32
    package let phase: Phase

    package init(
        contentID: ContentID,
        languageMode: LanguageMode,
        readerVersion: UInt32 = Self.currentReaderVersion,
        phase: Phase = .custom(UUID())
    ) {
        self.contentID = contentID
        self.languageMode = languageMode
        self.readerVersion = readerVersion
        self.phase = phase
    }
}

/// Distinguishes a pending lookup from a prepared index with no matches.
package enum ReaderIdentifierState: Equatable, Sendable {
    case notRequested
    case building
    case ready
    case unavailable(String)
}
