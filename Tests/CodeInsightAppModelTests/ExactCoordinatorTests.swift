import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightGit
import Foundation
import Testing
@testable import CodeInsightAppModel

@MainActor
@Test
func exactCoordinatorPreparesOpportunistically() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let coordinator = fixture.coordinator(state: state)

    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)

    #expect(await exactWaitUntil { coordinator.readiness == .ready })
    #expect(state.prepareCount == 1)
}

@MainActor
@Test
func exactCoordinatorRestartsOneCrashThenBecomesUnavailable() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState { _, _, _ in
        throw LSPError.processExited(9, "test crash")
    }
    let coordinator = fixture.coordinator(state: state)
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await exactWaitUntil { coordinator.readiness == .ready })

    let result = await coordinator.definition(
        file: "main.rs",
        byteOffset: 0,
        generation: 1
    )

    #expect(result == nil)
    #expect(state.prepareCount == 2)
    #expect(state.definitionCount == 2)
    guard case .unavailable = coordinator.readiness else {
        Issue.record("coordinator did not exhaust the single restart")
        return
    }
}

@MainActor
@Test
func exactCoordinatorTurnsOffSafeModeWithoutSandbox() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let coordinator = fixture.coordinator(
        state: state,
        sandboxAvailable: { false }
    )

    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)

    #expect(await exactWaitUntil {
        if case .off = coordinator.readiness { return true }
        return false
    })
    #expect(state.prepareCount == 0)
}

@MainActor
@Test
func exactOverlayReusesVersionProfileAndToolButNotSnapshotID() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let versions = ExactVersionBox("fake-1")
    let snapshots = ExactSnapshotFactoryState(files: fixture.files)
    let coordinator = ExactCoordinator(
        providerFactory: { _ in
            ExactTestProvider(toolVersion: versions.value, state: state)
        },
        snapshotFactory: snapshots.make,
        sandboxAvailable: { true },
        trustRegistry: fixture.trustRegistry
    )

    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await exactWaitUntil { coordinator.readiness == .ready })
    #expect(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: 1
    ) != nil)

    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 2)
    #expect(await exactWaitUntil { coordinator.readiness == .ready })
    #expect(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: 2
    ) != nil)
    #expect(state.definitionCount == 1)
    #expect(Set(snapshots.snapshotIDs).count == 2)

    versions.value = "fake-2"
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 3)
    #expect(await exactWaitUntil { coordinator.readiness == .ready })
    #expect(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: 3
    ) != nil)
    #expect(state.definitionCount == 2)

    try "[package]\nname='changed'\nversion='0.1.0'\n".write(
        to: fixture.root.appendingPathComponent("Cargo.toml"),
        atomically: true,
        encoding: .utf8
    )
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 4)
    #expect(await exactWaitUntil { coordinator.readiness == .ready })
    #expect(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: 4
    ) != nil)
    #expect(state.definitionCount == 3)
}

@MainActor
@Test
func exactCoordinatorInvalidatesAnOlderSnapshotResult() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let blocker = BlockingExactSession()
    let coordinator = ExactCoordinator(
        providerFactory: { _ in BlockingExactProvider(session: blocker) },
        snapshotFactory: ExactSnapshotFactoryState(files: fixture.files).make,
        sandboxAvailable: { true },
        trustRegistry: fixture.trustRegistry
    )
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await exactWaitUntil { coordinator.readiness == .ready })

    let request = Task {
        await coordinator.definition(file: "main.rs", byteOffset: 0, generation: 1)
    }
    #expect(await exactWaitUntil { blocker.started })
    coordinator.invalidate(generation: 2)
    blocker.release()

    #expect(await request.value == nil)
}

@MainActor
@Test
func contextExactUpgradeKeepsEveryFuzzyCandidateAndSelectsExact() async throws {
    let source = """
        struct A; impl A { fn close(&self) {} }
        struct B; impl B { fn close(&self) {} }
        fn f(value: A) { value.close(); }
        """
    let root = try exactTemporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = exactQueryContext(for: session, generation: 1)
    let gate = ContextExactGate()
    let model = ContextWindowModel(
        { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        },
        exactResolver: gate.resolve
    )
    model.updateProjectState(.ready(session, context), root: root)
    let callOffset = exactByteOffset(of: "close();", in: source)
    let secondDefinition = exactByteOffset(
        of: "close(&self)",
        in: String(source[source.range(of: "struct B")!.lowerBound...])
    ) + exactByteOffset(of: "struct B", in: source)

    model.tokenClicked(file: "main.rs", offset: callOffset)
    #expect(await exactWaitUntil { model.candidateCount == 2 && gate.count == 1 })
    let fuzzySymbols = exactSymbols(model)
    #expect(model.selectedCandidate?.provenanceBadge.contains("Exact") == false)

    gate.complete(0, with: exactEntry(
        file: "main.rs",
        byteOffset: secondDefinition
    ))

    #expect(await exactWaitUntil {
        model.selectedCandidate?.provenanceBadge.contains("Exact") == true
    })
    #expect(model.candidateCount == 2)
    #expect(Set(exactSymbols(model)) == Set(fuzzySymbols))
    #expect(model.selectedCandidate?.targetByteOffset == secondDefinition)
    #expect(model.selectedCandidate?.certainty == .exact)
    #expect(model.selectedCandidate?.exactAttribution?.coverage == .partial)
    guard case .lsp = model.selectedCandidate?.provenance else {
        Issue.record("exact candidate did not carry LSP provenance")
        return
    }
}

@MainActor
@Test
func contextExactUpgradeRejectsStaleRequestAndGeneration() async throws {
    let source = "fn alpha() {}\nfn beta() {}\nfn main() { alpha(); beta(); }"
    let root = try exactTemporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = exactQueryContext(for: session, generation: 1)
    let gate = ContextExactGate()
    let model = ContextWindowModel(
        { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        },
        exactResolver: gate.resolve
    )
    model.updateProjectState(.ready(session, context), root: root)
    let alphaCall = exactByteOffset(of: "alpha();", in: source)
    let betaCall = exactByteOffset(of: "beta();", in: source)
    let alphaDefinition = exactByteOffset(of: "alpha() {}", in: source)
    let betaDefinition = exactByteOffset(of: "beta() {}", in: source)

    model.tokenClicked(file: "main.rs", offset: alphaCall)
    #expect(await exactWaitUntil { gate.count == 1 })
    model.tokenClicked(file: "main.rs", offset: betaCall)
    #expect(await exactWaitUntil { gate.count == 2 })
    gate.complete(0, with: exactEntry(
        file: "main.rs",
        byteOffset: alphaDefinition
    ))
    for _ in 0..<10 { await Task.yield() }
    #expect(model.selectedCandidate?.targetByteOffset == betaDefinition)
    #expect(model.selectedCandidate?.certainty != .exact)

    model.updateProjectState(
        .ready(session, exactQueryContext(for: session, generation: 2)),
        root: root
    )
    gate.complete(1, with: exactEntry(
        file: "main.rs",
        byteOffset: betaDefinition
    ))
    for _ in 0..<10 { await Task.yield() }
    #expect(model.selectedCandidate?.targetByteOffset == betaDefinition)
    #expect(model.selectedCandidate?.certainty != .exact)
}

@MainActor
@Test
func pinnedContextOnlyUpgradesItsDisplayedTargetInPlace() async throws {
    let source = "fn alpha() {}\nfn beta() {}\nfn main() { alpha(); beta(); }"
    let root = try exactTemporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = exactQueryContext(for: session, generation: 1)
    let gate = ContextExactGate()
    let model = ContextWindowModel(
        { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        },
        exactResolver: gate.resolve
    )
    model.updateProjectState(.ready(session, context), root: root)
    let alphaCall = exactByteOffset(of: "alpha();", in: source)
    let alphaDefinition = exactByteOffset(of: "alpha() {}", in: source)
    let betaDefinition = exactByteOffset(of: "beta() {}", in: source)
    model.tokenClicked(file: "main.rs", offset: alphaCall)
    #expect(await exactWaitUntil { model.candidateCount == 1 && gate.count == 1 })
    let original = try #require(model.selectedCandidate)

    model.setMode(.pinned)
    #expect(await exactWaitUntil { gate.count == 2 })
    gate.complete(1, with: exactEntry(
        file: "main.rs",
        byteOffset: betaDefinition
    ))
    for _ in 0..<10 { await Task.yield() }
    #expect(model.selectedCandidate?.symbol == original.symbol)
    #expect(model.selectedCandidate?.targetByteOffset == original.targetByteOffset)
    #expect(model.candidateCount == 1)
    #expect(model.selectedCandidate?.certainty != .exact)

    model.setMode(.follow)
    model.setMode(.pinned)
    #expect(await exactWaitUntil { gate.count == 3 })
    gate.complete(2, with: exactEntry(
        file: "main.rs",
        byteOffset: alphaDefinition
    ))
    #expect(await exactWaitUntil { model.selectedCandidate?.certainty == .exact })
    #expect(model.selectedCandidate?.symbol == original.symbol)
    #expect(model.selectedCandidate?.targetByteOffset == original.targetByteOffset)
    #expect(model.candidateCount == 1)

    gate.complete(0, with: exactEntry(
        file: "main.rs",
        byteOffset: betaDefinition
    ))
    for _ in 0..<10 { await Task.yield() }
    #expect(model.selectedCandidate?.symbol == original.symbol)
    #expect(model.selectedCandidate?.targetByteOffset == original.targetByteOffset)
    #expect(model.candidateCount == 1)
}

private final class ExactTestProvider: ExactProvider, @unchecked Sendable {
    let capabilities: ExactCapabilities = [.definition]
    let toolVersion: String
    private let state: ExactProviderState

    init(toolVersion: String = "fake-1", state: ExactProviderState) {
        self.toolVersion = toolVersion
        self.state = state
    }

    func prepare(
        snapshot: any Snapshot,
        profile: ExactProfileKey,
        trustMode: TrustMode
    ) throws -> any ExactSession {
        state.makeSession(
            attribution: ExactAttribution(
                provider: "fake-exact",
                toolVersion: toolVersion,
                configFingerprint: profile.configFingerprint,
                environmentFingerprint: profile.environmentFingerprint,
                trustMode: trustMode,
                generatedAt: Date(timeIntervalSince1970: 0),
                coverage: trustMode == .safe ? .partial : .full
            )
        )
    }
}

private final class ExactProviderState: @unchecked Sendable {
    typealias Behavior = @Sendable (Int, String, Int) throws -> ExactLocation?

    private let lock = NSLock()
    private let behavior: Behavior
    private var prepares = 0
    private var definitions = 0

    init(
        behavior: @escaping Behavior = { _, _, _ in
            ExactLocation(file: "main.rs", byteOffset: 0, line: 1, column: 1)
        }
    ) {
        self.behavior = behavior
    }

    var prepareCount: Int { locked { prepares } }
    var definitionCount: Int { locked { definitions } }

    func makeSession(attribution: ExactAttribution) -> ExactStateSession {
        let ordinal = locked {
            prepares += 1
            return prepares
        }
        return ExactStateSession(
            attribution: attribution,
            ordinal: ordinal,
            state: self
        )
    }

    func define(ordinal: Int, file: String, byteOffset: Int) throws -> ExactLocation? {
        locked { definitions += 1 }
        return try behavior(ordinal, file, byteOffset)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ExactStateSession: ExactSession, @unchecked Sendable {
    let readiness: ExactReadiness = .ready
    let attribution: ExactAttribution
    private let ordinal: Int
    private let state: ExactProviderState

    init(
        attribution: ExactAttribution,
        ordinal: Int,
        state: ExactProviderState
    ) {
        self.attribution = attribution
        self.ordinal = ordinal
        self.state = state
    }

    func definition(file: String, byteOffset: Int) throws -> ExactLocation? {
        try state.define(ordinal: ordinal, file: file, byteOffset: byteOffset)
    }

    func cancel() {}
    func close() {}
}

private final class ExactVersionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String

    init(_ value: String) { stored = value }

    var value: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

private final class ExactSnapshotFactoryState: @unchecked Sendable {
    private let lock = NSLock()
    private let files: [String: String]
    private var identifiers: [SnapshotID] = []

    init(files: [String: String]) { self.files = files }

    var snapshotIDs: [SnapshotID] {
        lock.lock()
        defer { lock.unlock() }
        return identifiers
    }

    func make(root: URL, revision: String?) throws -> any Snapshot {
        let snapshot = ExactTestSnapshot(files: files)
        lock.lock()
        identifiers.append(snapshot.snapshotID)
        lock.unlock()
        return snapshot
    }
}

private final class ExactTestSnapshot: Snapshot, @unchecked Sendable {
    let snapshotID = SnapshotID(rawValue: UUID())
    let objectFormat = GitObjectFormat.sha1
    let sourceKind = SourceKind.untracked
    private let files: [String: [UInt8]]

    init(files: [String: String]) {
        self.files = files.mapValues { Array($0.utf8) }
    }

    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)] {
        files.keys.sorted().map { path in
            (path, ContentID.sha256(of: files[path]!), .regular)
        }
    }

    func readBytes(path: String) throws -> [UInt8] {
        guard let bytes = files[path] else { throw ExactTestError.missing(path) }
        return bytes
    }
}

private final class BlockingExactProvider: ExactProvider, @unchecked Sendable {
    let capabilities: ExactCapabilities = [.definition]
    let toolVersion = "blocking-1"
    private let session: BlockingExactSession

    init(session: BlockingExactSession) { self.session = session }

    func prepare(
        snapshot: any Snapshot,
        profile: ExactProfileKey,
        trustMode: TrustMode
    ) throws -> any ExactSession {
        session.attribution = ExactAttribution(
            provider: "blocking",
            toolVersion: toolVersion,
            configFingerprint: profile.configFingerprint,
            environmentFingerprint: profile.environmentFingerprint,
            trustMode: trustMode,
            generatedAt: Date(timeIntervalSince1970: 0),
            coverage: .partial
        )
        return session
    }
}

private final class BlockingExactSession: ExactSession, @unchecked Sendable {
    private let condition = NSCondition()
    private var didStart = false
    private var released = false
    var attribution = exactAttribution()
    let readiness: ExactReadiness = .ready

    var started: Bool {
        condition.lock()
        defer { condition.unlock() }
        return didStart
    }

    func definition(file: String, byteOffset: Int) throws -> ExactLocation? {
        condition.lock()
        didStart = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
        return ExactLocation(file: file, byteOffset: 0, line: 1, column: 1)
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {}
    func close() {}
}

@MainActor
private final class ContextExactGate {
    private var continuations: [Int: CheckedContinuation<ExactOverlay.Entry?, Never>] = [:]
    private var nextID = 0

    var count: Int { nextID }

    func resolve(
        file: String,
        offset: UInt32,
        generation: UInt64
    ) async -> ExactOverlay.Entry? {
        let id = nextID
        nextID += 1
        return await withCheckedContinuation { continuations[id] = $0 }
    }

    func complete(_ id: Int, with entry: ExactOverlay.Entry?) {
        continuations.removeValue(forKey: id)?.resume(returning: entry)
    }
}

private struct ExactTestFixture {
    let root: URL
    let files = ["main.rs": "fn target() {}\nfn main() { target(); }\n"]
    let trustRegistry: TrustRegistry

    init() throws {
        root = try exactTemporaryProject(files)
        trustRegistry = TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        )
    }

    @MainActor
    func coordinator(
        state: ExactProviderState,
        sandboxAvailable: @escaping @Sendable () -> Bool = { true }
    ) -> ExactCoordinator {
        ExactCoordinator(
            providerFactory: { _ in ExactTestProvider(state: state) },
            snapshotFactory: ExactSnapshotFactoryState(files: files).make,
            sandboxAvailable: sandboxAvailable,
            trustRegistry: trustRegistry
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func exactEntry(file: String, byteOffset: UInt32) -> ExactOverlay.Entry {
    ExactOverlay.Entry(
        location: ExactLocation(
            file: file,
            byteOffset: Int(byteOffset),
            line: 1,
            column: Int(byteOffset) + 1
        ),
        attribution: exactAttribution()
    )
}

private func exactAttribution() -> ExactAttribution {
    ExactAttribution(
        provider: "fake-exact",
        toolVersion: "fake-1",
        configFingerprint: "config",
        environmentFingerprint: "environment",
        trustMode: .safe,
        generatedAt: Date(timeIntervalSince1970: 0),
        coverage: .partial
    )
}

@MainActor
private func exactSymbols(_ model: ContextWindowModel) -> [SymbolOccurrenceID] {
    guard case let .candidates(candidates, _) = model.stage else { return [] }
    return candidates.map(\.symbol)
}

@MainActor
private func exactWaitUntil(
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

private func exactTemporaryProject(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightExactCoordinatorTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "[package]\nname='exact-test'\nversion='0.1.0'\n".write(
        to: root.appendingPathComponent("Cargo.toml"),
        atomically: true,
        encoding: .utf8
    )
    for (path, contents) in files {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
    return root
}

private func exactQueryContext(
    for session: EngineSession,
    generation: UInt64
) -> QueryContext {
    QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: generation
    )
}

private func exactByteOffset(of needle: String, in source: String) -> UInt32 {
    let range = source.range(of: needle)!
    return UInt32(source[..<range.lowerBound].utf8.count)
}

private enum ExactTestError: Error {
    case missing(String)
}
