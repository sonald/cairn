import CryptoKit
import Foundation

public struct ContentID: Hashable, Sendable {
    public let algorithm: UInt8
    public let bytes: [UInt8]

    public init(algorithm: UInt8, bytes: [UInt8]) {
        self.algorithm = algorithm
        self.bytes = bytes
    }

    /// SHA-256 is algorithm 1. BLAKE3 will use algorithm 2 when introduced.
    public static func sha256(of data: Data) -> ContentID {
        ContentID(algorithm: 1, bytes: Array(SHA256.hash(data: data)))
    }

    public static func sha256(of bytes: [UInt8]) -> ContentID {
        sha256(of: Data(bytes))
    }
}

public struct NameID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public struct PathID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public struct StringID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

/// A lock protects both maps, so callers may share an interner across extractor
/// workers without changing the synchronous extraction API into an actor API.
public final class Interner<ID>: @unchecked Sendable
where ID: RawRepresentable & Hashable & Sendable, ID.RawValue == UInt32 {
    private let lock = NSLock()
    private var idsByString: [String: ID] = [:]
    private var stringsByID: [String] = []

    public init() {}

    public func intern(_ string: String) -> ID {
        lock.lock()
        defer { lock.unlock() }

        if let existing = idsByString[string] {
            return existing
        }
        guard
            let rawValue = UInt32(exactly: stringsByID.count),
            let id = ID(rawValue: rawValue)
        else {
            preconditionFailure("Interner exhausted UInt32 IDs")
        }

        idsByString[string] = id
        stringsByID.append(string)
        return id
    }

    public func resolve(_ id: ID) -> String {
        lock.lock()
        defer { lock.unlock() }

        let index = Int(id.rawValue)
        guard stringsByID.indices.contains(index) else {
            preconditionFailure("ID does not belong to this interner")
        }
        return stringsByID[index]
    }
}
