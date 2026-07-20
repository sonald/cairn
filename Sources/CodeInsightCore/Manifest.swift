import Foundation

public struct SnapshotID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public struct FileOccurrenceID: Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public enum SourceKind: Sendable {
    case tracked
    case dirty
    case untracked
    case generated
}

public enum FileMode: Sendable {
    case regular
    case symlink
    case gitlink
    case lfsPointer
}

public struct FileOccurrence: Sendable {
    public let occurrenceID: FileOccurrenceID
    public let pathID: PathID
    public let contentID: ContentID
    public let detectedLanguage: LanguageID?
    public let sourceKind: SourceKind
    public let fileMode: FileMode
    public let size: UInt64

    public init(
        occurrenceID: FileOccurrenceID,
        pathID: PathID,
        contentID: ContentID,
        detectedLanguage: LanguageID?,
        sourceKind: SourceKind,
        fileMode: FileMode,
        size: UInt64
    ) {
        self.occurrenceID = occurrenceID
        self.pathID = pathID
        self.contentID = contentID
        self.detectedLanguage = detectedLanguage
        self.sourceKind = sourceKind
        self.fileMode = fileMode
        self.size = size
    }
}

public struct SnapshotManifest: Sendable {
    public let snapshotID: SnapshotID
    public let files: [FileOccurrence]

    public init(snapshotID: SnapshotID, files: [FileOccurrence]) {
        self.snapshotID = snapshotID
        self.files = files
    }
}
