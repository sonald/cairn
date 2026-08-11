import CodeInsightCore
import CodeInsightGit
import CodeInsightReaderCore
import Foundation
import Observation

@MainActor
@Observable
public final class CompareModel {
    public private(set) var rightRevision: String?
    public private(set) var rightSnapshotID: SnapshotID?
    public private(set) var rightBytes: [UInt8]?
    public private(set) var diff: DiffCore.Result?
    public private(set) var functionChanges: [DiffCore.FunctionChange] = []
    public private(set) var selectedHunkIndex: Int?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    @ObservationIgnored public private(set) var rightSource: DocumentLoader.ContentSource?

    @ObservationIgnored private var rightSnapshot: (any Snapshot)?
    @ObservationIgnored private var diffTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotGeneration: UInt64 = 0
    @ObservationIgnored private var diffGeneration: UInt64 = 0
    @ObservationIgnored private var diffLanguageMode: LanguageMode?

    public init() {}

    public var currentHunk: DiffCore.Hunk? {
        guard let selectedHunkIndex,
              let diff,
              diff.hunks.indices.contains(selectedHunkIndex)
        else { return nil }
        return diff.hunks[selectedHunkIndex]
    }

    @discardableResult
    func beginLoading(revision: String) -> UInt64 {
        clear()
        rightRevision = revision
        isLoading = true
        return snapshotGeneration
    }

    @discardableResult
    func install(
        snapshot: any Snapshot,
        root: URL,
        revision: String,
        generation expectedGeneration: UInt64
    ) -> Bool {
        guard snapshotGeneration == expectedGeneration, rightRevision == revision else {
            return false
        }
        rightSnapshot = snapshot
        rightSnapshotID = snapshot.snapshotID
        rightSource = { file in
            guard let path = Self.relativePath(of: file, under: root) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return try snapshot.readBytes(path: path)
        }
        isLoading = false
        errorMessage = nil
        return true
    }

    func update(
        file: URL?,
        leftSource: DocumentLoader.ContentSource?,
        languageMode: LanguageMode?
    ) {
        diffTask?.cancel()
        diffGeneration &+= 1
        let updateGeneration = diffGeneration
        diffLanguageMode = languageMode
        diff = nil
        functionChanges = []
        selectedHunkIndex = nil
        rightBytes = nil
        isLoading = false
        errorMessage = nil
        guard let file, let rightSource, let languageMode else { return }

        do {
            let left = try (leftSource ?? Self.readFile)(file)
            let right = try rightSource(file)
            rightBytes = right
            isLoading = true
            diffTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) { () -> (
                    diff: DiffCore.Result?,
                    functionChanges: [DiffCore.FunctionChange],
                    errorMessage: String?
                ) in
                    let core = DiffCore()
                    do {
                        return try (
                            core.compare(
                                left: left,
                                right: right,
                                languageMode: languageMode
                            ),
                            core.functionChanges(
                                left: left,
                                right: right,
                                languageMode: languageMode
                            ),
                            nil
                        )
                    } catch {
                        return (nil, [], error.localizedDescription)
                    }
                }.value
                guard let self,
                      !Task.isCancelled,
                      diffGeneration == updateGeneration,
                      diffLanguageMode == languageMode
                else { return }
                diff = result.diff
                functionChanges = result.functionChanges
                errorMessage = result.errorMessage
                isLoading = false
            }
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    func fail(generation expectedGeneration: UInt64, error: any Error) {
        guard snapshotGeneration == expectedGeneration else { return }
        isLoading = false
        errorMessage = error.localizedDescription
    }

    public func selectNextHunk() -> DiffCore.Hunk? {
        selectHunk(delta: 1)
    }

    public func selectPreviousHunk() -> DiffCore.Hunk? {
        selectHunk(delta: -1)
    }

    public func clear() {
        diffTask?.cancel()
        diffTask = nil
        snapshotGeneration &+= 1
        diffGeneration &+= 1
        diffLanguageMode = nil
        rightRevision = nil
        rightSnapshotID = nil
        rightBytes = nil
        diff = nil
        functionChanges = []
        selectedHunkIndex = nil
        isLoading = false
        errorMessage = nil
        rightSource = nil
        rightSnapshot = nil
    }

    private func selectHunk(delta: Int) -> DiffCore.Hunk? {
        guard let diff, !diff.hunks.isEmpty else { return nil }
        let current = selectedHunkIndex ?? (delta > 0 ? -1 : 0)
        selectedHunkIndex = (current + delta + diff.hunks.count) % diff.hunks.count
        return currentHunk
    }

    nonisolated private static func relativePath(
        of file: URL,
        under root: URL
    ) -> String? {
        let root = root.standardizedFileURL
        let file = file.standardizedFileURL
        guard file.pathComponents.starts(with: root.pathComponents),
              file.pathComponents.count > root.pathComponents.count
        else { return nil }
        return file.pathComponents.dropFirst(root.pathComponents.count)
            .joined(separator: "/")
    }

    nonisolated private static func readFile(_ file: URL) throws -> [UInt8] {
        Array(try Data(contentsOf: file, options: .mappedIfSafe))
    }
}
