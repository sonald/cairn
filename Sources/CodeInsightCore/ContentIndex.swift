import Foundation

public enum LanguageID: UInt8, Codable, Sendable {
    case rust = 0
    case python = 1
    case typescript = 2
    case javascript = 3
}

public struct LanguageMode: Codable, Hashable, Sendable {
    public let language: LanguageID
    public let variant: String?

    public init(language: LanguageID, variant: String? = nil) {
        self.language = language
        self.variant = variant?.precomposedStringWithCanonicalMapping
    }

    public static func classify(path: String, language: LanguageID) -> LanguageMode? {
        switch language {
        case .rust, .python:
            let stringPath = path as NSString
            var pathExtension = stringPath.pathExtension
            if pathExtension.isEmpty {
                let lastComponent = stringPath.lastPathComponent
                if lastComponent == "." || lastComponent == ".." {
                    // Preserve URL normalization for callers passing a directory traversal.
                    pathExtension = URL(fileURLWithPath: path).pathExtension
                }
            }
            guard pathExtension == (language == .rust ? "rs" : "py") else {
                return nil
            }
            return LanguageMode(language: language)
        case .typescript, .javascript:
            guard language == .typescript else { return nil }
            if path.hasSuffix(".ts")
                && !path.hasSuffix(".d.ts")
                && !path.hasSuffix(".mts")
                && !path.hasSuffix(".cts")
            {
                return LanguageMode(language: .typescript)
            }
            if path.hasSuffix(".tsx") {
                return LanguageMode(language: .typescript, variant: "tsx")
            }
            return nil
        }
    }

    /// Languages a project can be analyzed in, in `rawValue` order.
    public static let supported: [LanguageID] = [.rust, .python, .typescript]

    /// Classifies against every supported language. Only snapshot language
    /// detection uses this; everything else classifies against the
    /// project's current set so a language it does not analyze stays a
    /// plain preview.
    public static func classify(path: String) -> LanguageMode? {
        classify(path: path, languages: supported)
    }

    package static func classify(
        path: String,
        languages: [LanguageID]
    ) -> LanguageMode? {
        for language in languages {
            if let mode = classify(path: path, language: language) {
                return mode
            }
        }
        return nil
    }

}

/// Whether `path` lies in the project unit rooted at `root`; `.` holds
/// every path.
package func isWithin(root: String, path: String) -> Bool {
    root == "." || root.isEmpty
        || path == root
        || path.hasPrefix(root + "/")
}

/// The deepest of `roots` that holds `path`. A source belongs to exactly
/// this one unit of its language, so nested units never share files.
package func deepestUnitRoot(containing path: String, among roots: [String]) -> String? {
    func depth(_ root: String) -> Int {
        root == "." || root.isEmpty ? 0 : root.split(separator: "/").count
    }
    return roots.filter { isWithin(root: $0, path: path) }
        .max { depth($0) < depth($1) }
}

public struct ContentIndexKey: Codable, Hashable, Sendable {
    public let contentID: ContentID
    public let languageMode: LanguageMode
    public let grammarVersion: UInt32
    public let extractorVersion: UInt32

    public init(
        contentID: ContentID,
        languageMode: LanguageMode,
        grammarVersion: UInt32,
        extractorVersion: UInt32
    ) {
        self.contentID = contentID
        self.languageMode = languageMode
        self.grammarVersion = grammarVersion
        self.extractorVersion = extractorVersion
    }
}

public enum DeclarationKind: UInt8, Codable, Sendable {
    case rustFn
    case rustStruct
    case rustEnum
    case rustTrait
    case rustImpl
    case rustMod
    case rustConst
    case rustStatic
    case rustTypeAlias
    case rustMethod
    case rustField
    case pythonFunction = 11
    case pythonClass = 12
    case typescriptFunction = 13
    case typescriptClass = 14
}

public struct SymbolGroupID: Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public struct DeclarationFacet: Codable, Sendable {
    public let symbolGroupID: SymbolGroupID
    public let space: SymbolSpace
    public let kind: DeclarationKind
    public let nameID: NameID
    public let range: ByteRange
    public let nameRange: ByteRange
    public let parentFacetIndex: UInt32?
    public let signatureFingerprint: ContentID?
    public let bodyFingerprint: ContentID?
    /// Where a field's type is spelled (only fields carry it today).
    public let typeRef: TypeRef?

    public init(
        symbolGroupID: SymbolGroupID,
        space: SymbolSpace,
        kind: DeclarationKind,
        nameID: NameID,
        range: ByteRange,
        nameRange: ByteRange,
        parentFacetIndex: UInt32?,
        signatureFingerprint: ContentID?,
        bodyFingerprint: ContentID?,
        typeRef: TypeRef? = nil
    ) {
        self.symbolGroupID = symbolGroupID
        self.space = space
        self.kind = kind
        self.nameID = nameID
        self.range = range
        self.nameRange = nameRange
        self.parentFacetIndex = parentFacetIndex
        self.signatureFingerprint = signatureFingerprint
        self.bodyFingerprint = bodyFingerprint
        self.typeRef = typeRef
    }
}

public struct ImplRelation: Codable, Sendable {
    public let implFacetIndex: UInt32
    public let traitNameID: NameID?
    public let traitNameRange: ByteRange?
    public let typeNameID: NameID

    public init(
        implFacetIndex: UInt32,
        traitNameID: NameID?,
        traitNameRange: ByteRange?,
        typeNameID: NameID
    ) {
        self.implFacetIndex = implFacetIndex
        self.traitNameID = traitNameID
        self.traitNameRange = traitNameRange
        self.typeNameID = typeNameID
    }
}

public enum ContentRegionKind: UInt8, Codable, Sendable {
    case comment
    case string
}

/// A syntax region. Indexes store these in source order without overlaps.
public struct ContentRegion: Codable, Equatable, Sendable {
    public let range: ByteRange
    public let kind: ContentRegionKind

    public init(range: ByteRange, kind: ContentRegionKind) {
        self.range = range
        self.kind = kind
    }

    // A compact tuple avoids repeating field names for every literal and comment.
    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        let lower = try values.decode(UInt32.self)
        let upper = try values.decode(UInt32.self)
        guard lower < upper else {
            throw DecodingError.dataCorruptedError(in: values, debugDescription: "Empty or reversed content region")
        }
        range = ByteRange(lowerBound: lower, upperBound: upper)
        kind = try values.decode(ContentRegionKind.self)
        guard values.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: values, debugDescription: "Extra content region fields")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(range.lowerBound)
        try values.encode(range.upperBound)
        try values.encode(kind)
    }
}

public struct ContentIndex: Codable, Sendable {
    public let key: ContentIndexKey
    public let scopes: [ScopeRecord]
    public let bindings: [BindingRecord]
    public let executableRegions: [ExecutableRegionRecord]
    public let symbols: [DeclarationFacet]
    public let implRelations: [ImplRelation]
    public let calls: [UnresolvedCall]
    public let imports: [ImportBinding]
    public let exports: [ExportRecord]
    public let lineTable: LineTable
    public let regions: [ContentRegion]

    public init(
        key: ContentIndexKey,
        scopes: [ScopeRecord],
        bindings: [BindingRecord],
        executableRegions: [ExecutableRegionRecord],
        symbols: [DeclarationFacet],
        implRelations: [ImplRelation] = [],
        calls: [UnresolvedCall],
        imports: [ImportBinding],
        exports: [ExportRecord],
        lineTable: LineTable,
        regions: [ContentRegion] = []
    ) {
        self.key = key
        self.scopes = scopes
        self.bindings = bindings
        self.executableRegions = executableRegions
        self.symbols = symbols
        self.implRelations = implRelations
        self.calls = calls
        self.imports = imports
        self.exports = exports
        self.lineTable = lineTable
        self.regions = regions
    }
}

public struct ExtractionInterners: Sendable {
    public let names: Interner<NameID>
    public let strings: Interner<StringID>

    public init(
        names: Interner<NameID>,
        strings: Interner<StringID>
    ) {
        self.names = names
        self.strings = strings
    }
}

public protocol LanguageExtractor: Sendable {
    var language: LanguageID { get }
    var grammarVersion: UInt32 { get }
    var extractorVersion: UInt32 { get }

    /// Content extraction interns syntax names and free-form strings. Paths are
    /// intentionally absent because they belong to SnapshotManifest.
    func extract(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner: ExtractionInterners
    ) throws -> ContentIndex

    func extractWithDiagnostics(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner: ExtractionInterners
    ) throws -> (index: ContentIndex, containsErrorNodes: Bool)

    func identifierRanges(
        named name: String,
        in bytes: [UInt8],
        mode: LanguageMode
    ) throws -> [ByteRange]
}

public extension LanguageExtractor {
    func extract(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner: ExtractionInterners
    ) throws -> ContentIndex {
        try extractWithDiagnostics(
            bytes: bytes,
            key: key,
            interner: interner
        ).index
    }
}
