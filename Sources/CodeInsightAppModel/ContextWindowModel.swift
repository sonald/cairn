import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightReaderCore
import Foundation
import Observation

@MainActor
@Observable
public final class ContextWindowModel {
    /// R6.1: what the lens tracks (T1=B) — orthogonal to `isPinned`.
    public enum Tracking: String, Codable, Sendable {
        case symbol
        case enclosing
    }

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
        /// Explanatory badge text, e.g. why the lens stays on a primitive.
        public let note: String?

        public init(
            symbol: SymbolOccurrenceID?,
            path: String,
            line: UInt32,
            column: UInt32,
            excerpt: String,
            bindingKind: String?,
            targetByteOffset: UInt32,
            basis: Basis,
            note: String? = nil
        ) {
            self.symbol = symbol
            self.path = path
            self.line = line
            self.column = column
            self.excerpt = excerpt
            self.bindingKind = bindingKind
            self.targetByteOffset = targetByteOffset
            self.basis = basis
            self.note = note
        }

        func withCertainty(_ certainty: Certainty) -> Candidate {
            Candidate(
                symbol: symbol,
                path: path,
                line: line,
                column: column,
                excerpt: excerpt,
                bindingKind: bindingKind,
                targetByteOffset: targetByteOffset,
                basis: .resolved(
                    certainty: certainty,
                    dispatch: resolutionDispatch ?? .direct,
                    provenance: provenance
                ),
                note: note
            )
        }

        func withNote(_ note: String) -> Candidate {
            Candidate(
                symbol: symbol,
                path: path,
                line: line,
                column: column,
                excerpt: excerpt,
                bindingKind: bindingKind,
                targetByteOffset: targetByteOffset,
                basis: basis,
                note: note
            )
        }

        var resolutionDispatch: DispatchKind? {
            if case let .resolved(_, dispatch, _) = basis { return dispatch }
            return nil
        }

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
        /// The lens shows the type a value binding or field points to (P1).
        case typeHop(TypeHop, selected: Int)
        /// R5: the lens shows the declaration enclosing the caret.
        case enclosing(EnclosingScope)
    }

    /// R5.2: the declaration enclosing the caret — document comment start
    /// through the signature end, plus the first body line, and its size.
    public struct EnclosingScope: Sendable, Equatable {
        public let path: String
        public let kind: OutlineKind
        public let name: String
        public let nameLine: UInt32
        public let displayRange: CodeInsightCore.ByteRange
        public let signatureEndLine: UInt32
        public let bodyFirstLine: UInt32
        public let bodyLineCount: Int
        public let methodCount: Int?
    }

    /// Everything the model needs from the syntactic type hop (P1.4).
    package struct TypeHopAnswer: Sendable {
        let result: TypeHopResult
        let viaText: String?
        let viaKind: TypeHopViaKind?
        let boundNote: String?
    }

    /// One type-hop presentation: the binding the user pointed at (`via`)
    /// plus the type candidates the window may display (R1/R7).
    public struct TypeHop: Sendable {
        public enum Showing: Sendable { case type, declaration }

        public let via: Candidate
        public let viaText: String
        public let viaKind: String
        public var targets: [Candidate]
        public var showing: Showing
        public var userChoseShowing: Bool
        public var boundNote: String?
        /// Set while a `typeDefinition` request is in flight (P2).
        public var pendingExact: Bool

        public init(
            via: Candidate,
            viaText: String,
            viaKind: String,
            targets: [Candidate],
            showing: Showing,
            userChoseShowing: Bool = false,
            boundNote: String? = nil,
            pendingExact: Bool = false
        ) {
            self.via = via
            self.viaText = viaText
            self.viaKind = viaKind
            self.targets = targets
            self.showing = showing
            self.userChoseShowing = userChoseShowing
            self.boundNote = boundNote
            self.pendingExact = pendingExact
        }
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
    /// The syntactic type hop plus the first hop's spelled binding text.
    typealias TypeHopResolver = @MainActor (
        EngineSession,
        PathID,
        UInt32,
        QueryContext
    ) async throws -> TypeHopAnswer
    typealias TypeDefinitionResolver = @MainActor (
        String,
        UInt32,
        UInt64,
        ExactRequestBatch
    ) async -> ExactCoordinator.TypeDefinitionResult?
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
    public private(set) var tracking: Tracking = .symbol
    public private(set) var isPinned = false
    /// R4.3: the caret sits on no symbol; the lens keeps the last content.
    public private(set) var isShowingPreviousToken = false
    public private(set) var stage: Stage = .idle
    public private(set) var requestID: UInt64 = 0
    /// Reports a project path whose content no longer matches the indexed
    /// bytes an Exact reply was computed against, so the owner can surface a
    /// stale-index notice instead of silently mixing contents.
    package var onStaleIndexContent: (@MainActor (String) -> Void)?

    private let resolver: Resolver
    private var typeHopResolver: TypeHopResolver?
    private var typeDefinitionResolver: TypeDefinitionResolver?
    private var typeDefinitionReadiness: (() -> String?)?
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
        typeHopResolver = { session, file, offset, context in
            let result = try session.typeHop(file: file, offset: offset, context: context)
            let spelling = try? session.bindingSpelling(
                file: file, offset: offset, context: context
            )
            return TypeHopAnswer(
                result: result,
                viaText: spelling?.text,
                viaKind: spelling?.kind,
                boundNote: spelling?.boundNote
            )
        }
        loader = loadReaderDocument
        exactResolver = nil
        contentIdentityOverride = nil
    }

    init(
        _ resolver: @escaping Resolver,
        loader: @escaping Loader = loadReaderDocument,
        exactResolver: ExactResolver? = nil,
        contentIdentity: ContentIdentityReader? = nil,
        typeHopResolver: TypeHopResolver? = nil,
        typeDefinitionResolver: TypeDefinitionResolver? = nil,
        typeDefinitionReadiness: (() -> String?)? = nil
    ) {
        self.resolver = resolver
        self.loader = loader
        self.exactResolver = exactResolver
        self.typeHopResolver = typeHopResolver
        self.typeDefinitionResolver = typeDefinitionResolver
        self.typeDefinitionReadiness = typeDefinitionReadiness
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
        typeDefinitionResolver = { [weak coordinator] file, offset, generation, batch in
            await coordinator?.typeDefinition(
                file: file,
                byteOffset: offset,
                generation: generation,
                batch: batch
            )
        }
        typeDefinitionReadiness = { [weak coordinator] in
            guard let coordinator else { return nil }
            return switch coordinator.readiness {
            case .ready: nil
            case .preparing: localized("model.typehop.pendingExact")
            case let .unavailable(reason), let .off(reason): reason
            }
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

    /// 用户指向的符号（R2.2）：⌘+单击、查看引用/调用方/实现、悬停文档等
    /// "对符号做事"的入口只读它；类型直达（P1）下它仍是那个绑定。
    public var symbolCandidate: Candidate? {
        switch stage {
        case .enclosing:
            // R5.4: the enclosing mode points at no symbol.
            return nil
        case let .typeHop(hop, _):
            return hop.via
        case let .candidates(candidates, selected):
            return candidates.indices.contains(selected) ? candidates[selected] : nil
        case .idle, .indexBuilding:
            return nil
        }
    }

    /// 窗口显示的内容（R2.3）：正文、路径、徽章、双击打开读它。
    /// 类型直达下按 `showing` 返回类型目标或绑定本身（R7）。
    public var displayedCandidate: Candidate? {
        switch stage {
        case .enclosing:
            // R5.4: the enclosing scope renders through its own header and
            // mini reader; there is no candidate to open as a symbol.
            return nil
        case let .typeHop(hop, selected):
            if hop.showing == .type, hop.targets.indices.contains(selected) {
                return hop.targets[selected]
            }
            return hop.via
        case let .candidates(candidates, selected):
            return candidates.indices.contains(selected) ? candidates[selected] : nil
        case .idle, .indexBuilding:
            return nil
        }
    }

    /// The active type-hop presentation, for the one-hop label (P1.5).
    public var activeTypeHop: TypeHop? {
        if case let .typeHop(hop, _) = stage { return hop }
        return nil
    }

    /// The enclosing-scope presentation (R5).
    public var activeEnclosingScope: EnclosingScope? {
        if case let .enclosing(scope) = stage { return scope }
        return nil
    }

    /// R7.2: switch what the window displays for this hop; the user's choice
    /// blocks later auto-switching.
    public func showTypeHop(_ showing: TypeHop.Showing) {
        guard case let .typeHop(hop, selected) = stage else { return }
        var updated = hop
        updated.showing = showing
        updated.userChoseShowing = true
        stage = .typeHop(updated, selected: selected)
    }

    package var selectedLanguageMode: LanguageMode? {
        guard let candidate = symbolCandidate,
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
        switch stage {
        case let .candidates(candidates, _):
            return candidates.count
        case let .typeHop(hop, _):
            return hop.targets.count
        case .idle, .indexBuilding, .enclosing:
            return 0
        }
    }

    public var selectedIndex: Int? {
        switch stage {
        case let .candidates(candidates, selected):
            return candidates.indices.contains(selected) ? selected : nil
        case let .typeHop(hop, selected):
            return hop.targets.indices.contains(selected) ? selected : nil
        case .idle, .indexBuilding, .enclosing:
            return nil
        }
    }

    public var isIndexBuilding: Bool {
        if case .indexBuilding = stage { return true }
        return false
    }

    public func setMode(_ mode: Mode) {
        switch mode {
        case .follow: setPinned(false)
        case .pinned: setPinned(true)
        }
    }

    /// R6.1: switch what the lens tracks. Switching away from the enclosing
    /// mode replays the current token so the lens shows the symbol again.
    public func setTracking(_ tracking: Tracking) {
        guard tracking != self.tracking else { return }
        self.tracking = tracking
        // Drop in-flight symbol lookups and Exact work: their results belong
        // to the other mode. Forget the located token so the replay below
        // is not swallowed by the same-token dedup.
        requestID &+= 1
        cancelExactUpgrade()
        pendingDwellTask?.cancel()
        pendingDwellTask = nil
        dwellArmedToken = nil
        locatedToken = nil
        isShowingPreviousToken = false
        guard tracking == .symbol else { return }
        if case .enclosing = stage { stage = .idle }
        if mode == .follow, let displayedToken {
            tokenClicked(file: displayedToken.file, offset: displayedToken.offset)
        }
    }

    /// R6.1/R6.2: the pin is orthogonal to tracking. Entering the pin keeps
    /// the exact-upgrade semantics of the old `setMode(.pinned)`.
    public func setPinned(_ pinned: Bool) {
        let enteringPin = pinned && !isPinned
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
        mode = pinned ? .pinned : .follow
        isPinned = pinned
        if enteringPin,
           let displayedToken,
           case let .ready(session, context) = projectState,
           symbolCandidate != nil
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

    /// R4.2: `.click` fires exact requests immediately; `.caret` delays them
    /// until the caret has dwelled on the same token for `exactDwell`.
    public enum Trigger: Sendable {
        case click
        case caret
    }

    /// Test seam for the caret dwell (R4.2); production uses 400 ms.
    public var exactDwell: Duration = .milliseconds(400)
    private var pendingDwellTask: Task<Void, Never>?
    private var dwellArmedToken: (file: String, range: ByteRange)?

    public func tokenClicked(
        file: String,
        offset: UInt32,
        trigger: Trigger = .click
    ) {
        // R5.3: the enclosing mode follows the caret's scope, not symbols.
        guard mode == .follow, tracking == .symbol else { return }
        let token = Token(file: file, offset: offset)
        Task { [weak self] in
            _ = await self?.lookup(token, trigger: trigger)
        }
    }

    /// R5: the enclosing-function mode. Purely syntactic — no index and no
    /// exact requests; the same outline facet does not refresh the stage.
    public func caretMoved(file: String, offset: UInt32, document: ReaderDocument) {
        guard tracking == .enclosing, !isPinned else { return }
        let facets = ReadingPlan.enclosingAssociatedFacets(at: offset, in: document)
        // Innermost function or method first (closures are not outline
        // facets, so they cannot win); then the innermost type; else idle.
        // `enclosingAssociatedFacets` orders outermost first, so the
        // innermost match is the last one.
        let functions: Set<OutlineKind> = [.fn, .method]
        let types: Set<OutlineKind> = [.impl, .struct, .enum, .trait, .class]
        let chosen = facets.last { functions.contains($0.kind) }
            ?? facets.last { types.contains($0.kind) }
        // R5.1: no function and no type — the placeholder (idle) state.
        guard let facet = chosen,
              let scope = enclosingScope(facet, in: document, path: file)
        else {
            stage = .idle
            isShowingPreviousToken = false
            return
        }
        if let current = activeEnclosingScope,
           current.path == file,
           current.name == facet.name,
           current.kind == facet.kind,
           current.displayRange == scope.displayRange
        {
            return // same outline facet — no refresh (R5.3)
        }
        enclosingRefreshCount += 1
        stage = .enclosing(scope)
        isShowingPreviousToken = false
    }

    /// Test observable for the same-facet dedup (R5.3): how many enclosing
    /// stages were written.
    package private(set) var enclosingRefreshCount = 0

    /// Builds the display facts for an enclosing facet (R5.2).
    private func enclosingScope(
        _ facet: OutlineFacet,
        in document: ReaderDocument,
        path: String
    ) -> EnclosingScope? {
        let table = document.lineTable
        guard let nameLine = table.lineColumn(at: facet.nameRange.lowerBound)?.line
        else { return nil }

        // Signature end: the first fold region inside the facet that starts
        // after the name; its opening line is the signature's last line.
        var signatureEndLine = nameLine
        var bodyFirstLine = nameLine
        for region in document.foldRegions {
            // The first fold region inside the facet that starts after the
            // name: its body start (`{` line) is the signature's last line.
            guard region.bodyRange.lowerBound >= facet.nameRange.upperBound,
                  region.bodyRange.lowerBound < facet.range.upperBound
            else { continue }
            if let line = table.lineColumn(at: region.bodyRange.lowerBound)?.line {
                signatureEndLine = max(signatureEndLine, line)
                bodyFirstLine = line + 1
                break
            }
        }
        // Fallback: display just the name's line.
        if signatureEndLine == nameLine {
            bodyFirstLine = nameLine
        }

        let docStart: UInt32
        if let docRange = docCommentRange(above: facet.range, in: document),
           let line = table.lineColumn(at: docRange.lowerBound)?.line
        {
            docStart = line
        } else {
            docStart = nameLine
        }

        let facetStartLine = table.lineColumn(at: facet.range.lowerBound)?.line ?? docStart
        let displayStart = min(docStart, facetStartLine, nameLine)
        guard let lower = table.byteOffset(line: displayStart, column: 1) else {
            return nil
        }
        let bodyLineCount = max(
            0,
            Int((table.lineColumn(at: facet.range.upperBound)?.line ?? bodyFirstLine)) - Int(bodyFirstLine)
        )
        var methodCount: Int?
        if facet.kind == .impl {
            methodCount = document.outlineFacets.filter {
                $0.kind == .method && facet.range.contains($0.range.lowerBound)
            }.count
        }
        return EnclosingScope(
            path: path,
            kind: facet.kind,
            name: facet.name,
            nameLine: nameLine,
            displayRange: ByteRange(lowerBound: lower, upperBound: facet.range.upperBound),
            signatureEndLine: signatureEndLine,
            bodyFirstLine: bodyFirstLine,
            bodyLineCount: bodyLineCount,
            methodCount: methodCount
        )
    }

    public func explicitJump(file: String, offset: UInt32) async -> Candidate? {
        // Pinned or tracking the enclosing scope: answer the jump without
        // replacing what the lens shows (R6.2, R5.3).
        if mode == .pinned || tracking == .enclosing {
            return await resolvedCandidate(file: file, offset: offset)
        }
        return await lookup(Token(file: file, offset: offset))
    }

    public func resolvedCandidate(file: String, offset: UInt32) async -> Candidate? {
        guard case let .ready(session, context) = projectState else { return nil }
        if let locatedToken,
           locatedToken.file == file,
           locatedToken.range.contains(offset),
           let current = symbolCandidate
        {
            return current
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
        switch stage {
        case let .candidates(candidates, selected):
            guard !candidates.isEmpty else { return }
            selectionEpoch &+= 1
            stage = .candidates(candidates, selected: (selected + 1) % candidates.count)
        case let .typeHop(hop, selected):
            guard !hop.targets.isEmpty else { return }
            selectionEpoch &+= 1
            stage = .typeHop(hop, selected: (selected + 1) % hop.targets.count)
        case .idle, .indexBuilding, .enclosing:
            break
        }
    }

    public func select(at index: Int) {
        switch stage {
        case let .candidates(candidates, selected):
            guard candidates.indices.contains(index), index != selected else { return }
            selectionEpoch &+= 1
            stage = .candidates(candidates, selected: index)
        case let .typeHop(hop, selected):
            guard hop.targets.indices.contains(index), index != selected else { return }
            selectionEpoch &+= 1
            stage = .typeHop(hop, selected: index)
        case .idle, .indexBuilding, .enclosing:
            break
        }
    }

    public func selectPrevious() {
        switch stage {
        case let .candidates(candidates, selected):
            guard !candidates.isEmpty else { return }
            selectionEpoch &+= 1
            stage = .candidates(
                candidates,
                selected: (selected - 1 + candidates.count) % candidates.count
            )
        case let .typeHop(hop, selected):
            guard !hop.targets.isEmpty else { return }
            selectionEpoch &+= 1
            stage = .typeHop(
                hop,
                selected: (selected - 1 + hop.targets.count) % hop.targets.count
            )
        case .idle, .indexBuilding, .enclosing:
            break
        }
    }

    private func lookup(_ token: Token, trigger: Trigger = .click) async -> Candidate? {
        guard case let .ready(session, context) = projectState else {
            pendingToken = token
            if case .indexing = projectState { stage = .indexBuilding }
            return nil
        }
        if let locatedToken,
           locatedToken.file == token.file,
           locatedToken.range.contains(token.offset)
        {
            return symbolCandidate
        }
        // Only a new token supersedes the displayed one. A miss (blank,
        // keyword) or a caret echo inside the same token keeps the displayed
        // content — and its in-flight Exact work, which it still needs.
        guard let pathID = pathID(token.file, in: session) else {
            requestID &+= 1
            cancelExactUpgrade()
            pendingDwellTask?.cancel()
            pendingDwellTask = nil
            dwellArmedToken = nil
            locatedToken = nil
            stage = .idle
            isShowingPreviousToken = false
            return nil
        }
        guard let range = try? session.tokenRange(
            file: pathID,
            offset: token.offset,
            context: context
        ) else {
            // R4.3: the caret/click sits on no symbol — keep the previous
            // content and flag it (T4). Only a not-yet-sent dwell request
            // is dropped (R4.2).
            pendingDwellTask?.cancel()
            pendingDwellTask = nil
            dwellArmedToken = nil
            isShowingPreviousToken = true
            return nil
        }
        if let locatedToken,
           locatedToken.file == token.file,
           locatedToken.range == range
        {
            return symbolCandidate
        }
        requestID &+= 1
        cancelExactUpgrade()
        pendingDwellTask?.cancel()
        pendingDwellTask = nil
        dwellArmedToken = nil
        let currentRequest = requestID

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
                isShowingPreviousToken = false
                return nil
            }
            stage = .candidates(candidates, selected: 0)
            displayedToken = token
            isShowingPreviousToken = false
            var wantsTypeDefinition = await applyTypeHop(
                firstCandidate: candidates[0],
                file: pathID,
                offset: token.offset,
                session: session,
                context: context,
                request: currentRequest
            )
            if trigger == .caret {
                // R4.2: delay exact requests until the caret dwells on this
                // token; leaving the token cancels the pending request.
                dwellArmedToken = (token.file, range)
                let dwell = exactDwell
                pendingDwellTask = Task { [weak self] in
                    try? await Task.sleep(for: dwell)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self, self.mode == .follow else { return }
                        guard self.dwellArmedToken?.file == token.file,
                              self.dwellArmedToken?.range == range
                        else { return }
                        self.dwellArmedToken = nil
                        self.startExactUpgrade(
                            token,
                            session: session,
                            context: context,
                            request: self.requestID,
                            requestTypeDefinition: wantsTypeDefinition
                        )
                    }
                }
            } else {
                startExactUpgrade(
                    token,
                    session: session,
                    context: context,
                    request: currentRequest,
                    requestTypeDefinition: wantsTypeDefinition
                )
            }
            return symbolCandidate ?? candidates[0]
        } catch {
            guard requestID == currentRequest else { return nil }
            locatedToken = nil
            stage = .idle
            isShowingPreviousToken = false
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
            // A class attribute reached through its receiver (Python): a
            // field, with no engine facet behind it.
            let isMember = resolution.evidence.contains {
                if case .memberBinding = $0 { return true }
                return false
            }
            if let bindingIndex = lexicalBindingIndex(in: resolution.evidence),
               index.bindings.indices.contains(Int(bindingIndex))
            {
                let binding = index.bindings[Int(bindingIndex)]
                targetRange = binding.declarationRange
                targetOffset = binding.declarationRange.lowerBound
                bindingKind = isMember
                    ? localized("model.typehop.field")
                    : bindingLabel(binding.kind)
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
                // The member's localIndex is a binding index, not a facet:
                // relations must not read it as a symbol.
                symbol: isMember ? nil : resolution.target,
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

    /// P1.4: when the pointed-at candidate is a value binding or a field
    /// with a spelled type, the lens switches to `.typeHop` and shows the
    /// type. Primitives and unconstrained generics stay on the declaration
    /// with an explanatory note; `.none` keeps the plain candidate list
    /// (P2 may still promote it once the Exact layer answers).
    /// Returns true when the Exact `typeDefinition` should ride the same
    /// batch as the definition upgrade (value bindings and fields whose type
    /// is not a primitive or an unconstrained generic).
    private func applyTypeHop(
        firstCandidate: Candidate,
        file: PathID,
        offset: UInt32,
        session: EngineSession,
        context: QueryContext,
        request: UInt64
    ) async -> Bool {
        guard let typeHopResolver else { return false }
        guard let answer = try? await typeHopResolver(
            session, file, offset, context
        ) else { return false }
        guard requestID == request else { return false }
        switch answer.result {
        case let .targets(resolutions, certainty) where !resolutions.isEmpty:
            var targets = await present(resolutions, session: session)
            if targets.isEmpty { return false }
            targets = targets.map { candidate in
                candidate.withCertainty(certainty)
            }
            let kind = answer.viaKind.map { viaKindLabel($0) }
            stage = .typeHop(TypeHop(
                via: firstCandidate,
                viaText: answer.viaText ?? firstCandidate.excerpt,
                viaKind: kind ?? viaKindLabel(.parameter),
                targets: targets,
                showing: .type,
                boundNote: answer.boundNote
            ), selected: 0)
            return true
        case let .primitive(name):
            stage = .candidates(
                [firstCandidate.withNote(localizedFormat(
                    "model.typehop.primitiveNote", name
                ))],
                selected: 0
            )
            return false
        case let .genericUnbounded(name):
            stage = .candidates(
                [firstCandidate.withNote(localizedFormat(
                    "model.typehop.genericNote", name
                ))],
                selected: 0
            )
            return false
        case .targets, .none:
            // R1.2 item 4 / R1.5: only value bindings and fields park in a
            // pending type hop for the Exact layer; targets that are already
            // types, functions, or modules keep the existing presentation.
            guard answer.viaKind != nil,
                  typeDefinitionResolver != nil,
                  exactResolver != nil
            else { return false }
            stage = .typeHop(TypeHop(
                via: firstCandidate,
                viaText: answer.viaText ?? firstCandidate.excerpt,
                viaKind: answer.viaKind.map(viaKindLabel)
                    ?? viaKindLabel(.parameter),
                targets: [],
                showing: .type,
                pendingExact: true
            ), selected: 0)
            return true
        }
    }

    private func viaKindLabel(_ kind: TypeHopViaKind) -> String {
        switch kind {
        case .parameter: localized("model.typehop.parameter")
        case .letBinding: localized("model.typehop.letBinding")
        case .receiver: localized("model.typehop.receiver")
        case .field: localized("model.typehop.field")
        }
    }

    /// R3: the "跳到类型定义" target for the binding under `offset` without
    /// touching the stage. Fails with a localized reason when there is
    /// nothing to jump to.
    public func typeDefinitionTarget(file: String, offset: UInt32) async -> TypeTargetResult {
        guard case let .ready(session, context) = projectState,
              let pathID = pathID(file, in: session)
        else { return .failed(localized("model.typehop.noType")) }
        guard let typeHopResolver else {
            return .failed(localized("model.typehop.needsExact"))
        }
        guard let answer = try? await typeHopResolver(
            session, pathID, offset, context
        ) else { return .failed(localized("model.typehop.noType")) }
        switch answer.result {
        case let .targets(resolutions, certainty) where !resolutions.isEmpty:
            let targets = await present(resolutions, session: session)
                .map { $0.withCertainty(certainty) }
            guard let target = targets.first else {
                return .failed(localized("model.typehop.noType"))
            }
            return .target(target)
        case let .primitive(name):
            return .failed(localizedFormat("model.typehop.primitiveNote", name))
        case let .genericUnbounded(name):
            return .failed(localizedFormat("model.typehop.genericNote", name))
        case .targets, .none:
            // R3.1 / R1.6: the syntax spells no type here (an inferred
            // binding, a dependency type); the Exact layer may still know.
            return await exactTypeDefinitionTarget(
                file: file, offset: offset, session: session, context: context
            )
        }
    }

    /// The Exact `typeDefinition` answer for the jump command, held to the
    /// same generation and content-drift checks as the lens upgrade. It uses
    /// its own batch so it never cancels the lens's in-flight requests.
    private func exactTypeDefinitionTarget(
        file: String,
        offset: UInt32,
        session: EngineSession,
        context: QueryContext
    ) async -> TypeTargetResult {
        guard let typeDefinitionResolver else {
            return .failed(localized("model.typehop.needsExact"))
        }
        if let notReady = typeDefinitionReadiness?() {
            return .failed(notReady)
        }
        let batch = ExactRequestBatch()
        let result = await typeDefinitionResolver(file, offset, context.generation, batch)
        guard sessionIsCurrent(session, context) else {
            return .failed(localized("model.typehop.noType"))
        }
        switch result {
        case let .completed(entries):
            guard let exact = entries.first,
                  let targetOffset = UInt32(exactly: exact.location.byteOffset)
            else { return .failed(localized("model.typehop.noType")) }
            let targetPath = projectPath(exact.location.file)
            let sourceIsCurrent = await indexContentIsCurrent(file, session: session)
            let targetIsCurrent = await indexContentIsCurrent(targetPath, session: session)
            guard sourceIsCurrent && targetIsCurrent else {
                onStaleIndexContent?(sourceIsCurrent ? targetPath : file)
                return .failed(localized("model.typehop.noType"))
            }
            guard sessionIsCurrent(session, context),
                  let candidate = await exactCandidate(
                      at: targetPath,
                      offset: targetOffset,
                      attribution: exact.attribution,
                      origin: exact.origin,
                      session: session
                  )
            else { return .failed(localized("model.typehop.noType")) }
            return .target(candidate)
        case .cancelled, .unsupported, .unavailable, nil:
            return .failed(localized("model.typehop.needsExact"))
        }
    }

    private func startExactUpgrade(
        _ token: Token,
        session: EngineSession,
        context: QueryContext,
        request: UInt64,
        requestTypeDefinition: Bool = false
    ) {
        guard exactResolver != nil else { return }
        Task { [weak self] in
            await self?.upgradeExact(
                token,
                session: session,
                context: context,
                request: request,
                requestTypeDefinition: requestTypeDefinition
            )
        }
    }

    private func upgradeExact(
        _ token: Token,
        session: EngineSession,
        context: QueryContext,
        request: UInt64,
        requestTypeDefinition: Bool = false
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
        guard requestID == request,
              batch.isCurrent,
              sessionIsCurrent(session, context)
        else {
            finishExactUpgrade(batch)
            // Still this request's stage (the batch was cancelled from
            // outside): a pending type hop must not spin forever.
            if requestID == request { markTypeHopExactUnavailable() }
            return
        }
        if case .completed(let entries) = result {
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
        // P2: the typeDefinition request rides the same batch as the
        // definition upgrade.
        if requestTypeDefinition, let typeDefinitionResolver {
            let typeResult = await typeDefinitionResolver(
                token.file,
                token.offset,
                context.generation,
                batch
            )
            defer { finishExactUpgrade(batch) }
            guard requestID == request,
                  batch.isCurrent,
                  sessionIsCurrent(session, context)
            else {
                if requestID == request { markTypeHopExactUnavailable() }
                return
            }
            switch typeResult {
            case .completed(let entries):
                for exact in entries {
                    await applyTypeDefinition(
                        exact,
                        token: token,
                        session: session,
                        context: context,
                        request: request,
                        selectionEpoch: requestSelectionEpoch
                    )
                }
            case nil, .cancelled, .unsupported, .unavailable:
                // A cancelled batch normally means a newer click already
                // replaced the stage; when it was the final reply, stop the
                // resolving state instead of spinning forever.
                markTypeHopExactUnavailable()
            }
        } else {
            finishExactUpgrade(batch)
        }
    }

    /// P2: the exact layer cannot answer the type hop — surface the
    /// "not ready" status instead of an endless resolving state.
    private func markTypeHopExactUnavailable() {
        guard case let .typeHop(hop, selected) = stage, hop.pendingExact else {
            return
        }
        var updated = hop
        updated.pendingExact = false
        stage = .typeHop(updated, selected: selected)
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

    /// P2: applies a `typeDefinition` reply. In a `.typeHop` stage the
    /// matching target upgrades to Exact in place (never moving the user's
    /// selection) and non-matching targets are inserted at the front; a
    /// pending stage (no syntactic type) is promoted in place (R1.7).
    private func applyTypeDefinition(
        _ exact: ExactOverlay.Entry,
        token: Token,
        session: EngineSession,
        context: QueryContext,
        request: UInt64,
        selectionEpoch requestSelectionEpoch: UInt64
    ) async {
        guard requestID == request,
              sessionIsCurrent(session, context),
              let targetOffset = UInt32(exactly: exact.location.byteOffset)
        else { return }
        let targetPath = projectPath(exact.location.file)
        let sourceIsCurrent = await indexContentIsCurrent(
            token.file,
            session: session
        )
        let targetIsCurrent = await indexContentIsCurrent(
            targetPath,
            session: session
        )
        guard requestID == request,
              sessionIsCurrent(session, context)
        else { return }
        guard sourceIsCurrent && targetIsCurrent else {
            onStaleIndexContent?(
                sourceIsCurrent ? targetPath : token.file
            )
            markTypeHopExactUnavailable()
            return
        }
        // Re-read the stage after every await; replies may interleave with
        // user selection or newer clicks.
        switch stage {
        case let .typeHop(hop, selected):
            var updated = hop
            updated.pendingExact = false
            if let index = updated.targets.firstIndex(where: {
                $0.path == targetPath && $0.targetByteOffset == targetOffset
            }) {
                updated.targets[index] = exactCandidate(
                    upgrading: updated.targets[index],
                    attribution: exact.attribution,
                    origin: exact.origin,
                    language: session.analysisProfile.language
                )
                stage = .typeHop(updated, selected: selected)
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
                  case let .typeHop(latest, latestSelected) = stage
            else { return }
            updated = latest
            updated.pendingExact = false
            let keepsUserChoice = selectionEpoch != requestSelectionEpoch
                && latest.targets.indices.contains(latestSelected)
            updated.targets = [candidate] + latest.targets
            stage = .typeHop(
                updated,
                selected: keepsUserChoice ? latestSelected + 1 : 0
            )
        case let .candidates(current, selected):
            // R1.7: the syntax spelled no type; the Exact answer promotes the
            // lens to the type in place.
            guard current.indices.contains(selected),
                  mode != .pinned,
                  let candidate = await exactCandidate(
                      at: targetPath,
                      offset: targetOffset,
                      attribution: exact.attribution,
                      origin: exact.origin,
                      session: session
                  ),
                  requestID == request,
                  sessionIsCurrent(session, context),
                  case let .candidates(latest, latestSelected) = stage,
                  latest.indices.contains(latestSelected)
            else { return }
            let via = latest[latestSelected]
            stage = .typeHop(TypeHop(
                via: via,
                viaText: via.excerpt,
                viaKind: via.bindingKind ?? viaKindLabel(.parameter),
                targets: [candidate],
                showing: .type
            ), selected: 0)
        case .idle, .indexBuilding, .enclosing:
            return
        }
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
            // Both bind into the target file's bindings.
            if case let .lexicalBinding(bindingIndex) = item { return bindingIndex }
            if case let .memberBinding(bindingIndex) = item { return bindingIndex }
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

/// R3: the outcome of "跳到类型定义" for the symbol under a position.
public enum TypeTargetResult: Sendable {
    case target(ContextWindowModel.Candidate)
    case failed(String)
}
