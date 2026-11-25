import CodeInsightCore
import CodeInsightGit
import Foundation

/// A remote directory captured over an `SSHTransport`: the same manifest a
/// `WorktreeSnapshot` of that directory would hold (built-in skips, the
/// project's rules, no `.gitignore`, symlinks left out, `.lfsPointer` by
/// content), with no source copy on this Mac.
///
/// The walk goes one directory level per request and every path is judged
/// here by `ProjectPathRules`, so the rules are never restated remotely.
/// Sources and configuration (what the indexer reads) come back in one
/// compressed stream, are hashed here and fill the byte cache; other files
/// are hashed remotely and read when asked for.
///
/// Given the previous capture of the same directory, a file whose size and
/// modification time are both unchanged keeps its content identity: a source
/// is not fetched again while its bytes are still cached, another file is not
/// hashed again remotely. That trusts size plus mtime as Git's index does: a
/// file rewritten to the same size within the same mtime tick is missed until
/// either changes, and reading it then reports it changed (`readBytes` checks
/// the hash), so wrong content is never shown. Kept in memory only.
public final class RemoteSnapshot: Snapshot, @unchecked Sendable {
    public let transport: SSHTransport
    private let files: [String: RemoteFile]
    private let sourceBytes: SourceByteCache?

    public let snapshotID: SnapshotID
    public let objectFormat: GitObjectFormat = .sha1
    public let sourceKind: SourceKind = .untracked
    public let projectRootName: String
    public let configurationPaths: [String]
    public let ruleExcludedPaths: [String]
    public let unreadablePaths: [String]
    public let languages: [LanguageID]

    /// Connects if needed. Throws `SSHTransport.Failure` when the link fails
    /// or the remote directory cannot be read; a file or folder that cannot be
    /// read is left out and listed in `unreadablePaths`, as locally.
    public init(
        transport: SSHTransport,
        pathRules: ProjectPathRules = ProjectPathRules(),
        sourceBytes: SourceByteCache? = nil,
        previous: RemoteSnapshot? = nil
    ) throws {
        try transport.connect()
        var walked: [String] = []
        var stamps: [String: (size: UInt64, stamp: String)] = [:]
        var excluded: [String] = []
        var unreadable: [String] = []
        var level = [""]
        while !level.isEmpty {
            try Task.checkCancellation()
            let listings = try transport.list(level.map { $0.isEmpty ? "." : $0 })
            var next: [String] = []
            for (directory, listing) in zip(level, listings) {
                guard let listing else {
                    if directory.isEmpty { throw SSHTransport.Failure.remote("cannot read \(transport.remotePath)") }
                    unreadable.append(directory)
                    continue
                }
                for entry in listing {
                    let decoded = String(bytes: entry.name, encoding: .utf8)
                    let name = decoded ?? String(decoding: entry.name, as: UTF8.self)
                    let path = directory.isEmpty ? name : directory + "/" + name
                    // A name that is not UTF-8 cannot be asked for again.
                    guard decoded != nil else {
                        unreadable.append(path)
                        continue
                    }
                    if name == ".DS_Store" { continue }
                    switch pathRules.verdict(for: path, isDirectory: entry.isDirectory) {
                    case .included:
                        if entry.isDirectory {
                            next.append(path)
                        } else {
                            walked.append(path)
                            if let size = entry.size, let stamp = entry.stamp { stamps[path] = (size, stamp) }
                        }
                    case .excludedByRule:
                        excluded.append(path)
                    case .skippedByDefault, .alwaysSkipped:
                        continue
                    }
                }
            }
            level = next
        }

        // What the indexer reads (`ProjectIndexer` reads semantic sources and
        // configuration), for every supported language.
        let sources = Set(walked.filter {
            LanguageMode.classify(path: $0) != nil || configurationLanguage(for: fileName(of: $0)) != nil
        })
        var captured: [String: RemoteFile] = [:]
        var fetched: [String] = []
        var hashed: [String] = []
        for path in walked {
            if let old = previous?.files[path], let now = stamps[path],
               old.size == now.size, old.stamp == now.stamp,
               !sources.contains(path) || sourceBytes?.cachedBytes(old.contentID) != nil
            {
                captured[path] = old
            } else if sources.contains(path) {
                fetched.append(path)
            } else {
                hashed.append(path)
            }
        }

        try transport.capture(fetched) { index, bytes in
            let path = fetched[index]
            guard let bytes else {
                unreadable.append(path)
                return
            }
            let contentID = ContentID.sha256(of: bytes)
            sourceBytes?.insert(bytes, for: contentID)
            captured[path] = RemoteFile(
                contentID: contentID,
                fileMode: bytes.starts(with: lfsPointerPrefix) ? .lfsPointer : .regular,
                size: UInt64(bytes.count),
                stamp: stamps[path].flatMap { $0.size == UInt64(bytes.count) ? $0.stamp : nil }
            )
        }
        for (path, facts) in zip(hashed, try transport.hash(hashed)) {
            guard let facts else {
                unreadable.append(path)
                continue
            }
            captured[path] = RemoteFile(
                contentID: facts.contentID,
                fileMode: facts.isLFSPointer ? .lfsPointer : .regular,
                size: facts.size,
                stamp: stamps[path].flatMap { $0.size == facts.size ? $0.stamp : nil }
            )
        }

        self.transport = transport
        self.sourceBytes = sourceBytes
        snapshotID = SnapshotID(rawValue: UUID())
        projectRootName = transport.remotePath.split(separator: "/").last.map(String.init) ?? "/"
        files = captured
        ruleExcludedPaths = excluded.sorted()
        unreadablePaths = unreadable.sorted()
        configurationPaths = captured.keys.filter { configurationLanguage(for: fileName(of: $0)) != nil }.sorted()
        languages = detectedLanguages(in: captured.map { ($0.key, $0.value.contentID, $0.value.fileMode) })
    }

    public func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)] {
        files.keys.sorted().compactMap { path in files[path].map { (path, $0.contentID, $0.fileMode) } }
    }

    /// Reads the file again over the connection. Throws `changedSinceCapture`
    /// when it is gone or no longer has the captured content, and the
    /// transport's own error when the link fails, never empty bytes.
    public func readBytes(path: String) throws -> [UInt8] {
        guard let file = files[path] else { throw GitError.missingPath(path) }
        guard let bytes = try transport.readFile(path), ContentID.sha256(of: bytes) == file.contentID else {
            throw GitError.changedSinceCapture(path)
        }
        return bytes
    }

    /// The file as captured, while its bytes are still in memory: what the
    /// reader shows when the link is down. Nil for a file that was never
    /// fetched (anything but sources and configuration) or has been evicted.
    public func capturedBytes(path: String) -> [UInt8]? {
        files[path].flatMap { sourceBytes?.cachedBytes($0.contentID) }
    }

    public func fileSize(path: String) throws -> UInt64 {
        guard let file = files[path] else { throw GitError.missingPath(path) }
        return file.size
    }
}

private struct RemoteFile: Sendable {
    let contentID: ContentID
    let fileMode: FileMode
    let size: UInt64
    /// The listing's mtime token when it agrees with the bytes taken (same
    /// size); nil means the next capture takes the file again.
    let stamp: String?
}

/// Where a remote project lives: an ssh host (a `~/.ssh/config` name) and an
/// absolute directory there.
///
/// The app stands for it with a placeholder directory,
/// `<placeholderParent>/<sha256(host NUL path)>/`, holding only
/// `remote.json` (this record) and no source. Sessions, the index cache,
/// exclusion rules and window ownership key on that local path as for any
/// project; code that still reads the root from disk finds nothing instead of
/// another file. `RemoteOrigin(placeholder:)` is the one test for "is this
/// root remote".
public struct RemoteOrigin: Encodable, Equatable, Hashable, Sendable {
    public let host: String
    public let path: String

    /// `host:/absolute/path`; nil unless the host is usable by ssh and the
    /// path is absolute. `.` and empty components are dropped and a trailing
    /// `/` removed, so one directory has one placeholder; `..` is refused.
    public init?(parsing text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = text.firstIndex(of: ":") else { return nil }
        self.init(host: String(text[..<colon]), path: String(text[text.index(after: colon)...]))
    }

    public init?(host: String, path: String) {
        let components = path.split(separator: "/").filter { $0 != "." }
        guard SSHTransport.isUsableHost(host), path.hasPrefix("/"), !path.contains("\0"),
              !components.contains("..")
        else { return nil }
        self.host = host
        self.path = "/" + components.joined(separator: "/")
    }

    /// What the app shows wherever a project path would be shown.
    public var displayName: String { "\(host):\(path)" }

    /// `$CODEINSIGHT_REMOTES_ROOT`, else
    /// `~/Library/Application Support/CodeInsight/remotes`.
    public static var placeholderParent: URL {
        if let root = ProcessInfo.processInfo.environment["CODEINSIGHT_REMOTES_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport.appendingPathComponent("CodeInsight/remotes", isDirectory: true)
    }

    /// The placeholder directory, created (with its record) if needed.
    public func placeholder(in parent: URL = RemoteOrigin.placeholderParent) throws -> URL {
        let directory = parent.appendingPathComponent(Self.name(host: host, path: path), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = directory.appendingPathComponent(Self.recordName)
        if Self.read(record) != self {
            try JSONEncoder().encode(self).write(to: record, options: .atomic)
        }
        return directory
    }

    /// The origin `root` stands for: only a directory directly under
    /// `parent` whose name is the digest of the record it holds, so a
    /// project that merely contains a `remote.json` is never taken for one.
    public init?(placeholder root: URL, parent: URL = RemoteOrigin.placeholderParent) {
        let name = root.lastPathComponent
        guard name.utf8.count == 64,
              root.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
              == parent.resolvingSymlinksInPath().standardizedFileURL.path,
              let origin = Self.read(root.appendingPathComponent(Self.recordName)),
              Self.name(host: origin.host, path: origin.path) == name
        else { return nil }
        self = origin
    }

    /// `host:/path` for a remote placeholder, else the folder's name.
    public static func displayName(for root: URL) -> String {
        RemoteOrigin(placeholder: root)?.displayName ?? root.lastPathComponent
    }

    private static let recordName = "remote.json"

    private static func name(host: String, path: String) -> String {
        ContentID.sha256(of: Array("\(host)\0\(path)".utf8)).bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func read(_ record: URL) -> RemoteOrigin? {
        guard let data = try? Data(contentsOf: record),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        return RemoteOrigin(host: decoded.host, path: decoded.path)
    }

    private struct Stored: Decodable {
        let host: String
        let path: String
    }
}
