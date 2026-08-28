import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Observation

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
        case .drifted: "Bookmark content has drifted."
        case .revisionUnavailable: "Bookmark revision is unavailable."
        case .fileAbsent: "Bookmark file is absent."
        case .offsetInvalid: "Bookmark offset is invalid."
        case .notEvaluated: nil
        }
    }

    package var displayText: String {
        switch self {
        case .exactContent: "Exact content"
        case .drifted: "Drifted"
        case .revisionUnavailable: "Revision unavailable"
        case .fileAbsent: "File absent"
        case .offsetInvalid: "Offset invalid"
        case .notEvaluated: "Not evaluated"
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
            case .empty: "Bookmarks require a current project file in the primary reader."
            case .readingSet: "Reading Sets cannot be bookmarked."
            case .dependency: "Dependency files cannot be bookmarked."
            case .comparison: "Compare views cannot be bookmarked."
            case .miniReader: "Mini readers cannot be bookmarked."
            case .readerNotReady: "The primary reader is not ready to bookmark this file."
            case .noSelection: "Choose a source position before creating a bookmark."
            case .capturedSourceMismatch: "The displayed file is no longer the captured snapshot."
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
    package private(set) var records: [BookmarkRecord] = []
    package private(set) var storageError: BookmarkStoreError?
    package private(set) var rescueBytes: Data?
    package private(set) var isDirty = false
    package private(set) var workspaceGeneration: UInt64 = 0
    package private(set) var bookmarkAttemptGeneration: UInt64 = 0
    @ObservationIgnored private var bookmarkJumpTask: Task<Void, Never>?
    @ObservationIgnored private var activeAttempt: (
        id: UUID,
        generation: UInt64,
        workspaceGeneration: UInt64
    )?
    @ObservationIgnored private let store: BookmarkStore?

    package init(store: BookmarkStore? = nil) {
        self.store = store
        if store != nil { reload() }
    }

    package func reload() {
        guard let store else {
            records = []
            storageError = nil
            rescueBytes = nil
            isDirty = false
            return
        }
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
                "- Path: \(markdownEscape(record.path))",
                "- Snapshot: \(markdownEscape(snapshotText(record)))",
                "- Line: \(record.line)",
                "- Status: \(status(record).displayText)",
            ]
            if !record.note.isEmpty {
                lines.append("### Note")
                lines.append(markdownEscape(record.note))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func snapshotText(_ record: BookmarkRecord) -> String {
        switch record.snapshot {
        case .worktree: "Worktree"
        case let .commit(fullOID): "Saved at \(fullOID)"
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
        return commit(candidate) ? .updated : .rejected
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
        guard let store else {
            records = candidate
            storageError = nil
            rescueBytes = nil
            isDirty = false
            return true
        }
        guard rescueBytes == nil || storageError == nil else { return false }
        do {
            try store.replace(candidate)
            records = candidate
            storageError = nil
            rescueBytes = nil
            isDirty = false
            return true
        } catch let error as BookmarkStoreError {
            guard error == .writeFailed else {
                storageError = error
                return false
            }
            records = candidate
            storageError = error
            isDirty = true
            return true
        } catch {
            storageError = .writeFailed
            records = candidate
            isDirty = true
            return true
        }
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
