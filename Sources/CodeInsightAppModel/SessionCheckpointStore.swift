import CodeInsightCore
import Foundation
import Observation

package struct SessionLoadResult: Sendable {
    package enum Problem: Equatable, Sendable {
        /// Undecodable data; the file was quarantined as *.corrupt and
        /// the project may record a fresh session.
        case corruptFile
        /// Temporary read/permission failure; preserve and block writes until a successful retry.
        case readFailed
        /// Written by a newer Cairn; the file is kept untouched and
        /// must not be overwritten.
        case unsupportedSchemaVersion(Int)
        /// The snapshot's project directory does not currently exist
        /// (e.g. an unmounted volume); data is kept for later.
        case projectUnavailable
    }

    package let snapshot: SessionCodec.Snapshot?
    package let problem: Problem?

    package init(
        snapshot: SessionCodec.Snapshot?,
        problem: Problem? = nil
    ) {
        self.snapshot = snapshot
        self.problem = problem
    }
}

/// The on-disk reading-session store: per-project files beside the legacy
/// single-file migration source, quarantine of unreadable files, and write
/// protection for files that cannot safely be replaced. The model builds
/// snapshots and decides when to checkpoint; this decides whether and where
/// a snapshot may be written. It stays on the main actor with synchronous
/// writes, as the model's checkpoints were before.
@MainActor
@Observable
final class SessionCheckpointStore {
    /// Set when the latest checkpoint write failed, e.g. because the disk
    /// was full or the store directory was unwritable; the next successful
    /// write clears it.
    private(set) var saveNotice: String?
    /// Set when loading a saved session hit a recoverable problem (corrupt
    /// data, newer schema, unavailable project directory).
    private(set) var loadNotice: String?

    /// Legacy single-file session store (v1/v2 data): the anchor whose
    /// directory also holds the per-project `sessions/` store.
    @ObservationIgnored let legacyURL: URL
    @ObservationIgnored private let maximumTabCount: Int
    /// Snapshots that cannot safely be read stay protected until a successful
    /// retry or an explicit clear (including future schemas and I/O failures).
    @ObservationIgnored private var overwriteBlockedKeys: Set<String> = []
    /// Root of a legacy snapshot that was loaded for migration; the legacy
    /// file is retired only after that exact project completes its first
    /// per-project write.
    @ObservationIgnored private var legacyRootPendingMigration: String?

    init(legacyURL: URL, maximumTabCount: Int) {
        self.legacyURL = legacyURL
        self.maximumTabCount = maximumTabCount
    }

    /// Stable per-project file name: SHA-256 of the standardized,
    /// symlink-resolved absolute root path. Swift's Hasher is not stable
    /// across processes and must never be used here.
    nonisolated static func projectKey(
        for root: URL
    ) -> String {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        return ContentID.sha256(of: Array(path.utf8)).bytes
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated private static func isSameProjectRoot(
        _ lhs: String,
        _ rhs: URL
    ) -> Bool {
        URL(fileURLWithPath: lhs, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// When the project was last read: its session checkpoint's modification
    /// time. Nil when the project has no saved session.
    func lastSessionDate(forProjectRoot root: String) -> Date? {
        let fileURL = fileURL(forProjectRoot: root)
        return (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[
            .modificationDate
        ] as? Date
    }

    private func fileURL(
        forProjectRoot root: String
    ) -> URL {
        legacyURL.deletingLastPathComponent()
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(
                Self.projectKey(
                    for: URL(fileURLWithPath: root, isDirectory: true)
                ) + ".json"
            )
    }

    /// Loads the newest saved session for `root` from the per-project
    /// store. The snapshot's own `projectRoot` must match the requested
    /// project; the file name alone is not trusted.
    func load(
        forProject root: URL
    ) -> SessionLoadResult {
        let fileURL = fileURL(forProjectRoot: root.path)
        let projectKey = Self.projectKey(for: root)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Only absence permits fallback. fileExists also returns false
            // for inaccessible parent directories, which must remain protected.
            let legacy = loadLegacy()
            if let problem = legacy.problem {
                loadNotice = Self.problemText(problem)
                switch problem {
                case .readFailed, .unsupportedSchemaVersion:
                    // The old root is unknown. Do not let a fresh checkpoint
                    // hide this file from a later successful migration retry.
                    overwriteBlockedKeys.insert(projectKey)
                case .corruptFile, .projectUnavailable:
                    overwriteBlockedKeys.remove(projectKey)
                }
                return legacy
            }
            overwriteBlockedKeys.remove(projectKey)
            loadNotice = nil
            guard let snapshot = legacy.snapshot,
                  Self.isSameProjectRoot(snapshot.projectRoot, root)
            else { return SessionLoadResult(snapshot: nil) }
            return legacy
        } catch {
            overwriteBlockedKeys.insert(projectKey)
            loadNotice = Self.problemText(.readFailed)
            return SessionLoadResult(snapshot: nil, problem: .readFailed)
        }
        do {
            let snapshot = try SessionCodec.decode(
                data,
                maximumTabCount: maximumTabCount,
                dependencyAllowed: exactLocationIsInDependency
            )
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: snapshot.projectRoot,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                loadNotice = Self.problemText(
                    .projectUnavailable
                )
                return SessionLoadResult(
                    snapshot: nil,
                    problem: .projectUnavailable
                )
            }
            guard Self.isSameProjectRoot(snapshot.projectRoot, root) else {
                try quarantineCorrupt(at: fileURL)
                loadNotice = Self.problemText(.corruptFile)
                return SessionLoadResult(snapshot: nil, problem: .corruptFile)
            }
            overwriteBlockedKeys.remove(projectKey)
            loadNotice = nil
            return SessionLoadResult(snapshot: snapshot)
        } catch SessionCodec.DecodeError.unsupportedSchemaVersion(let version) {
            overwriteBlockedKeys.insert(
                Self.projectKey(for: root)
            )
            loadNotice = Self.problemText(
                .unsupportedSchemaVersion(version)
            )
            return SessionLoadResult(
                snapshot: nil,
                problem: .unsupportedSchemaVersion(version)
            )
        } catch {
            do {
                try quarantineCorrupt(at: fileURL)
                overwriteBlockedKeys.remove(projectKey)
            } catch {
                overwriteBlockedKeys.insert(projectKey)
                loadNotice = Self.problemText(.readFailed)
                return SessionLoadResult(snapshot: nil, problem: .readFailed)
            }
            loadNotice = Self.problemText(.corruptFile)
            return SessionLoadResult(snapshot: nil, problem: .corruptFile)
        }
    }

    /// Loads the legacy single-file session (v1/v2 data) for one-time
    /// migration at launch or when reopening its project without a new snapshot.
    func loadLegacy() -> SessionLoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: legacyURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return SessionLoadResult(snapshot: nil)
        } catch {
            loadNotice = Self.problemText(.readFailed)
            return SessionLoadResult(snapshot: nil, problem: .readFailed)
        }
        do {
            let snapshot = try SessionCodec.decode(
                data,
                maximumTabCount: maximumTabCount,
                dependencyAllowed: exactLocationIsInDependency
            )
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: snapshot.projectRoot,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                return SessionLoadResult(
                    snapshot: nil,
                    problem: .projectUnavailable
                )
            }
            legacyRootPendingMigration = snapshot.projectRoot
            return SessionLoadResult(snapshot: snapshot)
        } catch SessionCodec.DecodeError.unsupportedSchemaVersion(let version) {
            return SessionLoadResult(
                snapshot: nil,
                problem: .unsupportedSchemaVersion(version)
            )
        } catch {
            do {
                try quarantineCorrupt(at: legacyURL)
            } catch {
                loadNotice = Self.problemText(.readFailed)
                return SessionLoadResult(snapshot: nil, problem: .readFailed)
            }
            return SessionLoadResult(snapshot: nil, problem: .corruptFile)
        }
    }

    private func quarantineCorrupt(at fileURL: URL) throws {
        let quarantineURL = URL(
            fileURLWithPath: fileURL.path + ".corrupt",
            isDirectory: false
        )
        try? FileManager.default.removeItem(at: quarantineURL)
        try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
    }

    nonisolated private static func problemText(
        _ problem: SessionLoadResult.Problem
    ) -> String {
        switch problem {
        case .corruptFile:
            localized("model.app.corruptSession")
        case .readFailed:
            localized("model.app.unreadableSession")
        case .unsupportedSchemaVersion(let version):
            localizedFormat("model.app.newerSession", version)
        case .projectUnavailable:
            localized("model.app.projectUnavailable")
        }
    }

    /// Writes `snapshot` to its project's file unless that file is protected.
    /// `onWritten` runs after a successful write, before the legacy source
    /// it was migrated from is retired.
    func write(
        _ snapshot: SessionCodec.Snapshot,
        onWritten: (String) -> Void
    ) throws {
        let projectKey = Self.projectKey(
            for: URL(fileURLWithPath: snapshot.projectRoot, isDirectory: true)
        )
        guard !overwriteBlockedKeys.contains(projectKey) else { return }
        let targetURL = fileURL(forProjectRoot: snapshot.projectRoot)
        do {
            let data = try SessionCodec.encode(
                snapshot,
                maximumTabCount: maximumTabCount,
                dependencyAllowed: exactLocationIsInDependency
            )
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: targetURL, options: .atomic)
            if saveNotice != nil { saveNotice = nil }
            if loadNotice != nil { loadNotice = nil }
            // Report the successful write; the application layer decides
            // whether this project becomes the launch restore target
            // (§7.3 — background checkpoints no longer move the pointer
            // implicitly). A legacy file the snapshot was migrated from
            // can now be retired (kept as a one-time backup).
            onWritten(snapshot.projectRoot)
            retireLegacyIfPendingMigration(
                for: snapshot.projectRoot
            )
        } catch {
            saveNotice =
                localizedFormat("model.app.sessionSaveFailed", AppModel.failureSummary(error))
            throw error
        }
    }

    private func retireLegacyIfPendingMigration(
        for projectRoot: String
    ) {
        guard legacyRootPendingMigration == projectRoot,
              FileManager.default.fileExists(atPath: legacyURL.path)
        else { return }
        let backupURL = URL(
            fileURLWithPath: legacyURL.path + ".migrated",
            isDirectory: false
        )
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: legacyURL, to: backupURL)
        legacyRootPendingMigration = nil
    }

    /// Forgets `root`'s saved session: removes its per-project file, lifts
    /// its write protection, and retires the legacy migration source so the
    /// cleared session cannot be re-imported.
    func clear(projectRoot root: URL) {
        overwriteBlockedKeys.remove(Self.projectKey(for: root))
        try? FileManager.default.removeItem(at: fileURL(forProjectRoot: root.path))
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            let backupURL = URL(
                fileURLWithPath: legacyURL.path + ".migrated",
                isDirectory: false
            )
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: legacyURL, to: backupURL)
        }
        legacyRootPendingMigration = nil
    }
}
