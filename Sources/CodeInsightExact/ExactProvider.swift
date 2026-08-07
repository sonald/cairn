import CodeInsightCore
import CodeInsightGit
import CryptoKit
import Foundation

public struct ExactCapabilities: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let definition = ExactCapabilities(rawValue: 1 << 0)
    public static let implementations = ExactCapabilities(rawValue: 1 << 1)
    public static let callHierarchy = ExactCapabilities(rawValue: 1 << 2)
    public static let references = ExactCapabilities(rawValue: 1 << 3)
}

public enum ExactReadiness: Equatable, Sendable {
    case preparing
    case ready
    case unavailable(String)
    case closed
}

public struct ExactLocation: Equatable, Sendable {
    public let file: String
    public let byteOffset: Int
    public let line: Int
    public let column: Int

    public init(file: String, byteOffset: Int, line: Int, column: Int) {
        self.file = file
        self.byteOffset = byteOffset
        self.line = line
        self.column = column
    }
}

public struct ExactTarget: Sendable {
    public let location: ExactLocation

    public init(location: ExactLocation) {
        self.location = location
    }
}

public enum ExactDefinitionQueryResult: Sendable {
    case completed([ExactTarget])
    case cancelled
    case unavailable(String)
}

public enum ExactAnalysisLimitation: String, Hashable, Sendable {
    case buildScriptsDisabled
    case procMacrosDisabled
    case dependenciesUnavailableOffline

    public var displayName: String {
        switch self {
        case .buildScriptsDisabled: "build scripts disabled"
        case .procMacrosDisabled: "proc macros disabled"
        case .dependenciesUnavailableOffline: "dependencies unavailable offline"
        }
    }
}

public struct ExactAnalysisEnvironment: Sendable {
    public let trustMode: TrustMode
    public let limitations: Set<ExactAnalysisLimitation>

    public init(
        trustMode: TrustMode,
        limitations: Set<ExactAnalysisLimitation> = []
    ) {
        self.trustMode = trustMode
        self.limitations = limitations
    }
}

public enum QueryExhaustiveness: Sendable {
    case guaranteed
    case bestEffort
    case unknown
}

public struct ExactCallHierarchyItem: Sendable {
    public let name: String
    public let kind: Int
    public let uri: String
    public let range: ExactLocation
    public let selectionRange: ExactLocation
    public let data: Data?

    public init(
        name: String,
        kind: Int,
        uri: String,
        range: ExactLocation,
        selectionRange: ExactLocation,
        data: Data?
    ) {
        self.name = name
        self.kind = kind
        self.uri = uri
        self.range = range
        self.selectionRange = selectionRange
        self.data = data
    }
}

public struct ExactCallRelation: Sendable {
    /// The caller for incoming calls and the callee for outgoing calls.
    public let item: ExactCallHierarchyItem
    /// Call sites with their file identities already materialized.
    public let callSites: [ExactLocation]

    public init(
        item: ExactCallHierarchyItem,
        callSites: [ExactLocation]
    ) {
        self.item = item
        self.callSites = callSites
    }
}

public struct ExactProfileKey: Hashable, Sendable {
    public let configFingerprint: String
    public let environmentFingerprint: String
    public let featureSelection: FeatureSelection

    public init(
        projectURL: URL,
        featureSelection: FeatureSelection = .defaultFeatures
    ) throws {
        let root = projectURL.standardizedFileURL
        let cargo = root.appendingPathComponent("Cargo.toml")
        guard FileManager.default.isReadableFile(atPath: cargo.path) else {
            throw ExactError.missingConfiguration(cargo.path)
        }
        configFingerprint = try Self.sha256(contentsOf: cargo)

        let lock = root.appendingPathComponent("Cargo.lock")
        environmentFingerprint = FileManager.default.isReadableFile(
            atPath: lock.path
        ) ? try Self.sha256(contentsOf: lock) : ""
        self.featureSelection = featureSelection
    }

    public init(
        snapshot: any Snapshot,
        featureSelection: FeatureSelection = .defaultFeatures
    ) throws {
        let cargo: [UInt8]
        do {
            cargo = try snapshot.readBytes(path: "Cargo.toml")
        } catch {
            throw ExactError.missingConfiguration("Cargo.toml")
        }
        configFingerprint = Self.sha256(bytes: cargo)
        environmentFingerprint = (try? snapshot.readBytes(path: "Cargo.lock"))
            .map(Self.sha256(bytes:)) ?? ""
        self.featureSelection = featureSelection
    }

    public init(
        configFingerprint: String,
        environmentFingerprint: String,
        featureSelection: FeatureSelection = .defaultFeatures
    ) {
        self.configFingerprint = configFingerprint
        self.environmentFingerprint = environmentFingerprint
        self.featureSelection = featureSelection
    }

    private static func sha256(contentsOf url: URL) throws -> String {
        sha256(bytes: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    private static func sha256<D: DataProtocol>(bytes: D) -> String {
        SHA256.hash(data: Data(bytes))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct ExactAttribution: Sendable {
    public let provider: String
    public let toolVersion: String
    public let configFingerprint: String
    public let environmentFingerprint: String
    public let featureSelection: FeatureSelection
    public let environment: ExactAnalysisEnvironment
    public let generatedAt: Date

    public init(
        provider: String,
        toolVersion: String,
        configFingerprint: String,
        environmentFingerprint: String,
        featureSelection: FeatureSelection = .defaultFeatures,
        environment: ExactAnalysisEnvironment,
        generatedAt: Date
    ) {
        self.provider = provider
        self.toolVersion = toolVersion
        self.configFingerprint = configFingerprint
        self.environmentFingerprint = environmentFingerprint
        self.featureSelection = featureSelection
        self.environment = environment
        self.generatedAt = generatedAt
    }
}

public protocol ExactProvider: Sendable {
    var capabilities: ExactCapabilities { get }
    var toolVersion: String { get }

    func prepare(
        snapshot: any Snapshot,
        profile: ExactProfileKey,
        trustMode: TrustMode
    ) throws -> any ExactSession
}

public final class ExactRequestBatch: @unchecked Sendable {
    public static let maximumConcurrentRequests = 4

    private let condition = NSCondition()
    private var current = true
    private var activeRequests = 0

    public init() {}

    public var isCurrent: Bool {
        condition.lock()
        defer { condition.unlock() }
        return current
    }

    public func cancel() {
        condition.lock()
        current = false
        condition.broadcast()
        condition.unlock()
    }

    func acquire() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while current,
              activeRequests >= Self.maximumConcurrentRequests
        {
            _ = condition.wait(
                until: Date().addingTimeInterval(0.01)
            )
        }
        guard current else { return false }
        activeRequests += 1
        return true
    }

    func release() {
        condition.lock()
        activeRequests -= 1
        condition.broadcast()
        condition.unlock()
    }
}

public protocol ExactSession: AnyObject, Sendable {
    var negotiatedCapabilities: ExactCapabilities { get }
    var readiness: ExactReadiness { get }
    var attribution: ExactAttribution { get }
    var onEnvironmentChange: (@Sendable (ExactAnalysisEnvironment) -> Void)? {
        get set
    }

    func definition(
        file: String,
        byteOffset: Int
    ) throws -> ExactDefinitionQueryResult
    func implementations(
        file: String,
        byteOffset: Int
    ) throws -> [ExactLocation]?
    func references(
        file: String,
        byteOffset: Int,
        includeDeclaration: Bool
    ) throws -> [ExactLocation]?
    func prepareCallHierarchy(
        file: String,
        byteOffset: Int
    ) throws -> [ExactCallHierarchyItem]?
    func incomingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]?
    func outgoingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]?
    func definition(
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch
    ) throws -> ExactDefinitionQueryResult
    func implementations(
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch
    ) throws -> [ExactLocation]?
    func references(
        file: String,
        byteOffset: Int,
        includeDeclaration: Bool,
        batch: ExactRequestBatch
    ) throws -> [ExactLocation]?
    func prepareCallHierarchy(
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch
    ) throws -> [ExactCallHierarchyItem]?
    func incomingCalls(
        item: ExactCallHierarchyItem,
        batch: ExactRequestBatch
    ) throws -> [ExactCallRelation]?
    func outgoingCalls(
        item: ExactCallHierarchyItem,
        batch: ExactRequestBatch
    ) throws -> [ExactCallRelation]?
    func cancel(batch: ExactRequestBatch)
    func cancel()
    func close()
}

public extension ExactSession {
    var onEnvironmentChange: (@Sendable (ExactAnalysisEnvironment) -> Void)? {
        get { nil }
        set {}
    }

    func definition(
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch
    ) throws -> ExactDefinitionQueryResult {
        guard batch.acquire() else { return .cancelled }
        defer { batch.release() }
        guard batch.isCurrent else { return .cancelled }
        return try definition(file: file, byteOffset: byteOffset)
    }

    func implementations(
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch
    ) throws -> [ExactLocation]? {
        try inBatch(batch) {
            try implementations(file: file, byteOffset: byteOffset)
        }
    }

    func references(
        file: String,
        byteOffset: Int,
        includeDeclaration: Bool,
        batch: ExactRequestBatch
    ) throws -> [ExactLocation]? {
        try inBatch(batch) {
            try references(
                file: file,
                byteOffset: byteOffset,
                includeDeclaration: includeDeclaration
            )
        }
    }

    func prepareCallHierarchy(
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch
    ) throws -> [ExactCallHierarchyItem]? {
        try inBatch(batch) {
            try prepareCallHierarchy(file: file, byteOffset: byteOffset)
        }
    }

    func incomingCalls(
        item: ExactCallHierarchyItem,
        batch: ExactRequestBatch
    ) throws -> [ExactCallRelation]? {
        try inBatch(batch) { try incomingCalls(item: item) }
    }

    func outgoingCalls(
        item: ExactCallHierarchyItem,
        batch: ExactRequestBatch
    ) throws -> [ExactCallRelation]? {
        try inBatch(batch) { try outgoingCalls(item: item) }
    }

    func cancel(batch: ExactRequestBatch) {
        batch.cancel()
    }

    private func inBatch<Result>(
        _ batch: ExactRequestBatch,
        _ request: () throws -> Result?
    ) throws -> Result? {
        guard batch.acquire() else { return nil }
        defer { batch.release() }
        guard batch.isCurrent else { return nil }
        return try request()
    }
}

public enum ExactError: Error, LocalizedError {
    case missingConfiguration(String)
    case invalidPath(String)
    case invalidUTF8(String)
    case invalidPosition(String, Int)
    case invalidDefinitionResponse(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration(let path):
            "exact configuration not found: \(path)"
        case .invalidPath(let path): "invalid project-relative path: \(path)"
        case .invalidUTF8(let path): "source is not valid UTF-8: \(path)"
        case let .invalidPosition(path, offset):
            "byte offset \(offset) is outside a UTF-8 scalar boundary in \(path)"
        case .invalidDefinitionResponse(let detail):
            "invalid definition response: \(detail)"
        case .unavailable(let detail): "exact provider unavailable: \(detail)"
        }
    }
}

struct LSPPosition: Equatable {
    let line: Int
    let character: Int
}

struct LSPPositionMap {
    let bytes: [UInt8]
    private let lineStarts: [Int]

    init?(utf8 bytes: [UInt8]) {
        guard String(data: Data(bytes), encoding: .utf8) != nil else {
            return nil
        }
        self.bytes = bytes
        var starts = [0]
        for (offset, byte) in bytes.enumerated() where byte == 0x0A {
            starts.append(offset + 1)
        }
        lineStarts = starts
    }

    func position(forByteOffset offset: Int) -> LSPPosition? {
        guard offset >= 0, offset <= bytes.count else { return nil }
        let line = lastLineStart(atMost: offset)
        var byte = lineStarts[line]
        var utf16 = 0
        while byte < offset {
            let width = scalarWidth(firstByte: bytes[byte])
            guard byte + width <= offset else { return nil }
            utf16 += width == 4 ? 2 : 1
            byte += width
        }
        return LSPPosition(line: line, character: utf16)
    }

    func byteOffset(for position: LSPPosition) -> Int? {
        guard position.line >= 0,
              position.line < lineStarts.count,
              position.character >= 0
        else { return nil }

        let start = lineStarts[position.line]
        var end = position.line + 1 < lineStarts.count
            ? lineStarts[position.line + 1] - 1
            : bytes.count
        if end > start, bytes[end - 1] == 0x0D { end -= 1 }

        var byte = start
        var utf16 = 0
        while utf16 < position.character, byte < end {
            let width = scalarWidth(firstByte: bytes[byte])
            let units = width == 4 ? 2 : 1
            guard utf16 + units <= position.character else { return nil }
            byte += width
            utf16 += units
        }
        return utf16 == position.character ? byte : nil
    }

    func lineAndByteColumn(at offset: Int) -> (line: Int, column: Int)? {
        guard position(forByteOffset: offset) != nil else { return nil }
        let line = lastLineStart(atMost: offset)
        return (line + 1, offset - lineStarts[line] + 1)
    }

    private func lastLineStart(atMost offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low - 1
    }

    private func scalarWidth(firstByte: UInt8) -> Int {
        switch firstByte {
        case 0x00...0x7F: 1
        case 0xC2...0xDF: 2
        case 0xE0...0xEF: 3
        case 0xF0...0xF4: 4
        default: preconditionFailure("validated UTF-8 contains an invalid lead byte")
        }
    }
}
