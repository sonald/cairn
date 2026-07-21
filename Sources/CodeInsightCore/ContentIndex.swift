public enum LanguageID: Sendable {
    case rust
    case python
    case typescript
    case javascript
}

public struct LanguageMode: Hashable, Sendable {
    public let language: LanguageID
    public let variant: StringID?

    public init(language: LanguageID, variant: StringID? = nil) {
        self.language = language
        self.variant = variant
    }
}

public struct ContentIndexKey: Hashable, Sendable {
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

public enum DeclarationKind: Sendable {
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
}

public struct SymbolGroupID: Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public struct DeclarationFacet: Sendable {
    public let symbolGroupID: SymbolGroupID
    public let space: SymbolSpace
    public let kind: DeclarationKind
    public let nameID: NameID
    public let range: ByteRange
    public let nameRange: ByteRange
    public let parentFacetIndex: UInt32?
    public let signatureFingerprint: ContentID?
    public let bodyFingerprint: ContentID?

    public init(
        symbolGroupID: SymbolGroupID,
        space: SymbolSpace,
        kind: DeclarationKind,
        nameID: NameID,
        range: ByteRange,
        nameRange: ByteRange,
        parentFacetIndex: UInt32?,
        signatureFingerprint: ContentID?,
        bodyFingerprint: ContentID?
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
    }
}

public struct ImplRelation: Sendable {
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

public struct ContentIndex: Sendable {
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
        lineTable: LineTable
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
    /// Content extraction interns syntax names and free-form strings. Paths are
    /// intentionally absent because they belong to SnapshotManifest.
    func extract(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner: ExtractionInterners
    ) throws -> ContentIndex
}
