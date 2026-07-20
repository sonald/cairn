import CodeInsightCore

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

public final class EngineSession: Sendable {
    public let manifest: SnapshotManifest
    public let contentIndexes: [ContentIndexKey: ContentIndex]
    public let stats: IndexStats
    public let names: Interner<NameID>
    public let paths: Interner<PathID>
    public let strings: Interner<StringID>
    public let analysisProfile: AnalysisProfile

    public var snapshotID: SnapshotID { manifest.snapshotID }
    public var moduleChildren: [PathID: [NameID: PathID]] {
        moduleMap.moduleChildren
    }

    let namePosting: NamePosting
    let moduleMap: ModuleMap
    private let sourceBytesByContent: [ContentID: [UInt8]]

    init(
        manifest: SnapshotManifest,
        contentIndexes: [ContentIndexKey: ContentIndex],
        stats: IndexStats,
        names: Interner<NameID>,
        paths: Interner<PathID>,
        strings: Interner<StringID>,
        analysisProfile: AnalysisProfile,
        moduleMap: ModuleMap,
        sourceBytesByContent: [ContentID: [UInt8]]
    ) {
        self.manifest = manifest
        self.contentIndexes = contentIndexes
        self.stats = stats
        self.names = names
        self.paths = paths
        self.strings = strings
        self.analysisProfile = analysisProfile
        self.moduleMap = moduleMap
        self.sourceBytesByContent = sourceBytesByContent
        namePosting = NamePosting(indexes: contentIndexes)
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
        for index in contentIndexes.values {
            for binding in index.imports where binding.importedName == nameID {
                if let localName = binding.localName { callNameIDs.insert(localName) }
            }
        }

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
                        localSymbolIndex: posting.callIndex
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
            return $0.callSite.localSymbolIndex < $1.callSite.localSymbolIndex
        }
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

    func content(at pathID: PathID) -> (ContentIndexKey, ContentIndex)? {
        guard let file = manifest.files.first(where: { $0.pathID == pathID }) else {
            return nil
        }
        return contentIndexes.first { $0.key.contentID == file.contentID }
            .map { ($0.key, $0.value) }
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
                    localSymbolIndex: posting.facetIndex
                )
                result.append((occurrence, facet, file.pathID))
            }
        }
        return result.sorted {
            let lhs = paths.resolve($0.2)
            let rhs = paths.resolve($1.2)
            if lhs != rhs { return lhs < rhs }
            return $0.0.localSymbolIndex < $1.0.localSymbolIndex
        }
    }

    func directory(of pathID: PathID) -> String {
        paths.resolve(pathID).split(separator: "/").dropLast()
            .joined(separator: "/")
    }

    func sourceBytes(at pathID: PathID) -> [UInt8]? {
        manifest.files.first(where: { $0.pathID == pathID })
            .flatMap { sourceBytesByContent[$0.contentID] }
    }

    private func occurrences(of key: ContentIndexKey) -> [FileOccurrence] {
        manifest.files.filter {
            $0.contentID == key.contentID
                && $0.detectedLanguage == key.languageMode.language
        }
    }

    private func facet(for occurrence: SymbolOccurrenceID) -> DeclarationFacet? {
        guard let (_, index) = content(at: occurrence.pathID),
              index.symbols.indices.contains(Int(occurrence.localSymbolIndex))
        else { return nil }
        return index.symbols[Int(occurrence.localSymbolIndex)]
    }

    private func validate(_ context: QueryContext) throws {
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
}
