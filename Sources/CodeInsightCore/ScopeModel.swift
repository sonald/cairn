public struct ScopeID: Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public enum ScopeKind: Sendable {
    case block
    case function
    case module
    case impl
    case `class`
    case closure
    case matchArm
}

public struct ScopeRecord: Sendable {
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

public enum SymbolSpace: Sendable {
    case value
    case type
    case namespace
    case module
    case macro
    case lifetime
    case label
}

public enum BindingKind: Sendable {
    case param
    case letBinding
    case importBinding
    case assignment
    case patternBinding
    case globalDecl
    case nonlocalDecl
}

public enum UnresolvedSymbolHintKind: Sendable {
    case unqualified
    case qualified
    case member
}

public struct UnresolvedSymbolRef: Sendable {
    public let nameID: NameID
    public let hintKind: UnresolvedSymbolHintKind

    public init(nameID: NameID, hintKind: UnresolvedSymbolHintKind) {
        self.nameID = nameID
        self.hintKind = hintKind
    }
}

public struct BindingRecord: Sendable {
    public let scopeID: ScopeID
    public let localNameID: NameID
    public let space: SymbolSpace
    public let kind: BindingKind
    public let declarationRange: ByteRange
    public let targetHint: UnresolvedSymbolRef?

    public init(
        scopeID: ScopeID,
        localNameID: NameID,
        space: SymbolSpace,
        kind: BindingKind,
        declarationRange: ByteRange,
        targetHint: UnresolvedSymbolRef?
    ) {
        self.scopeID = scopeID
        self.localNameID = localNameID
        self.space = space
        self.kind = kind
        self.declarationRange = declarationRange
        self.targetHint = targetHint
    }
}

public struct ExecutableRegionID: Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public enum ExecutableRegionKind: Sendable {
    case function
    case method
    case closure
    case moduleInitializer
    case classBody
    case fieldInitializer
    case decoratorApplication
    case constantInitializer
}

public struct ExecutableRegionRecord: Sendable {
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
