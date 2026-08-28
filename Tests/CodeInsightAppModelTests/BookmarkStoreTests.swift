import CodeInsightCore
import Foundation
import Testing
@testable import CodeInsightAppModel

@Test
func bookmarkStoreRoundTripsTheBoundedSchemaWithoutPersistingATitle() throws {
    let fileURL = bookmarkStoreTestFileURL()
    let directory = fileURL.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    let record = bookmarkRecord()
    let worktree = bookmarkRecord(index: 1, snapshot: .worktree)
    let store = BookmarkStore(fileURL: fileURL)

    #expect(try store.load().isEmpty)
    try store.replace([record, worktree])

    #expect(try store.load() == [record, worktree])
    let json = try #require(String(data: try store.rawBytes(), encoding: .utf8))
    #expect(json.contains("\"schemaVersion\":1"))
    #expect(!json.contains("\"title\""))
}

@Test
func bookmarkStoreRejectsUnreadableSchemasWithoutChangingTheirOriginalBytes() throws {
    let fileURL = bookmarkStoreTestFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = BookmarkStore(fileURL: fileURL)
    let cases: [(Data, BookmarkStoreError)] = [
        (Data("{".utf8), .corrupt),
        (Data("{\"schemaVersion\":2,\"bookmarks\":[]}".utf8), .unsupportedSchema),
    ]

    for (bytes, expectedError) in cases {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: fileURL)
        #expect(bookmarkStoreError { _ = try store.load() } == expectedError)
        #expect(try store.rawBytes() == bytes)
    }
}

@Test
func bookmarkStoreRejectsInvalidSemanticsAndExportsTheOriginalBytes() throws {
    let fileURL = bookmarkStoreTestFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = BookmarkStore(fileURL: fileURL)
    try store.replace([bookmarkRecord()])
    var object = try #require(
        JSONSerialization.jsonObject(with: try store.rawBytes()) as? [String: Any]
    )
    var bookmarks = try #require(object["bookmarks"] as? [[String: Any]])
    var bookmark = try #require(bookmarks.first)
    bookmark["path"] = "../main.rs"
    bookmarks[0] = bookmark
    object["bookmarks"] = bookmarks
    let invalid = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try invalid.write(to: fileURL)

    #expect(bookmarkStoreError { _ = try store.load() } == .invalidRecord)
    #expect(try store.rawBytes() == invalid)
}

@Test
func bookmarkStoreValidatesIdentityAnchorsAndFieldBoundsBeforeWriting() throws {
    let fileURL = bookmarkStoreTestFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = BookmarkStore(fileURL: fileURL)
    let baseline = bookmarkRecord()
    try store.replace([baseline])
    let bytes = try store.rawBytes()

    let invalid: [BookmarkRecord] = [
        bookmarkRecord(projectPath: "/tmp/project/../other"),
        bookmarkRecord(projectPath: "/" + String(repeating: "p", count: BookmarkStore.maximumPathBytes)),
        bookmarkRecord(path: "../main.rs"),
        bookmarkRecord(path: String(repeating: "f", count: BookmarkStore.maximumPathBytes + 1)),
        bookmarkRecord(snapshot: .commit(fullOID: String(repeating: "A", count: 40))),
        bookmarkRecord(contentID: ContentID(algorithm: 2, bytes: Array(repeating: 7, count: 32))),
        bookmarkRecord(contentID: ContentID(algorithm: 1, bytes: Array(repeating: 7, count: 31))),
        bookmarkRecord(note: String(repeating: "n", count: BookmarkStore.maximumNoteBytes + 1)),
        bookmarkRecord(symbolName: String(repeating: "s", count: BookmarkStore.maximumPathBytes + 1)),
    ]
    for record in invalid {
        #expect(bookmarkStoreError { try store.replace([record]) } == .invalidRecord)
        #expect(try store.rawBytes() == bytes)
    }

    let duplicateID = bookmarkRecord(index: 1)
    #expect(bookmarkStoreError {
        try store.replace([baseline, BookmarkRecord(
            id: baseline.id,
            projectPath: duplicateID.projectPath,
            snapshot: duplicateID.snapshot,
            path: duplicateID.path,
            contentID: duplicateID.contentID,
            byteOffset: duplicateID.byteOffset,
            line: duplicateID.line,
            symbolName: duplicateID.symbolName,
            symbolKind: duplicateID.symbolKind,
            note: duplicateID.note,
            updatedAt: duplicateID.updatedAt
        )])
    } == .invalidRecord)
    #expect(bookmarkStoreError {
        try store.replace([baseline, BookmarkRecord(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
            projectPath: baseline.projectPath,
            snapshot: baseline.snapshot,
            path: baseline.path,
            contentID: baseline.contentID,
            byteOffset: baseline.byteOffset,
            line: baseline.line,
            symbolName: baseline.symbolName,
            symbolKind: baseline.symbolKind,
            note: baseline.note,
            updatedAt: baseline.updatedAt
        )])
    } == .invalidRecord)
    #expect(try store.rawBytes() == bytes)
}

@Test
func bookmarkStoreWritesThirtyTwoRecordsAndRejectsLargerFilesWithoutOverwrite() throws {
    let fileURL = bookmarkStoreTestFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = BookmarkStore(fileURL: fileURL)
    let maximum = (0..<BookmarkStore.maximumRecordCount).map { bookmarkRecord(index: $0) }
    try store.replace(maximum)
    let bytes = try store.rawBytes()
    #expect(bytes.count <= BookmarkStore.fileCap)
    #expect(try store.load().count == BookmarkStore.maximumRecordCount)

    #expect(bookmarkStoreError {
        try store.replace(maximum + [bookmarkRecord(index: 33)])
    } == .tooManyRecords)
    #expect(try store.rawBytes() == bytes)

    let oversized = Data(repeating: 0, count: BookmarkStore.fileCap + 1)
    try oversized.write(to: fileURL)
    #expect(bookmarkStoreError { _ = try store.load() } == .fileTooLarge)
    #expect(try store.rawBytes() == oversized)
}

private func bookmarkStoreTestFileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("BookmarkStoreTests-\(UUID().uuidString)")
        .appendingPathComponent("bookmarks.json")
}

private func bookmarkRecord(
    index: Int = 0,
    projectPath: String = "/tmp/project",
    snapshot: BookmarkRecord.SnapshotAnchor = .commit(fullOID: String(repeating: "a", count: 40)),
    path: String = "src/main.rs",
    contentID: ContentID = ContentID(algorithm: 1, bytes: Array(repeating: 7, count: 32)),
    note: String = "remember this",
    symbolName: String? = "main"
) -> BookmarkRecord {
    BookmarkRecord(
        id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", index + 1))!,
        projectPath: projectPath,
        snapshot: snapshot,
        path: path,
        contentID: contentID,
        byteOffset: UInt32(index),
        line: UInt32(index + 1),
        symbolName: symbolName,
        symbolKind: "function",
        note: note,
        updatedAt: Date(timeIntervalSince1970: 1_786_270_000)
    )
}

private func bookmarkStoreError(_ body: () throws -> Void) -> BookmarkStoreError? {
    do {
        try body()
        return nil
    } catch let error as BookmarkStoreError {
        return error
    } catch {
        return nil
    }
}
