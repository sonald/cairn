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
        storeState.contentIndexes
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

    let namePosting: NamePosting
    var moduleMap: ModuleMap { snapshotView.moduleMap }
    let store: ProjectIndexStore
    let snapshotView: SnapshotView
    private let storeState: ProjectIndexStore.State
    private let filesByPath: [PathID: FileOccurrence]
    private let contentKeysByPath: [PathID: ContentIndexKey]
    private let occurrencesByContentKey: [ContentIndexKey: [FileOccurrence]]
    private let aliasIndex: [NameID: Set<NameID>]
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
        storeState = snapshotView.storeState
        let manifest = snapshotView.manifest
        let contentIndexes = storeState.contentIndexes
        filesByPath = Dictionary(uniqueKeysWithValues: manifest.files.map {
            ($0.pathID, $0)
        })

        let keysByContent = Dictionary(grouping: contentIndexes.keys) {
            $0.contentID
        }
        var contentKeysByPath: [PathID: ContentIndexKey] = [:]
        var occurrencesByContentKey: [ContentIndexKey: [FileOccurrence]] = [:]
        for file in manifest.files {
            guard let keys = keysByContent[file.contentID] else { continue }
            for key in keys where key.languageMode.language == file.detectedLanguage {
                if contentKeysByPath[file.pathID] == nil {
                    contentKeysByPath[file.pathID] = key
                }
                occurrencesByContentKey[key, default: []].append(file)
            }
        }
        self.contentKeysByPath = contentKeysByPath
        self.occurrencesByContentKey = occurrencesByContentKey

        var aliasIndex: [NameID: Set<NameID>] = [:]
        let viewIndexes = Dictionary(uniqueKeysWithValues: occurrencesByContentKey.keys
            .compactMap { key in contentIndexes[key].map { (key, $0) } })
        for index in viewIndexes.values {
            for binding in index.imports {
                guard let importedName = binding.importedName,
                      let localName = binding.localName
                else { continue }
                aliasIndex[importedName, default: []].insert(localName)
            }
        }
        self.aliasIndex = aliasIndex
        implIndex = ImplIndex(indexes: viewIndexes)
        namePosting = storeState.namePosting
        let viewKeys = Set(viewIndexes.keys)
        searchableDefinitionNameIDs = namePosting.definitions.compactMap {
            nameID, postings in
            postings.contains { viewKeys.contains($0.key) } ? nameID : nil
        }
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
                          let region = index.executableRegions.first(where: {
                              $0.id == call.regionID
                          })
                    else { continue }

                    let candidates = resolver.resolve(
                        file: file.pathID,
                        offset: call.range.lowerBound,
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
                        certainty: call.syntacticKind == .methodCall
                            ? .possible : certainty,
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
              let (_, index) = content(at: definition.pathID),
              index.symbols.indices.contains(Int(definition.localIndex))
        else {
            return OutgoingCallsResult(calls: [], completeness: .complete)
        }

        let facet = index.symbols[Int(definition.localIndex)]
        let matching = index.calls.enumerated().filter { _, call in
            guard facet.range.lowerBound <= call.range.lowerBound,
                  call.range.upperBound <= facet.range.upperBound
            else { return false }
            // ponytail: file-local calls × regions scan; add region parents if it gets hot.
            let owner = index.executableRegions.filter {
                $0.associatedFacetIndex != nil
                    && $0.range.contains(call.range.lowerBound)
            }.min {
                if $0.range.length != $1.range.length {
                    return $0.range.length < $1.range.length
                }
                return $0.id.rawValue > $1.id.rawValue
            }?.associatedFacetIndex
            return owner == definition.localIndex
        }.sorted {
            if $0.element.range.lowerBound != $1.element.range.lowerBound {
                return $0.element.range.lowerBound < $1.element.range.lowerBound
            }
            return $0.offset < $1.offset
        }
        let completeness: Completeness = matching.count > 512
            ? .truncated : .complete
        let resolver = Resolver(session: self)
        let calls = matching.prefix(512).compactMap {
            callIndex, call -> OutgoingCall? in
            guard let callIndex = UInt32(exactly: callIndex) else { return nil }
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
                    offset: call.range.lowerBound,
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

    public func tokenRange(
        file: PathID,
        offset: UInt32,
        context: QueryContext
    ) throws -> ByteRange? {
        try validate(context)
        return Resolver(session: self).tokenRange(file: file, offset: offset)
    }

    func content(at pathID: PathID) -> (ContentIndexKey, ContentIndex)? {
        guard let key = contentKeysByPath[pathID],
              let index = contentIndexes[key]
        else { return nil }
        return (key, index)
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

    func sourceBytes(at pathID: PathID) -> [UInt8]? {
        filesByPath[pathID].flatMap { sourceBytesByContent[$0.contentID] }
    }

    private func occurrences(of key: ContentIndexKey) -> [FileOccurrence] {
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
            case .sameFile, .uniqueImport, .nameOnly, .methodNameOnly:
                true
            case .lexicalBinding:
                false
            }
        }
    }

    private func callerCertainty(
        from candidate: ResolutionCandidate?,
        definitionNameID: NameID
    ) -> Certainty {
        guard let candidate, candidate.certainty == .strong else {
            return .possible
        }
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
            case .lexicalBinding, .nameOnly, .methodNameOnly:
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
        }
    }
}
