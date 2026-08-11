import CodeInsightCore
import CryptoKit
import Foundation
import SQLite3

final class IndexCache: @unchecked Sendable {
    struct Metadata: Equatable, Sendable {
        let schemaVersion: UInt32
    }

    static let defaultQuotaBytes = 512 * 1024 * 1024
    private static let schemaVersion: UInt32 = 2

    let metadata: Metadata
    private let fileURL: URL
    private let quotaBytes: Int64
    private let queue: DispatchQueue
    private var database: OpaquePointer?

    convenience init(projectURL: URL) throws {
        try self.init(fileURL: Self.fileURL(for: projectURL))
    }

    init(
        fileURL: URL,
        quotaBytes: Int = IndexCache.defaultQuotaBytes,
        schemaVersionOverride: UInt32? = nil
    ) throws {
        self.fileURL = fileURL
        self.quotaBytes = Int64(max(0, quotaBytes))
        metadata = Metadata(
            schemaVersion: schemaVersionOverride ?? Self.schemaVersion
        )
        queue = DispatchQueue(label: "CodeInsight.IndexCache.\(fileURL.lastPathComponent)")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try openAndPrepare()
        } catch {
            closeAndRemoveDatabase()
            try openAndPrepare()
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    func payload(for key: String) -> Data? {
        payloads(for: [key])[key]
    }

    func payloads(for keys: [String]) -> [String: Data] {
        guard !keys.isEmpty else { return [:] }
        let result: [String: Data] = queue.sync {
            do {
                var payloads: [String: Data] = [:]
                for start in stride(from: 0, to: keys.count, by: 500) {
                    let chunk = keys[start..<min(start + 500, keys.count)]
                    let placeholders = chunk.indices.map { "?\($0 - chunk.startIndex + 1)" }
                        .joined(separator: ",")
                    let statement = try prepare(
                        "SELECT contentKey, payload FROM contents "
                            + "WHERE contentKey IN (\(placeholders))"
                    )
                    defer { sqlite3_finalize(statement) }
                    for (offset, key) in chunk.enumerated() {
                        try bind(key, at: Int32(offset + 1), to: statement)
                    }
                    var code = sqlite3_step(statement)
                    while code == SQLITE_ROW {
                        guard let keyBytes = sqlite3_column_text(statement, 0) else {
                            throw IndexCacheError.sqlite(SQLITE_CORRUPT)
                        }
                        let count = Int(sqlite3_column_bytes(statement, 1))
                        payloads[String(cString: keyBytes)] = sqlite3_column_blob(
                            statement,
                            1
                        ).map { Data(bytes: $0, count: count) } ?? Data()
                        code = sqlite3_step(statement)
                    }
                    guard code == SQLITE_DONE else { throw IndexCacheError.sqlite(code) }
                }
                return payloads
            } catch {
                try? rebuild()
                return [:]
            }
        }
        let touchedKeys = Array(result.keys)
        if !touchedKeys.isEmpty {
            queue.async {
                do {
                    try self.touch(touchedKeys, at: Self.now)
                } catch {
                    try? self.rebuild()
                }
            }
        }
        return result
    }

    func removePayload(for key: String) {
        queue.async {
            do {
                let statement = try self.prepare(
                    "DELETE FROM contents WHERE contentKey = ?1"
                )
                defer { sqlite3_finalize(statement) }
                try self.bind(key, at: 1, to: statement)
                try self.stepDone(statement)
            } catch {
                try? self.rebuild()
            }
        }
    }

    func store(_ drafts: [ExtractionDraft]) {
        guard !drafts.isEmpty else { return }
        let lastAccess = Self.now
        queue.async {
            let entries = drafts.compactMap { draft -> (String, Data, Int64)? in
                guard let payload = try? ContentIndexDraftCodec.encode(draft) else {
                    return nil
                }
                return (cacheKey(for: draft.index.key), payload, lastAccess)
            }
            self.storeSynchronously(entries)
        }
    }

    func storeSynchronously(_ entries: [(String, Data, Int64)]) {
        let work = {
            do {
                try self.write(entries)
            } catch {
                try? self.rebuild()
            }
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    func flush() {
        queue.sync {}
    }

    private let queueKey = DispatchSpecificKey<UInt8>()

    private func openAndPrepare() throws {
        var opened: OpaquePointer?
        let code = fileURL.withUnsafeFileSystemRepresentation { path in
            sqlite3_open_v2(
                path,
                &opened,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
        }
        guard code == SQLITE_OK, let opened else {
            if let opened { sqlite3_close_v2(opened) }
            throw IndexCacheError.sqlite(code)
        }
        database = opened
        queue.setSpecific(key: queueKey, value: 1)
        sqlite3_busy_timeout(opened, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS meta(
                schemaVersion INTEGER NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS contents(
                contentKey TEXT PRIMARY KEY,
                payload BLOB NOT NULL,
                lastAccess INTEGER NOT NULL
            ) WITHOUT ROWID
            """)
        let rows = try metadataRows()
        if rows.isEmpty {
            let statement = try prepare(
                "INSERT INTO meta(schemaVersion) VALUES(?1)"
            )
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(metadata.schemaVersion))
            try stepDone(statement)
        } else if rows != [metadata] {
            throw IndexCacheError.metadataMismatch
        }
    }

    private func metadataRows() throws -> [Metadata] {
        let statement = try prepare(
            "SELECT schemaVersion FROM meta"
        )
        defer { sqlite3_finalize(statement) }
        var rows: [Metadata] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            guard let schema = UInt32(exactly: sqlite3_column_int64(statement, 0))
            else { throw IndexCacheError.invalidMetadata }
            rows.append(Metadata(schemaVersion: schema))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw IndexCacheError.sqlite(code) }
        return rows
    }

    private func write(_ entries: [(String, Data, Int64)]) throws {
        guard !entries.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for (key, payload, lastAccess) in entries {
                let statement = try prepare("""
                    INSERT INTO contents(contentKey, payload, lastAccess)
                    VALUES(?1, ?2, ?3)
                    ON CONFLICT(contentKey) DO UPDATE SET
                        payload = excluded.payload,
                        lastAccess = excluded.lastAccess
                    """)
                defer { sqlite3_finalize(statement) }
                try bind(key, at: 1, to: statement)
                try bind(payload, at: 2, to: statement)
                sqlite3_bind_int64(statement, 3, lastAccess)
                try stepDone(statement)
            }
            try evictIfNeeded()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func evictIfNeeded() throws {
        var total = try payloadBytes()
        while total > quotaBytes {
            let statement = try prepare("""
                SELECT contentKey, length(payload)
                FROM contents
                ORDER BY lastAccess ASC, contentKey ASC
                LIMIT 1
                """)
            defer { sqlite3_finalize(statement) }
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW,
                  let keyBytes = sqlite3_column_text(statement, 0)
            else { throw IndexCacheError.sqlite(code) }
            let key = String(cString: keyBytes)
            let bytes = sqlite3_column_int64(statement, 1)
            let deletion = try prepare(
                "DELETE FROM contents WHERE contentKey = ?1"
            )
            defer { sqlite3_finalize(deletion) }
            try bind(key, at: 1, to: deletion)
            try stepDone(deletion)
            total -= bytes
        }
    }

    private func payloadBytes() throws -> Int64 {
        let statement = try prepare(
            "SELECT COALESCE(SUM(length(payload)), 0) FROM contents"
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw IndexCacheError.sqlite(sqlite3_errcode(database))
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func touch(_ keys: [String], at lastAccess: Int64) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare(
                "UPDATE contents SET lastAccess = ?2 WHERE contentKey = ?1"
            )
            defer { sqlite3_finalize(statement) }
            for key in keys {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(key, at: 1, to: statement)
                sqlite3_bind_int64(statement, 2, lastAccess)
                try stepDone(statement)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw IndexCacheError.sqlite(sqlite3_errcode(database)) }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw IndexCacheError.sqlite(sqlite3_errcode(database))
        }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let code = value.withCString {
            sqlite3_bind_text(
                statement,
                index,
                $0,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        guard code == SQLITE_OK else { throw IndexCacheError.sqlite(code) }
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
        let code = value.isEmpty
            ? sqlite3_bind_zeroblob(statement, index, 0)
            : value.withUnsafeBytes {
                sqlite3_bind_blob(
                    statement,
                    index,
                    $0.baseAddress,
                    Int32($0.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
        guard code == SQLITE_OK else { throw IndexCacheError.sqlite(code) }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw IndexCacheError.sqlite(code) }
    }

    private func rebuild() throws {
        closeAndRemoveDatabase()
        try openAndPrepare()
    }

    private func closeAndRemoveDatabase() {
        if let database {
            sqlite3_close_v2(database)
            self.database = nil
        }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: fileURL.path + suffix)
        }
    }

    private static var now: Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    private static func fileURL(for projectURL: URL) -> URL {
        let path = projectURL.resolvingSymlinksInPath().standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let root = ProcessInfo.processInfo.environment["CODEINSIGHT_INDEX_CACHE_ROOT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?.appendingPathComponent("CodeInsight/index-cache", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/CodeInsight/index-cache",
                    isDirectory: true
                )
        return root
            .appendingPathComponent("\(digest).sqlite3")
    }
}

func cacheKey(for key: ContentIndexKey) -> String {
    let content = key.contentID.bytes.map { String(format: "%02x", $0) }.joined()
    let variant = key.languageMode.variant.map {
        let normalized = $0.precomposedStringWithCanonicalMapping
        let bytes = Array(normalized.utf8)
        return "v\(bytes.count)#" + bytes.map { String(format: "%02x", $0) }.joined()
    } ?? "n"
    return "\(key.contentID.algorithm):\(key.contentID.bytes.count)#\(content):"
        + "\(key.languageMode.language.rawValue):"
        + "\(variant):\(key.grammarVersion):\(key.extractorVersion)"
}

private enum IndexCacheError: Error {
    case invalidMetadata
    case metadataMismatch
    case sqlite(Int32)
}
