import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Observation

/// Single-process authority for bookmark records and their persistence
/// state (§8.1): one instance shared by every window's BookmarkModel.
/// Jump/attempt state stays per-window in BookmarkModel.
@MainActor
@Observable
package final class SharedBookmarkStore {
    package private(set) var records: [BookmarkRecord] = []
    package private(set) var storageError: BookmarkStoreError?
    package private(set) var rescueBytes: Data?
    package private(set) var isDirty = false

    @ObservationIgnored private let store: BookmarkStore?
    @ObservationIgnored private var observers: [UUID: @MainActor () -> Void] = [:]

    package init(fileURL: URL) {
        self.store = BookmarkStore(fileURL: fileURL)
        load()
    }

    package init(store: BookmarkStore?) {
        self.store = store
        if store != nil { load() }
    }

    /// An empty in-memory store for tests that never touch disk.
    package init() {
        self.store = nil
    }

    /// Loads from disk exactly once, at creation. A later reload would
    /// clobber a dirty in-memory table with stale disk contents (§8.1).
    private func load() {
        guard let store else { return }
        do {
            records = try store.load()
            storageError = nil
            rescueBytes = nil
            isDirty = false
        } catch let error as BookmarkStoreError {
            records = []
            storageError = error
            rescueBytes = try? store.rawBytes()
            isDirty = false
        } catch {
            records = []
            storageError = .unreadable
            rescueBytes = try? store.rawBytes()
            isDirty = false
        }
    }

    /// Read-modify-write boundary: computes the next table from the latest
    /// shared records and persists it in one MainActor operation. Callers
    /// must not `await` between reading `records` and committing.
    @discardableResult
    package func commit(_ candidate: [BookmarkRecord]) -> Bool {
        guard let store else {
            records = candidate
            storageError = nil
            rescueBytes = nil
            isDirty = false
            notifyObservers()
            return true
        }
        guard rescueBytes == nil || storageError == nil else {
            notifyObservers()
            return false
        }
        do {
            try store.replace(candidate)
            records = candidate
            storageError = nil
            rescueBytes = nil
            isDirty = false
            notifyObservers()
            return true
        } catch let error as BookmarkStoreError {
            guard error == .writeFailed else {
                storageError = error
                notifyObservers()
                return false
            }
            // Write failed: the newest in-memory table stays authoritative
            // and dirty; the next commit retries from it (§8.1).
            records = candidate
            storageError = error
            isDirty = true
            notifyObservers()
            return true
        } catch {
            storageError = .writeFailed
            records = candidate
            isDirty = true
            notifyObservers()
            return true
        }
    }

    /// Registers a per-window change callback; returns the removal token.
    @discardableResult
    package func addObserver(
        _ observer: @escaping @MainActor () -> Void
    ) -> UUID {
        let token = UUID()
        observers[token] = observer
        return token
    }

    package func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    private func notifyObservers() {
        for observer in observers.values {
            observer()
        }
    }
}

package enum BookmarkStatus: Hashable, Sendable {
    case exactContent
    case drifted
    case revisionUnavailable
    case fileAbsent
    case offsetInvalid
    case notEvaluated

    package var attemptMessage: String? {
        switch self {
        case .exactContent: nil
        case .drifted: localized("model.bookmark.driftMessage")
        case .revisionUnavailable: localized("model.bookmark.revisionMessage")
        case .fileAbsent: localized("model.bookmark.absentMessage")
        case .offsetInvalid: localized("model.bookmark.offsetMessage")
        case .notEvaluated: nil
        }
    }

    package var displayText: String {
        switch self {
        case .exactContent: localized("model.bookmark.exact")
        case .drifted: localized("model.bookmark.drift")
        case .revisionUnavailable: localized("model.bookmark.revision")
        case .fileAbsent: localized("model.bookmark.absent")
        case .offsetInvalid: localized("model.bookmark.offset")
        case .notEvaluated: localized("model.bookmark.unevaluated")
        }
    }

    package var tooltip: String { displayText }

    package static func evaluate(
        record: BookmarkRecord,
        snapshot: BookmarkRecord.SnapshotAnchor?,
        revisionAvailable: Bool,
        capturedSource: (contentID: ContentID, bytes: [UInt8])?
    ) -> BookmarkStatus {
        guard snapshot == record.snapshot else {
            if case .commit = record.snapshot, !revisionAvailable {
                return .revisionUnavailable
            }
            return .notEvaluated
        }
        if case .commit = record.snapshot, !revisionAvailable {
            return .revisionUnavailable
        }
        guard let capturedSource else { return .fileAbsent }
        guard capturedSource.contentID == record.contentID else {
            if case .worktree = record.snapshot { return .drifted }
            return .fileAbsent
        }
        guard let byteOffset = Int(exactly: record.byteOffset),
              ByteUTF16Map(validUTF8: capturedSource.bytes)
                .utf16Offset(forByte: byteOffset) != nil
        else {
            return .offsetInvalid
        }
        return .exactContent
    }
}

package enum BookmarkEligibility: Equatable, Sendable {
    case eligible
    case unavailable(Reason)

    package enum Reason: Equatable, Sendable {
        case empty
        case readingSet
        case dependency
        case comparison
        case miniReader
        case readerNotReady
        case noSelection
        case capturedSourceMismatch

        package var accessibilityHelp: String {
            switch self {
            case .empty: localized("model.bookmark.empty")
            case .readingSet: localized("model.bookmark.readingSet")
            case .dependency: localized("model.bookmark.dependency")
            case .comparison: localized("model.bookmark.compare")
            case .miniReader: localized("model.bookmark.mini")
            case .readerNotReady: localized("model.bookmark.notReady")
            case .noSelection: localized("model.bookmark.selection")
            case .capturedSourceMismatch: localized("model.bookmark.mismatch")
            }
        }
    }

    package var accessibilityHelp: String? {
        guard case let .unavailable(reason) = self else { return nil }
        return reason.accessibilityHelp
    }
}

package enum BookmarkToggleResult: Equatable, Sendable {
    case added
    case deleted
    case confirmationRequired(UUID)
    case rejected
}

package enum BookmarkReanchorResult: Equatable, Sendable {
    case updated
    case unchanged
    case conflict(UUID)
    case unsupportedSnapshot
    case rejected
}

@MainActor
@Observable
package final class BookmarkModel {
    package struct AttemptMessage: Equatable, Sendable {
        package let id: UUID
        package let workspaceGeneration: UInt64
        package let attemptGeneration: UInt64
        package let message: String
    }

    package private(set) var lastAttemptMessage: AttemptMessage?
    /// Records and persistence state come from the shared store when one
    /// is attached; otherwise this per-model array serves storeless tests.
    @ObservationIgnored private var localRecords: [BookmarkRecord] = []
    package var records: [BookmarkRecord] {
        get { sharedStore?.records ?? localRecords }
        set { localRecords = newValue }
    }

    package var storageError: BookmarkStoreError? {
        sharedStore?.storageError
    }

    package var rescueBytes: Data? {
        sharedStore?.rescueBytes
    }

    package var isDirty: Bool {
        sharedStore?.isDirty ?? false
    }

    /// Fired when the shared records changed (any window, including this
    /// one) so owning surfaces re-render (§8.1).
    package var onSharedRecordsChanged: (@MainActor () -> Void)?

    package private(set) var workspaceGeneration: UInt64 = 0
    package private(set) var bookmarkAttemptGeneration: UInt64 = 0
    @ObservationIgnored private var bookmarkJumpTask: Task<Void, Never>?
    @ObservationIgnored private var activeAttempt: (
        id: UUID,
        generation: UInt64,
        workspaceGeneration: UInt64
    )?
    @ObservationIgnored private let sharedStore: SharedBookmarkStore?

    package init(store: BookmarkStore? = nil) {
        if let store {
            let shared = SharedBookmarkStore(store: store)
            self.sharedStore = shared
            registerSharedObserver()
        } else {
            self.sharedStore = nil
        }
    }

    package init(sharedStore: SharedBookmarkStore) {
        self.sharedStore = sharedStore
        registerSharedObserver()
    }

    /// The stored closure only weakly captures this model, so a deallocated
    /// window's entry is inert without explicit removal.
    private func registerSharedObserver() {
        guard let sharedStore else { return }
        sharedStore.addObserver { [weak self] in
            self?.onSharedRecordsChanged?()
        }
    }

    package var sharedRecordStore: SharedBookmarkStore? { sharedStore }

    package func reload() {
        guard sharedStore == nil else { return }
        records = []
    }

    package func filteredRecords(projectPath: String, query: String = "") -> [BookmarkRecord] {
        let projectPath = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        return records.filter { record in
            guard record.projectPath == projectPath else { return false }
            guard !query.isEmpty else { return true }
            return [title(for: record), record.path, record.note]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    package func title(for record: BookmarkRecord) -> String {
        record.symbolName ?? "\(record.path):\(record.line)"
    }

    package func statusCounts(
        projectPath: String,
        status: (BookmarkRecord) -> BookmarkStatus
    ) -> [BookmarkStatus: Int] {
        var counts: [BookmarkStatus: Int] = [:]
        for record in filteredRecords(projectPath: projectPath) {
            counts[status(record), default: 0] += 1
        }
        return counts
    }

    package func markdown(
        projectPath: String,
        status: (BookmarkRecord) -> BookmarkStatus
    ) -> String {
        filteredRecords(projectPath: projectPath).map { record in
            var lines = [
                "## \(markdownEscape(title(for: record)))",
                localizedFormat("model.bookmark.export.path", markdownEscape(record.path)),
                localizedFormat("model.bookmark.export.snapshot", markdownEscape(snapshotText(record))),
                localizedFormat("model.bookmark.export.line", record.line),
                localizedFormat("model.bookmark.export.status", status(record).displayText),
            ]
            if !record.note.isEmpty {
                lines.append(localized("model.bookmark.export.note"))
                lines.append(markdownEscape(record.note))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func snapshotText(_ record: BookmarkRecord) -> String {
        switch record.snapshot {
        case .worktree: localized("model.bookmark.worktree")
        case let .commit(fullOID): localizedFormat("model.bookmark.saved", fullOID)
        }
    }

    private func markdownEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: ">", with: "\\>")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "+", with: "\\+")
            .replacingOccurrences(of: "-", with: "\\-")
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "!", with: "\\!")
    }

    package func attemptMessage(for id: UUID) -> String? {
        lastAttemptMessage?.id == id ? lastAttemptMessage?.message : nil
    }

    package func lineTarget(
        in document: ReaderDocument,
        requestedLine: UInt32
    ) -> (line: UInt32, byteOffset: UInt32)? {
        guard !document.lineTable.lineStarts.isEmpty else { return nil }
        let last = UInt32(document.lineTable.lineStarts.count)
        let line = min(max(requestedLine, 1), last)
        return (line, document.lineTable.lineStarts[Int(line - 1)])
    }

    package func reanchorWorktree(
        id: UUID,
        document: ReaderDocument,
        line: UInt32,
        updatedAt: Date = .now
    ) -> BookmarkReanchorResult {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            return .unsupportedSnapshot
        }
        let existing = records[index]
        guard existing.snapshot == .worktree,
              let target = lineTarget(in: document, requestedLine: line)
        else { return .unsupportedSnapshot }
        let facet = document.outlineFacets
            .filter { $0.range.contains(target.byteOffset) }
            .min { $0.range.length < $1.range.length }
        let replacement = BookmarkRecord(
            id: existing.id,
            projectPath: existing.projectPath,
            snapshot: existing.snapshot,
            path: existing.path,
            contentID: document.contentID,
            byteOffset: target.byteOffset,
            line: target.line,
            symbolName: facet?.name,
            symbolKind: facet?.kind.rawValue,
            note: existing.note,
            updatedAt: updatedAt
        )
        if replacement.toggleKey == existing.toggleKey { return .unchanged }
        if let conflict = records.first(where: {
            $0.id != existing.id && $0.toggleKey == replacement.toggleKey
        }) {
            return .conflict(conflict.id)
        }
        var candidate = records
        candidate[index] = replacement
        guard commit(candidate) else { return .rejected }
        clearAttempt(for: id)
        return .updated
    }

    @discardableResult
    package func update(_ record: BookmarkRecord) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else {
            return false
        }
        guard !records.contains(where: {
            $0.id != record.id && $0.toggleKey == record.toggleKey
        }) else { return false }
        var candidate = records
        candidate[index] = record
        return commit(candidate)
    }

    @discardableResult
    package func updateNote(id: UUID, text: String) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = records
        let record = candidate[index]
        candidate[index] = BookmarkRecord(
            id: record.id, projectPath: record.projectPath, snapshot: record.snapshot,
            path: record.path, contentID: record.contentID, byteOffset: record.byteOffset,
            line: record.line, symbolName: record.symbolName, symbolKind: record.symbolKind,
            note: text, updatedAt: record.updatedAt
        )
        return commit(candidate)
    }

    @discardableResult
    package func finalizeNote(id: UUID, updatedAt: Date = .now) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = records
        let record = candidate[index]
        candidate[index] = BookmarkRecord(
            id: record.id, projectPath: record.projectPath, snapshot: record.snapshot,
            path: record.path, contentID: record.contentID, byteOffset: record.byteOffset,
            line: record.line, symbolName: record.symbolName, symbolKind: record.symbolKind,
            note: record.note, updatedAt: updatedAt
        )
        return commit(candidate)
    }

    package func toggle(_ record: BookmarkRecord) -> BookmarkToggleResult {
        guard let existing = records.first(where: { $0.toggleKey == record.toggleKey }) else {
            return commit(records + [record]) ? .added : .rejected
        }
        guard existing.note.isEmpty else { return .confirmationRequired(existing.id) }
        return delete(id: existing.id) ? .deleted : .rejected
    }

    @discardableResult
    package func delete(id: UUID) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = records
        candidate.remove(at: index)
        guard commit(candidate) else { return false }
        clearAttempt(for: id)
        return true
    }

    @discardableResult
    private func commit(_ candidate: [BookmarkRecord]) -> Bool {
        guard let sharedStore else {
            records = candidate
            return true
        }
        return sharedStore.commit(candidate)
    }

    package func workspaceDidChange(to generation: UInt64) {
        workspaceGeneration = generation
        clearAttempt()
    }

    package func beginAttempt(
        for record: BookmarkRecord,
        workspaceGeneration: UInt64,
        evaluate: @escaping @Sendable () async -> BookmarkStatus
    ) {
        beginAttemptMessage(for: record, workspaceGeneration: workspaceGeneration) {
            (await evaluate()).attemptMessage
        }
    }

    package func beginAttempt(
        for record: BookmarkRecord,
        workspaceGeneration: UInt64,
        message: String
    ) {
        beginAttemptMessage(for: record, workspaceGeneration: workspaceGeneration) {
            message
        }
    }

    private func beginAttemptMessage(
        for record: BookmarkRecord,
        workspaceGeneration: UInt64,
        evaluate: @escaping @Sendable () async -> String?
    ) {
        bookmarkJumpTask?.cancel()
        bookmarkAttemptGeneration &+= 1
        let attemptGeneration = bookmarkAttemptGeneration
        activeAttempt = (record.id, attemptGeneration, workspaceGeneration)
        lastAttemptMessage = nil
        bookmarkJumpTask = Task { [weak self] in
            let message = await evaluate()
            guard !Task.isCancelled,
                  let self,
                  self.workspaceGeneration == workspaceGeneration,
                  self.bookmarkAttemptGeneration == attemptGeneration,
                  self.activeAttempt?.id == record.id,
                  self.activeAttempt?.generation == attemptGeneration
            else { return }
            guard let message else {
                self.bookmarkJumpTask = nil
                self.activeAttempt = nil
                return
            }
            self.lastAttemptMessage = AttemptMessage(
                id: record.id,
                workspaceGeneration: workspaceGeneration,
                attemptGeneration: attemptGeneration,
                message: message
            )
            self.bookmarkJumpTask = nil
            self.activeAttempt = nil
        }
    }

    package func clearAttempt(for id: UUID? = nil) {
        guard id == nil || activeAttempt?.id == id || lastAttemptMessage?.id == id else {
            return
        }
        bookmarkJumpTask?.cancel()
        bookmarkJumpTask = nil
        activeAttempt = nil
        bookmarkAttemptGeneration &+= 1
        lastAttemptMessage = nil
    }

    package func beginStrictJump(
        for record: BookmarkRecord,
        workspaceGeneration: UInt64,
        perform: @escaping @MainActor @Sendable (UInt64) async -> String?
    ) {
        bookmarkJumpTask?.cancel()
        bookmarkAttemptGeneration &+= 1
        let attemptGeneration = bookmarkAttemptGeneration
        activeAttempt = (record.id, attemptGeneration, workspaceGeneration)
        lastAttemptMessage = nil
        bookmarkJumpTask = Task { [weak self] in
            let message = await perform(attemptGeneration)
            guard !Task.isCancelled,
                  let self,
                  let active = self.activeAttempt,
                  active.id == record.id,
                  active.generation == attemptGeneration
            else { return }
            if let message {
                self.lastAttemptMessage = AttemptMessage(
                    id: record.id,
                    workspaceGeneration: active.workspaceGeneration,
                    attemptGeneration: attemptGeneration,
                    message: message
                )
            }
            self.bookmarkJumpTask = nil
            self.activeAttempt = nil
        }
    }

    package func advanceWorkspace(
        to workspaceGeneration: UInt64,
        attemptGeneration: UInt64
    ) -> Bool {
        guard activeAttempt?.generation == attemptGeneration else { return false }
        self.workspaceGeneration = workspaceGeneration
        activeAttempt?.workspaceGeneration = workspaceGeneration
        return true
    }

    package func isCurrentJump(
        _ attemptGeneration: UInt64,
        workspaceGeneration: UInt64
    ) -> Bool {
        !Task.isCancelled
            && self.workspaceGeneration == workspaceGeneration
            && activeAttempt?.generation == attemptGeneration
            && activeAttempt?.workspaceGeneration == workspaceGeneration
    }
}
