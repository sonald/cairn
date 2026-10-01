public struct ScopeID: Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public enum ScopeKind: UInt8, Codable, Sendable {
    case block
    case function
    case module
    case impl
    case `class`
    case closure
    case matchArm
}

public struct ScopeRecord: Codable, Sendable {
    public let id: ScopeID
    public let parent: ScopeID?
    public let kind: ScopeKind
    public let range: ByteRange

    public init(
        id: ScopeID,
        parent: ScopeID?,
        kind: ScopeKind,
        range: ByteRange
    ) {
        self.id = id
        self.parent = parent
        self.kind = kind
        self.range = range
    }
}

public enum SymbolSpace: UInt8, Codable, Sendable {
    case value
    case type
    case namespace
    case module
    case macro
    case lifetime
    case label
}

public enum BindingKind: UInt8, Codable, Sendable {
    case param
    case letBinding
    case importBinding
    case assignment
    case patternBinding
    case globalDecl
    case nonlocalDecl
}

public enum UnresolvedSymbolHintKind: UInt8, Codable, Sendable {
    case unqualified
    case qualified
    case member
}

public struct UnresolvedSymbolRef: Codable, Sendable {
    public let nameID: NameID
    public let hintKind: UnresolvedSymbolHintKind

    public init(nameID: NameID, hintKind: UnresolvedSymbolHintKind) {
        self.nameID = nameID
        self.hintKind = hintKind
    }
}

public struct BindingRecord: Codable, Sendable {
    public let scopeID: ScopeID
    public let localNameID: NameID
    public let space: SymbolSpace
    public let kind: BindingKind
    public let declarationRange: ByteRange
    public let targetHint: UnresolvedSymbolRef?
    public let typeRef: TypeRef?

    public init(
        scopeID: ScopeID,
        localNameID: NameID,
        space: SymbolSpace,
        kind: BindingKind,
        declarationRange: ByteRange,
        targetHint: UnresolvedSymbolRef?,
        typeRef: TypeRef? = nil
    ) {
        self.scopeID = scopeID
        self.localNameID = localNameID
        self.space = space
        self.kind = kind
        self.declarationRange = declarationRange
        self.targetHint = targetHint
        self.typeRef = typeRef
    }
}

/// Where a binding's or field's type is spelled, already reduced to its
/// head name (wrappers stripped at extraction time).
public enum TypeRef: Codable, Hashable, Sendable {
    case named(ByteRange)                       // `S` in `ps: &Box<S>`
    case primitive(ByteRange)                   // `u32`
    case selfType(ByteRange)                    // the impl's / class's type name
    case constructed(ByteRange)                 // `S` in `S::new()` / `S { .. }`
    case genericBound(parameter: ByteRange, bound: ByteRange)
    case genericUnbounded(parameter: ByteRange)

    /// Every byte range the reference points through.
    public var ranges: [ByteRange] {
        switch self {
        case let .named(range), let .primitive(range), let .selfType(range),
             let .constructed(range):
            [range]
        case let .genericBound(parameter, bound):
            [parameter, bound]
        case let .genericUnbounded(parameter):
            [parameter]
        }
    }
}

public struct ExecutableRegionID: Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public enum ExecutableRegionKind: UInt8, Codable, Sendable {
    case function
    case method
    case closure
    case moduleInitializer
    case classBody
    case fieldInitializer
    case decoratorApplication
    case constantInitializer
}

public struct ExecutableRegionRecord: Codable, Sendable {
    public let id: ExecutableRegionID
    public let kind: ExecutableRegionKind
    public let range: ByteRange
    public let enclosingScopeID: ScopeID
    public let associatedFacetIndex: UInt32?

    public init(
        id: ExecutableRegionID,
        kind: ExecutableRegionKind,
        range: ByteRange,
        enclosingScopeID: ScopeID,
        associatedFacetIndex: UInt32?
    ) {
        self.id = id
        self.kind = kind
        self.range = range
        self.enclosingScopeID = enclosingScopeID
        self.associatedFacetIndex = associatedFacetIndex
    }
}
