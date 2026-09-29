import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightReaderCore
import Foundation
import Observation

@MainActor
@Observable
public final class ContextWindowModel {
    public enum Mode: Sendable {
        case follow
        case pinned
    }

    public struct Candidate: Sendable {
        /// The structured facts a candidate stands on. Every label and badge
        /// is derived from them; nothing reads a presented string back.
        public enum Basis: Sendable {
            case resolved(
                certainty: Certainty,
                dispatch: DispatchKind,
                provenance: ResolutionProvenance
            )
            case exact(ExactAttribution, origin: ExactOrigin, language: LanguageID)
            case dependencyExact(
                crate: String,
                ExactAttribution,
                origin: ExactOrigin,
                language: LanguageID
            )
        }

        public let symbol: SymbolOccurrenceID?
        public let path: String
        public let line: UInt32
        public let column: UInt32
        public let excerpt: String
        public let bindingKind: String?
        public let targetByteOffset: UInt32
        public let basis: Basis

        public var certainty: Certainty {
            if case let .resolved(certainty, _, _) = basis { return certainty }
            return .exact
        }

        public var provenance: ResolutionProvenance {
            if case let .resolved(_, _, provenance) = basis { return provenance }
            return .lsp
        }

        public var exactAttribution: ExactAttribution? {
            switch basis {
            case .resolved: nil
            case let .exact(attribution, _, _), let .dependencyExact(_, attribution, _, _): attribution
            }
        }

        public var exactOrigin: ExactOrigin? {
            switch basis {
            case .resolved: nil
            case let .exact(_, origin, _), let .dependencyExact(_, _, origin, _): origin
            }
        }

        public var label: String {
            switch basis {
            case let .resolved(certainty, dispatch, _):
                "\(resolutionCertaintyLabel(certainty))·\(resolutionDispatchLabel(dispatch))"
            case .exact:
                localized("model.context.exactDirect")
            case .dependencyExact:
                localized("model.context.external")
            }
        }

        public var provenanceBadge: String {
            switch basis {
            case .resolved:
                label
            case let .exact(attribution, origin, language):
                exactProvenanceBadge(label, attribution: attribution, origin: origin, language: language)
            case let .dependencyExact(crate, attribution, origin, language):
                "\(label) · \(crate) · " + exactProvenanceBadge(
                    localized("model.context.exactDirect"),
                    attribution: attribution,
                    origin: origin,
                    language: language
                )
            }
        }
    }

    public enum Stage: Sendable {
        case idle
        case indexBuilding
        case candidates([Candidate], selected: Int)
    }

    private struct Token: Sendable {
        let file: String
        let offset: UInt32
    }

    private struct LocatedToken: Sendable {
        let file: String
        let range: ByteRange
    }

    private struct DocumentKey: Hashable {
        let path: String
        let contentID: ContentID
        let languageMode: LanguageMode
    }

    typealias Resolver = @MainActor (
        EngineSession,
        PathID,
        UInt32,
        QueryContext
    ) async throws -> [ResolutionCandidate]
    typealias Loader = @Sendable (URL, LanguageMode) async -> ReaderDocument?
    typealias ExactResolver = @MainActor (
        String,
        UInt32,
        UInt64,
        ExactRequestBatch
    ) async -> ExactCoordinator.DefinitionResult?
    /// Reads the current content identity of a project file for Exact
    /// verification; nil when the file cannot be read.
    typealias ContentIdentityReader = @Sendable (URL) async -> ContentID?

    public private(set) var mode: Mode = .follow
    public private(set) var stage: Stage = .idle
    public private(set) var requestID: UInt64 = 0
    /// Reports a project path whose content no longer matches the indexed
    /// bytes an Exact reply was computed against, so the owner can surface a
    /// stale-index notice instead of silently mixing contents.
    package var onStaleIndexContent: (@MainActor (String) -> Void)?

    private let resolver: Resolver
    private let loader: Loader
    private var exactResolver: ExactResolver?
    private var hoverResolver: (@MainActor (
        String,
        UInt32,
        UInt64,
        ExactRequestBatch
    ) async -> ExactCoordinator.HoverResult?)?
    private var projectState: ProjectState = .empty
    private var root: URL?
    private var contentSource: DocumentLoader.ContentSource?
    private var pendingToken: Token?
    private var locatedToken: LocatedToken?
    private var displayedToken: Token?
    private var documents: [DocumentKey: ReaderDocument] = [:]
    private var exactBatch: ExactRequestBatch?
    private var cancelExactBatch: (@MainActor (ExactRequestBatch) -> Void)?
    private var documentRecency: [DocumentKey] = []
    private let contentIdentityOverride: ContentIdentityReader?
    /// Advances on every explicit user selection change. An Exact reply
    /// arriving after the user chose a candidate upgrades in place and never
    /// moves that choice.
    private var selectionEpoch: UInt64 = 0

    public init() {
        resolver = { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        }
        loader = loadReaderDocument
        exactResolver = nil
        contentIdentityOverride = nil
    }

    init(
        _ resolver: @escaping Resolver,
        loader: @escaping Loader = loadReaderDocument,
        exactResolver: ExactResolver? = nil,
        contentIdentity: ContentIdentityReader? = nil
    ) {
        self.resolver = resolver
        self.loader = loader
        self.exactResolver = exactResolver
        contentIdentityOverride = contentIdentity
    }

    func attachExactCoordinator(_ coordinator: ExactCoordinator) {
        exactResolver = { [weak coordinator] file, offset, generation, batch in
            await coordinator?.definition(
                file: file,
                byteOffset: offset,
                generation: generation,
                batch: batch
            )
        }
        cancelExactBatch = { [weak coordinator] batch in
            coordinator?.cancel(batch: batch)
        }
        hoverResolver = { [weak coordinator] file, offset, generation, batch in
            await coordinator?.hover(
                file: file,
                byteOffset: offset,
                generation: generation,
                batch: batch
            )
        }
    }

    /// Syntactic fallback for the hover card. A declaration name is read
    /// straight from the displayed document; any other identifier resolves
    /// like a click, without touching the panel's stage, and only when the
    /// displayed bytes are the indexed ones.
    package func hoverFallback(
        file: String,
        offset: UInt32,
        contentID: ContentID,
        document: ReaderDocument?
    ) async -> SymbolDoc? {
        // `impl Oid`'s name is a reference to `Oid`, not a declaration.
        if let document,
           let facet = document.outlineFacets.first(where: {
               $0.kind != .impl && $0.nameRange.contains(offset)
           })
        {
            let line = document.lineTable.lineColumn(at: facet.nameRange.lowerBound)?.line
            return syntacticSymbolDoc(
                forDeclarationAt: facet.range,
                in: document,
                location: line.map { "\(file):\($0)" } ?? file
            )
        }
        guard case let .ready(session, context) = projectState,
              let pathID = pathID(file, in: session),
              self.contentID(at: pathID, in: session) == contentID,
              let resolved = try? await resolver(session, pathID, offset, context),
              sessionIsCurrent(session, context)
        else { return nil }
        for resolution in resolved
            where resolution.target.localKind == .declarationFacet
                && resolution.certainty != .unresolved
        {
            guard let (key, index) = session.content(at: resolution.target.pathID),
                  index.symbols.indices.contains(Int(resolution.target.localIndex)),
                  let targetContentID = self.contentID(at: resolution.target.pathID, in: session)
            else { continue }
            let facet = index.symbols[Int(resolution.target.localIndex)]
            let path = session.paths.resolve(resolution.target.pathID)
            guard let targetDocument = await self.document(
                path: path,
                contentID: targetContentID,
                languageMode: key.languageMode
            ) else { continue }
            let location = index.lineTable.lineColumn(at: facet.nameRange.lowerBound)
                .map { "\(path):\($0.line)" } ?? path
            return syntacticSymbolDoc(
                forDeclarationAt: facet.range,
                in: targetDocument,
                location: location
            )
        }
        return nil
    }

    /// The project definition an intra-doc link names, preferring an exact
    /// name match; used by links in the hover card.
    package func definition(named name: String) -> (path: String, byteOffset: UInt32)? {
        guard case let .ready(session, context) = projectState,
              let hits = try? session.searchSymbols(
                  query: name,
                  limit: 50,
                  boost: SearchBoost(),
                  context: context
              ),
              let hit = hits.first(where: { session.names.resolve($0.nameID) == name })
        else { return nil }
        return (hit.path, hit.facet.nameRange.lowerBound)
    }

    /// Exact hover for the card, against the generation the panel queries.
    /// Content the index never saw (another revision) is refused.
    package func exactHover(
        file: String,
        offset: UInt32,
        contentID: ContentID,
        batch: ExactRequestBatch
    ) async -> ExactCoordinator.HoverResult? {
        guard let hoverResolver,
              case let .ready(session, context) = projectState
        else { return nil }
        if let pathID = pathID(file, in: session) {
            guard self.contentID(at: pathID, in: session) == contentID else {
                return .unavailable(localized("model.hover.revisionNotIndexed"))
            }
        } else if !exactLocationIsInDependency(file) {
            return .unavailable(localized("model.hover.revisionNotIndexed"))
        }
        return await hoverResolver(file, offset, context.generation, batch)
    }

    public var selectedCandidate: Candidate? {
        guard case let .candidates(candidates, selected) = stage,
              candidates.indices.contains(selected)
        else { return nil }
        return candidates[selected]
    }

    package var selectedLanguageMode: LanguageMode? {
        guard let candidate = selectedCandidate,
              case let .ready(session, _) = projectState
        else { return nil }
        if exactLocationIsInDependency(candidate.path) {
            return dependencyLanguageMode(path: candidate.path)
        }
        guard let pathID = pathID(candidate.path, in: session) else {
            return nil
        }
        return session.content(at: pathID)?.0.languageMode
    }

    public var candidateCount: Int {
        guard case let .candidates(candidates, _) = stage else { return 0 }
        return candidates.count
    }

    public var selectedIndex: Int? {
        guard case let .candidates(candidates, selected) = stage,
              candidates.indices.contains(selected)
        else { return nil }
        return selected
    }

    public var isIndexBuilding: Bool {
        if case .indexBuilding = stage { return true }
        return false
    }

    public func setMode(_ mode: Mode) {
        let enteringPin = mode == .pinned && self.mode != .pinned
        if enteringPin {
            requestID &+= 1
            cancelExactUpgrade()
            pendingToken = nil
            let hasDisplayedLocatedToken = if let displayedToken, let locatedToken {
                locatedToken.file == displayedToken.file
                    && locatedToken.range.contains(displayedToken.offset)
            } else {
                false
            }
            if !hasDisplayedLocatedToken { locatedToken = nil }
        }
        self.mode = mode
        if enteringPin,
           let displayedToken,
           case let .ready(session, context) = projectState,
           selectedCandidate != nil
        {
            startExactUpgrade(
                displayedToken,
                session: session,
                context: context,
                request: requestID
            )
        }
    }

    public func updateProjectState(
        _ state: ProjectState,
        root: URL?,
        contentSource: DocumentLoader.ContentSource? = nil
    ) {
        let previousIdentity = if case let .ready(_, context) = projectState {
            (context.snapshotID, context.analysisProfileID, context.generation)
        } else {
            nil as (
                snapshotID: SnapshotID,
                analysisProfileID: AnalysisProfileID,
                generation: UInt64
            )?
        }
        let normalizedRoot = root?.standardizedFileURL
        if self.root != normalizedRoot {
            requestID &+= 1
            cancelExactUpgrade()
            pendingToken = nil
            displayedToken = nil
            locatedToken = nil
        }
        self.root = normalizedRoot
        self.contentSource = contentSource
        projectState = state

        switch state {
        case .indexing:
            requestID &+= 1
            cancelExactUpgrade()
            locatedToken = nil
            displayedToken = nil
            stage = .indexBuilding
        case let .ready(_, context):
            if let previousIdentity,
               previousIdentity.snapshotID != context.snapshotID
                || previousIdentity.analysisProfileID != context.analysisProfileID
            {
                requestID &+= 1
                cancelExactUpgrade()
                locatedToken = nil
                displayedToken = nil
                stage = .idle
            } else if let previousIdentity,
                      previousIdentity.generation != context.generation
            {
                requestID &+= 1
                cancelExactUpgrade()
                locatedToken = nil
            }
            if let pendingToken {
                self.pendingToken = nil
                Task { [weak self] in
                    _ = await self?.lookup(pendingToken)
                }
            } else if case .indexBuilding = stage {
                stage = .idle
            }
        case .empty, .failed:
            requestID &+= 1
            cancelExactUpgrade()
            pendingToken = nil
            locatedToken = nil
            displayedToken = nil
            stage = .idle
        }
    }

    public func tokenClicked(file: String, offset: UInt32) {
        guard mode == .follow else { return }
        let token = Token(file: file, offset: offset)
        Task { [weak self] in
            _ = await self?.lookup(token)
        }
    }

    public func explicitJump(file: String, offset: UInt32) async -> Candidate? {
        if mode == .pinned {
            return await resolvedCandidate(file: file, offset: offset)
        }
        return await lookup(Token(file: file, offset: offset))
    }

    public func resolvedCandidate(file: String, offset: UInt32) async -> Candidate? {
        guard case let .ready(session, context) = projectState else { return nil }
        if let locatedToken,
           locatedToken.file == file,
           locatedToken.range.contains(offset)
        {
            return selectedCandidate
        }
        guard let pathID = pathID(file, in: session) else { return nil }
        guard let candidates = try? await resolveCandidates(
                  session: session,
                  pathID: pathID,
                  offset: offset,
                  context: context
              ),
              sessionIsCurrent(session, context)
        else { return nil }
        return candidates.first
    }

    public func selectNext() {
        guard case let .candidates(candidates, selected) = stage,
              !candidates.isEmpty
        else { return }
        selectionEpoch &+= 1
        stage = .candidates(candidates, selected: (selected + 1) % candidates.count)
    }

    public func select(at index: Int) {
        guard case let .candidates(candidates, selected) = stage,
              candidates.indices.contains(index),
              index != selected
        else { return }
        selectionEpoch &+= 1
        stage = .candidates(candidates, selected: index)
    }

    public func selectPrevious() {
        guard case let .candidates(candidates, selected) = stage,
              !candidates.isEmpty
        else { return }
        selectionEpoch &+= 1
        stage = .candidates(
            candidates,
            selected: (selected - 1 + candidates.count) % candidates.count
        )
    }

    private func lookup(_ token: Token) async -> Candidate? {
        guard case let .ready(session, context) = projectState else {
            pendingToken = token
            if case .indexing = projectState { stage = .indexBuilding }
            return nil
        }
        if let locatedToken,
           locatedToken.file == token.file,
           locatedToken.range.contains(token.offset)
        {
            return selectedCandidate
        }
        requestID &+= 1
        cancelExactUpgrade()
        let currentRequest = requestID
        guard let pathID = pathID(token.file, in: session) else {
            locatedToken = nil
            stage = .idle
            return nil
        }
        guard let range = try? session.tokenRange(
            file: pathID,
            offset: token.offset,
            context: context
        ) else {
            locatedToken = nil
            stage = .idle
            return nil
        }
        if let locatedToken,
           locatedToken.file == token.file,
           locatedToken.range == range
        {
            return selectedCandidate
        }

        locatedToken = LocatedToken(file: token.file, range: range)
        do {
            let candidates = try await resolveCandidates(
                session: session,
                pathID: pathID,
                offset: token.offset,
                context: context
            )
            guard requestID == currentRequest else { return nil }
            guard !candidates.isEmpty else {
                stage = .idle
                return nil
            }
            stage = .candidates(candidates, selected: 0)
            displayedToken = token
            startExactUpgrade(
                token,
                session: session,
                context: context,
                request: currentRequest
            )
            return candidates[0]
        } catch {
            guard requestID == currentRequest else { return nil }
            locatedToken = nil
            stage = .idle
            return nil
        }
    }

    private func resolveCandidates(
        session: EngineSession,
        pathID: PathID,
        offset: UInt32,
        context: QueryContext
    ) async throws -> [Candidate] {
        await present(
            try await resolver(session, pathID, offset, context),
            session: session
        )
    }

    private func present(
        _ resolved: [ResolutionCandidate],
        session: EngineSession
    ) async -> [Candidate] {
        var candidates: [Candidate] = []
        for resolution in resolved {
            guard let (key, index) = session.content(at: resolution.target.pathID)
            else { continue }

            let targetRange: ByteRange
            let targetOffset: UInt32
            let bindingKind: String?
            if let bindingIndex = lexicalBindingIndex(in: resolution.evidence),
               index.bindings.indices.contains(Int(bindingIndex))
            {
                let binding = index.bindings[Int(bindingIndex)]
                targetRange = binding.declarationRange
                targetOffset = binding.declarationRange.lowerBound
                bindingKind = bindingLabel(binding.kind)
            } else {
                bindingKind = nil
                switch resolution.target.localKind {
                case .declarationFacet:
                    guard index.symbols.indices.contains(Int(resolution.target.localIndex))
                    else { continue }
                    let facet = index.symbols[Int(resolution.target.localIndex)]
                    targetRange = facet.range
                    targetOffset = facet.nameRange.lowerBound
                case .importBinding:
                    guard index.imports.indices.contains(Int(resolution.target.localIndex))
                    else { continue }
                    let binding = index.imports[Int(resolution.target.localIndex)]
                    targetRange = binding.range
                    targetOffset = binding.range.lowerBound
                case .callSite:
                    guard index.calls.indices.contains(Int(resolution.target.localIndex))
                    else { continue }
                    let call = index.calls[Int(resolution.target.localIndex)]
                    targetRange = call.nameRange
                    targetOffset = call.nameRange.lowerBound
                }
            }

            guard let coordinate = index.lineTable.lineColumn(at: targetOffset) else {
                continue
            }
            let path = session.paths.resolve(resolution.target.pathID)
            let text: String
            if resolution.certainty == .unresolved,
               resolution.target.localKind == .importBinding
            {
                text = localized("model.context.importError")
            } else if let contentID = contentID(
                at: resolution.target.pathID,
                in: session
            ), let document = await document(
                path: path,
                contentID: contentID,
                languageMode: key.languageMode
            ) {
                text = excerpt(
                    for: targetRange,
                    in: document,
                    binding: bindingKind != nil
                )
            } else {
                text = ""
            }
            candidates.append(Candidate(
                symbol: resolution.target,
                path: path,
                line: coordinate.line,
                column: coordinate.column,
                excerpt: text,
                bindingKind: bindingKind,
                targetByteOffset: targetOffset,
                basis: .resolved(
                    certainty: resolution.certainty,
                    dispatch: resolution.dispatch,
                    provenance: resolution.provenance
                )
            ))
        }
        return candidates
    }

    private func startExactUpgrade(
        _ token: Token,
        session: EngineSession,
        context: QueryContext,
        request: UInt64
    ) {
        guard exactResolver != nil else { return }
        Task { [weak self] in
            await self?.upgradeExact(
                token,
                session: session,
                context: context,
                request: request
            )
        }
    }

    private func upgradeExact(
        _ token: Token,
        session: EngineSession,
        context: QueryContext,
        request: UInt64
    ) async {
        guard let exactResolver,
              let batch = makeUpgradeBatch()
        else { return }
        let requestSelectionEpoch = selectionEpoch
        let result = await exactResolver(
            token.file,
            token.offset,
            context.generation,
            batch
        )
        defer { finishExactUpgrade(batch) }
        guard requestID == request,
              batch.isCurrent,
              sessionIsCurrent(session, context)
        else { return }
        guard case .completed(let entries) = result else { return }
        for exact in entries {
            await applyExact(
                exact,
                token: token,
                session: session,
                context: context,
                request: request,
                selectionEpoch: requestSelectionEpoch
            )
        }
    }

    package func cancelExactUpgrade() {
        guard let exactBatch else { return }
        exactBatch.cancel()
        cancelExactBatch?(exactBatch)
        self.exactBatch = nil
    }

    private func makeUpgradeBatch() -> ExactRequestBatch? {
        cancelExactUpgrade()
        guard exactResolver != nil else { return nil }
        let batch = ExactRequestBatch()
        exactBatch = batch
        return batch
    }

    private func finishExactUpgrade(_ batch: ExactRequestBatch) {
        if exactBatch === batch {
            exactBatch = nil
        }
    }

    private func applyExact(
        _ exact: ExactOverlay.Entry,
        token: Token,
        session: EngineSession,
        context: QueryContext,
        request: UInt64,
        selectionEpoch requestSelectionEpoch: UInt64
    ) async {
        // Candidates are identified by (path, targetByteOffset), never by a
        // captured index: every await below may interleave with user
        // selection, so the stage is re-read after each one.
        guard requestID == request,
              sessionIsCurrent(session, context),
              case let .candidates(entryCandidates, entrySelected) = stage,
              entryCandidates.indices.contains(entrySelected),
              let targetOffset = UInt32(exactly: exact.location.byteOffset)
        else { return }
        let targetPath = projectPath(exact.location.file)
        // The provider answered against the captured bytes; matching profile
        // and snapshot alone does not prove the query source and target still
        // hold those bytes. Drift suspends the upgrade instead of presenting
        // changed content as Exact.
        let sourceIsCurrent = await indexContentIsCurrent(
            token.file,
            session: session
        )
        let targetIsCurrent = await indexContentIsCurrent(
            targetPath,
            session: session
        )
        guard requestID == request,
              sessionIsCurrent(session, context),
              case let .candidates(current, selected) = stage,
              current.indices.contains(selected)
        else { return }
        guard sourceIsCurrent && targetIsCurrent else {
            onStaleIndexContent?(
                sourceIsCurrent ? targetPath : token.file
            )
            return
        }
        if let index = current.firstIndex(where: {
            $0.path == targetPath && $0.targetByteOffset == targetOffset
        }) {
            var candidates = current
            let upgraded = exactCandidate(
                upgrading: candidates[index],
                attribution: exact.attribution,
                origin: exact.origin,
                language: session.analysisProfile.language
            )
            if mode == .pinned {
                guard index == selected else { return }
                candidates[index] = upgraded
                stage = .candidates(candidates, selected: selected)
            } else if index == selected || selectionEpoch != requestSelectionEpoch {
                candidates[index] = upgraded
                stage = .candidates(candidates, selected: selected)
            } else {
                candidates.remove(at: index)
                candidates.insert(upgraded, at: 0)
                stage = .candidates(candidates, selected: 0)
            }
            return
        }

        guard mode != .pinned,
              let candidate = await exactCandidate(
                  at: targetPath,
                  offset: targetOffset,
                  attribution: exact.attribution,
                  origin: exact.origin,
                  session: session
              ),
              requestID == request,
              sessionIsCurrent(session, context),
              case let .candidates(latest, latestSelected) = stage
        else { return }
        let keepsUserChoice = selectionEpoch != requestSelectionEpoch
            && latest.indices.contains(latestSelected)
        stage = .candidates(
            [candidate] + latest,
            selected: keepsUserChoice ? latestSelected + 1 : 0
        )
    }

    private func exactCandidate(
        upgrading candidate: Candidate,
        attribution: ExactAttribution,
        origin: ExactOrigin,
        language: LanguageID
    ) -> Candidate {
        Candidate(
            symbol: candidate.symbol,
            path: candidate.path,
            line: candidate.line,
            column: candidate.column,
            excerpt: candidate.excerpt,
            bindingKind: candidate.bindingKind,
            targetByteOffset: candidate.targetByteOffset,
            basis: .exact(attribution, origin: origin, language: language)
        )
    }

    private func exactCandidate(
        at path: String,
        offset: UInt32,
        attribution: ExactAttribution,
        origin: ExactOrigin,
        session: EngineSession
    ) async -> Candidate? {
        if exactLocationIsInDependency(path) {
            return await dependencyExactCandidate(
                at: path,
                offset: offset,
                attribution: attribution,
                origin: origin,
                language: session.analysisProfile.language
            )
        }
        guard let pathID = pathID(path, in: session),
              let (key, index) = session.content(at: pathID),
              let symbolIndex = index.symbols.firstIndex(where: {
                  $0.nameRange.contains(offset) || $0.nameRange.lowerBound == offset
              }),
              let coordinate = index.lineTable.lineColumn(at: offset),
              let contentID = contentID(at: pathID, in: session),
              let document = await document(
                  path: path,
                  contentID: contentID,
                  languageMode: key.languageMode
              )
        else { return nil }
        let facet = index.symbols[symbolIndex]
        return Candidate(
            symbol: SymbolOccurrenceID(
                snapshotID: session.snapshotID,
                pathID: pathID,
                localKind: .declarationFacet,
                localIndex: UInt32(symbolIndex)
            ),
            path: path,
            line: coordinate.line,
            column: coordinate.column,
            excerpt: excerpt(for: facet.range, in: document, binding: false),
            bindingKind: nil,
            targetByteOffset: offset,
            basis: .exact(
                attribution,
                origin: origin,
                language: session.analysisProfile.language
            )
        )
    }

    private func dependencyExactCandidate(
        at path: String,
        offset: UInt32,
        attribution: ExactAttribution,
        origin: ExactOrigin,
        language: LanguageID
    ) async -> Candidate? {
        guard let languageMode = dependencyLanguageMode(path: path),
              let document = await dependencyDocument(
                  path: path,
                  languageMode: languageMode
              ),
              let byteCount = UInt32(exactly: document.bytes.count),
              offset <= byteCount,
              let coordinate = document.lineTable.lineColumn(at: offset)
        else { return nil }
        let targetRange = document.outlineFacets.first {
            $0.nameRange.contains(offset) || $0.nameRange.lowerBound == offset
        }?.range ?? ByteRange(lowerBound: offset, upperBound: offset)
        return Candidate(
            symbol: nil,
            path: path,
            line: coordinate.line,
            column: coordinate.column,
            excerpt: excerpt(for: targetRange, in: document, binding: false),
            bindingKind: nil,
            targetByteOffset: offset,
            basis: .dependencyExact(
                crate: dependencyCrateName(path) ?? path,
                attribution,
                origin: origin,
                language: language
            )
        )
    }

    private func projectPath(_ path: String) -> String {
        guard path.hasPrefix("/"), let root else { return path }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.pathComponents.starts(with: root.pathComponents) else {
            return path
        }
        return file.pathComponents.dropFirst(root.pathComponents.count)
            .joined(separator: "/")
    }

    /// Whether a result computed against `session`/`context` may still be
    /// published: the same generation, snapshot and analysis profile.
    private func sessionIsCurrent(_ session: EngineSession, _ context: QueryContext) -> Bool {
        guard case let .ready(currentSession, currentContext) = projectState else {
            return false
        }
        return currentContext.generation == context.generation
            && currentSession.snapshotID == session.snapshotID
            && currentSession.analysisProfile.id == session.analysisProfile.id
    }

    private func pathID(_ path: String, in session: EngineSession) -> PathID? {
        session.manifest.files.first {
            session.paths.resolve($0.pathID) == path
        }?.pathID
    }

    private func contentID(at pathID: PathID, in session: EngineSession) -> ContentID? {
        session.manifest.files.first { $0.pathID == pathID }?.contentID
    }

    private func document(
        path: String,
        contentID: ContentID,
        languageMode: LanguageMode
    ) async -> ReaderDocument? {
        let key = DocumentKey(
            path: path,
            contentID: contentID,
            languageMode: languageMode
        )
        if let cached = documents[key] {
            documentRecency.removeAll { $0 == key }
            documentRecency.append(key)
            return cached
        }
        guard let root else { return nil }
        let file = root.appendingPathComponent(path)
        let loaded: ReaderDocument?
        if let contentSource {
            loaded = await Task.detached(priority: .userInitiated) {
                try? DocumentLoader(source: contentSource).load(
                    file: file,
                    languageMode: languageMode
                ).document
            }.value
        } else {
            loaded = await loader(file, languageMode)
        }
        guard let loaded else { return nil }
        // A worktree file may have drifted since indexing; never hand back
        // different bytes under the requested identity.
        guard loaded.contentID == contentID else { return nil }
        return remember(loaded, path: path)
    }

    /// Freshly verifies that an indexed project file still holds the bytes
    /// the session captured. Deliberately bypasses the excerpt cache so a
    /// drifted worktree file is detected even when older consistent bytes are
    /// still cached. Snapshot-backed and dependency paths are consistent by
    /// construction.
    private func indexContentIsCurrent(
        _ path: String,
        session: EngineSession
    ) async -> Bool {
        guard exactLocationIsInDependency(path) == false,
              let pathID = pathID(path, in: session),
              session.content(at: pathID) != nil,
              let expected = contentID(at: pathID, in: session),
              let root
        else { return true }
        let file = root.appendingPathComponent(path)
        if let contentIdentityOverride {
            return await contentIdentityOverride(file) == expected
        }
        // Identity only needs the bytes; building a reader document here
        // would run the full syntax pass for every verification.
        let source = contentSource
        let current = await Task.detached(priority: .userInitiated) {
            let bytes: [UInt8]? = if let source {
                try? source(file)
            } else {
                (try? Data(contentsOf: file, options: .mappedIfSafe)).map { [UInt8]($0) }
            }
            return bytes.map { ContentID.sha256(of: $0) }
        }.value
        return current == expected
    }

    private func dependencyDocument(
        path: String,
        languageMode: LanguageMode
    ) async -> ReaderDocument? {
        if let key = documentRecency.last(where: {
            $0.path == path && $0.languageMode == languageMode
        }),
           let cached = documents[key]
        {
            documentRecency.removeAll { $0 == key }
            documentRecency.append(key)
            return cached
        }
        guard let loaded = await loader(
            URL(fileURLWithPath: path),
            languageMode
        ) else {
            return nil
        }
        return remember(loaded, path: path)
    }

    private func dependencyLanguageMode(path: String) -> LanguageMode? {
        guard case let .ready(session, _) = projectState else { return nil }
        let language = session.analysisProfile.language
        return LanguageMode.classify(path: path, language: language)
            ?? (URL(fileURLWithPath: path).pathExtension.isEmpty
                ? LanguageMode(language: language)
                : nil)
    }

    private func remember(
        _ document: ReaderDocument,
        path: String
    ) -> ReaderDocument {
        let key = DocumentKey(
            path: path,
            contentID: document.contentID,
            languageMode: document.languageMode
        )
        documents[key] = document
        documentRecency.removeAll { $0 == key }
        documentRecency.append(key)
        if documentRecency.count > 8 {
            documents.removeValue(forKey: documentRecency.removeFirst())
        }
        return document
    }

    private func lexicalBindingIndex(
        in evidence: [ResolutionEvidence]
    ) -> UInt32? {
        for item in evidence {
            if case let .lexicalBinding(bindingIndex) = item { return bindingIndex }
        }
        return nil
    }

    private func bindingLabel(_ kind: BindingKind) -> String {
        switch kind {
        case .param: localized("model.binding.param")
        case .letBinding: localized("model.binding.letBinding")
        case .importBinding: localized("model.binding.importBinding")
        case .assignment: localized("model.binding.assignment")
        case .patternBinding: localized("model.binding.patternBinding")
        case .globalDecl: localized("model.binding.globalDecl")
        case .nonlocalDecl: localized("model.binding.nonlocalDecl")
        }
    }
}

private func dependencyCrateName(_ path: String) -> String? {
    let ancestors = Array(
        URL(fileURLWithPath: path).pathComponents.dropLast()
    )
    let isCargoRegistry = ancestors.indices.contains { index in
        index + 1 < ancestors.count
            && ancestors[index] == "registry"
            && ancestors[index + 1] == "src"
    }
    // A semver-looking directory alone is not evidence of a crate name.
    guard isCargoRegistry || ancestors.contains("materialized") else {
        return nil
    }
    for component in ancestors.reversed() {
        guard let version = component.range(
            of: #"-\d+\.\d+\.\d+(?:[-+].*)?$"#,
            options: .regularExpression
        ), version.lowerBound != component.startIndex
        else { continue }
        return String(component[..<version.lowerBound])
    }
    return nil
}

private func loadReaderDocument(
    at file: URL,
    languageMode: LanguageMode
) async -> ReaderDocument? {
    await Task.detached(priority: .userInitiated) {
        try? DocumentLoader().load(
            file: file,
            languageMode: languageMode
        ).document
    }.value
}

private func exactProvenanceBadge(
    _ label: String,
    attribution: ExactAttribution,
    origin: ExactOrigin,
    language: LanguageID
) -> String {
    let trust = switch attribution.environment.trustMode {
    case .safe: localized("model.context.safe")
    case .trusted: localized("model.context.trusted")
    }
    let source = switch origin {
    case .worktree:
        ""
    case .materialized(let commitOID):
        localizedFormat("model.context.materialized", String(commitOID.prefix(7)))
    }
    let featureDetail: String? = if language == .python {
        nil
    } else {
        switch attribution.featureSelection {
        case .defaultFeatures: localized("model.context.default")
        case .allFeatures: localized("model.context.all")
        case .noDefaultFeatures: localized("model.context.noDefault")
        }
    }
    let featureSuffix = featureDetail.map {
        localizedFormat("model.context.features", $0)
    } ?? ""
    let limitations = attribution.environment.limitations
        .sorted { $0.rawValue < $1.rawValue }
        .map(localizedLimitation)
        .joined(separator: "; ")
    let environment = limitations.isEmpty
        ? localized("model.context.unlimited")
        : localizedFormat("model.context.limitations", limitations)
    return "\(label) · \(attribution.provider) \(attribution.toolVersion) · \(trust) · \(environment)\(source)\(featureSuffix)"
}

package func resolutionCertaintyLabel(_ certainty: Certainty) -> String {
    switch certainty {
    case .unresolved: localized("model.context.unresolved")
    case .possible: localized("model.context.possible")
    case .probable: localized("model.context.probable")
    case .strong: localized("model.context.strong")
    case .exact: localized("model.context.exact")
    }
}

func resolutionDispatchLabel(_ dispatch: DispatchKind) -> String {
    switch dispatch {
    case .direct: localized("model.context.direct")
    case .virtualDispatch: localized("model.context.virtual")
    case .traitDispatch: localized("model.context.trait")
    case .interfaceDispatch: localized("model.context.interface")
    case .callback: localized("model.context.callback")
    case .dynamicDispatch: localized("model.context.dynamic")
    case .macroGenerated: localized("model.context.macro")
    }
}

package func localizedLimitation(_ limitation: ExactAnalysisLimitation) -> String {
    switch limitation {
    case .buildScriptsDisabled: localized("model.limitation.buildScripts")
    case .procMacrosDisabled: localized("model.limitation.procMacros")
    case .dependenciesUnavailableOffline: localized("model.limitation.offline")
    }
}
