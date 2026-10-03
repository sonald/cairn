import CodeInsightCore
import Foundation

private final class SymbolSearchCache: @unchecked Sendable {
    private let lock = NSLock()
    private var index: SymbolSearchIndex?

    func get(orBuild build: () -> SymbolSearchIndex) -> SymbolSearchIndex {
        lock.withLock {
            if let index { return index }
            let built = build()
            index = built
            return built
        }
    }
}

private struct ImplIndex: Sendable {
    let byTraitName: [NameID: [(ContentIndexKey, UInt32)]]
    let byTypeName: [NameID: [(ContentIndexKey, UInt32)]]

    init(indexes: [ContentIndexKey: ContentIndex]) {
        var byTraitName: [NameID: [(ContentIndexKey, UInt32)]] = [:]
        var byTypeName: [NameID: [(ContentIndexKey, UInt32)]] = [:]
        for (key, index) in indexes {
            for relation in index.implRelations {
                if let traitNameID = relation.traitNameID {
                    byTraitName[traitNameID, default: []].append((
                        key,
                        relation.implFacetIndex
                    ))
                }
                byTypeName[relation.typeNameID, default: []].append((
                    key,
                    relation.implFacetIndex
                ))
            }
        }
        self.byTraitName = byTraitName
        self.byTypeName = byTypeName
    }
}

public enum EngineError: Error {
    case snapshotMismatch(expected: SnapshotID, actual: SnapshotID)
    case profileMismatch(expected: AnalysisProfileID, actual: AnalysisProfileID)
}

public struct CallerResult: Sendable {
    public let callSite: SymbolOccurrenceID
    public let region: ExecutableRegionRecord
    public let associatedFacet: DeclarationFacet?
    public let certainty: Certainty
    public let dispatch: DispatchKind
    public let provenance: ResolutionProvenance
    public let completeness: Completeness
    public let evidence: [ResolutionEvidence]
}

public struct OutgoingCall: Sendable {
    public let callSite: SymbolOccurrenceID
    public let call: UnresolvedCall
    public let calleeName: String
    public let candidates: [ResolutionCandidate]
}

public struct OutgoingCallsResult: Sendable {
    public let calls: [OutgoingCall]
    public let completeness: Completeness
}

public struct ImplementationResult: Sendable {
    public let implementation: SymbolOccurrenceID
    public let typeName: String
    public let certainty: Certainty
    public let traitDefinitions: [ResolutionCandidate]
}

public final class EngineSession: Sendable {
    public var manifest: SnapshotManifest { snapshotView.manifest }
    public var contentIndexes: [ContentIndexKey: ContentIndex] {
        snapshotView.contentIndexes
    }
    public var stats: IndexStats { snapshotView.stats }
    public var names: Interner<NameID> { store.names }
    public var paths: Interner<PathID> { store.paths }
    public var strings: Interner<StringID> { store.strings }
    public var analysisProfile: AnalysisProfile { snapshotView.analysisProfile }

    public var snapshotID: SnapshotID { manifest.snapshotID }
    public var moduleChildren: [PathID: [NameID: PathID]] {
        moduleMap.moduleChildren
    }
    var byTypeName: [NameID: [(ContentIndexKey, UInt32)]] {
        implIndex.byTypeName
    }

    let namePosting: NamePosting
    var moduleMap: ModuleMap { snapshotView.moduleMap }
    let store: ProjectIndexStore
    let snapshotView: SnapshotView
    let extractor: any LanguageExtractor
    private let storeState: ProjectIndexStore.State
    private let filesByPath: [PathID: FileOccurrence]
    private let contentKeysByPath: [PathID: ContentIndexKey]
    private let occurrencesByContentKey: [ContentIndexKey: [FileOccurrence]]
    private let aliasIndex: [NameID: Set<NameID>]
    private let callOwnershipByContent: [ContentIndexKey: CallOwnershipIndex]
    private let implIndex: ImplIndex
    private let searchableDefinitionNameIDs: [NameID]
    var sourceBytesByContent: [ContentID: [UInt8]] {
        storeState.sourceBytesByContent
    }
    private let symbolSearchCache = SymbolSearchCache()

    init(
        store: ProjectIndexStore,
        snapshotView: SnapshotView
    ) {
        precondition(snapshotView.store === store)
        self.store = store
        self.snapshotView = snapshotView
        extractor = snapshotView.extractor
        storeState = snapshotView.storeState
        let manifest = snapshotView.manifest
        let contentIndexes = snapshotView.contentIndexes
        filesByPath = Dictionary(uniqueKeysWithValues: manifest.files.map {
            ($0.pathID, $0)
        })

        contentKeysByPath = snapshotView.contentKeysByPath
        var occurrencesByContentKey: [ContentIndexKey: [FileOccurrence]] = [:]
        for file in manifest.files {
            guard let key = contentKeysByPath[file.pathID] else { continue }
            occurrencesByContentKey[key, default: []].append(file)
        }
        self.occurrencesByContentKey = occurrencesByContentKey

        var aliasIndex: [NameID: Set<NameID>] = [:]
        let viewIndexes = contentIndexes
        for index in viewIndexes.values {
            for binding in index.imports {
                guard let importedName = binding.importedName,
                      let localName = binding.localName
                else { continue }
                aliasIndex[importedName, default: []].insert(localName)
            }
        }
        self.aliasIndex = aliasIndex
        callOwnershipByContent = viewIndexes.mapValues { CallOwnershipIndex(content: $0) }
        implIndex = ImplIndex(indexes: viewIndexes)
        namePosting = NamePosting(indexes: viewIndexes)
        searchableDefinitionNameIDs = Array(namePosting.definitions.keys)
    }

    public func reprofiled(
        featureSelection: FeatureSelection
    ) -> EngineSession {
        let profile = AnalysisProfile(
            language: analysisProfile.language,
            projectRoot: analysisProfile.projectRoot,
            projectUnitName: analysisProfile.projectUnitName,
            configFingerprint: analysisProfile.configFingerprint,
            environmentFingerprint: analysisProfile.environmentFingerprint,
            featureSelection: featureSelection,
            featureNames: analysisProfile.featureNames,
            edition: analysisProfile.edition,
            trustMode: analysisProfile.trustMode
        )
        return EngineSession(
            store: store,
            snapshotView: SnapshotView(
                reprofiling: snapshotView,
                analysisProfile: profile
            )
        )
    }

    public func definitions(
        of name: String,
        context: QueryContext
    ) throws -> [(SymbolOccurrenceID, DeclarationFacet, PathID)] {
        try validate(context)
        return definitionOccurrences(named: names.intern(name))
    }

    public func callers(
        of name: String,
        context: QueryContext
    ) throws -> [CallerResult] {
        try validate(context)
        let nameID = names.intern(name)
        var callNameIDs: Set<NameID> = [nameID]
        callNameIDs.formUnion(aliasIndex[nameID] ?? [])

        var seen: Set<SymbolOccurrenceID> = []
        var results: [CallerResult] = []
        let resolver = Resolver(session: self)
        for callNameID in callNameIDs {
            for posting in namePosting.calls[callNameID] ?? [] {
                guard let index = contentIndexes[posting.key],
                      index.calls.indices.contains(Int(posting.callIndex))
                else { continue }
                let call = index.calls[Int(posting.callIndex)]
                for file in occurrences(of: posting.key) {
                    let callSite = SymbolOccurrenceID(
                        snapshotID: snapshotID,
                        pathID: file.pathID,
                        localKind: .callSite,
                        localIndex: posting.callIndex
                    )
                    guard seen.insert(callSite).inserted,
                          let regionOffset = callOwnershipByContent[posting.key]?.regionIndexByID[call.regionID]
                    else { continue }

                    let region = index.executableRegions[regionOffset]
                    let candidates = resolver.resolve(
                        file: file.pathID,
                        offset: call.nameRange.lowerBound,
                        context: context
                    )
                    let matched = candidates.first { candidate in
                        guard candidate.certainty >= .probable,
                              isDefinitionEvidence(candidate.evidence),
                              let facet = facet(for: candidate.target)
                        else { return false }
                        return facet.nameID == nameID
                    }
                    let certainty = callerCertainty(
                        from: matched,
                        definitionNameID: nameID
                    )
                    results.append(CallerResult(
                        callSite: callSite,
                        region: region,
                        associatedFacet: region.associatedFacetIndex.flatMap {
                            index.symbols.indices.contains(Int($0))
                                ? index.symbols[Int($0)] : nil
                        },
                        certainty: certainty,
                        dispatch: matched?.dispatch ?? dispatch(for: call.syntacticKind),
                        provenance: .fuzzyResolver,
                        completeness: .complete,
                        evidence: matched?.evidence ?? fallbackEvidence(
                            for: call.syntacticKind,
                            nameID: nameID
                        )
                    ))
                }
            }
        }
        return results.sorted {
            if $0.certainty != $1.certainty { return $0.certainty > $1.certainty }
            let lhs = paths.resolve($0.callSite.pathID)
            let rhs = paths.resolve($1.callSite.pathID)
            if lhs != rhs { return lhs < rhs }
            return $0.callSite.localIndex < $1.callSite.localIndex
        }
    }

    public func outgoingCalls(
        from definition: SymbolOccurrenceID,
        context: QueryContext
    ) throws -> OutgoingCallsResult {
        try validate(context)
        guard definition.snapshotID == snapshotID,
              definition.localKind == .declarationFacet,
              let (key, index) = content(at: definition.pathID),
              index.symbols.indices.contains(Int(definition.localIndex))
        else {
            return OutgoingCallsResult(calls: [], completeness: .complete)
        }

        let matching = callOwnershipByContent[key]?.callIndicesByFacet[Int(definition.localIndex)] ?? []
        let completeness: Completeness = matching.count > 512
            ? .truncated : .complete
        let resolver = Resolver(session: self)
        let calls = matching.prefix(512).compactMap {
            offset -> OutgoingCall? in
            let call = index.calls[offset]
            guard let callIndex = UInt32(exactly: offset) else { return nil }
            return OutgoingCall(
                callSite: SymbolOccurrenceID(
                    snapshotID: snapshotID,
                    pathID: definition.pathID,
                    localKind: .callSite,
                    localIndex: callIndex
                ),
                call: call,
                calleeName: names.resolve(call.nameID),
                candidates: resolver.resolve(
                    file: definition.pathID,
                    offset: call.nameRange.lowerBound,
                    context: context
                )
            )
        }
        return OutgoingCallsResult(calls: calls, completeness: completeness)
    }

    public func implementations(
        ofTrait name: String,
        context: QueryContext
    ) throws -> [ImplementationResult] {
        try validate(context)
        let traitNameID = names.intern(name)
        let definitions = definitionOccurrences(named: traitNameID).filter {
            $0.1.kind == .rustTrait
        }
        let certainty: Certainty = definitions.count == 1 ? .strong : .possible
        let definitionCandidates = definitions.map { occurrence, _, _ in
            ResolutionCandidate(
                target: occurrence,
                certainty: certainty,
                dispatch: .traitDispatch,
                provenance: .languageProof,
                completeness: .complete,
                evidence: [.nameOnly(nameID: traitNameID)]
            )
        }

        var results: [ImplementationResult] = []
        for (key, implFacetIndex) in implIndex.byTraitName[traitNameID] ?? [] {
            guard let index = contentIndexes[key],
                  index.symbols.indices.contains(Int(implFacetIndex)),
                  let relation = index.implRelations.first(where: {
                      $0.implFacetIndex == implFacetIndex
                  })
            else { continue }
            for file in occurrences(of: key) {
                results.append(ImplementationResult(
                    implementation: SymbolOccurrenceID(
                        snapshotID: snapshotID,
                        pathID: file.pathID,
                        localKind: .declarationFacet,
                        localIndex: implFacetIndex
                    ),
                    typeName: names.resolve(relation.typeNameID),
                    certainty: certainty,
                    traitDefinitions: definitionCandidates
                ))
            }
        }
        return results.sorted {
            let lhs = paths.resolve($0.implementation.pathID)
            let rhs = paths.resolve($1.implementation.pathID)
            if lhs != rhs { return lhs < rhs }
            return $0.implementation.localIndex < $1.implementation.localIndex
        }
    }

    public func overrides(
        ofTraitMethod method: SymbolOccurrenceID,
        context: QueryContext
    ) throws -> [ResolutionCandidate] {
        try validate(context)
        guard method.snapshotID == snapshotID,
              method.localKind == .declarationFacet,
              let (_, traitIndex) = content(at: method.pathID),
              traitIndex.symbols.indices.contains(Int(method.localIndex))
        else { return [] }
        let traitMethod = traitIndex.symbols[Int(method.localIndex)]
        guard traitMethod.kind == .rustMethod,
              let traitFacetIndex = traitMethod.parentFacetIndex,
              traitIndex.symbols.indices.contains(Int(traitFacetIndex)),
              traitIndex.symbols[Int(traitFacetIndex)].kind == .rustTrait
        else { return [] }

        let traitNameID = traitIndex.symbols[Int(traitFacetIndex)].nameID
        let definitionCount = definitionOccurrences(named: traitNameID).filter {
            $0.1.kind == .rustTrait
        }.count
        let certainty: Certainty = definitionCount == 1 ? .strong : .possible
        var seen: Set<SymbolOccurrenceID> = []
        var results: [ResolutionCandidate] = []
        for (key, implFacetIndex) in implIndex.byTraitName[traitNameID] ?? [] {
            guard let index = contentIndexes[key] else { continue }
            for (facetIndex, facet) in index.symbols.enumerated() where
                facet.kind == .rustMethod
                    && facet.parentFacetIndex == implFacetIndex
                    && facet.nameID == traitMethod.nameID
            {
                guard let facetIndex = UInt32(exactly: facetIndex) else { continue }
                for file in occurrences(of: key) {
                    let target = SymbolOccurrenceID(
                        snapshotID: snapshotID,
                        pathID: file.pathID,
                        localKind: .declarationFacet,
                        localIndex: facetIndex
                    )
                    guard seen.insert(target).inserted else { continue }
                    results.append(ResolutionCandidate(
                        target: target,
                        certainty: certainty,
                        dispatch: .traitDispatch,
                        provenance: .languageProof,
                        completeness: .complete,
                        evidence: [.methodNameOnly(nameID: traitMethod.nameID)]
                    ))
                }
            }
        }
        return results.sorted {
            let lhs = paths.resolve($0.target.pathID)
            let rhs = paths.resolve($1.target.pathID)
            if lhs != rhs { return lhs < rhs }
            return $0.target.localIndex < $1.target.localIndex
        }
    }

    public func searchSymbols(
        query: String,
        limit: Int,
        boost: SearchBoost,
        context: QueryContext
    ) throws -> [SymbolSearchHit] {
        try validate(context)
        guard limit > 0 else { return [] }
        let index = symbolSearchCache.get {
            SymbolSearchIndex(
                nameIDs: searchableDefinitionNameIDs,
                names: names
            )
        }

        let recentWeights = Dictionary(
            boost.recentFiles.prefix(20).enumerated().reversed().map {
                ($0.element, Double(20 - $0.offset))
            },
            uniquingKeysWith: max
        )
        let currentDirectory = boost.currentFile.map(directory)
        var hits: [SymbolSearchHit] = []
        for candidate in index.candidates(for: query) {
            for (occurrence, facet, pathID) in definitionOccurrences(named: candidate.nameID) {
                guard let (_, contentIndex) = content(at: pathID),
                      let coordinate = contentIndex.lineTable.lineColumn(
                        at: facet.nameRange.lowerBound
                      )
                else { continue }
                var score = candidate.score + kindWeight(facet.kind)
                if pathID == boost.currentFile {
                    score += 32
                } else if let currentDirectory,
                          directory(of: pathID) == currentDirectory
                {
                    score += 12
                }
                score += recentWeights[pathID] ?? 0
                hits.append(SymbolSearchHit(
                    nameID: candidate.nameID,
                    facet: facet,
                    occurrence: occurrence,
                    path: paths.resolve(pathID),
                    line: coordinate.line,
                    column: coordinate.column,
                    score: score,
                    matchRanges: candidate.matchRanges
                ))
            }
        }
        return hits.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.occurrence.localIndex < $1.occurrence.localIndex
        }.prefix(limit).map { $0 }
    }

    public func resolve(
        file: PathID,
        offset: UInt32,
        context: QueryContext
    ) throws -> [ResolutionCandidate] {
        try validate(context)
        return Resolver(session: self).resolve(
            file: file,
            offset: offset,
            context: context
        )
    }

    /// The second hop of the lens type follow (P1): for a value binding or a
    /// field under `offset`, resolve the head type its `typeRef` spells.
    /// `.none` leaves the door open for the Exact layer (P2).
    public func typeHop(
        file: PathID,
        offset: UInt32,
        context: QueryContext
    ) throws -> TypeHopResult {
        try validate(context)
        guard let candidates = try? resolve(
            file: file, offset: offset, context: context
        ) else { return .none }

        // Only value bindings and rust fields carry a spelled type today.
        guard let firstHop = try firstTypeHopCandidate(
            file: file, candidates: candidates
        ) else { return .none }

        // The typeRef's byte ranges belong to the file that holds the
        // record: the source file for a lexical binding, the declaring file
        // for a field or class attribute (which may differ from the file
        // being read).
        let typeRef: TypeRef?
        let typeFile: PathID
        if let hit = firstHopBinding(firstHop, queried: file) {
            typeRef = hit.binding.typeRef
            typeFile = hit.file
        } else if firstHop.target.localKind == .declarationFacet,
                  let index = content(at: firstHop.target.pathID)?.1,
                  index.symbols.indices.contains(Int(firstHop.target.localIndex))
        {
            typeRef = index.symbols[Int(firstHop.target.localIndex)].typeRef
            typeFile = firstHop.target.pathID
        } else {
            typeRef = nil
            typeFile = file
        }
        guard let typeRef else { return .none }

        let sourceName: (ByteRange) -> String = { [weak self] range in
            guard let self, let bytes = self.sourceBytes(at: typeFile) else { return "" }
            return Self.spelledRange(range, bytes: bytes)
        }

        switch typeRef {
        case let .primitive(range):
            return .primitive(name: sourceName(range))
        case let .genericUnbounded(parameter):
            return .genericUnbounded(name: sourceName(parameter))
        case let .named(range), let .selfType(range):
            return try hopToType(
                spelling: range,
                file: typeFile,
                firstHop: firstHop,
                context: context,
                capAtProbable: false
            )
        case let .constructed(range):
            return try hopToType(
                spelling: range,
                file: typeFile,
                firstHop: firstHop,
                context: context,
                capAtProbable: true
            )
        case let .genericBound(_, bound):
            return try hopToType(
                spelling: bound,
                file: typeFile,
                firstHop: firstHop,
                context: context,
                capAtProbable: false
            )
        }
    }

    /// The binding a first hop names and the file holding it: a lexical
    /// binding lives in the queried file, a class attribute (member
    /// binding) in the target's file.
    private func firstHopBinding(
        _ firstHop: ResolutionCandidate,
        queried file: PathID
    ) -> (binding: BindingRecord, file: PathID, isMember: Bool)? {
        for evidence in firstHop.evidence {
            switch evidence {
            case let .lexicalBinding(bindingIndex):
                guard let key = contentKeysByPath[file],
                      let index = contentIndexes[key],
                      index.bindings.indices.contains(Int(bindingIndex))
                else { return nil }
                return (index.bindings[Int(bindingIndex)], file, false)
            case let .memberBinding(bindingIndex):
                guard let index = content(at: firstHop.target.pathID)?.1,
                      index.bindings.indices.contains(Int(bindingIndex))
                else { return nil }
                return (index.bindings[Int(bindingIndex)], firstHop.target.pathID, true)
            default:
                continue
            }
        }
        return nil
    }

    /// The first-hop candidate for a type hop: a lexical binding, a class
    /// attribute, or a rust field (P1.3).
    private func firstTypeHopCandidate(
        file: PathID,
        candidates: [ResolutionCandidate]
    ) throws -> ResolutionCandidate? {
        candidates.first { candidate in
            candidate.evidence.contains {
                switch $0 {
                case .lexicalBinding, .memberBinding: true
                default: false
                }
            }
        } ?? candidates.first { candidate in
            guard candidate.target.localKind == .declarationFacet,
                  let index = content(at: candidate.target.pathID)?.1,
                  index.symbols.indices.contains(Int(candidate.target.localIndex))
            else { return false }
            return index.symbols[Int(candidate.target.localIndex)].kind == .rustField
        }
    }

    /// R7.1: the spelled source text of the binding or field under the first
    /// hop — `ps: &S`, `&self`, `made`, `inner: Inner` — plus its kind.
    public func bindingSpelling(
        file: PathID,
        offset: UInt32,
        context: QueryContext
    ) throws -> (text: String, kind: TypeHopViaKind, boundNote: String?)? {
        try validate(context)
        guard let candidates = try? resolve(
            file: file, offset: offset, context: context
        ) else { return nil }
        guard let firstHop = try firstTypeHopCandidate(
            file: file, candidates: candidates
        ) else { return nil }

        if let hit = firstHopBinding(firstHop, queried: file) {
            let binding = hit.binding
            guard let bytes = sourceBytes(at: hit.file) else { return nil }
            let text = Self.bindingSpellingText(
                bytes: bytes, nameRange: binding.declarationRange
            )
            let kind: TypeHopViaKind
            if hit.isMember {
                kind = .field
            } else if binding.kind == .param,
               text == "self" || text.hasSuffix("self") && text.contains("&")
            {
                kind = .receiver
            } else if binding.kind == .param {
                kind = .parameter
            } else {
                kind = .letBinding
            }
            let boundNote: String?
            if case let .genericBound(parameter, bound) = binding.typeRef {
                boundNote = Self.spelledRange(
                    parameter, bytes: bytes
                ) + ":" + Self.spelledRange(bound, bytes: bytes)
            } else {
                boundNote = nil
            }
            return (text, kind, boundNote)
        }

        guard firstHop.target.localKind == .declarationFacet,
              let index = content(at: firstHop.target.pathID)?.1,
              index.symbols.indices.contains(Int(firstHop.target.localIndex)),
              index.symbols[Int(firstHop.target.localIndex)].kind == .rustField,
              let bytes = sourceBytes(at: firstHop.target.pathID)
        else { return nil }
        let facet = index.symbols[Int(firstHop.target.localIndex)]
        return (
            Self.bindingSpellingText(bytes: bytes, nameRange: facet.nameRange),
            .field,
            nil
        )
    }

    private static func spelledRange(
        _ range: ByteRange, bytes: [UInt8]
    ) -> String {
        guard Int(range.lowerBound) < bytes.count else { return "" }
        let upper = min(Int(range.upperBound), bytes.count)
        return String(
            decoding: bytes[Int(range.lowerBound)..<upper], as: UTF8.self
        )
    }

    /// Expands a declaration name range to the full binding spelling: a
    /// leading `&`/`mut` for receivers and, when a `: type` annotation
    /// follows, the type up to the first top-level separator.
    private static func bindingSpellingText(
        bytes: [UInt8], nameRange: ByteRange
    ) -> String {
        var start = Int(nameRange.lowerBound)
        while true {
            var probe = start
            while probe > 0,
                  bytes[probe - 1] == UInt8(ascii: " ")
                  || bytes[probe - 1] == UInt8(ascii: "\t")
            { probe -= 1 }
            if probe > 0, bytes[probe - 1] == UInt8(ascii: "&") {
                start = probe - 1
                continue
            }
            if probe >= 3,
               bytes[probe - 1] == UInt8(ascii: "t"),
               bytes[probe - 2] == UInt8(ascii: "u"),
               bytes[probe - 3] == UInt8(ascii: "m")
            {
                start = probe - 3
                continue
            }
            break
        }
        var end = Int(nameRange.upperBound)
        var index = end
        while index < bytes.count,
              bytes[index] == UInt8(ascii: " ")
              || bytes[index] == UInt8(ascii: "\t")
        { index += 1 }
        if index + 1 < bytes.count,
           bytes[index] == UInt8(ascii: ":"),
           bytes[index + 1] != UInt8(ascii: ":")
        {
            var depth = 0
            var scan = index
            var stop: Int? = nil
            while scan < bytes.count, stop == nil {
                let byte = bytes[scan]
                if byte == UInt8(ascii: "<") || byte == UInt8(ascii: "(") {
                    depth += 1
                } else if byte == UInt8(ascii: ">") || byte == UInt8(ascii: ")") {
                    if depth == 0 {
                        stop = scan
                        break
                    }
                    depth -= 1
                } else if depth == 0,
                          byte == UInt8(ascii: ",")
                          || byte == UInt8(ascii: "=")
                          || byte == UInt8(ascii: ";")
                          || byte == UInt8(ascii: "{")
                          || byte == UInt8(ascii: "}")
                {
                    stop = scan
                    break
                }
                scan += 1
            }
            end = stop ?? bytes.count
        }
        let slice = bytes[start..<end]
        return String(decoding: slice, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Resolves the type spelled at `spelling` and keeps type-kind facets.
    /// The result certainty is the weaker of the two hops; constructed heads
    /// (inferred from `S::new()` / `S { .. }`) cap at `.probable` (R1.2).
    private func hopToType(
        spelling: ByteRange,
        file: PathID,
        firstHop: ResolutionCandidate,
        context: QueryContext,
        capAtProbable: Bool
    ) throws -> TypeHopResult {
        var secondHop = try resolve(
            file: file, offset: spelling.lowerBound, context: context
        ).filter { candidate in
            guard candidate.target.localKind == .declarationFacet,
                  let index = content(at: candidate.target.pathID)?.1,
                  index.symbols.indices.contains(Int(candidate.target.localIndex))
            else { return false }
            return Self.typeKinds.contains(
                index.symbols[Int(candidate.target.localIndex)].kind
            )
        }
        var nameOnlyFallback = false
        if secondHop.isEmpty, let bytes = sourceBytes(at: file) {
            // Some grammars do not index annotation positions (TS type
            // annotations, quoted Python annotations), so `resolve` answers
            // nothing there. Fall back to the head name's definition
            // occurrences at name-only certainty.
            let upper = min(Int(spelling.upperBound), bytes.count)
            guard Int(spelling.lowerBound) < upper else { return .none }
            let name = String(
                decoding: bytes[Int(spelling.lowerBound)..<upper], as: UTF8.self
            )
            let nameID = names.intern(name)
            secondHop = definitionOccurrences(named: nameID)
                .filter { _, facet, _ in Self.typeKinds.contains(facet.kind) }
                .map { occurrence, _, _ in
                    ResolutionCandidate(
                        target: occurrence,
                        certainty: .possible,
                        dispatch: .direct,
                        provenance: .fuzzyResolver,
                        completeness: .complete,
                        evidence: [.nameOnly(nameID: nameID)]
                    )
                }
            nameOnlyFallback = !secondHop.isEmpty
        }
        guard !secondHop.isEmpty else { return .none }
        var certainty = nameOnlyFallback
            ? min(firstHop.certainty, .possible)
            : min(firstHop.certainty, secondHop[0].certainty)
        if capAtProbable { certainty = min(certainty, .probable) }
        return .targets(secondHop, certainty: certainty)
    }

    static let typeKinds: Set<DeclarationKind> = [
        .rustStruct, .rustEnum, .rustTrait, .rustTypeAlias,
        .pythonClass, .typescriptClass,
    ]

    public func tokenRange(
        file: PathID,
        offset: UInt32,
        context: QueryContext
    ) throws -> ByteRange? {
        try validate(context)
        return Resolver(session: self).tokenRange(file: file, offset: offset)
    }

    package func content(at pathID: PathID) -> (ContentIndexKey, ContentIndex)? {
        guard let key = contentKeysByPath[pathID],
              let index = contentIndexes[key]
        else { return nil }
        return (key, index)
    }

    /// CLI read access to a file's content index (type hop output, R8.1).
    public func contentForCLI(at pathID: PathID) -> ContentIndex? {
        content(at: pathID)?.1
    }

    func definitionOccurrences(
        named nameID: NameID
    ) -> [(SymbolOccurrenceID, DeclarationFacet, PathID)] {
        var result: [(SymbolOccurrenceID, DeclarationFacet, PathID)] = []
        for posting in namePosting.definitions[nameID] ?? [] {
            guard let index = contentIndexes[posting.key],
                  index.symbols.indices.contains(Int(posting.facetIndex))
            else { continue }
            let facet = index.symbols[Int(posting.facetIndex)]
            for file in occurrences(of: posting.key) {
                let occurrence = SymbolOccurrenceID(
                    snapshotID: snapshotID,
                    pathID: file.pathID,
                    localKind: .declarationFacet,
                    localIndex: posting.facetIndex
                )
                result.append((occurrence, facet, file.pathID))
            }
        }
        return result.sorted {
            let lhs = paths.resolve($0.2)
            let rhs = paths.resolve($1.2)
            if lhs != rhs { return lhs < rhs }
            return $0.0.localIndex < $1.0.localIndex
        }
    }

    func directory(of pathID: PathID) -> String {
        paths.resolve(pathID).split(separator: "/").dropLast()
            .joined(separator: "/")
    }

    package func sourceBytes(at pathID: PathID) -> [UInt8]? {
        filesByPath[pathID]
            .flatMap { sourceBytesByContent[$0.contentID] }
    }

    package func capturedSource(
        atManifestPath path: String
    ) -> (contentID: ContentID, bytes: [UInt8])? {
        guard let file = manifest.files.first(where: {
            paths.resolve($0.pathID) == path
        }), let bytes = sourceBytesByContent[file.contentID]
        else { return nil }
        return (file.contentID, bytes)
    }

    func occurrences(of key: ContentIndexKey) -> [FileOccurrence] {
        occurrencesByContentKey[key] ?? []
    }

    private func facet(for occurrence: SymbolOccurrenceID) -> DeclarationFacet? {
        guard let (_, index) = content(at: occurrence.pathID),
              occurrence.localKind == .declarationFacet,
              index.symbols.indices.contains(Int(occurrence.localIndex))
        else { return nil }
        return index.symbols[Int(occurrence.localIndex)]
    }

    func validate(_ context: QueryContext) throws {
        guard context.snapshotID == snapshotID else {
            throw EngineError.snapshotMismatch(
                expected: snapshotID,
                actual: context.snapshotID
            )
        }
        guard context.analysisProfileID == analysisProfile.id else {
            throw EngineError.profileMismatch(
                expected: analysisProfile.id,
                actual: context.analysisProfileID
            )
        }
        // M0 不校验 generation。
    }

    private func dispatch(for kind: CallKind) -> DispatchKind {
        switch kind {
        case .methodCall: .dynamicDispatch
        case .macroInvocation: .macroGenerated
        default: .direct
        }
    }

    private func fallbackEvidence(
        for kind: CallKind,
        nameID: NameID
    ) -> [ResolutionEvidence] {
        switch kind {
        case .methodCall: [.methodNameOnly(nameID: nameID)]
        default: [.nameOnly(nameID: nameID)]
        }
    }

    private func isDefinitionEvidence(_ evidence: [ResolutionEvidence]) -> Bool {
        evidence.contains {
            switch $0 {
            case .sameFile, .uniqueImport, .nameOnly, .methodNameOnly,
                 .receiverType:
                true
            case .lexicalBinding, .memberBinding:
                false
            }
        }
    }

    private func callerCertainty(
        from candidate: ResolutionCandidate?,
        definitionNameID: NameID
    ) -> Certainty {
        guard let candidate, candidate.certainty >= .probable else {
            return .possible
        }
        if candidate.evidence.contains(where: {
            if case .receiverType = $0 { return true }
            return false
        }) {
            return min(candidate.certainty, .strong)
        }
        guard candidate.certainty == .strong else { return .possible }
        for evidence in candidate.evidence {
            switch evidence {
            case .uniqueImport:
                return .strong
            case let .sameFile(pathID):
                guard let (_, index) = content(at: pathID) else { continue }
                let matches = index.symbols.filter {
                    $0.parentFacetIndex == nil && $0.nameID == definitionNameID
                }
                if matches.count == 1 { return .strong }
            case .lexicalBinding, .memberBinding, .nameOnly, .methodNameOnly, .receiverType:
                continue
            }
        }
        return .possible
    }

    private func kindWeight(_ kind: DeclarationKind) -> Double {
        switch kind {
        case .rustFn: 24
        case .rustStruct: 22
        case .rustMethod: 20
        case .rustEnum, .rustTrait: 18
        case .rustTypeAlias, .rustMod: 14
        case .rustConst, .rustStatic: 10
        case .rustImpl: 8
        case .rustField: 0
        case .pythonFunction: 24
        case .pythonClass: 22
        case .typescriptFunction: 24
        case .typescriptClass: 22
        }
    }
}

/// Result of the syntactic type hop (P1.3).
public enum TypeHopResult: Sendable {
    case targets([ResolutionCandidate], certainty: Certainty)
    case primitive(name: String)
    case genericUnbounded(name: String)
    /// Nothing spelled at the syntax level; the Exact layer may still answer.
    case none
}

/// What the first hop of a type hop points at (R7.1).
public enum TypeHopViaKind: Sendable {
    case parameter
    case letBinding
    case receiver
    case field
}
