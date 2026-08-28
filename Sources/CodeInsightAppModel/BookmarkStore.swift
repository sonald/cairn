import CodeInsightCore
import Foundation

package struct BookmarkRecord: Codable, Equatable, Sendable {
    package enum SnapshotAnchor: Codable, Equatable, Hashable, Sendable {
        case worktree
        case commit(fullOID: String)
    }

    package struct ToggleKey: Hashable, Sendable {
        let projectPath: String
        let snapshot: SnapshotAnchor
        let path: String
        let contentID: ContentID
        let byteOffset: UInt32
    }

    package let id: UUID
    package let projectPath: String
    package let snapshot: SnapshotAnchor
    package let path: String
    package let contentID: ContentID
    package let byteOffset: UInt32
    package let line: UInt32
    package let symbolName: String?
    package let symbolKind: String?
    package let note: String
    package let updatedAt: Date

    package init(
        id: UUID,
        projectPath: String,
        snapshot: SnapshotAnchor,
        path: String,
        contentID: ContentID,
        byteOffset: UInt32,
        line: UInt32,
        symbolName: String?,
        symbolKind: String?,
        note: String,
        updatedAt: Date
    ) {
        self.id = id
        self.projectPath = projectPath
        self.snapshot = snapshot
        self.path = path
        self.contentID = contentID
        self.byteOffset = byteOffset
        self.line = line
        self.symbolName = symbolName
        self.symbolKind = symbolKind
        self.note = note
        self.updatedAt = updatedAt
    }

    package var toggleKey: ToggleKey {
        ToggleKey(
            projectPath: projectPath,
            snapshot: snapshot,
            path: path,
            contentID: contentID,
            byteOffset: byteOffset
        )
    }
}

package enum BookmarkStoreError: Error, Equatable {
    case corrupt
    case unsupportedSchema
    case invalidRecord
    case fileTooLarge
    case tooManyRecords
    case encodedFileTooLarge
    case unreadable
    case writeFailed
}

package struct BookmarkStore {
    package static let fileCap = 256 * 1024
    package static let maximumRecordCount = 32
    package static let maximumNoteBytes = 2 * 1024
    package static let maximumPathBytes = 1024

    private let fileURL: URL

    package init(fileURL: URL) {
        self.fileURL = fileURL
    }

    package func load() throws -> [BookmarkRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw BookmarkStoreError.unreadable
        }
        guard data.count <= Self.fileCap else { throw BookmarkStoreError.fileTooLarge }

        let envelope: Envelope
        do {
            envelope = try Self.makeDecoder().decode(Envelope.self, from: data)
        } catch {
            throw BookmarkStoreError.corrupt
        }
        guard envelope.schemaVersion == 1 else {
            throw BookmarkStoreError.unsupportedSchema
        }
        try validate(envelope.bookmarks)
        return envelope.bookmarks
    }

    package func replace(_ bookmarks: [BookmarkRecord]) throws {
        try validate(bookmarks)
        let data = try Self.makeEncoder().encode(
            Envelope(schemaVersion: 1, bookmarks: bookmarks)
        )
        guard data.count <= Self.fileCap else {
            throw BookmarkStoreError.encodedFileTooLarge
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: Data.WritingOptions.atomic)
        } catch {
            throw BookmarkStoreError.writeFailed
        }
    }

    package func rawBytes() throws -> Data {
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw BookmarkStoreError.unreadable
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private func validate(_ bookmarks: [BookmarkRecord]) throws {
        guard bookmarks.count <= Self.maximumRecordCount else {
            throw BookmarkStoreError.tooManyRecords
        }
        var identifiers = Set<UUID>()
        var toggleKeys = Set<BookmarkRecord.ToggleKey>()
        for bookmark in bookmarks {
            guard identifiers.insert(bookmark.id).inserted,
                  toggleKeys.insert(bookmark.toggleKey).inserted
            else { throw BookmarkStoreError.invalidRecord }
            try validate(bookmark)
        }
    }

    private func validate(_ bookmark: BookmarkRecord) throws {
        guard bookmark.projectPath.hasPrefix("/"),
              bookmark.projectPath == URL(fileURLWithPath: bookmark.projectPath)
                .standardizedFileURL.path,
              byteCount(bookmark.projectPath) <= Self.maximumPathBytes,
              validRelativePath(bookmark.path),
              byteCount(bookmark.path) <= Self.maximumPathBytes,
              bookmark.symbolName.map({ byteCount($0) <= Self.maximumPathBytes }) ?? true,
              bookmark.symbolKind.map({ byteCount($0) <= Self.maximumPathBytes }) ?? true,
              byteCount(bookmark.note) <= Self.maximumNoteBytes,
              bookmark.contentID.algorithm == 1,
              bookmark.contentID.bytes.count == 32
        else { throw BookmarkStoreError.invalidRecord }

        if case .commit(let fullOID) = bookmark.snapshot,
           !validFullOID(fullOID) {
            throw BookmarkStoreError.invalidRecord
        }
    }

    private func validRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func validFullOID(_ oid: String) -> Bool {
        guard oid.utf8.count == 40 || oid.utf8.count == 64 else { return false }
        return oid.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private func byteCount(_ string: String) -> Int { string.utf8.count }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let bookmarks: [BookmarkRecord]
    }
}
