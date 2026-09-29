import CodeInsightCore
import CodeInsightExact
import CodeInsightReaderCore
import Foundation
import Observation

/// Drives the hover documentation card: dwell timing, the grace period
/// between the symbol and the card, and replacing the syntactic fallback with
/// the exact result in place. Pointer tracking only reports tokens; no query
/// runs until the pointer has settled for `dwell`.
@MainActor
@Observable
public final class SymbolHoverModel {
    public struct Token: Hashable, Sendable {
        public let file: String
        /// Distinguishes revisions of the same path so cached docs never leak
        /// across them, and lets queries refuse content the index never saw.
        public let contentID: ContentID
        public let lowerBound: UInt32
        public let upperBound: UInt32
        /// The displayed document the token was read from. Not part of the
        /// token's identity.
        public let document: ReaderDocument?

        public init(
            file: String,
            contentID: ContentID,
            range: ByteRange,
            document: ReaderDocument? = nil
        ) {
            self.file = file
            self.contentID = contentID
            lowerBound = range.lowerBound
            upperBound = range.upperBound
            self.document = document
        }

        public var range: ByteRange {
            ByteRange(lowerBound: lowerBound, upperBound: upperBound)
        }

        public static func == (lhs: Token, rhs: Token) -> Bool {
            lhs.file == rhs.file && lhs.contentID == rhs.contentID
                && lhs.lowerBound == rhs.lowerBound && lhs.upperBound == rhs.upperBound
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(file)
            hasher.combine(contentID)
            hasher.combine(lowerBound)
            hasher.combine(upperBound)
        }
    }

    public enum Phase: Equatable {
        case idle
        case dwelling(Token)
        case showing(Token, SymbolDoc)
    }

    typealias Syntactic = @MainActor (Token) async -> SymbolDoc?
    typealias Exact = @MainActor (
        Token,
        ExactRequestBatch
    ) async -> ExactCoordinator.HoverResult?
    typealias Sleep = @Sendable (Duration) async -> Void
    /// Whether the symbol names a dependency whose source is not cached
    /// locally; asked only when neither layer found anything.
    typealias DependencyProbe = @MainActor (Token) async -> Bool

    public static let dwell: Duration = .milliseconds(500)
    public static let switchDwell: Duration = .milliseconds(250)
    public static let grace: Duration = .milliseconds(250)
    static let cacheLimit = 64

    public private(set) var phase: Phase = .idle
    /// The "show documentation on hover" setting. Explicit requests (⌥-click,
    /// menu command) ignore it.
    public var isHoverEnabled = true {
        didSet { if !isHoverEnabled, case .dwelling = phase { dismiss() } }
    }

    @ObservationIgnored private var syntactic: Syntactic?
    @ObservationIgnored private var exact: Exact?
    @ObservationIgnored private var dependencyProbe: DependencyProbe?
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    @ObservationIgnored private var exactBatch: ExactRequestBatch?
    @ObservationIgnored private var requestID: UInt64 = 0
    @ObservationIgnored private var pointerInCard = false
    @ObservationIgnored private var cache: [Token: SymbolDoc] = [:]
    @ObservationIgnored private var cacheOrder: [Token] = []

    public init() {
        sleep = { duration in try? await Task.sleep(for: duration) }
    }

    init(
        syntactic: @escaping Syntactic,
        exact: Exact?,
        dependencyProbe: DependencyProbe? = nil,
        sleep: @escaping Sleep
    ) {
        self.syntactic = syntactic
        self.exact = exact
        self.dependencyProbe = dependencyProbe
        self.sleep = sleep
    }

    func attach(
        syntactic: @escaping Syntactic,
        exact: Exact?,
        dependencyProbe: DependencyProbe? = nil
    ) {
        self.syntactic = syntactic
        self.exact = exact
        self.dependencyProbe = dependencyProbe
    }

    public var shownToken: Token? {
        if case let .showing(token, _) = phase { return token }
        return nil
    }

    // MARK: - Pointer events

    /// The pointer moved over the reader. `token` is the identifier under it,
    /// or `nil` over anything that must not trigger a card.
    public func pointerMoved(over token: Token?) {
        guard isHoverEnabled || shownToken != nil else { return }
        guard let token else {
            cancelDwell()
            if case .dwelling = phase { phase = .idle }
            if shownToken != nil { scheduleClose() }
            return
        }
        if shownToken == token {
            cancelDwell()
            cancelClose()
            return
        }
        if case .dwelling(let pending) = phase, pending == token { return }
        if let pendingDwell = dwellTarget, pendingDwell == token { return }
        guard isHoverEnabled else {
            scheduleClose()
            return
        }
        let delay = shownToken == nil ? Self.dwell : Self.switchDwell
        if shownToken == nil { phase = .dwelling(token) } else { scheduleClose() }
        startDwell(token, after: delay)
    }

    public func pointerExitedText() {
        cancelDwell()
        if case .dwelling = phase { phase = .idle }
        if shownToken != nil { scheduleClose() }
    }

    public func pointerEnteredCard() {
        pointerInCard = true
        cancelClose()
        cancelDwell()
    }

    public func pointerExitedCard() {
        pointerInCard = false
        scheduleClose()
    }

    /// ⌥-click or the menu command: show immediately, even with hover off.
    public func showNow(_ token: Token) {
        cancelDwell()
        cancelClose()
        Task { await self.present(token) }
    }

    /// Escape, scrolling, switching files or losing focus.
    public func dismiss() {
        cancelDwell()
        cancelClose()
        cancelExact()
        requestID &+= 1
        pointerInCard = false
        phase = .idle
    }

    // MARK: - Timing

    @ObservationIgnored private var dwellTarget: Token?

    private func startDwell(_ token: Token, after delay: Duration) {
        dwellTask?.cancel()
        dwellTarget = token
        let sleep = sleep
        dwellTask = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self, self.dwellTarget == token else {
                return
            }
            self.dwellTarget = nil
            await self.present(token)
        }
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
        dwellTarget = nil
    }

    private func scheduleClose() {
        guard closeTask == nil else { return }
        let sleep = sleep
        closeTask = Task { [weak self] in
            await sleep(Self.grace)
            guard !Task.isCancelled, let self else { return }
            self.closeTask = nil
            guard !self.pointerInCard else { return }
            self.dismissKeepingDwell()
        }
    }

    private func cancelClose() {
        closeTask?.cancel()
        closeTask = nil
    }

    /// Closes the card but lets a dwell on another token continue.
    private func dismissKeepingDwell() {
        cancelExact()
        requestID &+= 1
        if let dwellTarget { phase = .dwelling(dwellTarget) } else { phase = .idle }
    }

    // MARK: - Resolution

    private func present(_ token: Token) async {
        cancelExact()
        cancelClose()
        requestID &+= 1
        let request = requestID
        if let cached = cache[token] {
            touch(token)
            phase = .showing(token, cached)
            return
        }
        phase = .dwelling(token)
        let fallback = await syntactic?(token)
        guard requestID == request else { return }
        guard let exact else {
            finish(token, doc: fallback, request: request)
            return
        }
        if var fallback, !fallback.isEmpty {
            fallback.notes = [.exactPending]
            phase = .showing(token, fallback)
        }
        // With nothing syntactic to show, a missing dependency source is known
        // from local files long before a cold language server answers.
        var missingSource = false
        if fallback?.isEmpty ?? true, let dependencyProbe {
            missingSource = await dependencyProbe(token)
            guard requestID == request else { return }
            if missingSource {
                phase = .showing(token, SymbolDoc(source: .syntactic, notes: [.dependencySourceMissing]))
            }
        }
        let batch = ExactRequestBatch()
        exactBatch = batch
        let result = await exact(token, batch)
        guard requestID == request, batch.isCurrent else { return }
        exactBatch = nil
        finish(
            token,
            doc: merge(result, fallback: fallback, missingSource: missingSource),
            request: request,
            cacheable: Self.isFinal(result)
        )
    }

    private func finish(
        _ token: Token,
        doc: SymbolDoc?,
        request: UInt64,
        cacheable: Bool = true
    ) {
        guard requestID == request else { return }
        guard let doc, !(doc.isEmpty && doc.notes.isEmpty) else {
            phase = .idle
            return
        }
        // A language server that timed out or was cancelled may answer on the
        // next hover; only final answers are remembered.
        if cacheable { store(doc, for: token) }
        phase = .showing(token, doc)
    }

    private static func isFinal(_ result: ExactCoordinator.HoverResult?) -> Bool {
        switch result {
        case .completed, .unsupported: true
        case .unavailable, .cancelled, nil: false
        }
    }

    /// A timed-out request means the server is still warming up, which the
    /// reader knows as "not ready yet" rather than a failure.
    private static func unavailableNote(_ reason: String) -> SymbolDoc.Note {
        reason.contains("timeout") ? .exactPending : .exactUnavailable(reason)
    }

    private func merge(
        _ result: ExactCoordinator.HoverResult?,
        fallback: SymbolDoc?,
        missingSource: Bool
    ) -> SymbolDoc? {
        let fallback = fallback.flatMap { $0.isEmpty ? nil : $0 }
        switch result {
        case .completed(let markdown?, let limitations):
            var doc = symbolDoc(fromHoverMarkdown: markdown)
            if doc.location == nil { doc.location = fallback?.location }
            if doc.isEmpty, let fallback { doc = fallback }
            doc.source = .exact
            doc.notes = doc.isEmpty ? limitationNotes(limitations) : []
            return doc
        case .completed(nil, let limitations):
            if var fallback {
                fallback.notes = limitationNotes(limitations)
                return fallback
            }
            if missingSource || limitations.contains(.dependenciesUnavailableOffline) {
                return SymbolDoc(source: .exact, notes: [.dependencySourceMissing])
            }
            return nil
        case .unsupported:
            return fallback ?? missingSourceDoc(missingSource)
        case .unavailable(let reason):
            guard var fallback else {
                return SymbolDoc(
                    source: .exact,
                    notes: [missingSource ? .dependencySourceMissing : Self.unavailableNote(reason)]
                )
            }
            fallback.notes = [Self.unavailableNote(reason)]
            return fallback
        case .cancelled, nil:
            return fallback ?? missingSourceDoc(missingSource)
        }
    }

    private func missingSourceDoc(_ missingSource: Bool) -> SymbolDoc? {
        missingSource ? SymbolDoc(source: .syntactic, notes: [.dependencySourceMissing]) : nil
    }

    private func limitationNotes(
        _ limitations: Set<ExactAnalysisLimitation>
    ) -> [SymbolDoc.Note] {
        limitations.map(\.rawValue).sorted().map(SymbolDoc.Note.limitation)
    }

    private func cancelExact() {
        exactBatch?.cancel()
        exactBatch = nil
    }

    private func store(_ doc: SymbolDoc, for token: Token) {
        if cache.updateValue(doc, forKey: token) == nil {
            cacheOrder.append(token)
            if cacheOrder.count > Self.cacheLimit {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        } else {
            touch(token)
        }
    }

    private func touch(_ token: Token) {
        guard let index = cacheOrder.firstIndex(of: token) else { return }
        cacheOrder.append(cacheOrder.remove(at: index))
    }
}

/// Splits rust-analyzer hover Markdown into the card's parts. Leading fenced
/// blocks are the module path (when two are present) and the signature; the
/// rest, after `---` separators, is the body.
public func symbolDoc(fromHoverMarkdown markdown: String) -> SymbolDoc {
    var rest = Substring(markdown)
    var fences: [(language: String, body: String)] = []
    while fences.count < 2 {
        let trimmed = rest.drop { $0 == "\n" || $0 == " " }
        guard trimmed.hasPrefix("```"),
              let infoEnd = trimmed.firstIndex(of: "\n")
        else { break }
        let language = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<infoEnd]
            .trimmingCharacters(in: .whitespaces)
        let bodyStart = trimmed.index(after: infoEnd)
        guard let close = trimmed[bodyStart...].range(of: "\n```") else { break }
        fences.append((language, String(trimmed[bodyStart..<close.lowerBound])))
        rest = trimmed[close.upperBound...]
        if rest.hasPrefix("\n") || rest.isEmpty {
            continue
        }
        break
    }
    var body = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    while body.hasPrefix("---") {
        body = String(body.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let location = fences.count == 2 ? fences[0].body : nil
    let signature = fences.last
    return SymbolDoc(
        location: location,
        signature: signature?.body,
        signatureLanguage: signature.map { $0.language.isEmpty ? "rust" : $0.language },
        markdown: linkingIntraDocReferences(body),
        source: .exact
    )
}

