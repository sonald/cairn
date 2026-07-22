public struct ImportFlags: Codable, OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let wildcard = ImportFlags(rawValue: 1 << 0)
    public static let reexport = ImportFlags(rawValue: 1 << 1)
    public static let typeOnly = ImportFlags(rawValue: 1 << 2)
    public static let conditional = ImportFlags(rawValue: 1 << 3)
    public static let dynamic = ImportFlags(rawValue: 1 << 4)
}

public enum ImportKind: UInt8, Codable, Sendable {
    case module
    case named
    case `default`
    case namespace
    case sideEffect
}

public struct ImportBinding: Codable, Sendable {
    public let moduleSpecifier: StringID
    public let importedName: NameID?
    public let localName: NameID?
    public let kind: ImportKind
    public let flags: ImportFlags
    public let scopeID: ScopeID
    public let range: ByteRange

    public init(
        moduleSpecifier: StringID,
        importedName: NameID?,
        localName: NameID?,
        kind: ImportKind,
        flags: ImportFlags,
        scopeID: ScopeID,
        range: ByteRange
    ) {
        self.moduleSpecifier = moduleSpecifier
        self.importedName = importedName
        self.localName = localName
        self.kind = kind
        self.flags = flags
        self.scopeID = scopeID
        self.range = range
    }
}

public struct ExportRecord: Codable, Sendable {
    public let exportedName: NameID
    public let sourceBindingIndex: UInt32?
    public let range: ByteRange

    public init(
        exportedName: NameID,
        sourceBindingIndex: UInt32?,
        range: ByteRange
    ) {
        self.exportedName = exportedName
        self.sourceBindingIndex = sourceBindingIndex
        self.range = range
    }
}
