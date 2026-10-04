import CodeInsightCore
import CodeInsightExact
import CodeInsightReaderCore
import Testing
@testable import CodeInsightAppModel

@MainActor
@Test
func hoverDwellShowsSyntacticDocThenExactReplacesItInPlace() async {
    let harness = HoverHarness()
    harness.model.pointerMoved(over: tokenA)
    await settle()
    #expect(harness.model.phase == .dwelling(tokenA))
    #expect(harness.syntacticCalls.isEmpty)
    #expect(harness.clock.pending == [SymbolHoverModel.dwell])

    await harness.clock.advance()
    guard case let .showing(token, fallback) = harness.model.phase else {
        Issue.record("expected fallback card, got \(harness.model.phase)")
        return
    }
    #expect(token == tokenA)
    #expect(fallback.source == .syntactic)
    #expect(fallback.notes == [.exactPending])

    await harness.releaseExact(.completed(
        "```rust\ncairn_git::snapshot\n```\n\n```rust\npub fn open()\n```\n\n---\n\nOpens it.",
        limitations: [.procMacrosDisabled]
    ))
    #expect(harness.model.phase == .showing(tokenA, SymbolDoc(
        location: "cairn_git::snapshot",
        signature: "pub fn open()",
        signatureLanguage: "rust",
        markdown: "Opens it.",
        source: .exact
    )))
}

@MainActor
@Test
func hoverMovesInsideOneTokenWithoutRestartingAndCancelsWhenLeavingEarly() async {
    let harness = HoverHarness()
    harness.model.pointerMoved(over: tokenA)
    harness.model.pointerMoved(over: tokenA)
    await settle()
    #expect(harness.clock.pending.count == 1)

    harness.model.pointerMoved(over: nil)
    await harness.clock.advance()
    #expect(harness.model.phase == .idle)
    #expect(harness.syntacticCalls.isEmpty)
    #expect(harness.exactCalls.isEmpty)
}

@MainActor
@Test
func hoverSwitchingTokensCancelsTheInFlightExactRequest() async {
    let harness = HoverHarness()
    harness.model.pointerMoved(over: tokenA)
    await harness.clock.advance()
    let firstBatch = try? #require(harness.exactCalls.first?.1)
    #expect(firstBatch?.isCurrent == true)

    harness.model.pointerMoved(over: tokenB)
    await settle()
    #expect(harness.clock.pending.sorted() == [SymbolHoverModel.grace, SymbolHoverModel.switchDwell])
    await harness.clock.advance()
    #expect(firstBatch?.isCurrent == false)
    #expect(harness.model.shownToken == tokenB)
}

@MainActor
@Test
func hoverDismissesOnEscapeAndServesRepeatsFromCache() async {
    let harness = HoverHarness()
    harness.model.pointerMoved(over: tokenA)
    await harness.clock.advance()
    await harness.releaseExact(.completed("Docs.", limitations: []))
    harness.model.dismiss()
    #expect(harness.model.phase == .idle)

    harness.model.pointerMoved(over: tokenA)
    await harness.clock.advance()
    #expect(harness.model.shownToken == tokenA)
    #expect(harness.syntacticCalls.count == 1)
    #expect(harness.exactCalls.count == 1)

    let otherRevision = SymbolHoverModel.Token(
        file: tokenA.file,
        contentID: ContentID(algorithm: 1, bytes: [2]),
        range: tokenA.range
    )
    harness.model.dismiss()
    harness.model.pointerMoved(over: otherRevision)
    await harness.clock.advance()
    #expect(harness.syntacticCalls.count == 2)
}

@Test
func hoverMarkdownSplitsLocationSignatureAndBody() {
    #expect(symbolDoc(fromHoverMarkdown: "```rust\npub struct Oid\n```") == SymbolDoc(
        signature: "pub struct Oid",
        signatureLanguage: "rust",
        source: .exact
    ))
    #expect(symbolDoc(fromHoverMarkdown: "```rust\nstd::collections\n```\n\n```rust\npub struct HashMap<K, V>\n```\n\n---\n\nsize = 48\n\n---\n\nA hash map.\n\n```rust\nlet m = HashMap::new();\n```") == SymbolDoc(
        location: "std::collections",
        signature: "pub struct HashMap<K, V>",
        signatureLanguage: "rust",
        markdown: "size = 48\n\n---\n\nA hash map.\n\n```rust\nlet m = HashMap::new();\n```",
        source: .exact
    ))
    #expect(symbolDoc(fromHoverMarkdown: "Plain docs only.") == SymbolDoc(
        markdown: "Plain docs only.",
        source: .exact
    ))
}

@Test
func hoverMarkdownSplitsPyrightAndTypeScriptServerShapes() {
    // pyright: one signature fence with a declaration-kind prefix, then a
    // `---` separator before the docstring body.
    #expect(symbolDoc(
        fromHoverMarkdown: """
        ```python
        (function) def format_name(
            user: str,
            greeting: str = "Hello"
        ) -> str
        ```
        ---
        Format a greeting for `user`.

        Args:
            user: the user name.
        """,
        language: .python
    ) == SymbolDoc(
        signature: """
        def format_name(
            user: str,
            greeting: str = "Hello"
        ) -> str
        """,
        signatureLanguage: "python",
        markdown: """
        Format a greeting for `user`.

        Args:
            user: the user name.
        """,
        source: .exact
    ))
    // typescript-language-server prefixes most kinds too, some with spaces.
    for (fenced, expected) in [
        ("(property) Store.id: number", "Store.id: number"),
        ("(local var) retries: number", "retries: number"),
        ("(alias) readFileSync(path: string): Buffer\nimport readFileSync",
         "readFileSync(path: string): Buffer\nimport readFileSync"),
    ] {
        #expect(symbolDoc(
            fromHoverMarkdown: "```typescript\n\(fenced)\n```\nDocs.",
            language: .typescript
        ).signature == expected)
    }
    // A signature that merely opens with parentheses is not a kind prefix.
    #expect(symbolDoc(
        fromHoverMarkdown: "```python\n(...args) -> None\n```\n\nDocs.",
        language: .python
    ) == SymbolDoc(
        signature: "(...args) -> None",
        signatureLanguage: "python",
        markdown: "Docs.",
        source: .exact
    ))
    // typescript-language-server: no separator line, JSDoc already rendered.
    #expect(symbolDoc(
        fromHoverMarkdown: """
        ```typescript
        function loadStore(id: number): Promise<Store>
        ```
        Loads the store.

        *@param* `id` — the store id
        """,
        language: .typescript
    ) == SymbolDoc(
        signature: "function loadStore(id: number): Promise<Store>",
        signatureLanguage: "typescript",
        markdown: """
        Loads the store.

        *@param* `id` — the store id
        """,
        source: .exact
    ))
    #expect(symbolDoc(
        fromHoverMarkdown: "Plain docs only.",
        language: .typescript
    ) == SymbolDoc(
        markdown: "Plain docs only.",
        source: .exact
    ))
}

// MARK: - Harness

private let tokenA = SymbolHoverModel.Token(
    file: "src/snapshot.rs",
    contentID: ContentID(algorithm: 1, bytes: [1]),
    range: ByteRange(lowerBound: 10, upperBound: 14)
)
private let tokenB = SymbolHoverModel.Token(
    file: "src/snapshot.rs",
    contentID: ContentID(algorithm: 1, bytes: [1]),
    range: ByteRange(lowerBound: 30, upperBound: 37)
)

@MainActor
private final class ManualClock {
    private var waiters: [(Duration, CheckedContinuation<Void, Never>)] = []

    var pending: [Duration] { waiters.map(\.0) }

    func wait(_ duration: Duration) async {
        await withCheckedContinuation { waiters.append((duration, $0)) }
    }

    func advance() async {
        await settle()
        let ready = waiters
        waiters.removeAll()
        for (_, continuation) in ready { continuation.resume() }
        await settle()
    }
}

@MainActor
private final class HoverHarness {
    let clock = ManualClock()
    var syntacticCalls: [SymbolHoverModel.Token] = []
    var exactCalls: [(SymbolHoverModel.Token, ExactRequestBatch)] = []
    private var exactGates: [CheckedContinuation<ExactCoordinator.HoverResult?, Never>] = []
    var probeCalls = 0
    private(set) var model: SymbolHoverModel!

    init(fallback: SymbolDoc? = SymbolDoc(
        location: "snapshot.rs:21",
        signature: "pub fn open()",
        markdown: "Opens it.",
        source: .syntactic
    ), sourceMissing: Bool = false) {
        let clock = clock
        model = SymbolHoverModel(
            syntactic: { [unowned self] token in
                self.syntacticCalls.append(token)
                return fallback
            },
            exact: { [unowned self] token, batch in
                self.exactCalls.append((token, batch))
                return await withCheckedContinuation { self.exactGates.append($0) }
            },
            dependencyProbe: { [unowned self] _ in
                self.probeCalls += 1
                return sourceMissing
            },
            sleep: { duration in await clock.wait(duration) }
        )
    }

    func releaseExact(_ result: ExactCoordinator.HoverResult?) async {
        await settle()
        for gate in exactGates { gate.resume(returning: result) }
        exactGates.removeAll()
        await settle()
    }
}

@MainActor
private func settle() async {
    for _ in 0..<40 { await Task.yield() }
}
