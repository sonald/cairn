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
}

public enum ExactCoverage: String, Equatable, Sendable {
    case full
    case partial
    case dependenciesUnavailableOffline = "deps unavailable (offline)"
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
    public let trustMode: TrustMode
    public let generatedAt: Date
    public let coverage: ExactCoverage

    public init(
        provider: String,
        toolVersion: String,
        configFingerprint: String,
        environmentFingerprint: String,
        featureSelection: FeatureSelection = .defaultFeatures,
        trustMode: TrustMode,
        generatedAt: Date,
        coverage: ExactCoverage
    ) {
        self.provider = provider
        self.toolVersion = toolVersion
        self.configFingerprint = configFingerprint
        self.environmentFingerprint = environmentFingerprint
        self.featureSelection = featureSelection
        self.trustMode = trustMode
        self.generatedAt = generatedAt
        self.coverage = coverage
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

public protocol ExactSession: AnyObject, Sendable {
    var readiness: ExactReadiness { get }
    var attribution: ExactAttribution { get }
    var onCoverageChange: (@Sendable (ExactCoverage) -> Void)? { get set }

    func definition(file: String, byteOffset: Int) throws -> ExactLocation?
    func cancel()
    func close()
}

public extension ExactSession {
    var onCoverageChange: (@Sendable (ExactCoverage) -> Void)? {
        get { nil }
        set {}
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
