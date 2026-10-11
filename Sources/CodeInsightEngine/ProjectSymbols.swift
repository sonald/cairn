import CodeInsightCore

/// One analysis unit's declarations, one row per facet per file: two files
/// with identical bytes share a content index but each lists its own rows.
public struct ProjectSymbolListing: Sendable {
    public struct File: Sendable {
        /// Manifest path (relative to the project root).
        public let path: String
        public let contentID: ContentID
        /// Module components below the crate or unit root; `nil` when no
        /// Rust crate root reaches the file (see `ModuleMap.modulePath`).
        public let modulePath: [String]?
        /// The file roots a Rust crate (`main.rs`, `lib.rs`, `src/bin/*.rs`).
        public let isCrateRoot: Bool
    }

    public let language: LanguageID
    /// `.` or the unit root relative to the project root.
    public let unitRoot: String
    public let files: [File]
    public let symbols: [ProjectSymbol]
}

public struct ProjectSymbol: Sendable {
    public let occurrence: SymbolOccurrenceID
    /// Index into `ProjectSymbolListing.files`.
    public let fileIndex: Int
    public let name: String
    public let kind: DeclarationKind
    public let visibility: DeclarationVisibility?
    public let nameRange: ByteRange
    /// 1-based line of the name.
    public let line: UInt32
    public var facetIndex: UInt32 { occurrence.localIndex }
    /// The enclosing facet in the same file (impl, trait, class, module).
    public let parentFacetIndex: UInt32?
    /// For an impl row, the implemented trait (`impl Engine for BitCask`).
    public let implTraitName: String?
}

extension EngineSession {
    /// Every declaration facet of the unit's indexed files, unscored and
    /// uncapped, ordered by path and then position.
    public func projectSymbols(context: QueryContext) throws -> ProjectSymbolListing {
        try validate(context)
        var files: [ProjectSymbolListing.File] = []
        var symbols: [ProjectSymbol] = []
        let ordered = contentIndexes.keys.flatMap { key in
            occurrences(of: key).map { (key, $0) }
        }.map { (key: $0.0, file: $0.1, path: paths.resolve($0.1.pathID)) }
            .sorted { $0.path < $1.path }
        for (key, file, path) in ordered {
            guard let index = contentIndexes[key] else { continue }
            let fileIndex = files.count
            files.append(.init(
                path: path,
                contentID: file.contentID,
                modulePath: moduleMap.modulePath(of: file.pathID, names: names),
                isCrateRoot: moduleMap.crateRootFiles.contains(file.pathID)
            ))
            let traits = Dictionary(
                index.implRelations.compactMap { relation in
                    relation.traitNameID.map { (relation.implFacetIndex, names.resolve($0)) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            for (offset, facet) in index.symbols.enumerated()
                .sorted(by: { $0.element.range.lowerBound < $1.element.range.lowerBound })
            {
                let facetIndex = UInt32(offset)
                symbols.append(ProjectSymbol(
                    occurrence: SymbolOccurrenceID(
                        snapshotID: snapshotID,
                        pathID: file.pathID,
                        localKind: .declarationFacet,
                        localIndex: facetIndex
                    ),
                    fileIndex: fileIndex,
                    name: names.resolve(facet.nameID),
                    kind: facet.kind,
                    visibility: facet.visibility,
                    nameRange: facet.nameRange,
                    line: index.lineTable.lineColumn(at: facet.nameRange.lowerBound)?.line ?? 1,
                    parentFacetIndex: facet.parentFacetIndex,
                    implTraitName: traits[facetIndex]
                ))
            }
        }
        return ProjectSymbolListing(
            language: analysisProfile.language,
            unitRoot: paths.resolve(analysisProfile.projectRoot),
            files: files,
            symbols: symbols
        )
    }
}

/// The `⌘P #` name matching (prefix, acronym, subsequence) over an arbitrary
/// set of names, without the 2,000-name recall cap.
public struct SymbolNameMatcher: Sendable {
    public struct Match: Sendable {
        public let score: Double
        /// UTF-16 ranges in the name.
        public let ranges: [Range<Int>]
    }

    private let index: SymbolSearchIndex
    private let names: Interner<NameID>

    public init(names: some Sequence<String>) {
        let interner = Interner<NameID>()
        let ids = Set(names.map(interner.intern))
        self.names = interner
        index = SymbolSearchIndex(nameIDs: Array(ids), names: interner)
    }

    public func matches(_ query: String) -> [String: Match] {
        var result: [String: Match] = [:]
        for candidate in index.candidates(for: query, cap: .max) {
            result[names.resolve(candidate.nameID)] = Match(
                score: candidate.score,
                ranges: candidate.matchRanges
            )
        }
        return result
    }
}
