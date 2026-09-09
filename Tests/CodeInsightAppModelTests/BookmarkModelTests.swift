import CodeInsightCore
import CodeInsightEngine
import CodeInsightGit
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightAppModel

@Test
func bookmarkStatusUsesCapturedSourceOnlyForTheMatchingSnapshot() {
    let record = bookmarkModelRecord(snapshot: .worktree)
    let bytes = Array("fn captured() {}\n".utf8)
    let contentID = ContentID.sha256(of: Data(bytes))
    let exact = BookmarkStatus.evaluate(
        record: BookmarkRecord(
            id: record.id,
            projectPath: record.projectPath,
            snapshot: record.snapshot,
            path: record.path,
            contentID: contentID,
            byteOffset: 3,
            line: 1,
            symbolName: nil,
            symbolKind: nil,
            note: "",
            updatedAt: record.updatedAt
        ),
        snapshot: .worktree,
        revisionAvailable: true,
        capturedSource: (contentID, bytes)
    )

    #expect(exact == .exactContent)
    #expect(BookmarkStatus.evaluate(
        record: record,
        snapshot: .worktree,
        revisionAvailable: true,
        capturedSource: (contentID, bytes)
    ) == .drifted)
    #expect(BookmarkStatus.evaluate(
        record: record,
        snapshot: .commit(fullOID: String(repeating: "a", count: 40)),
        revisionAvailable: true,
        capturedSource: nil
    ) == .notEvaluated)
    #expect(BookmarkStatus.evaluate(
        record: BookmarkRecord(
            id: record.id,
            projectPath: record.projectPath,
            snapshot: record.snapshot,
            path: record.path,
            contentID: contentID,
            byteOffset: UInt32(bytes.count + 1),
            line: 1,
            symbolName: nil,
            symbolKind: nil,
            note: "",
            updatedAt: record.updatedAt
        ),
        snapshot: .worktree,
        revisionAvailable: true,
        capturedSource: (contentID, bytes)
    ) == .offsetInvalid)

    let emojiBytes = Array("a😀z\n".utf8)
    let emojiContentID = ContentID.sha256(of: Data(emojiBytes))
    let emojiRecord = BookmarkRecord(
        id: record.id,
        projectPath: record.projectPath,
        snapshot: .worktree,
        path: record.path,
        contentID: emojiContentID,
        byteOffset: 2,
        line: 1,
        symbolName: nil,
        symbolKind: nil,
        note: "",
        updatedAt: record.updatedAt
    )
    #expect(BookmarkStatus.evaluate(
        record: emojiRecord,
        snapshot: .worktree,
        revisionAvailable: true,
        capturedSource: (emojiContentID, emojiBytes)
    ) == .offsetInvalid)
    #expect(BookmarkStatus.evaluate(
        record: BookmarkRecord(
            id: record.id,
            projectPath: record.projectPath,
            snapshot: .commit(fullOID: String(repeating: "a", count: 40)),
            path: record.path,
            contentID: ContentID.sha256(of: Data("old".utf8)),
            byteOffset: 0,
            line: 1,
            symbolName: nil,
            symbolKind: nil,
            note: "",
            updatedAt: record.updatedAt
        ),
        snapshot: .commit(fullOID: String(repeating: "a", count: 40)),
        revisionAvailable: true,
        capturedSource: (ContentID.sha256(of: Data("new".utf8)), Array("new".utf8))
    ) == .fileAbsent)
}

@MainActor
@Test
func bookmarkModelDefaultsToMemoryAndSessionAppModelUsesSiblingBookmarkStore() throws {
    let memoryOnly = BookmarkModel()
    #expect(memoryOnly.records.isEmpty)
    #expect(memoryOnly.storageError == nil)
    let sessionURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("BookmarkModelTests-\(UUID().uuidString)")
        .appendingPathComponent("session.json")
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent()) }
    let stored = bookmarkPanelRecord(
        id: "00000000-0000-4000-8000-000000000100",
        path: "src/persisted.rs", symbolName: nil, note: "",
        updatedAt: Date(timeIntervalSince1970: 20)
    )
    let bookmarkURL = sessionURL.deletingLastPathComponent().appendingPathComponent("bookmarks.json")
    try BookmarkStore(fileURL: bookmarkURL).replace([stored])

    let model = AppModel(sessionURL: sessionURL)

    #expect(model.bookmarkModel.records == [stored])
}

@MainActor
@Test
func bookmarkModelPersistsUUIDBasedToggleAndFilteredRows() throws {
    let fileURL = bookmarkModelTestFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let model = BookmarkModel(store: BookmarkStore(fileURL: fileURL))
    let older = bookmarkPanelRecord(
        id: "00000000-0000-4000-8000-000000000101",
        path: "src/old.rs",
        symbolName: nil,
        note: "NÉEDLE note",
        updatedAt: Date(timeIntervalSince1970: 10)
    )
    let newer = bookmarkPanelRecord(
        id: "00000000-0000-4000-8000-000000000102",
        path: "src/new.rs",
        symbolName: "NÉEDLE",
        note: "",
        updatedAt: Date(timeIntervalSince1970: 20)
    )

    #expect(model.records.isEmpty)
    #expect(model.toggle(older) == .added)
    #expect(model.toggle(newer) == .added)
    #expect(model.filteredRecords(projectPath: "/tmp/project", query: "nÉedle").map(\.id)
        == [newer.id, older.id])
    #expect(model.filteredRecords(projectPath: "/tmp/project", query: "old.rs:1").map(\.id)
        == [older.id])
    #expect(try BookmarkStore(fileURL: fileURL).load().map(\.id) == [older.id, newer.id])

    let moved = BookmarkRecord(
        id: older.id,
        projectPath: older.projectPath,
        snapshot: older.snapshot,
        path: "src/renamed.rs",
        contentID: older.contentID,
        byteOffset: older.byteOffset,
        line: older.line,
        symbolName: older.symbolName,
        symbolKind: older.symbolKind,
        note: older.note,
        updatedAt: older.updatedAt
    )
    #expect(model.update(moved))
    #expect(model.records.first(where: { $0.id == older.id })?.path == "src/renamed.rs")
}

@MainActor
@Test
func bookmarkNoteWritesEachChangeButOnlyFinalizesTimestamp() throws {
    let fileURL = bookmarkModelTestFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let model = BookmarkModel(store: BookmarkStore(fileURL: fileURL))
    let record = bookmarkPanelRecord(
        id: "00000000-0000-4000-8000-000000000109",
        path: "src/note.rs", symbolName: "note", note: "",
        updatedAt: Date(timeIntervalSince1970: 10)
    )
    #expect(model.toggle(record) == .added)

    #expect(model.updateNote(id: record.id, text: "first"))
    #expect(model.records.first?.updatedAt == record.updatedAt)
    #expect(try BookmarkStore(fileURL: fileURL).load().first?.note == "first")
    #expect(model.updateNote(id: record.id, text: "latest"))
    #expect(BookmarkModel(store: BookmarkStore(fileURL: fileURL)).records.first?.note == "latest")
    #expect(model.finalizeNote(id: record.id, updatedAt: Date(timeIntervalSince1970: 20)))
    #expect(model.records.first?.updatedAt == Date(timeIntervalSince1970: 20))
}

@MainActor
@Test
func bookmarkMarkdownEscapesControlsOmitsEmptyNotesAndKeepsNotEvaluatedHonest() throws {
    let fileURL = bookmarkModelTestFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let model = BookmarkModel(store: BookmarkStore(fileURL: fileURL))
    let noted = bookmarkPanelRecord(
        id: "00000000-0000-4000-8000-000000000110", path: "src/`x`-(a)!.rs",
        symbolName: "# title-(x)!", note: "* _ [ ] # > | \\ ` { } ( ) + - . !\nnext", updatedAt: .now
    )
    let empty = bookmarkPanelRecord(
        id: "00000000-0000-4000-8000-000000000111", path: "src/empty.rs",
        symbolName: "empty", note: "", updatedAt: Date(timeIntervalSince1970: 1)
    )
    #expect(model.toggle(noted) == .added)
    #expect(model.toggle(empty) == .added)
    let recordsBeforeExport = model.records
    let bytesBeforeExport = try BookmarkStore(fileURL: fileURL).rawBytes()
    let markdown = model.markdown(projectPath: noted.projectPath) { _ in .notEvaluated }
    #expect(markdown.contains("\\# title\\-\\(x\\)\\!"))
    #expect(markdown.contains("src/\\`x\\`\\-\\(a\\)\\!\\.rs"))
    #expect(markdown.contains("\\* \\_ \\[ \\] \\# \\> \\| \\\\ \\` \\{ \\} \\( \\) \\+ \\- \\. \\!\nnext"))
    #expect(markdown.contains("Status: Not evaluated"))
    #expect(markdown.components(separatedBy: "### Note").count == 2)
    #expect(model.records == recordsBeforeExport)
    #expect(try BookmarkStore(fileURL: fileURL).rawBytes() == bytesBeforeExport)
}

@MainActor
@Test
func bookmarkModelRequiresConfirmationForNotesAndCleansAttemptAfterDelete() async throws {
    let fileURL = bookmarkModelTestFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let model = BookmarkModel(store: BookmarkStore(fileURL: fileURL))
    let record = bookmarkPanelRecord(
        id: "00000000-0000-4000-8000-000000000103",
        path: "src/main.rs",
        symbolName: "main",
        note: "keep me",
        updatedAt: .now
    )
    #expect(model.toggle(record) == .added)
    model.workspaceDidChange(to: 1)
    model.beginAttempt(for: record, workspaceGeneration: 1, message: "attempt")
    #expect(await testWaitUntil("bookmark delete attempt") {
        model.lastAttemptMessage?.id == record.id
    })
    #expect(model.attemptMessage(for: record.id) == "attempt")
    #expect(model.attemptMessage(for: UUID()) == nil)
    #expect(model.statusCounts(projectPath: record.projectPath) { _ in .exactContent }
        == [.exactContent: 1])
    #expect(BookmarkStatus.drifted.displayText == "Drifted")
    #expect(BookmarkStatus.drifted.tooltip == "Drifted")
    #expect(model.toggle(record) == .confirmationRequired(record.id))
    #expect(model.records == [record])
    #expect(model.delete(id: record.id))
    #expect(model.records.isEmpty)
    #expect(model.lastAttemptMessage == nil)
    #expect(model.filteredRecords(projectPath: record.projectPath).isEmpty)

    let empty = bookmarkPanelRecord(
        id: "00000000-0000-4000-8000-000000000108",
        path: "src/empty.rs", symbolName: nil, note: "", updatedAt: .now
    )
    #expect(model.toggle(empty) == .added)
    #expect(model.toggle(empty) == .deleted)
    #expect(model.records.isEmpty)
}

@MainActor
@Test
func bookmarkModelReanchorsOnlyWorktreeRecordsAndClampsLineOpenWithoutMutation() async throws {
    let fileURL = bookmarkModelTestFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let model = BookmarkModel(store: BookmarkStore(fileURL: fileURL))
    let bytes = Array("fn one() {}\nfn two() {}\n".utf8)
    let document = ReaderDocument(bytes: bytes, outlineFacets: [
        OutlineFacet(
            kind: .impl,
            name: "outer",
            range: ByteRange(lowerBound: 0, upperBound: UInt32(bytes.count)),
            nameRange: ByteRange(lowerBound: 0, upperBound: 1),
            depth: 0
        ),
        OutlineFacet(
            kind: .fn,
            name: "one",
            range: ByteRange(lowerBound: 0, upperBound: 12),
            nameRange: ByteRange(lowerBound: 3, upperBound: 6),
            depth: 1
        ),
    ])
    let currentID = document.contentID
    let conflict = BookmarkRecord(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000104")!,
        projectPath: "/tmp/project", snapshot: .worktree, path: "src/main.rs",
        contentID: currentID, byteOffset: document.lineTable.lineStarts[1], line: 2,
        symbolName: nil, symbolKind: nil, note: "other", updatedAt: .now
    )
    let source = bookmarkPanelRecord(
        id: "00000000-0000-4000-8000-000000000105",
        path: "src/main.rs", symbolName: nil, note: "keep", updatedAt: .distantPast
    )
    #expect(model.toggle(conflict) == .added)
    #expect(model.toggle(source) == .added)
    let target = try #require(model.lineTarget(in: document, requestedLine: 99))
    #expect(target.line == UInt32(document.lineTable.lineStarts.count))
    #expect(target.byteOffset == document.lineTable.lineStarts.last)
    #expect(model.records.first(where: { $0.id == source.id }) == source)
    #expect(model.reanchorWorktree(id: source.id, document: document, line: 2)
        == .conflict(conflict.id))
    #expect(model.records.first(where: { $0.id == source.id }) == source)
    model.workspaceDidChange(to: 1)
    model.beginAttempt(for: source, workspaceGeneration: 1, message: "Bookmark content has drifted.")
    #expect(await testWaitUntil("reanchor failed attempt") { model.attemptMessage(for: source.id) != nil })
    #expect(model.reanchorWorktree(
        id: source.id,
        document: document,
        line: 1,
        updatedAt: Date(timeIntervalSince1970: 20)
    ) == .updated)
    let reanchored = try #require(model.records.first(where: { $0.id == source.id }))
    #expect(model.attemptMessage(for: source.id) == nil)
    #expect(reanchored.contentID == currentID)
    #expect(reanchored.byteOffset == 0)
    #expect(reanchored.line == 1)
    #expect(reanchored.note == source.note)
    #expect(reanchored.updatedAt == Date(timeIntervalSince1970: 20))
    #expect(reanchored.symbolName == "one")
    #expect(reanchored.symbolKind == OutlineKind.fn.rawValue)

    let committed = bookmarkPanelRecord(
        id: "00000000-0000-4000-8000-000000000106",
        path: "src/commit.rs", symbolName: nil, note: "", updatedAt: .now
    )
    let commitRecord = BookmarkRecord(
        id: committed.id, projectPath: committed.projectPath,
        snapshot: .commit(fullOID: String(repeating: "a", count: 40)), path: committed.path,
        contentID: committed.contentID, byteOffset: committed.byteOffset, line: committed.line,
        symbolName: committed.symbolName, symbolKind: committed.symbolKind,
        note: committed.note, updatedAt: committed.updatedAt
    )
    #expect(model.toggle(commitRecord) == .added)
    #expect(model.reanchorWorktree(id: commitRecord.id, document: document, line: 1)
        == .unsupportedSnapshot)
}

@MainActor
@Test
func bookmarkModelRetainsLoadRescueAndDirtyMemoryWhenPersistenceFails() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BookmarkModelTests-\(UUID().uuidString)")
    let fileURL = directory.appendingPathComponent("bookmarks.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let corrupt = Data("{bad".utf8)
    try corrupt.write(to: fileURL)
    let rescued = BookmarkModel(store: BookmarkStore(fileURL: fileURL))
    #expect(rescued.records.isEmpty)
    #expect(rescued.storageError == .corrupt)
    #expect(rescued.rescueBytes == corrupt)
    let preserved = bookmarkPanelRecord(
        id: "00000000-0000-4000-8000-000000000109",
        path: "src/preserved.rs", symbolName: nil, note: "", updatedAt: .now
    )
    #expect(rescued.toggle(preserved) == .rejected)
    #expect(!rescued.isDirty)
    #expect(rescued.storageError == .corrupt)
    #expect(try BookmarkStore(fileURL: fileURL).rawBytes() == corrupt)

    try FileManager.default.removeItem(at: fileURL)
    try Data().write(to: fileURL)
    let blockedURL = fileURL.appendingPathComponent("bookmarks.json")
    let dirty = BookmarkModel(store: BookmarkStore(fileURL: blockedURL))
    let record = bookmarkPanelRecord(
        id: "00000000-0000-4000-8000-000000000107",
        path: "src/dirty.rs", symbolName: nil, note: "", updatedAt: .now
    )
    #expect(dirty.toggle(record) == .added)
    #expect(dirty.records == [record])
    #expect(dirty.isDirty)
    #expect(dirty.storageError == .writeFailed)
}

@MainActor
@Test
func bookmarkModelRejectsSemanticStoreFailuresWithoutKeepingInvalidMemory() throws {
    let fileURL = bookmarkModelTestFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = BookmarkStore(fileURL: fileURL)
    let existing = (0..<BookmarkStore.maximumRecordCount).map { index in
        bookmarkPanelRecord(
            id: String(format: "00000000-0000-4000-8000-%012x", 0x200 + index),
            path: "src/\(index).rs", symbolName: nil, note: "",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
    }
    try store.replace(existing)
    let model = BookmarkModel(store: store)
    let bytes = try store.rawBytes()
    let overflow = bookmarkPanelRecord(
        id: "00000000-0000-4000-8000-000000000299",
        path: "src/overflow.rs", symbolName: nil, note: "", updatedAt: .now
    )
    #expect(model.toggle(overflow) == .rejected)
    #expect(model.records == existing)
    #expect(model.storageError == .tooManyRecords)
    #expect(!model.isDirty)
    #expect(try store.rawBytes() == bytes)

    let invalid = BookmarkRecord(
        id: existing[0].id, projectPath: existing[0].projectPath,
        snapshot: existing[0].snapshot, path: existing[0].path,
        contentID: existing[0].contentID, byteOffset: existing[0].byteOffset,
        line: existing[0].line, symbolName: existing[0].symbolName,
        symbolKind: existing[0].symbolKind,
        note: String(repeating: "x", count: BookmarkStore.maximumNoteBytes + 1),
        updatedAt: existing[0].updatedAt
    )
    #expect(!model.update(invalid))
    #expect(model.records == existing)
    #expect(model.storageError == .invalidRecord)
    #expect(!model.isDirty)
    #expect(try store.rawBytes() == bytes)
}

@MainActor
@Test
func bookmarkAttemptDropsTheOlderResultAndClearsOnWorkspaceChange() async throws {
    let model = BookmarkModel()
    let record = bookmarkModelRecord()
    model.workspaceDidChange(to: 4)
    model.beginAttempt(for: record, workspaceGeneration: 4) {
        try? await Task.sleep(for: .milliseconds(25))
        return .revisionUnavailable
    }
    model.beginAttempt(for: record, workspaceGeneration: 4) { .fileAbsent }

    #expect(await testWaitUntil("latest bookmark attempt") {
        model.lastAttemptMessage?.id == record.id
    })
    #expect(model.lastAttemptMessage?.id == record.id)
    #expect(model.lastAttemptMessage?.message == BookmarkStatus.fileAbsent.attemptMessage)

    model.workspaceDidChange(to: 5)
    #expect(model.lastAttemptMessage == nil)
}

@MainActor
@Test
func bookmarkAttemptDeletedBeforeCompletionCannotPublish() async throws {
    let model = BookmarkModel()
    let record = bookmarkModelRecord()
    model.workspaceDidChange(to: 4)
    model.beginAttempt(for: record, workspaceGeneration: 4) {
        try? await Task.sleep(for: .milliseconds(25))
        return .fileAbsent
    }
    model.clearAttempt(for: record.id)

    try await Task.sleep(for: .milliseconds(50))
    #expect(model.lastAttemptMessage == nil)
}

@MainActor
@Test
func appModelSingleLanguageOpenSynchronizesBookmarkWorkspaceGeneration() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn main() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: ProjectIndexService())

    let generationBeforeOpen = model.generation
    try model.openProject(root: root, language: .rust)

    #expect(model.generation == generationBeforeOpen + 1)
    #expect(model.bookmarkModel.workspaceGeneration == model.generation)
    #expect(await testWaitUntil("single-language project ready") {
        model.snapshotPhase == .fullReady
    })
}

@MainActor
@Test
func persistedCrossSnapshotBookmarkAttemptSurvivesSingleLanguageOpen() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn main() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionURL = root
        .deletingLastPathComponent()
        .appendingPathComponent("BookmarkModelTests-\(UUID().uuidString)")
        .appendingPathComponent("session.json")
    defer { try? FileManager.default.removeItem(at: sessionURL.deletingLastPathComponent()) }
    let record = bookmarkModelRecord(
        id: UUID(),
        projectPath: root.path,
        byteOffset: 3,
        updatedAt: .now
    )
    try BookmarkStore(
        fileURL: sessionURL.deletingLastPathComponent().appendingPathComponent("bookmarks.json")
    ).replace([record])
    let model = AppModel(
        sessionURL: sessionURL,
        indexService: ProjectIndexService()
    )
    #expect(model.bookmarkModel.records.map(\.id) == [record.id])

    try model.openProject(root: root, language: .rust)
    #expect(await testWaitUntil("single-language project ready before bookmark open") {
        model.snapshotPhase == .fullReady
    })

    model.openStrictBookmark(
        record,
        leaving: JumpRecord(
            path: "src/main.rs",
            contentID: nil,
            byteOffset: 0,
            line: 1,
            column: 1,
            symbolAnchor: nil,
            snapshotID: model.currentSnapshotID
        )
    )

    #expect(await testWaitUntil("persisted cross-snapshot bookmark attempt") {
        model.bookmarkModel.lastAttemptMessage?.id == record.id
    })
    #expect(model.bookmarkModel.lastAttemptMessage?.message
        == BookmarkStatus.revisionUnavailable.attemptMessage)
}

@MainActor
@Test
func featureSelectionChangeClearsOlderBookmarkAttempt() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn main() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: ProjectIndexService())
    try model.openProject(root: root, language: .rust)
    #expect(await testWaitUntil("feature switch project ready") {
        model.snapshotPhase == .fullReady
    })

    model.bookmarkModel.workspaceDidChange(to: model.generation)
    let record = bookmarkModelRecord(snapshot: .worktree)
    let generationBeforeSwitch = model.generation
    model.bookmarkModel.beginAttempt(
        for: record,
        workspaceGeneration: generationBeforeSwitch
    ) {
        try? await Task.sleep(for: .milliseconds(50))
        return .drifted
    }

    model.switchFeatureSelection(.allFeatures)

    #expect(model.generation == generationBeforeSwitch + 1)
    #expect(model.bookmarkModel.workspaceGeneration == model.generation)
    #expect(model.bookmarkModel.lastAttemptMessage == nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.bookmarkModel.lastAttemptMessage == nil)
}

@MainActor
@Test
func appModelPreflightPublishesOnlyTransientMissingCommitAttempts() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn committed() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    try bookmarkModelGit(root, "add", ".")
    try bookmarkModelGit(
        root,
        "-c", "user.name=Bookmark Test",
        "-c", "user.email=bookmark@example.invalid",
        "commit", "-qm", "initial"
    )
    let model = AppModel(indexService: ProjectIndexService())
    try await model.openProject(root: root, languages: [.rust])

    let unavailable = bookmarkModelRecord(
        snapshot: .commit(fullOID: String(repeating: "a", count: 40))
    )
    #expect(model.bookmarkStatus(for: unavailable) == .notEvaluated)
    model.preflightBookmark(unavailable)
    #expect(await testWaitUntil("unavailable bookmark attempt") {
        model.bookmarkModel.lastAttemptMessage?.id == unavailable.id
    })
    #expect(model.bookmarkModel.lastAttemptMessage?.message
        == BookmarkStatus.revisionUnavailable.attemptMessage)
    #expect(model.bookmarkStatus(for: unavailable) == .notEvaluated)

    let fullOID = try bookmarkModelGitOutput(root, "rev-parse", "HEAD")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let missingFile = BookmarkRecord(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
        projectPath: root.path,
        snapshot: .commit(fullOID: fullOID),
        path: "src/missing.rs",
        contentID: ContentID.sha256(of: Data("missing".utf8)),
        byteOffset: 0,
        line: 1,
        symbolName: nil,
        symbolKind: nil,
        note: "",
        updatedAt: .now
    )
    #expect(model.bookmarkStatus(for: missingFile) == .notEvaluated)
    model.preflightBookmark(missingFile)
    #expect(await testWaitUntil("missing file bookmark attempt") {
        model.bookmarkModel.lastAttemptMessage?.id == missingFile.id
    })
    #expect(model.bookmarkModel.lastAttemptMessage?.message
        == BookmarkStatus.fileAbsent.attemptMessage)
    #expect(model.bookmarkStatus(for: missingFile) == .notEvaluated)
}

@MainActor
@Test
func appModelExplicitBookmarkLineOpenUsesCapturedWorktreeBytesWithoutReanchoring() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn one() {}\nfn two() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("src/main.rs")
    let model = AppModel(indexService: ProjectIndexService())
    try await model.openProject(root: root, languages: [.rust])
    let captured = try #require(model.capturedProjectSource(at: "src/main.rs"))
    let bookmarkURL = bookmarkModelTestFileURL()
    defer { try? FileManager.default.removeItem(at: bookmarkURL.deletingLastPathComponent()) }
    model.bookmarkModel = BookmarkModel(store: BookmarkStore(fileURL: bookmarkURL))
    let record = BookmarkRecord(
        id: UUID(), projectPath: root.path, snapshot: .worktree, path: "src/main.rs",
        contentID: captured.contentID, byteOffset: 0, line: 1,
        symbolName: nil, symbolKind: nil, note: "keep", updatedAt: .now
    )
    #expect(model.bookmarkModel.toggle(record) == .added)
    try "fn changed() {}\n".write(to: file, atomically: true, encoding: .utf8)

    let target = try #require(model.explicitBookmarkLineOpen(record, line: 99))

    let capturedDocument = ReaderDocument(bytes: captured.bytes)
    #expect(target.file == file.standardizedFileURL)
    #expect(target.line == UInt32(capturedDocument.lineTable.lineStarts.count))
    #expect(target.byteOffset == capturedDocument.lineTable.lineStarts.last)
    #expect(record.byteOffset == 0)
    #expect(record.updatedAt <= .now)
    #expect(model.reanchorBookmark(
        id: record.id,
        line: 2,
        updatedAt: Date(timeIntervalSince1970: 20)
    ) == .updated)
    let reanchored = try #require(model.bookmarkModel.records.first)
    #expect(reanchored.contentID == captured.contentID)
    #expect(reanchored.line == 2)
    #expect(reanchored.symbolName == "two")
    #expect(reanchored.symbolKind == OutlineKind.fn.rawValue)
}

@MainActor
@Test
func appModelCapturesOnlyTheCurrentReaderDocumentMatchingCapturedSource() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn captured() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("src/main.rs")
    let model = AppModel(indexService: ProjectIndexService())
    try await model.openProject(root: root, languages: [.rust])
    let captured = try #require(model.capturedProjectSource(at: "src/main.rs"))
    model.navigate(to: file, byteOffset: 3)
    model.tabStrip.setActiveDocument(ReaderDocument(
        bytes: captured.bytes,
        outlineFacets: [OutlineFacet(
            kind: .fn,
            name: "captured",
            range: ByteRange(lowerBound: 0, upperBound: UInt32(captured.bytes.count)),
            nameRange: ByteRange(lowerBound: 3, upperBound: 11),
            depth: 0
        )]
    ), for: file)

    #expect(model.bookmarkEligibility() == .eligible)
    let bookmark = try #require(model.captureCurrentBookmark())
    #expect(bookmark.snapshot == .worktree)
    #expect(bookmark.contentID == captured.contentID)
    #expect(bookmark.byteOffset == 3)
    #expect(bookmark.symbolName == "captured")
    #expect(bookmark.symbolKind == OutlineKind.fn.rawValue)

    try "fn changed_on_disk() {}\n".write(to: file, atomically: true, encoding: .utf8)
    #expect(model.captureCurrentBookmark()?.contentID == captured.contentID)

    model.tabStrip.setActiveDocument(
        ReaderDocument(bytes: Array("fn changed_on_disk() {}\n".utf8)),
        for: file
    )
    #expect(model.bookmarkEligibility() == .unavailable(.capturedSourceMismatch))
    #expect(model.captureCurrentBookmark() == nil)
}

@MainActor
@Test
func appModelBookmarkMarkersExcludeOffsetInvalidRecordsEvenWhenContentMatches() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "a😀z\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("src/main.rs")
    let model = AppModel(indexService: ProjectIndexService())
    try await model.openProject(root: root, languages: [.rust])
    let captured = try #require(model.capturedProjectSource(at: "src/main.rs"))
    let document = ReaderDocument(bytes: captured.bytes)
    model.navigate(to: file, byteOffset: 0)
    model.tabStrip.setActiveDocument(document, for: file)
    let valid = BookmarkRecord(
        id: UUID(), projectPath: root.path, snapshot: .worktree, path: "src/main.rs",
        contentID: captured.contentID, byteOffset: 0, line: 1,
        symbolName: "valid", symbolKind: nil, note: "", updatedAt: .now
    )
    let invalid = BookmarkRecord(
        id: UUID(), projectPath: root.path, snapshot: .worktree, path: "src/main.rs",
        contentID: captured.contentID, byteOffset: 2, line: 1,
        symbolName: "invalid", symbolKind: nil, note: "", updatedAt: .now
    )
    #expect(model.bookmarkModel.toggle(valid) == .added)
    #expect(model.bookmarkModel.toggle(invalid) == .added)

    #expect(model.bookmarkMarkers(for: file, document: document) == [1: ["valid"]])
}

@MainActor
@Test
func appModelRefusesToCaptureAnOffsetInsideAMultibyteScalar() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "let value = \"😀\";\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("src/main.rs")
    let model = AppModel(indexService: ProjectIndexService())
    try await model.openProject(root: root, languages: [.rust])
    let captured = try #require(model.capturedProjectSource(at: "src/main.rs"))
    let emojiStart = try #require(captured.bytes.firstIndex(of: 0xf0))
    model.navigate(to: file, byteOffset: UInt32(emojiStart + 1))
    model.tabStrip.setActiveDocument(ReaderDocument(bytes: captured.bytes), for: file)

    #expect(model.bookmarkEligibility() == .unavailable(.noSelection))
    #expect(model.captureCurrentBookmark() == nil)
}

@MainActor
@Test
func appModelCapturesTheResolvedFullCommitOIDRatherThanTheRevisionExpression() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn committed() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    try bookmarkModelGit(root, "add", ".")
    try bookmarkModelGit(
        root,
        "-c", "user.name=Bookmark Test",
        "-c", "user.email=bookmark@example.invalid",
        "commit", "-qm", "initial"
    )

    let file = root.appendingPathComponent("src/main.rs")
    let model = AppModel(indexService: ProjectIndexService())
    try await model.openProject(root: root, languages: [.rust])
    model.switchToCommit("HEAD")
    #expect(await testWaitUntil("commit snapshot ready") {
        model.snapshotPhase == .fullReady && model.currentRevision == "HEAD"
    })
    let captured = try #require(model.capturedProjectSource(at: "src/main.rs"))
    model.navigate(to: file, byteOffset: 3)
    model.tabStrip.setActiveDocument(ReaderDocument(bytes: captured.bytes), for: file)
    let bookmark = try #require(model.captureCurrentBookmark())
    guard case let .commit(fullOID) = bookmark.snapshot else {
        Issue.record("commit capture produced a worktree anchor")
        return
    }
    #expect(fullOID.count == 40)
    #expect(fullOID != "HEAD")
    #expect(fullOID == fullOID.lowercased())
}

@MainActor
@Test
func appModelBookmarkEligibilityNamesUnsupportedSurfaces() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn selected() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("src/main.rs")
    let model = AppModel(indexService: ProjectIndexService())
    try await model.openProject(root: root, languages: [.rust])
    let captured = try #require(model.capturedProjectSource(at: "src/main.rs"))
    model.navigate(to: file, byteOffset: 3)
    model.tabStrip.setActiveDocument(ReaderDocument(bytes: captured.bytes), for: file)
    model.tabStrip.updateActiveSelection(nil)
    model.navigate(to: file)
    #expect(model.bookmarkEligibility() == .unavailable(.noSelection))

    model.openReadingSet(title: "set", excerpts: [])
    #expect(model.bookmarkEligibility() == .unavailable(.readingSet))

    let dependency = FileManager.default.temporaryDirectory
        .appendingPathComponent("BookmarkDependency.rs")
    model.navigate(to: dependency, byteOffset: 0)
    model.tabStrip.setActiveDocument(ReaderDocument(bytes: captured.bytes), for: dependency)
    #expect(model.bookmarkEligibility() == .unavailable(.dependency))

    model.navigate(to: file, byteOffset: 3)
    model.tabStrip.setActiveDocument(ReaderDocument(bytes: captured.bytes), for: file)
    _ = model.compare.beginLoading(revision: "comparison")
    #expect(model.bookmarkEligibility() == .unavailable(.comparison))
}

@MainActor
@Test
func appModelStrictSameSnapshotBookmarkNavigationUsesCapturedBytesExactlyOnce() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn captured_target() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("src/main.rs")
    let sink = BookmarkNavigationSink()
    let model = AppModel(
        indexService: ProjectIndexService(),
        navigationSink: { file, offset in sink.values.append((file, offset)) }
    )
    try await model.openProject(root: root, languages: [.rust])
    let captured = try #require(model.capturedProjectSource(at: "src/main.rs"))
    model.navigate(to: file, byteOffset: 3)
    model.tabStrip.setActiveDocument(ReaderDocument(bytes: captured.bytes), for: file)
    let record = try #require(model.captureCurrentBookmark())
    let original = JumpRecord(
        path: "src/main.rs",
        contentID: record.contentID,
        byteOffset: 0,
        line: 1,
        column: 1,
        symbolAnchor: nil,
        snapshotID: model.currentSnapshotID
    )
    let snapshotID = model.currentSnapshotID
    let historyCount = model.navigationHistory.records.count
    sink.values.removeAll()
    try "fn changed_on_disk() {}\n".write(to: file, atomically: true, encoding: .utf8)

    model.openStrictBookmark(record, leaving: original)

    #expect(sink.values.count == 1)
    #expect(sink.values.first?.0 == file.standardizedFileURL)
    #expect(sink.values.first?.1 == record.byteOffset)
    #expect(model.navigationHistory.records.count == historyCount + 1)
    #expect(model.navigationHistory.records.last == original)
    #expect(model.currentSnapshotID == snapshotID)
    #expect(model.hasPendingReplay == false)
    let source = try #require(model.documentSource)
    let document = try DocumentLoader(source: source).load(file: file).document
    #expect(document.contentID == record.contentID)
    #expect(document.bytes == captured.bytes)

    sink.values.removeAll()
    model.goBack(from: JumpRecord(
        path: record.path,
        contentID: record.contentID,
        byteOffset: record.byteOffset,
        line: record.line,
        column: 1,
        symbolAnchor: record.symbolName,
        snapshotID: model.currentSnapshotID
    ))
    #expect(await testWaitUntil("strict bookmark goBack replay") {
        model.selectedFile == file.standardizedFileURL && model.selectedByteOffset == 0
    })
    #expect(model.activeNavigationRequest?.cause == .historyReplay)
    #expect(sink.values.last?.0 == file.standardizedFileURL)
    #expect(sink.values.last?.1 == 0)
}

@MainActor
@Test
func appModelStrictSameCommitBookmarkNavigationUsesCapturedCommitBytes() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn committed_target() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    try bookmarkModelGit(root, "add", ".")
    try bookmarkModelGit(
        root,
        "-c", "user.name=Bookmark Test",
        "-c", "user.email=bookmark@example.invalid",
        "commit", "-qm", "initial"
    )
    let file = root.appendingPathComponent("src/main.rs")
    let sink = BookmarkNavigationSink()
    let model = AppModel(
        indexService: ProjectIndexService(),
        navigationSink: { file, offset in sink.values.append((file, offset)) }
    )
    try await model.openProject(root: root, languages: [.rust])
    model.switchToCommit("HEAD")
    #expect(await testWaitUntil("strict commit snapshot ready") {
        model.snapshotPhase == .fullReady && model.currentRevision == "HEAD"
    })
    let captured = try #require(model.capturedProjectSource(at: "src/main.rs"))
    model.navigate(to: file, byteOffset: 3)
    model.tabStrip.setActiveDocument(ReaderDocument(bytes: captured.bytes), for: file)
    let record = try #require(model.captureCurrentBookmark())
    guard case let .commit(fullOID) = record.snapshot else {
        Issue.record("strict commit bookmark did not retain a full OID")
        return
    }
    #expect(fullOID.count == 40)
    let original = JumpRecord(
        path: record.path,
        contentID: record.contentID,
        byteOffset: 0,
        line: 1,
        column: 1,
        symbolAnchor: nil,
        snapshotID: model.currentSnapshotID,
        revision: model.currentRevision
    )
    let historyCount = model.navigationHistory.records.count
    sink.values.removeAll()
    try "fn changed_worktree() {}\n".write(to: file, atomically: true, encoding: .utf8)

    model.openStrictBookmark(record, leaving: original)

    #expect(sink.values.count == 1)
    #expect(model.navigationHistory.records.count == historyCount + 1)
    #expect(model.hasPendingReplay == false)
    let source = try #require(model.documentSource)
    let document = try DocumentLoader(source: source).load(file: file).document
    #expect(document.contentID == record.contentID)
    #expect(document.bytes == captured.bytes)
}

@MainActor
@Test
func appModelStrictSameSnapshotNonExactAndProjectMismatchOnlyPublishAttempts() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn target() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("src/main.rs")
    let sink = BookmarkNavigationSink()
    let model = AppModel(
        indexService: ProjectIndexService(),
        navigationSink: { file, offset in sink.values.append((file, offset)) }
    )
    try await model.openProject(root: root, languages: [.rust])
    let captured = try #require(model.capturedProjectSource(at: "src/main.rs"))
    model.navigate(to: file, byteOffset: 3)
    model.tabStrip.setActiveDocument(ReaderDocument(bytes: captured.bytes), for: file)
    let exact = try #require(model.captureCurrentBookmark())
    let original = JumpRecord(
        path: exact.path,
        contentID: exact.contentID,
        byteOffset: 0,
        line: 1,
        column: 1,
        symbolAnchor: nil,
        snapshotID: model.currentSnapshotID
    )
    let historyCount = model.navigationHistory.records.count
    let selectedFile = model.selectedFile
    let selectedOffset = model.selectedByteOffset
    sink.values.removeAll()

    let drifted = BookmarkRecord(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
        projectPath: exact.projectPath,
        snapshot: exact.snapshot,
        path: exact.path,
        contentID: ContentID.sha256(of: Data("different".utf8)),
        byteOffset: exact.byteOffset,
        line: exact.line,
        symbolName: nil,
        symbolKind: nil,
        note: "",
        updatedAt: exact.updatedAt
    )
    model.openStrictBookmark(drifted, leaving: original)
    #expect(await testWaitUntil("drifted strict attempt") {
        model.bookmarkModel.lastAttemptMessage?.id == drifted.id
    })
    #expect(model.bookmarkModel.lastAttemptMessage?.message == BookmarkStatus.drifted.attemptMessage)
    #expect(sink.values.isEmpty)
    #expect(model.navigationHistory.records.count == historyCount)
    #expect(model.selectedFile == selectedFile)
    #expect(model.selectedByteOffset == selectedOffset)
    #expect(model.documentSource == nil)
    #expect(model.hasPendingReplay == false)

    let missingFile = BookmarkRecord(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000005")!,
        projectPath: exact.projectPath,
        snapshot: exact.snapshot,
        path: "src/missing.rs",
        contentID: exact.contentID,
        byteOffset: exact.byteOffset,
        line: exact.line,
        symbolName: nil,
        symbolKind: nil,
        note: "",
        updatedAt: exact.updatedAt
    )
    model.openStrictBookmark(missingFile, leaving: original)
    #expect(await testWaitUntil("missing strict attempt") {
        model.bookmarkModel.lastAttemptMessage?.id == missingFile.id
    })
    #expect(model.bookmarkModel.lastAttemptMessage?.message == BookmarkStatus.fileAbsent.attemptMessage)

    let invalidOffset = BookmarkRecord(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000006")!,
        projectPath: exact.projectPath,
        snapshot: exact.snapshot,
        path: exact.path,
        contentID: exact.contentID,
        byteOffset: UInt32(captured.bytes.count + 1),
        line: exact.line,
        symbolName: nil,
        symbolKind: nil,
        note: "",
        updatedAt: exact.updatedAt
    )
    model.openStrictBookmark(invalidOffset, leaving: original)
    #expect(await testWaitUntil("invalid-offset strict attempt") {
        model.bookmarkModel.lastAttemptMessage?.id == invalidOffset.id
    })
    #expect(model.bookmarkModel.lastAttemptMessage?.message == BookmarkStatus.offsetInvalid.attemptMessage)
    #expect(sink.values.isEmpty)
    #expect(model.navigationHistory.records.count == historyCount)
    #expect(model.selectedFile == selectedFile)
    #expect(model.selectedByteOffset == selectedOffset)
    #expect(model.hasPendingReplay == false)

    let otherProject = BookmarkRecord(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
        projectPath: "/tmp/another-project",
        snapshot: exact.snapshot,
        path: exact.path,
        contentID: exact.contentID,
        byteOffset: exact.byteOffset,
        line: exact.line,
        symbolName: nil,
        symbolKind: nil,
        note: "",
        updatedAt: exact.updatedAt
    )
    model.openStrictBookmark(otherProject, leaving: original)
    #expect(await testWaitUntil("project mismatch strict attempt") {
        model.bookmarkModel.lastAttemptMessage?.id == otherProject.id
    })
    #expect(sink.values.isEmpty)
    #expect(model.navigationHistory.records.count == historyCount)
    #expect(model.selectedFile == selectedFile)
    #expect(model.selectedByteOffset == selectedOffset)
    #expect(model.hasPendingReplay == false)
}

private func bookmarkModelRecord(
    id: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
    projectPath: String = "/tmp/project",
    snapshot: BookmarkRecord.SnapshotAnchor = .commit(fullOID: String(repeating: "a", count: 40)),
    byteOffset: UInt32 = 0,
    updatedAt: Date = Date(timeIntervalSince1970: 1_786_270_000)
) -> BookmarkRecord {
    BookmarkRecord(
        id: id,
        projectPath: projectPath,
        snapshot: snapshot,
        path: "src/main.rs",
        contentID: ContentID.sha256(of: Data("fn saved() {}\n".utf8)),
        byteOffset: byteOffset,
        line: 1,
        symbolName: nil,
        symbolKind: nil,
        note: "",
        updatedAt: updatedAt
    )
}

private func bookmarkModelTemporaryGitProject(source: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BookmarkModelTests-\(UUID().uuidString)")
    let file = root.appendingPathComponent("src/main.rs")
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try source.write(to: file, atomically: true, encoding: .utf8)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path, "init", "-q"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    return root
}

private func bookmarkModelGit(_ root: URL, _ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = root
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
}

private func bookmarkModelGitOutput(_ root: URL, _ arguments: String...) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = root
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

@MainActor
private final class BookmarkNavigationSink {
    var values: [(URL, UInt32?)] = []
}

@MainActor
@Test
func appModelStrictCrossSnapshotSecondAttemptWinsWhenFirstPrepareCompletesStale() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn committed() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    try bookmarkModelGit(root, "add", ".")
    try bookmarkModelGit(
        root,
        "-c", "user.name=Bookmark Test",
        "-c", "user.email=bookmark@example.invalid",
        "commit", "-qm", "initial"
    )
    let commit = try bookmarkModelGitOutput(root, "rev-parse", "HEAD")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let initial = TestSnapshot(label: "initial", files: ["src/main.rs": "fn initial() {}\n"])
    let first = TestSnapshot(label: "first", files: ["src/main.rs": "fn first() {}\n"])
    let second = TestSnapshot(label: "second", files: ["src/main.rs": "fn second() {}\n"])
    let service = ControlledSnapshotIndexService(
        initialSession: try ProjectIndexer().index(root: root),
        worktreeSnapshot: initial,
        snapshots: [:],
        externalSnapshots: [
            commit: try CommitSnapshot(repositoryURL: root, revision: commit),
        ],
        blockedCached: ["first"],
        blockedFull: ["second"],
        ignoresCachedCancellation: ["first"]
    )
    let model = AppModel(indexService: service)
    try await model.openProject(root: root, languages: [.rust])
    model.switchToCommit(commit)
    #expect(await testWaitUntil("controlled commit ready") {
        model.snapshotPhase == .fullReady && model.currentRevision == commit
    })
    let historyCount = model.navigationHistory.records.count
    let original = JumpRecord(
        path: "src/main.rs",
        contentID: ContentID.sha256(of: Data("fn committed() {}\n".utf8)),
        byteOffset: 0,
        line: 1,
        column: 1,
        symbolAnchor: nil,
        snapshotID: model.currentSnapshotID,
        revision: commit
    )
    let firstRecord = BookmarkRecord(
        id: UUID(), projectPath: root.path, snapshot: .worktree,
        path: "src/main.rs",
        contentID: ContentID.sha256(of: Data("fn first() {}\n".utf8)),
        byteOffset: 3, line: 1, symbolName: nil, symbolKind: nil, note: "", updatedAt: .now
    )
    let secondRecord = BookmarkRecord(
        id: UUID(), projectPath: root.path, snapshot: .worktree,
        path: "src/main.rs",
        contentID: ContentID.sha256(of: Data("fn second() {}\n".utf8)),
        byteOffset: 3, line: 1, symbolName: nil, symbolKind: nil, note: "", updatedAt: .now
    )
    await service.setWorktreeSnapshot(first)
    model.openStrictBookmark(firstRecord, leaving: original)
    #expect(await testWaitUntil("first strict prepare blocked") {
        await service.hasStartedCached("first")
    })

    await service.setWorktreeSnapshot(second)
    model.openStrictBookmark(secondRecord, leaving: original)
    #expect(await testWaitUntil("second strict cached install") {
        model.snapshotPhase == .cachedReady && model.currentSnapshotID == second.snapshotID
    })
    let winningAttempt = model.bookmarkModel.bookmarkAttemptGeneration
    #expect(model.navigationHistory.records.count == historyCount + 1)
    #expect(model.navigationHistory.records.last == original)
    let source = try #require(model.documentSource)
    let document = try DocumentLoader(source: source)
        .load(file: root.appendingPathComponent(secondRecord.path)).document
    #expect(document.contentID == secondRecord.contentID)
    #expect(document.bytes == Array("fn second() {}\n".utf8))

    await service.releaseCached("first")
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.bookmarkModel.bookmarkAttemptGeneration == winningAttempt)
    #expect(model.currentSnapshotID == second.snapshotID)
    #expect(model.currentRevision == nil)
    #expect(model.snapshotPhase == .cachedReady)
    #expect(model.navigationHistory.records.count == historyCount + 1)
    #expect(model.bookmarkModel.lastAttemptMessage == nil)
    let retained = try #require(model.documentSource)
    let after = try DocumentLoader(source: retained)
        .load(file: root.appendingPathComponent(secondRecord.path)).document
    #expect(after.contentID == secondRecord.contentID)
    #expect(after.bytes == Array("fn second() {}\n".utf8))

    await service.releaseFull("second")
    #expect(await testWaitUntil("second strict full install") {
        model.snapshotPhase == .fullReady && model.currentSnapshotID == second.snapshotID
    })
}

@MainActor
@Test
func appModelStrictCrossSnapshotWorktreeMismatchPublishesOnlyDriftedAttempt() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn committed() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    try bookmarkModelGit(root, "add", ".")
    try bookmarkModelGit(
        root,
        "-c", "user.name=Bookmark Test",
        "-c", "user.email=bookmark@example.invalid",
        "commit", "-qm", "initial"
    )
    let commit = try bookmarkModelGitOutput(root, "rev-parse", "HEAD")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let initial = TestSnapshot(label: "initial", files: ["src/main.rs": "fn initial() {}\n"])
    let drifted = TestSnapshot(label: "drifted", files: ["src/main.rs": "fn now() {}\n"])
    let service = ControlledSnapshotIndexService(
        initialSession: try ProjectIndexer().index(root: root),
        worktreeSnapshot: initial,
        snapshots: [:],
        externalSnapshots: [
            commit: try CommitSnapshot(repositoryURL: root, revision: commit),
        ]
    )
    let model = AppModel(indexService: service)
    try await model.openProject(root: root, languages: [.rust])
    model.switchToCommit(commit)
    #expect(await testWaitUntil("controlled commit ready") {
        model.snapshotPhase == .fullReady && model.currentRevision == commit
    })
    let file = root.appendingPathComponent("src/main.rs")
    model.navigate(to: file, byteOffset: 2)
    let generation = model.generation
    let snapshotID = model.currentSnapshotID
    let historyCount = model.navigationHistory.records.count
    let selectedFile = model.selectedFile
    let selectedOffset = model.selectedByteOffset
    let source = try #require(model.documentSource)
    let document = try DocumentLoader(source: source).load(file: file).document
    await service.setWorktreeSnapshot(drifted)
    let record = BookmarkRecord(
        id: UUID(), projectPath: root.path, snapshot: .worktree,
        path: "src/main.rs",
        contentID: ContentID.sha256(of: Data("fn saved() {}\n".utf8)),
        byteOffset: 3, line: 1, symbolName: nil, symbolKind: nil, note: "", updatedAt: .now
    )
    let original = JumpRecord(
        path: "src/main.rs", contentID: document.contentID, byteOffset: 2, line: 1, column: 1,
        symbolAnchor: nil, snapshotID: snapshotID, revision: commit
    )

    model.openStrictBookmark(record, leaving: original)

    #expect(await testWaitUntil("drifted strict attempt") {
        model.bookmarkModel.lastAttemptMessage?.id == record.id
    })
    #expect(model.bookmarkModel.lastAttemptMessage?.message == BookmarkStatus.drifted.attemptMessage)
    #expect(model.generation == generation)
    #expect(model.currentRevision == commit)
    #expect(model.currentSnapshotID == snapshotID)
    #expect(model.selectedFile == selectedFile)
    #expect(model.selectedByteOffset == selectedOffset)
    #expect(model.navigationHistory.records.count == historyCount)
    #expect(model.snapshotPhase == .fullReady)
    guard case .ready = model.projectState else {
        Issue.record("worktree drift must not fail the existing workspace")
        return
    }
    let retained = try #require(model.documentSource)
    let after = try DocumentLoader(source: retained).load(file: file).document
    #expect(after.contentID == document.contentID)
    #expect(after.bytes == document.bytes)
}

@MainActor
@Test
func appModelStrictCrossSnapshotRejectsInvalidCachedPreparedSessionsWithoutMutation() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn committed() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    try bookmarkModelGit(root, "add", ".")
    try bookmarkModelGit(
        root,
        "-c", "user.name=Bookmark Test",
        "-c", "user.email=bookmark@example.invalid",
        "commit", "-qm", "initial"
    )
    let commit = try bookmarkModelGitOutput(root, "rev-parse", "HEAD")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let initial = TestSnapshot(label: "initial", files: ["src/main.rs": "fn initial() {}\n"])
    let target = TestSnapshot(label: "target", files: [
        "src/main.rs": "fn target() {}\n",
        "src/foreign.py": "def target():\n    pass\n",
    ])
    let service = ControlledSnapshotIndexService(
        initialSession: try ProjectIndexer().index(root: root),
        worktreeSnapshot: initial,
        snapshots: [:],
        externalSnapshots: [
            commit: try CommitSnapshot(repositoryURL: root, revision: commit),
        ],
        cachedLanguageOverrides: ["target": .python]
    )
    let model = AppModel(indexService: service)
    try await model.openProject(root: root, languages: [.rust])
    model.switchToCommit(commit)
    #expect(await testWaitUntil("controlled commit ready") {
        model.snapshotPhase == .fullReady && model.currentRevision == commit
    })
    let file = root.appendingPathComponent("src/main.rs")
    model.navigate(to: file, byteOffset: 2)
    let generation = model.generation
    let snapshotID = model.currentSnapshotID
    let historyCount = model.navigationHistory.records.count
    let installed = model.lastInstalledWorkspace
    let selectedFile = model.selectedFile
    let selectedOffset = model.selectedByteOffset
    let treeNames = model.fileTree?.children.flatMap { [$0.name] + $0.children.map(\.name) }
    let source = try #require(model.documentSource)
    let document = try DocumentLoader(source: source).load(file: file).document
    guard case let .ready(session, context) = model.projectState else {
        Issue.record("expected committed workspace before strict install")
        return
    }
    await service.setWorktreeSnapshot(target)
    let record = BookmarkRecord(
        id: UUID(), projectPath: root.path, snapshot: .worktree,
        path: "src/main.rs",
        contentID: ContentID.sha256(of: Data("fn target() {}\n".utf8)),
        byteOffset: 3, line: 1, symbolName: nil, symbolKind: nil, note: "", updatedAt: .now
    )
    let original = JumpRecord(
        path: "src/main.rs", contentID: document.contentID, byteOffset: 2, line: 1, column: 1,
        symbolAnchor: nil, snapshotID: snapshotID, revision: commit
    )

    model.openStrictBookmark(record, leaving: original)

    #expect(await testWaitUntil("strict install attempt") {
        model.bookmarkModel.lastAttemptMessage?.id == record.id
    })
    #expect(model.bookmarkModel.lastAttemptMessage?.message == "Bookmark snapshot install failed.")
    #expect(model.generation == generation)
    #expect(model.currentRevision == commit)
    #expect(model.currentSnapshotID == snapshotID)
    #expect(model.fileTree?.children.flatMap { [$0.name] + $0.children.map(\.name) } == treeNames)
    #expect(model.selectedFile == selectedFile)
    #expect(model.selectedByteOffset == selectedOffset)
    #expect(model.navigationHistory.records.count == historyCount)
    #expect(model.snapshotPhase == .fullReady)
    #expect(model.lastInstalledWorkspace.projectRoot == installed.projectRoot)
    #expect(model.lastInstalledWorkspace.revision == installed.revision)
    #expect(model.lastInstalledWorkspace.generation == installed.generation)
    guard case let .ready(afterSession, afterContext) = model.projectState else {
        Issue.record("invalid cached sessions must not fail the existing workspace")
        return
    }
    #expect(afterSession.snapshotID == session.snapshotID)
    #expect(afterContext.snapshotID == context.snapshotID)
    #expect(afterContext.analysisProfileID == context.analysisProfileID)
    #expect(afterContext.generation == context.generation)
    let retained = try #require(model.documentSource)
    let afterDocument = try DocumentLoader(source: retained).load(file: file).document
    #expect(afterDocument.contentID == document.contentID)
    #expect(afterDocument.bytes == document.bytes)
}

@MainActor
@Test
func appModelStrictCrossSnapshotCaptureAndPreparationFailuresOnlyPublishAttempts() async throws {
    for failure in ["capture", "prepare"] {
        let root = try bookmarkModelTemporaryGitProject(source: "fn committed() {}\n")
        defer { try? FileManager.default.removeItem(at: root) }
        try bookmarkModelGit(root, "add", ".")
        try bookmarkModelGit(
            root,
            "-c", "user.name=Bookmark Test",
            "-c", "user.email=bookmark@example.invalid",
            "commit", "-qm", "initial"
        )
        let commit = try bookmarkModelGitOutput(root, "rev-parse", "HEAD")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let initial = TestSnapshot(label: "initial", files: ["src/main.rs": "fn initial() {}\n"])
        let target = TestSnapshot(label: "target", files: ["src/main.rs": "fn target() {}\n"])
        let service = ControlledSnapshotIndexService(
            initialSession: try ProjectIndexer().index(root: root),
            worktreeSnapshot: initial,
            snapshots: [:],
            externalSnapshots: [
                commit: try CommitSnapshot(repositoryURL: root, revision: commit),
            ],
            failedCapture: failure == "capture" ? ["target"] : [],
            failedPrepare: failure == "prepare" ? ["target"] : []
        )
        let model = AppModel(indexService: service)
        try await model.openProject(root: root, languages: [.rust])
        model.switchToCommit(commit)
        #expect(await testWaitUntil("controlled commit ready \(failure)") {
            model.snapshotPhase == .fullReady && model.currentRevision == commit
        })
        await service.setWorktreeSnapshot(target)
        let record = BookmarkRecord(
            id: UUID(), projectPath: root.path, snapshot: .worktree,
            path: "src/main.rs",
            contentID: ContentID.sha256(of: Data("fn target() {}\n".utf8)),
            byteOffset: 3, line: 1, symbolName: nil, symbolKind: nil, note: "", updatedAt: .now
        )
        let original = JumpRecord(
            path: "src/main.rs", contentID: nil, byteOffset: 0, line: 1, column: 1,
            symbolAnchor: nil, snapshotID: model.currentSnapshotID, revision: commit
        )
        let generation = model.generation
        let snapshotID = model.currentSnapshotID
        let historyCount = model.navigationHistory.records.count
        let source = try #require(model.documentSource)
        let before = try DocumentLoader(source: source)
            .load(file: root.appendingPathComponent(record.path)).document

        model.openStrictBookmark(record, leaving: original)

        #expect(await testWaitUntil("strict \(failure) attempt") {
            model.bookmarkModel.lastAttemptMessage?.id == record.id
        })
        #expect(model.bookmarkModel.lastAttemptMessage?.message == (
            failure == "capture"
                ? "Bookmark snapshot capture failed."
                : "Bookmark snapshot preparation failed."
        ))
        #expect(model.generation == generation)
        #expect(model.currentRevision == commit)
        #expect(model.currentSnapshotID == snapshotID)
        #expect(model.snapshotPhase == .fullReady)
        #expect(model.navigationHistory.records.count == historyCount)
        guard case .ready = model.projectState else {
            Issue.record("\(failure) must not fail the existing workspace")
            continue
        }
        let retained = try #require(model.documentSource)
        let after = try DocumentLoader(source: retained)
            .load(file: root.appendingPathComponent(record.path)).document
        #expect(after.contentID == before.contentID)
        #expect(after.bytes == before.bytes)
    }
}

@MainActor
@Test
func appModelStrictCrossSnapshotFullFailureLeavesCachedExactReadingInstalled() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn committed() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    try bookmarkModelGit(root, "add", ".")
    try bookmarkModelGit(
        root,
        "-c", "user.name=Bookmark Test",
        "-c", "user.email=bookmark@example.invalid",
        "commit", "-qm", "initial"
    )
    let commit = try bookmarkModelGitOutput(root, "rev-parse", "HEAD")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let initial = TestSnapshot(label: "initial", files: ["src/main.rs": "fn initial() {}\n"])
    let target = TestSnapshot(label: "target", files: ["src/main.rs": "fn captured() {}\n"])
    let service = ControlledSnapshotIndexService(
        initialSession: try ProjectIndexer().index(root: root),
        worktreeSnapshot: initial,
        snapshots: [:],
        externalSnapshots: [
            commit: try CommitSnapshot(repositoryURL: root, revision: commit),
        ],
        failedFull: ["target"]
    )
    let model = AppModel(indexService: service)
    try await model.openProject(root: root, languages: [.rust])
    model.switchToCommit(commit)
    #expect(await testWaitUntil("controlled commit ready") {
        model.snapshotPhase == .fullReady && model.currentRevision == commit
    })
    let installedBefore = model.lastInstalledWorkspace
    await service.setWorktreeSnapshot(target)
    let record = BookmarkRecord(
        id: UUID(), projectPath: root.path, snapshot: .worktree,
        path: "src/main.rs",
        contentID: ContentID.sha256(of: Data("fn captured() {}\n".utf8)),
        byteOffset: 3, line: 1, symbolName: nil, symbolKind: nil, note: "", updatedAt: .now
    )
    let original = JumpRecord(
        path: "src/main.rs", contentID: nil, byteOffset: 0, line: 1, column: 1,
        symbolAnchor: nil, snapshotID: model.currentSnapshotID, revision: commit
    )

    model.openStrictBookmark(record, leaving: original)

    #expect(await testWaitUntil("strict cached install before failed full") {
        model.snapshotPhase == .cachedReady && model.currentSnapshotID == target.snapshotID
    })
    #expect(await service.hasStartedFull("target"))
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.snapshotPhase == .cachedReady)
    #expect(model.lastInstalledWorkspace.projectRoot == installedBefore.projectRoot)
    #expect(model.lastInstalledWorkspace.revision == installedBefore.revision)
    #expect(model.lastInstalledWorkspace.generation == installedBefore.generation)
    guard case .ready = model.projectState else {
        Issue.record("failed full completion must retain cached workspace")
        return
    }
    let source = try #require(model.documentSource)
    let document = try DocumentLoader(source: source)
        .load(file: root.appendingPathComponent(record.path)).document
    #expect(document.contentID == record.contentID)
    #expect(model.bookmarkModel.lastAttemptMessage == nil)
}

@MainActor
@Test
func appModelStrictCrossSnapshotKeepsCachedInstallIndependentFromFullCompletion() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn committed() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    try bookmarkModelGit(root, "add", ".")
    try bookmarkModelGit(
        root,
        "-c", "user.name=Bookmark Test",
        "-c", "user.email=bookmark@example.invalid",
        "commit", "-qm", "initial"
    )
    let commit = try bookmarkModelGitOutput(root, "rev-parse", "HEAD")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let initial = TestSnapshot(label: "initial", files: ["src/main.rs": "fn initial() {}\n"])
    let target = TestSnapshot(label: "target", files: ["src/main.rs": "fn captured() {}\n"])
    let service = ControlledSnapshotIndexService(
        initialSession: try ProjectIndexer().index(root: root),
        worktreeSnapshot: initial,
        snapshots: [:],
        externalSnapshots: [
            commit: try CommitSnapshot(repositoryURL: root, revision: commit),
        ],
        blockedFull: ["target"]
    )
    let model = AppModel(indexService: service)
    try await model.openProject(root: root, languages: [.rust])
    model.switchToCommit(commit)
    #expect(await testWaitUntil("controlled commit ready") {
        model.snapshotPhase == .fullReady && model.currentRevision == commit
    })
    let installedBefore = model.lastInstalledWorkspace
    let originalSnapshotID = model.currentSnapshotID
    let original = JumpRecord(
        path: "src/main.rs",
        contentID: ContentID.sha256(of: Data("fn committed() {}\n".utf8)),
        byteOffset: 0,
        line: 1,
        column: 1,
        symbolAnchor: nil,
        snapshotID: originalSnapshotID,
        revision: commit
    )
    let record = BookmarkRecord(
        id: UUID(), projectPath: root.path, snapshot: .worktree,
        path: "src/main.rs",
        contentID: ContentID.sha256(of: Data("fn captured() {}\n".utf8)),
        byteOffset: 3, line: 1, symbolName: nil, symbolKind: nil, note: "", updatedAt: .now
    )
    await service.setWorktreeSnapshot(target)
    try "fn disk_changed_after_capture() {}\n".write(
        to: root.appendingPathComponent(record.path), atomically: true, encoding: .utf8
    )
    let historyCount = model.navigationHistory.records.count

    model.openStrictBookmark(record, leaving: original)

    #expect(await testWaitUntil("strict cached install") {
        model.snapshotPhase == .cachedReady && model.currentSnapshotID == target.snapshotID
    })
    #expect(model.lastInstalledWorkspace.projectRoot == installedBefore.projectRoot)
    #expect(model.lastInstalledWorkspace.revision == installedBefore.revision)
    #expect(model.lastInstalledWorkspace.generation == installedBefore.generation)
    #expect(model.navigationHistory.records.count == historyCount + 1)
    #expect(model.navigationHistory.records.last == original)
    #expect(model.hasPendingReplay == false)
    let cachedSource = try #require(model.documentSource)
    let cachedDocument = try DocumentLoader(source: cachedSource)
        .load(file: root.appendingPathComponent(record.path)).document
    #expect(cachedDocument.contentID == record.contentID)
    #expect(cachedDocument.bytes == Array("fn captured() {}\n".utf8))

    model.openStrictBookmark(record, leaving: original)
    #expect(await service.hasStartedFull("target"))
    await service.releaseFull("target")
    #expect(await testWaitUntil("strict full install") {
        model.snapshotPhase == .fullReady
    })
    #expect(model.lastInstalledWorkspace.projectRoot == root.standardizedFileURL)
    #expect(model.lastInstalledWorkspace.revision == nil)
    #expect(model.lastInstalledWorkspace.generation == model.generation)

    model.goBack(from: JumpRecord(
        path: record.path,
        contentID: record.contentID,
        byteOffset: record.byteOffset,
        line: record.line,
        column: 1,
        symbolAnchor: nil,
        snapshotID: target.snapshotID
    ))
    #expect(await testWaitUntil("strict goBack replays original commit") {
        model.snapshotPhase == .fullReady
            && model.currentRevision == commit
            && model.selectedByteOffset == original.byteOffset
    })
    #expect(model.activeNavigationRequest?.cause == .historyReplay)
}

@MainActor
@Test
func appModelStrictCrossSnapshotBookmarkStartsWithoutMutatingTheCurrentWorkspace() async throws {
    let root = try bookmarkModelTemporaryGitProject(source: "fn before() {}\n")
    defer { try? FileManager.default.removeItem(at: root) }
    try bookmarkModelGit(root, "add", ".")
    try bookmarkModelGit(
        root,
        "-c", "user.name=Bookmark Test",
        "-c", "user.email=bookmark@example.invalid",
        "commit", "-qm", "before"
    )
    let commit = try bookmarkModelGitOutput(root, "rev-parse", "HEAD")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try "fn after() {}\n".write(
        to: root.appendingPathComponent("src/main.rs"),
        atomically: true,
        encoding: .utf8
    )
    let model = AppModel(indexService: ProjectIndexService())
    try await model.openProject(root: root, languages: [.rust])
    let beforeSnapshot = model.currentSnapshotID
    let beforeGeneration = model.generation
    let record = BookmarkRecord(
        id: UUID(), projectPath: root.path, snapshot: .commit(fullOID: commit),
        path: "src/main.rs",
        contentID: ContentID.sha256(of: Data("fn before() {}\n".utf8)),
        byteOffset: 3, line: 1, symbolName: nil, symbolKind: nil, note: "", updatedAt: .now
    )
    let original = JumpRecord(
        path: "src/main.rs", contentID: nil, byteOffset: 0, line: 1, column: 1,
        symbolAnchor: nil, snapshotID: beforeSnapshot
    )
    let historyCount = model.navigationHistory.records.count
    try "fn changed_after_capture() {}\n".write(
        to: root.appendingPathComponent("src/main.rs"),
        atomically: true,
        encoding: .utf8
    )

    model.openStrictBookmark(record, leaving: original)

    #expect(await testWaitUntil("strict cross-snapshot settled") {
        model.currentSnapshotID != beforeSnapshot
            || model.bookmarkModel.lastAttemptMessage != nil
    })
    #expect(model.bookmarkModel.lastAttemptMessage == nil)
    #expect(model.currentRevision == commit)
    #expect(model.currentSnapshotID != beforeSnapshot)
    #expect(model.generation == beforeGeneration + 1)
    #expect(model.navigationHistory.records.count == historyCount + 1)
    let source = try #require(model.documentSource)
    let document = try DocumentLoader(source: source)
        .load(file: root.appendingPathComponent(record.path)).document
    #expect(document.contentID == record.contentID)
    #expect(document.bytes == Array("fn before() {}\n".utf8))
}

private func bookmarkModelTestFileURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("BookmarkModelTests-\(UUID().uuidString)")
        .appendingPathComponent("bookmarks.json")
}

private func bookmarkPanelRecord(
    id: String,
    path: String,
    symbolName: String?,
    note: String,
    updatedAt: Date
) -> BookmarkRecord {
    BookmarkRecord(
        id: UUID(uuidString: id)!,
        projectPath: "/tmp/project",
        snapshot: .worktree,
        path: path,
        contentID: ContentID.sha256(of: Data(path.utf8)),
        byteOffset: 0,
        line: 1,
        symbolName: symbolName,
        symbolKind: nil,
        note: note,
        updatedAt: updatedAt
    )
}
