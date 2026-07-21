import CodeInsightCore
import CodeInsightEngine
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
        public let symbol: SymbolOccurrenceID
        public let path: String
        public let line: UInt32
        public let column: UInt32
        public let label: String
        public let excerpt: String
        public let bindingKind: String?
        public let targetByteOffset: UInt32
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
    }

    typealias Resolver = @MainActor (
        EngineSession,
        PathID,
        UInt32,
        QueryContext
    ) async throws -> [ResolutionCandidate]
    typealias Loader = @Sendable (URL) async -> ReaderDocument?

    public private(set) var mode: Mode = .follow
    public private(set) var stage: Stage = .idle
    public private(set) var requestID: UInt64 = 0

    private let resolver: Resolver
    private let loader: Loader
    private var projectState: ProjectState = .empty
    private var root: URL?
    private var contentSource: DocumentLoader.ContentSource?
    private var pendingToken: Token?
    private var locatedToken: LocatedToken?
    private var documents: [DocumentKey: ReaderDocument] = [:]
    private var documentRecency: [DocumentKey] = []

    public init() {
        resolver = { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        }
        loader = loadReaderDocument
    }

    init(
        _ resolver: @escaping Resolver,
        loader: @escaping Loader = loadReaderDocument
    ) {
        self.resolver = resolver
        self.loader = loader
    }

    public var selectedCandidate: Candidate? {
        guard case let .candidates(candidates, selected) = stage,
              candidates.indices.contains(selected)
        else { return nil }
        return candidates[selected]
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
        if mode == .pinned, self.mode != .pinned {
            requestID &+= 1
            pendingToken = nil
            locatedToken = nil
        }
        self.mode = mode
    }

    public func updateProjectState(
        _ state: ProjectState,
        root: URL?,
        contentSource: DocumentLoader.ContentSource? = nil
    ) {
        let normalizedRoot = root?.standardizedFileURL
        if self.root != normalizedRoot {
            pendingToken = nil
        }
        self.root = normalizedRoot
        self.contentSource = contentSource
        projectState = state

        switch state {
        case .indexing:
            requestID &+= 1
            locatedToken = nil
            stage = .indexBuilding
        case .ready:
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
            pendingToken = nil
            locatedToken = nil
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
        guard case let .ready(session, context) = projectState,
              let pathID = pathID(file, in: session)
        else { return nil }
        return try? await resolveCandidates(
            session: session,
            pathID: pathID,
            offset: offset,
            context: context
        ).first
    }

    public func selectNext() {
        guard case let .candidates(candidates, selected) = stage,
              !candidates.isEmpty
        else { return }
        stage = .candidates(candidates, selected: (selected + 1) % candidates.count)
    }

    public func selectPrevious() {
        guard case let .candidates(candidates, selected) = stage,
              !candidates.isEmpty
        else { return }
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
            guard let index = contentIndex(at: resolution.target.pathID, in: session)
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
                    targetRange = call.range
                    targetOffset = call.range.lowerBound
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
                text = "external crate — not resolved (M1)"
            } else if let contentID = contentID(
                at: resolution.target.pathID,
                in: session
            ), let document = await document(
                path: path,
                contentID: contentID
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
                label: "\(resolutionCertaintyLabel(resolution.certainty))·\(resolutionDispatchLabel(resolution.dispatch))",
                excerpt: text,
                bindingKind: bindingKind,
                targetByteOffset: targetOffset
            ))
        }
        return candidates
    }

    private func pathID(_ path: String, in session: EngineSession) -> PathID? {
        session.manifest.files.first {
            session.paths.resolve($0.pathID) == path
        }?.pathID
    }

    private func contentIndex(at pathID: PathID, in session: EngineSession) -> ContentIndex? {
        guard let file = session.manifest.files.first(where: { $0.pathID == pathID })
        else { return nil }
        return session.contentIndexes.first {
            $0.key.contentID == file.contentID
                && $0.key.languageMode.language == file.detectedLanguage
        }?.value
    }

    private func contentID(at pathID: PathID, in session: EngineSession) -> ContentID? {
        session.manifest.files.first { $0.pathID == pathID }?.contentID
    }

    private func document(
        path: String,
        contentID: ContentID
    ) async -> ReaderDocument? {
        let key = DocumentKey(path: path, contentID: contentID)
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
                try? DocumentLoader(source: contentSource).load(file: file).document
            }.value
        } else {
            loaded = await loader(file)
        }
        guard let loaded else { return nil }
        documents[key] = loaded
        documentRecency.append(key)
        if documentRecency.count > 8 {
            documents.removeValue(forKey: documentRecency.removeFirst())
        }
        return loaded
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
        case .param: "param"
        case .letBinding: "letBinding"
        case .importBinding: "importBinding"
        case .assignment: "assignment"
        case .patternBinding: "patternBinding"
        case .globalDecl: "globalDecl"
        case .nonlocalDecl: "nonlocalDecl"
        }
    }
}

private func loadReaderDocument(at file: URL) async -> ReaderDocument? {
    await Task.detached(priority: .userInitiated) {
        try? DocumentLoader().load(file: file).document
    }.value
}

func resolutionCertaintyLabel(_ certainty: Certainty) -> String {
    switch certainty {
    case .unresolved: "Unresolved"
    case .possible: "Possible"
    case .probable: "Probable"
    case .strong: "Strong"
    case .exact: "Exact"
    }
}

func resolutionDispatchLabel(_ dispatch: DispatchKind) -> String {
    switch dispatch {
    case .direct: "direct"
    case .virtualDispatch: "virtual"
    case .traitDispatch: "trait"
    case .interfaceDispatch: "interface"
    case .callback: "callback"
    case .dynamicDispatch: "dynamic"
    case .macroGenerated: "macroGenerated"
    }
}
