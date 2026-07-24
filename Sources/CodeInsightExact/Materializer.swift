import CodeInsightCore
import CodeInsightGit
import Foundation

public final class Materializer: @unchecked Sendable {
    public static let defaultQuotaBytes: UInt64 = 2 * 1024 * 1024 * 1024

    public let rootURL: URL

    private let quotaBytes: UInt64
    private let lock = NSLock()
    private let completeMarker = ".complete"

    public init(
        rootURL: URL? = nil,
        quotaBytes: UInt64 = Materializer.defaultQuotaBytes
    ) {
        self.rootURL = (rootURL ?? Self.defaultRootURL).standardizedFileURL
        self.quotaBytes = quotaBytes
    }

    @discardableResult
    public func materialize(
        _ snapshot: CommitSnapshot,
        configFingerprint: String
    ) throws -> (url: URL, filesWritten: Int) {
        lock.lock()
        defer { lock.unlock() }

        let commit = try Self.safeComponent(snapshot.commitOID.hex)
        let config = try Self.safeComponent(configFingerprint)
        // Feature selection changes rust-analyzer results, not source bytes.
        // Keep materialization keyed only by commit × Cargo configuration.
        let destination = rootURL
            .appendingPathComponent(commit, isDirectory: true)
            .appendingPathComponent(config, isDirectory: true)
        let marker = destination.appendingPathComponent(completeMarker)
        if FileManager.default.fileExists(atPath: marker.path) {
            try touch(destination)
            try enforceQuota(keeping: destination)
            return (destination, 0)
        }

        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let staging = rootURL.appendingPathComponent(
            ".materializing-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )

        var filesWritten = 0
        for file in snapshot.listFiles() where file.fileMode == .regular {
            let output = try Self.materializedURL(
                for: file.path,
                under: staging
            )
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(snapshot.readBytes(path: file.path)).write(
                to: output,
                options: .atomic
            )
            filesWritten += 1
        }
        try Data().write(to: staging.appendingPathComponent(completeMarker))

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        try touch(destination)
        try enforceQuota(keeping: destination)
        return (destination, filesWritten)
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        try FileManager.default.removeItem(at: rootURL)
    }

    public static func materializedURL(
        for snapshotPath: String,
        under root: URL
    ) throws -> URL {
        let components = snapshotPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !snapshotPath.hasPrefix("/"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw ExactError.invalidPath(snapshotPath) }
        return components.reduce(root.standardizedFileURL) {
            $0.appendingPathComponent(String($1))
        }
    }

    public static func snapshotPath(
        for materializedURL: URL,
        under root: URL
    ) throws -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = materializedURL.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents),
              components.count > rootComponents.count
        else { throw ExactError.invalidPath(materializedURL.path) }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static var defaultRootURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent(
            "CodeInsight/materialized",
            isDirectory: true
        )
    }

    private static func safeComponent(_ value: String) throws -> String {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\")
        else { throw ExactError.invalidPath(value) }
        return value
    }

    private func touch(_ directory: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: directory.path
        )
    }

    private func enforceQuota(keeping current: URL) throws {
        var entries: [(url: URL, size: UInt64, lastAccess: Date)] = []
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        for commit in try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            if commit.lastPathComponent.hasPrefix(".materializing-") {
                try FileManager.default.removeItem(at: commit)
                continue
            }
            guard (try? commit.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            else { continue }
            for config in try FileManager.default.contentsOfDirectory(
                at: commit,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .contentModificationDateKey,
                ]
            ) {
                let values = try config.resourceValues(forKeys: [
                    .isDirectoryKey, .contentModificationDateKey,
                ])
                guard values.isDirectory == true else { continue }
                entries.append((
                    config,
                    try directorySize(config),
                    values.contentModificationDate ?? .distantPast
                ))
            }
        }

        var total = entries.reduce(UInt64(0)) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.lastAccess < $1.lastAccess })
        where total > quotaBytes && entry.url != current {
            try FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            let parent = entry.url.deletingLastPathComponent()
            if try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty {
                try FileManager.default.removeItem(at: parent)
            }
        }
    }

    private func directorySize(_ directory: URL) throws -> UInt64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys
        ) else { return 0 }
        var result: UInt64 = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                result += UInt64(values.fileSize ?? 0)
            }
        }
        return result
    }
}
