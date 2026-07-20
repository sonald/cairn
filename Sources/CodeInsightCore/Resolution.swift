public enum Certainty: Int, Comparable, Sendable {
    case unresolved = 0
    case possible = 1
    case probable = 2
    case strong = 3
    case exact = 4

    public static func < (lhs: Certainty, rhs: Certainty) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum DispatchKind: Sendable {
    case direct
    case virtualDispatch
    case traitDispatch
    case interfaceDispatch
    case callback
    case dynamicDispatch
    case macroGenerated
}

public enum ResolutionProvenance: Sendable {
    case fuzzyResolver
    case lsp
    case scip
    case languageProof
}

public enum Completeness: Sendable {
    case complete
    case partial
    case truncated
    case unknown
}

public enum ResolutionEvidence: Sendable {
    case lexicalBinding(bindingIndex: UInt32)
    case uniqueImport(importBindingIndex: UInt32)
    case sameFile(pathID: PathID)
    case nameOnly(nameID: NameID)
    case methodNameOnly(nameID: NameID)
}

public enum LocalOccurrenceKind: Hashable, Sendable {
    case declarationFacet
    case callSite
    case importBinding
}

public struct SymbolOccurrenceID: Hashable, Sendable {
    public let snapshotID: SnapshotID
    public let pathID: PathID
    public let localKind: LocalOccurrenceKind
    public let localIndex: UInt32

    public init(
        snapshotID: SnapshotID,
        pathID: PathID,
        localKind: LocalOccurrenceKind,
        localIndex: UInt32
    ) {
        self.snapshotID = snapshotID
        self.pathID = pathID
        self.localKind = localKind
        self.localIndex = localIndex
    }
}

public struct PackageID: Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public struct GeneratedDocumentID: Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public enum DocumentID: Sendable {
    case snapshotFile(SnapshotID, PathID, ContentID)
    case externalPackage(PackageID, PathID)
    case generated(AnalysisProfileID, GeneratedDocumentID)
    case builtin(LanguageID, StringID)
}

public struct ResolutionCandidate: Sendable {
    public let target: SymbolOccurrenceID
    public let certainty: Certainty
    public let dispatch: DispatchKind
    public let provenance: ResolutionProvenance
    public let completeness: Completeness
    public let evidence: [ResolutionEvidence]

    public init(
        target: SymbolOccurrenceID,
        certainty: Certainty,
        dispatch: DispatchKind,
        provenance: ResolutionProvenance,
        completeness: Completeness,
        evidence: [ResolutionEvidence]
    ) {
        self.target = target
        self.certainty = certainty
        self.dispatch = dispatch
        self.provenance = provenance
        self.completeness = completeness
        self.evidence = evidence
    }
}
