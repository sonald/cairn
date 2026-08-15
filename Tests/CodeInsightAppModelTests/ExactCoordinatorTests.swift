import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightGit
import Dispatch
import Foundation
import Observation
import Testing
@testable import CodeInsightAppModel

@MainActor
@Test
func exactCoordinatorAttributionObservationTracksPrepareAndInvalidate()
    async throws
{
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let prepareGate = DispatchSemaphore(value: 0)
    let coordinator = ExactCoordinator(
        providerFactory: { _ in ExactTestProvider(state: state) },
        snapshotFactory: { _, _ in
            prepareGate.wait()
            return ExactTestSnapshot(files: fixture.files)
        },
        sandboxAvailable: { true },
        trustRegistry: fixture.trustRegistry
    )

    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("coordinator.trustMode == .safe") { coordinator.trustMode == .safe })

    await confirmation("prepare publishes attribution") { observed in
        withObservationTracking {
            _ = coordinator.attribution
        } onChange: {
            observed()
        }
        prepareGate.signal()
        #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })
    }
    #expect(coordinator.attribution != nil)

    await confirmation("invalidate clears attribution") { observed in
        withObservationTracking {
            _ = coordinator.attribution
        } onChange: {
            observed()
        }
        coordinator.invalidate(generation: 2)
    }
    #expect(coordinator.attribution == nil)
}

@MainActor
@Test
func exactCoordinatorNestedProfileRootMapsProviderRootAndRejectsOutsideProfile()
    async throws
{
    let root = try exactTemporaryProject([
        "tools/ts/package.json": "{}\n",
        "tools/ts/tsconfig.json": "{ \"compilerOptions\": {} }\n",
        "tools/ts/main.ts": "export function target(): void {}\n",
        "tools/ts/other.ts": "export function other(): void {}\n",
        "outside.ts": "export function forbidden(): void {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let profilePrefix = "tools/ts"
    let state = ExactProviderState { _, file, _ in
        switch file {
        case "main.ts":
            ExactLocation(
                file: "main.ts",
                byteOffset: 0,
                line: 1,
                column: 1
            )
        case "other.ts":
            ExactLocation(
                file: "other.ts",
                byteOffset: 0,
                line: 1,
                column: 1
            )
        case "external.ts":
            ExactLocation(
                file: "/tmp/real-external/defs.ts",
                byteOffset: 0,
                line: 1,
                column: 1
            )
        case "absOutside.ts":
            ExactLocation(
                file: root.appendingPathComponent("outside.ts").path,
                byteOffset: 0,
                line: 1,
                column: 1
            )
        default:
            nil
        }
    }
    let providerRootBox = ExactVersionBox("")
    let snapshot = ExactTestSnapshot(files: [
        "tools/ts/package.json": "{}\n",
        "tools/ts/tsconfig.json": "{ \"compilerOptions\": {} }\n",
        "tools/ts/main.ts": "export function target(): void {}\n",
        "tools/ts/other.ts": "export function other(): void {}\n",
        "outside.ts": "export function forbidden(): void {}\n",
    ])
    let expectedProfile = try ExactProfileKey(
        snapshot: snapshot,
        language: .typescript,
        pathPrefix: profilePrefix
    )
    let coordinator = ExactCoordinator(
        providerFactory: { projectURL, language in
            providerRootBox.value = projectURL.path
            return ExactTestProvider(language: language, state: state)
        },
        snapshotFactory: { _, _ in snapshot },
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        )
    )

    try coordinator.prepare(
        projectURL: root,
        revision: nil,
        analysisProfile: exactTypeScriptProfile(
            language: .typescript,
            projectUnitName: profilePrefix,
            configFingerprint: expectedProfile.configFingerprint,
            environmentFingerprint: expectedProfile.environmentFingerprint
        ),
        profileRoot: profilePrefix,
        generation: 1
    )

    #expect(await testWaitUntil("nested profile ready") {
        coordinator.readiness == .ready
    })
    #expect(URL(fileURLWithPath: providerRootBox.value).lastPathComponent == "ts")
    #expect(state.prepareCount == 1)

    let inProfile = await coordinator.definition(
        file: "tools/ts/main.ts",
        byteOffset: 0,
        generation: 1
    )
    #expect(exactCompletedEntry(inProfile)?.location.file == "tools/ts/main.ts")
    #expect(state.filesRequested == ["main.ts"])

    guard case .completed(let absoluteEntries) = await coordinator.definition(
        file: "tools/ts/external.ts",
        byteOffset: 0,
        generation: 1
    ) else {
        Issue.record("provider external dependency should preserve location")
        return
    }
    #expect(absoluteEntries.count == 1)
    #expect(absoluteEntries[0].location.file == "/tmp/real-external/defs.ts")

    let outsideResult = await coordinator.definition(
        file: "tools/ts/absOutside.ts",
        byteOffset: 0,
        generation: 1
    )
    guard case .completed(let outsideEntries) = outsideResult else {
        Issue.record("absolute outside-profile query should complete empty")
        return
    }
    #expect(outsideEntries.isEmpty)
    #expect(state.filesRequested == ["main.ts", "external.ts", "absOutside.ts"])
}

@MainActor
@Test
func exactCoordinatorRejectsInvalidProfileRootBeforeInvalidate() throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }

    let state = ExactProviderState()
    let providerCalls = ExactVersionBox("not called")
    let coordinator = ExactCoordinator(
        providerFactory: { _ in
            providerCalls.value = "called"
            return ExactTestProvider(state: state)
        },
        snapshotFactory: ExactSnapshotFactoryState(files: fixture.files).make,
        sandboxAvailable: { true },
        trustRegistry: fixture.trustRegistry
    )

    let originalReadiness = coordinator.readiness
    #expect(throws: ExactError.self) {
        try coordinator.prepare(
            projectURL: fixture.root,
            revision: nil,
            analysisProfile: exactAnalysisProfile(
                language: .typescript,
                projectUnitName: "tools/ts",
                configFingerprint: "x",
                environmentFingerprint: ""
            ),
            profileRoot: "../outside",
            generation: 1
        )
    }
    #expect(coordinator.readiness == originalReadiness)
    #expect(providerCalls.value == "not called")
    #expect(state.prepareCount == 0)
}

@MainActor
@Test
func exactCoordinatorPreparesNestedProfilesAcrossLanguageNavigation() async throws {
    let root = try exactTemporaryProject([
        "crates/r/Cargo.toml": "[package]\nname = \"r\"\n",
        "crates/r/src/lib.rs": "pub fn f() {}\n",
        "pyproject.toml": "[project]\nname = \"p\"\n",
        "lib.py": "def f():\n    pass\n",
        "tools/ts/package.json": "{}\n",
        "tools/ts/tsconfig.json": "{}\n",
        "tools/ts/src/lib.ts": "export function f() {}\n",
    ])
    try FileManager.default.removeItem(at: root.appendingPathComponent("Cargo.toml"))
    try exactGit(root, "init", "-q")
    try exactGit(root, "config", "user.name", "CodeInsight Tests")
    try exactGit(root, "config", "user.email", "tests@codeinsight.invalid")
    try exactGit(root, "add", "-A")
    try exactGit(root, "commit", "-q", "-m", "fixture")
    let indexService = ProjectIndexService()
    defer {
        indexService.flushPersistentIndexCache()
        try? FileManager.default.removeItem(at: root)
    }

    let state = ExactProviderState()
    let model = AppModel(
        indexService: indexService,
        exactCoordinator: ExactCoordinator(
            providerFactory: { projectURL, language in
                state.recordPrepare(language: language, root: projectURL)
                return ExactTestProvider(
                    language: language,
                    state: state
                )
            },
            sandboxAvailable: { true },
            trustRegistry: TrustRegistry(
                fileURL: root.appendingPathComponent("trust.json")
            )
        )
    )
    try await model.openProject(root: root, languages: [.rust, .python, .typescript])
    #expect(await testWaitUntil("initial exact prepare count=1") {
        state.prepareCount == 1
    })
    #expect(model.querySessions.map {
        $0.0.paths.resolve($0.0.analysisProfile.projectRoot)
    } == ["crates/r", ".", "tools/ts"])

    model.navigate(to: root.appendingPathComponent("crates/r/src/lib.rs"))
    try await Task.sleep(for: .milliseconds(50))
    #expect(state.prepareCount == 1)
    #expect(state.prepareRoots.last?.lastPathComponent == "r")
    #expect(state.prepareLanguages == [.rust])

    model.navigate(to: root.appendingPathComponent("lib.py"))
    #expect(await testWaitUntil("python exact prepare count=2") {
        state.prepareCount == 2
    })
    #expect(state.prepareLanguages.last == .python)
    #expect(state.prepareRoots.last?.path == root.path)
    #expect(state.closedSessions.contains(1))

    model.navigate(to: root.appendingPathComponent("tools/ts/src/lib.ts"))
    #expect(await testWaitUntil("ts exact prepare count=3") {
        state.prepareCount == 3
    })
    #expect(state.prepareRoots.last?.path == root.appendingPathComponent("tools/ts").path)

    model.navigate(to: root.appendingPathComponent("crates/r/src/lib.rs"))
    #expect(await testWaitUntil("rust exact prepare count=4") {
        state.prepareCount == 4
    })
    #expect(state.prepareLanguages == [.rust, .python, .typescript, .rust])
    #expect(state.closedSessions.count == 3)
}

@MainActor
@Test
func exactCoordinatorGateOldPrepareBeforeNewProviderPrepare() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }

    let oldPrepareEntered = ExactVersionBox("not started")
    let secondPrepareEntered = ExactVersionBox("not started")
    let releaseOldPrepare = DispatchSemaphore(value: 0)
    let state = ExactProviderState()
    let providerFactoryCalls = ExactVersionBox("0")
    let coordinator = ExactCoordinator(
        providerFactory: { _, _ in
            let count = Int(providerFactoryCalls.value) ?? 0
            providerFactoryCalls.value = String(count + 1)
            if count == 0 {
                oldPrepareEntered.value = "started"
                releaseOldPrepare.wait()
            } else {
                secondPrepareEntered.value = "started"
            }
            return ExactTestProvider(state: state)
        },
        snapshotFactory: ExactSnapshotFactoryState(files: fixture.files).make,
        sandboxAvailable: { true },
        trustRegistry: fixture.trustRegistry
    )

    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("old provider prepare entered") {
        oldPrepareEntered.value == "started"
    })
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 2)
    try await Task.sleep(for: .milliseconds(50))
    #expect(secondPrepareEntered.value == "not started")
    releaseOldPrepare.signal()
    #expect(await testWaitUntil("new profile ready") {
        coordinator.readiness == .ready
    })
    #expect(state.prepareCount == 2)
    #expect(providerFactoryCalls.value == "2")
    #expect(state.closedSessions.contains(1))
}

@MainActor
@Test
func exactCoordinatorPublishesTrustBeforeSessionReadyAndClearsOnInvalidate()
    async throws
{
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let prepareGate = DispatchSemaphore(value: 0)
    let coordinator = ExactCoordinator(
        providerFactory: { _ in ExactTestProvider(state: state) },
        snapshotFactory: { _, _ in
            prepareGate.wait()
            return ExactTestSnapshot(files: fixture.files)
        },
        sandboxAvailable: { true },
        trustRegistry: fixture.trustRegistry
    )

    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)

    #expect(await testWaitUntil("coordinator.trustMode == .safe") { coordinator.trustMode == .safe })
    #expect(coordinator.readiness == .preparing)
    coordinator.invalidate(generation: 2)
    #expect(coordinator.trustMode == nil)
    prepareGate.signal()
    #expect(await testWaitUntil("state.prepareCount == 1") { state.prepareCount == 1 })
}

@MainActor
@Test
func exactCoordinatorPreparesOpportunistically() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let coordinator = fixture.coordinator(state: state)

    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)

    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })
    #expect(state.prepareCount == 1)
}

@MainActor
@Test
func exactCoordinatorRejectsJavaScriptWithoutChangingState() throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let snapshots = ExactSnapshotFactoryState(files: fixture.files)
    let providerFactoryStatus = ExactVersionBox("not called")
    let coordinator = ExactCoordinator(
        providerFactory: { _, _ in
            providerFactoryStatus.value = "called"
            return ExactTestProvider(state: state)
        },
        snapshotFactory: snapshots.make,
        sandboxAvailable: { true },
        trustRegistry: fixture.trustRegistry
    )
    let originalReadiness = coordinator.readiness

    do {
        try coordinator.prepare(
            projectURL: fixture.root,
            revision: nil,
            analysisProfile: exactAnalysisProfile(language: .javascript),
            generation: 1
        )
        Issue.record("expected unsupported language")
    } catch let error as CocoaError {
        #expect(error.code == .featureUnsupported)
        #expect(
            (error.userInfo[NSLocalizedFailureReasonErrorKey] as? String)?
                .contains("javascript") == true
        )
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    #expect(coordinator.readiness == originalReadiness)
    #expect(coordinator.attribution == nil)
    #expect(coordinator.analysisEnvironment == nil)
    #expect(coordinator.trustMode == nil)
    #expect(snapshots.snapshotIDs.isEmpty)
    #expect(providerFactoryStatus.value == "not called")
    #expect(state.prepareCount == 0)
}

@MainActor
@Test
func exactCoordinatorAcceptsPythonProfileAndUsesWorktreeDefaultSnapshot()
    async throws
{
    let root = try exactTemporaryPythonProject([
        "pyproject.toml": "[tool.pyright]\npythonVersion = \"3.12\"\n",
        "main.py": "def target():\n    pass\n\ntarget()\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    try exactGit(root, "init", "-q")
    try exactGit(root, "config", "user.name", "CodeInsight Tests")
    try exactGit(root, "config", "user.email", "tests@codeinsight.invalid")
    let trustRegistry = TrustRegistry(
        fileURL: root.appendingPathComponent("trust.json")
    )
    let state = ExactProviderState { _, _, _ in
        ExactLocation(file: "main.py", byteOffset: 0, line: 1, column: 1)
    }
    let worktree = try WorktreeSnapshot(
        repositoryURL: root,
        language: .python
    )
    let expectedProfile = try ExactProfileKey(
        snapshot: worktree,
        language: .python
    )
    let coordinator = ExactCoordinator(
        providerFactory: { _, language in
            ExactTestProvider(language: language, state: state)
        },
        sandboxAvailable: { true },
        trustRegistry: trustRegistry
    )

    try coordinator.prepare(
        projectURL: root,
        revision: nil,
        analysisProfile: exactAnalysisProfile(
            language: .python,
            projectUnitName: root.lastPathComponent,
            configFingerprint: expectedProfile.configFingerprint,
            environmentFingerprint: expectedProfile.environmentFingerprint,
            featureSelection: .defaultFeatures
        ),
        generation: 1
    )
    #expect(
        await testWaitUntil("python exact readiness == .ready || unavailable") {
            coordinator.readiness != .preparing
        }
    )
    guard case .ready = coordinator.readiness else {
        if case .unavailable(let reason) = coordinator.readiness {
            Issue.record("Python exact became unavailable: \(reason)")
        }
        return
    }
    #expect(state.prepareCount == 1)
    let result = await coordinator.definition(
        file: "main.py",
        byteOffset: 0,
        generation: 1
    )
    #expect(exactCompletedEntry(result)?.origin == .worktree)
}

@MainActor
@Test
func exactCoordinatorRejectsPythonProfileMismatchBeforeProvider() async throws {
    let root = try exactTemporaryPythonProject([
        "pyproject.toml": "[tool.pyright]\npythonVersion = \"3.12\"\n",
        "main.py": "def target():\n    pass\n\ntarget()\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let state = ExactProviderState()
    let coordinator = ExactCoordinator(
        providerFactory: { _, language in
            ExactTestProvider(language: language, state: state)
        },
        snapshotFactory: ExactSnapshotFactoryState(files: [
            "pyproject.toml": "[tool.pyright]\npythonVersion = \"3.12\"\n",
            "main.py": "def target():\n    pass\n\ntarget()\n",
        ]).make,
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        )
    )

    try coordinator.prepare(
        projectURL: root,
        revision: nil,
        analysisProfile: exactPythonProfile(
            language: .python,
            configFingerprint: "wrong-config",
            environmentFingerprint: ""
        ),
        generation: 1
    )

    #expect(await testWaitUntil("python mismatch leaves preparing") {
        coordinator.readiness != .preparing
    })
    guard case .unavailable(let reason) = coordinator.readiness else {
        Issue.record("python profile mismatch did not fail")
        return
    }
    #expect(reason.contains("profile"))
    #expect(state.prepareCount == 0)
}

@MainActor
@Test
func exactCoordinatorFiltersPythonStubTargets() async throws {
    let root = try exactTemporaryPythonProject([
        "pyproject.toml": "[project]\nname = \"p\"\n",
        "main.py": "def target():\n    pass\n\ntarget()\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let state = ExactProviderState{ _, _, _ in
        ExactLocation(file: "typeshed/foo.pyi", byteOffset: 0, line: 1, column: 1)
    }
    let expectedProfile = try ExactProfileKey(
        projectURL: root,
        language: .python
    )
    let coordinator = ExactCoordinator(
        providerFactory: { _, language in
            ExactTestProvider(language: language, state: state)
        },
        snapshotFactory: ExactSnapshotFactoryState(files: [
            "pyproject.toml": "[project]\nname = \"p\"\n",
            "main.py": "def target():\n    pass\n\ntarget()\n",
        ]).make,
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        )
    )

    try coordinator.prepare(
        projectURL: root,
        revision: nil,
        analysisProfile: exactPythonProfile(
            language: .python,
            projectUnitName: root.lastPathComponent,
            configFingerprint: expectedProfile.configFingerprint,
            environmentFingerprint: expectedProfile.environmentFingerprint
        ),
        generation: 1
    )
    #expect(await testWaitUntil("ready") { coordinator.readiness == .ready })

    guard case .completed(let entries) = await coordinator.definition(
        file: "main.py",
        byteOffset: 0,
        generation: 1
    ) else {
        Issue.record("python stub filter should complete empty")
        return
    }
    #expect(entries.isEmpty)
}

@MainActor
@Test
func exactCoordinatorAcceptsTypeScriptProfileAndPublishesTSAndTSXOnly()
    async throws
{
    let root = try exactTemporaryTypeScriptProject([
        "tsconfig.json": "{ \"compilerOptions\": {} }\n",
        "package.json": "{}\n",
        "main.ts": "export function target(): void {}\ntarget();\n",
        "widget.tsx": "export function widget(): void {}\n",
        "index.d.ts": "declare const old: any\n",
        "legacy.js": "let old = 1\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let state = ExactProviderState { _, _, _ in
        ExactLocation(file: "main.ts", byteOffset: 0, line: 1, column: 1)
    }
    let expectedProfile = try ExactProfileKey(
        projectURL: root,
        language: .typescript
    )
    let coordinator = ExactCoordinator(
        providerFactory: { _, language in
            ExactTestProvider(language: language, state: state)
        },
        snapshotFactory: ExactSnapshotFactoryState(files: [
            "tsconfig.json": "{ \"compilerOptions\": {} }\n",
            "package.json": "{}\n",
            "main.ts": "export function target(): void {}\ntarget();\n",
            "widget.tsx": "export function widget(): void {}\n",
            "index.d.ts": "export const old: any\n",
            "legacy.js": "let old = 1\n",
        ]).make,
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        )
    )

    try coordinator.prepare(
        projectURL: root,
        revision: nil,
        analysisProfile: exactTypeScriptProfile(
            language: .typescript,
            projectUnitName: root.lastPathComponent,
            configFingerprint: expectedProfile.configFingerprint,
            environmentFingerprint: expectedProfile.environmentFingerprint
        ),
        generation: 1
    )
    #expect(await testWaitUntil("ready or unavailable") {
        coordinator.readiness != .preparing
    })
    guard case .ready = coordinator.readiness else {
        if case .unavailable(let reason) = coordinator.readiness {
            Issue.record("TypeScript exact became unavailable: \(reason)")
        }
        return
    }
    #expect(state.prepareCount == 1)

    let tsResult = await coordinator.definition(
        file: "main.ts",
        byteOffset: 0,
        generation: 1
    )
    #expect(exactCompletedEntry(tsResult)?.origin == .worktree)
    #expect(exactCompletedEntry(tsResult)?.location.file == "main.ts")

    let tsxResult = await coordinator.definition(
        file: "widget.tsx",
        byteOffset: 0,
        generation: 1
    )
    #expect(exactCompletedEntry(tsxResult) != nil)
}

@MainActor
@Test
func exactCoordinatorTypeScriptRejectsProfileMismatchBeforeProvider() async throws {
    let root = try exactTemporaryTypeScriptProject([
        "tsconfig.json": "{ \"compilerOptions\": {} }\n",
        "package.json": "{}\n",
        "main.ts": "export function target(): void {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let state = ExactProviderState()
    let coordinator = ExactCoordinator(
        providerFactory: { _, language in
            ExactTestProvider(language: language, state: state)
        },
        snapshotFactory: ExactSnapshotFactoryState(files: [
            "tsconfig.json": "{ \"compilerOptions\": {} }\n",
            "package.json": "{}\n",
            "main.ts": "export function target(): void {}\n",
        ]).make,
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        )
    )

    try coordinator.prepare(
        projectURL: root,
        revision: nil,
        analysisProfile: exactTypeScriptProfile(
            language: .typescript,
            projectUnitName: root.lastPathComponent,
            configFingerprint: "wrong",
            environmentFingerprint: ""
        ),
        generation: 1
    )
    #expect(await testWaitUntil("ts profile mismatch leaves preparing") {
        coordinator.readiness != .preparing
    })
    guard case .unavailable(let reason) = coordinator.readiness else {
        Issue.record("ts profile mismatch did not fail")
        return
    }
    #expect(reason.contains("profile"))
    #expect(state.prepareCount == 0)
}

@MainActor
@Test
func exactCoordinatorReportsMissingTypeScriptProvider() async throws {
    let root = try exactTemporaryTypeScriptProject([
        "tsconfig.json": "{ \"compilerOptions\": {} }\n",
        "package.json": "{}\n",
        "main.ts": "export function target(): void {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = try ExactProfileKey(
        projectURL: root,
        language: .typescript
    )
    let coordinator = ExactCoordinator(
        providerFactory: { _, _ in
            throw ExactError.unavailable(
                "typescript-language-server is not installed"
            )
        },
        snapshotFactory: ExactSnapshotFactoryState(files: [
            "tsconfig.json": "{ \"compilerOptions\": {} }\n",
            "package.json": "{}\n",
            "main.ts": "export function target(): void {}\n",
        ]).make,
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        )
    )

    try coordinator.prepare(
        projectURL: root,
        revision: nil,
        analysisProfile: exactTypeScriptProfile(
            language: .typescript,
            projectUnitName: root.lastPathComponent,
            configFingerprint: profile.configFingerprint,
            environmentFingerprint: profile.environmentFingerprint
        ),
        generation: 1
    )
    #expect(await testWaitUntil("ts missing provider leaves preparing") {
        coordinator.readiness != .preparing
    })
    guard case .unavailable(let reason) = coordinator.readiness else {
        Issue.record("missing TS provider did not fail")
        return
    }
    #expect(reason.contains("typescript-language-server"))
}

@Test
func exactTypeScriptProfileTracksConfigPackageAndLockFingerprints() throws {
    let root = try exactTemporaryTypeScriptProject([
        "tsconfig.json": "{ \"compilerOptions\": { \"strict\": true } }\n",
        "package.json": "{ \"name\": \"p\", \"version\": \"1.0.0\" }\n",
        "bun.lockb": Data([0x01, 0x02, 0x03]).base64EncodedString(),
        "main.ts": "export function target(): void {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let base = try ExactProfileKey(
        projectURL: root,
        language: .typescript
    )
    #expect(base.featureSelection == .defaultFeatures)
    #expect(!base.configFingerprint.isEmpty)
    #expect(!base.environmentFingerprint.isEmpty)

    try "{ \"name\": \"p\", \"version\": \"2.0.0\" }\n".write(
        to: root.appendingPathComponent("package.json"),
        atomically: true,
        encoding: .utf8
    )
    let packageChanged = try ExactProfileKey(
        projectURL: root,
        language: .typescript
    )
    #expect(packageChanged.configFingerprint != base.configFingerprint)
    #expect(packageChanged.environmentFingerprint == base.environmentFingerprint)

    try "[0x09, 0x0a]".write(
        to: root.appendingPathComponent("bun.lockb"),
        atomically: true,
        encoding: .utf8
    )
    let lockChanged = try ExactProfileKey(
        projectURL: root,
        language: .typescript
    )
    #expect(lockChanged.environmentFingerprint != base.environmentFingerprint)
}

@MainActor
@Test
func exactCoordinatorFiltersDeferredTypeScriptTargets() async throws {
    let root = try exactTemporaryTypeScriptProject([
        "tsconfig.json": "{ \"compilerOptions\": {} }\n",
        "package.json": "{}\n",
        "main.ts": "export function target(): void {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let state = ExactProviderState { _, _, _ in
        ExactLocation(file: "index.d.ts", byteOffset: 0, line: 1, column: 1)
    }
    let profile = try ExactProfileKey(
        projectURL: root,
        language: .typescript
    )
    let coordinator = ExactCoordinator(
        providerFactory: { _, language in
            ExactTestProvider(language: language, state: state)
        },
        snapshotFactory: ExactSnapshotFactoryState(files: [
            "tsconfig.json": "{ \"compilerOptions\": {} }\n",
            "package.json": "{}\n",
            "main.ts": "export function target(): void {}\n",
        ]).make,
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        )
    )

    try coordinator.prepare(
        projectURL: root,
        revision: nil,
        analysisProfile: exactTypeScriptProfile(
            language: .typescript,
            projectUnitName: root.lastPathComponent,
            configFingerprint: profile.configFingerprint,
            environmentFingerprint: profile.environmentFingerprint
        ),
        generation: 1
    )
    #expect(await testWaitUntil("ts ready") { coordinator.readiness == .ready })
    let result = await coordinator.definition(
        file: "main.ts",
        byteOffset: 0,
        generation: 1
    )
    guard case .completed(let entries) = result else {
        Issue.record("deferred target should complete empty")
        return
    }
    #expect(entries.isEmpty)
    #expect(state.definitionCount == 1)
}

@MainActor
@Test
func exactCoordinatorReportsPythonImplementationsUnsupported() async throws {
    let root = try exactTemporaryPythonProject([
        "main.py": "class Target:\n    pass\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let state = ExactProviderState { _, _, _ in nil }
    let profile = try ExactProfileKey(
        projectURL: root,
        language: .python
    )
    let coordinator = ExactCoordinator(
        providerFactory: { _, language in
            ExactTestProvider(language: language, state: state)
        },
        snapshotFactory: ExactSnapshotFactoryState(files: [
            "main.py": "class Target:\n    pass\n",
        ]).make,
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        )
    )

    try coordinator.prepare(
        projectURL: root,
        revision: nil,
        analysisProfile: exactPythonProfile(
            language: .python,
            projectUnitName: root.lastPathComponent,
            configFingerprint: profile.configFingerprint,
            environmentFingerprint: profile.environmentFingerprint
        ),
        generation: 1
    )
    #expect(await testWaitUntil("implementation unsupported ready") {
        coordinator.readiness == .ready
    })
    guard case .unsupported = await coordinator.relations(
        file: "main.py",
        byteOffset: 0,
        item: nil,
        direction: .implementations,
        generation: 1
    )! else {
        Issue.record("Python implementations should be unsupported")
        return
    }
}

@MainActor
@Test
func exactCoordinatorReturnsUnsupportedForForeignLanguageRelationTargets()
    async throws
{
    let root = try exactTemporaryProject([
        "Cargo.toml": "[package]\nname='exact-test'\nversion='0.1.0'\n",
        "main.rs": "fn target() {}\nfn main() { target(); }\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let state = ExactProviderState(references: [
        ExactLocation(
            file: "main.py",
            byteOffset: 0,
            line: 1,
            column: 1
        )
    ])
    let profile = try ExactProfileKey(projectURL: root)
    let coordinator = ExactCoordinator(
        providerFactory: { _, language in
            ExactTestProvider(language: language, state: state)
        },
        snapshotFactory: ExactSnapshotFactoryState(files: [
            "Cargo.toml": "[package]\nname='exact-test'\nversion='0.1.0'\n",
            "main.rs": "fn target() {}\nfn main() { target(); }\n",
        ]).make,
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        )
    )
    try coordinator.prepare(
        projectURL: root,
        revision: nil,
        analysisProfile: exactAnalysisProfile(
            language: .rust,
            configFingerprint: profile.configFingerprint,
            environmentFingerprint: profile.environmentFingerprint
        ),
        generation: 1
    )
    #expect(await testWaitUntil("ready") { coordinator.readiness == .ready })
    let result = await coordinator.relations(
        file: "main.rs",
        byteOffset: 0,
        item: nil,
        direction: .references,
        generation: 1
    )
    guard case .unsupported = result! else {
        Issue.record("foreign language relation should be unsupported")
        return
    }
}

@MainActor
@Test
func exactCoordinatorRejectsProviderLanguageMismatchBeforePrepare() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let factoryLanguage = ExactVersionBox("")
    let profile = try ExactProfileKey(snapshot: ExactTestSnapshot(
        files: fixture.files.merging(
            ["Cargo.toml": "[package]\nname='exact-test'\nversion='0.1.0'\n"],
            uniquingKeysWith: { _, new in new }
        )
    ))
    let coordinator = ExactCoordinator(
        providerFactory: { _, language in
            factoryLanguage.value = String(describing: language)
            return ExactTestProvider(language: .python, state: state)
        },
        snapshotFactory: ExactSnapshotFactoryState(files: fixture.files).make,
        sandboxAvailable: { true },
        trustRegistry: fixture.trustRegistry
    )

    try coordinator.prepare(
        projectURL: fixture.root,
        revision: nil,
        analysisProfile: exactAnalysisProfile(
            language: .rust,
            projectUnitName: "exact-test",
            configFingerprint: profile.configFingerprint,
            environmentFingerprint: profile.environmentFingerprint
        ),
        generation: 1
    )

    #expect(await testWaitUntil("coordinator leaves preparing") {
        coordinator.readiness != .preparing
    })
    guard case .unavailable(let reason) = coordinator.readiness else {
        Issue.record("provider language mismatch did not fail")
        return
    }
    #expect(reason.contains("python"))
    #expect(reason.contains("rust"))
    #expect(factoryLanguage.value == "rust")
    #expect(state.prepareCount == 0)
}

@MainActor
@Test
func exactCoordinatorAcceptsRustProfileWithDifferentFingerprintRepresentation()
    async throws
{
    let root = try exactTemporaryProject(["main.rs": "fn main() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let state = ExactProviderState()
    let coordinator = ExactCoordinator(
        providerFactory: { _ in ExactTestProvider(state: state) },
        snapshotFactory: ExactSnapshotFactoryState(files: [
            "Cargo.toml": "[package]\nname='exact-test'\nversion='0.1.0'\n",
            "main.rs": "fn main() {}\n",
        ]).make,
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        )
    )

    try coordinator.prepare(
        projectURL: root,
        revision: nil,
        analysisProfile: exactAnalysisProfile(
            language: .rust,
            configFingerprint: "analysis-aggregate-config",
            environmentFingerprint: ""
        ),
        generation: 1
    )

    #expect(await testWaitUntil("rust fingerprint mismatch leaves preparing") {
        coordinator.readiness != .preparing
    })
    guard case .ready = coordinator.readiness else {
        Issue.record(
            "rust fingerprint representation mismatch should not fail exact"
        )
        return
    }
    #expect(state.prepareCount > 0)
}

@MainActor
@Test
func exactCoordinatorReportsMissingPythonProviderWithoutSessions() async throws {
    let root = try exactTemporaryPythonProject([
        "main.py": "def target():\n    pass\n\ntarget()\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = try ExactProfileKey(
        projectURL: root,
        language: .python
    )
    let coordinator = ExactCoordinator(
        providerFactory: { _, _ in
            throw ExactError.unavailable("pyright-langserver is not installed")
        },
        snapshotFactory: ExactSnapshotFactoryState(files: [
            "main.py": "def target():\n    pass\n\ntarget()\n",
        ]).make,
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        )
    )

    try coordinator.prepare(
        projectURL: root,
        revision: nil,
        analysisProfile: exactPythonProfile(
            language: .python,
            projectUnitName: root.lastPathComponent,
            configFingerprint: profile.configFingerprint,
            environmentFingerprint: profile.environmentFingerprint
        ),
        generation: 1
    )
    #expect(await testWaitUntil("python missing provider leaves preparing") {
        coordinator.readiness != .preparing
    })
    guard case .unavailable(let reason) = coordinator.readiness else {
        Issue.record("missing provider did not fail")
        return
    }
    #expect(reason.contains("pyright"))
}

@MainActor
@Test
func exactCoordinatorMarksWorktreeOrigin() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let coordinator = fixture.coordinator(state: ExactProviderState())

    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })

    let result = await coordinator.definition(
        file: "main.rs",
        byteOffset: 0,
        generation: 1
    )
    #expect(exactCompletedEntry(result)?.origin == .worktree)
}

@MainActor
@Test
func exactCoordinatorRefreshesEnvironmentWithoutAQuery() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let coordinator = fixture.coordinator(state: state)
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("coordinator.readiness == .ready && coordinator.analysisEnvironment != nil") {
        coordinator.readiness == .ready
            && coordinator.analysisEnvironment?.limitations
                == [.buildScriptsDisabled, .procMacrosDisabled]
    })

    state.publishEnvironment(ExactAnalysisEnvironment(
        trustMode: .safe,
        limitations: [
            .buildScriptsDisabled,
            .procMacrosDisabled,
            .dependenciesUnavailableOffline,
        ]
    ))

    #expect(await testWaitUntil("coordinator environment includes offline limitation") {
        coordinator.analysisEnvironment?.limitations.contains(
            .dependenciesUnavailableOffline
        ) == true
    })
    #expect(state.definitionCount == 0)
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
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })

    let result = await coordinator.definition(
        file: "main.rs",
        byteOffset: 0,
        generation: 1
    )

    guard case .unavailable(let reason) = result else {
        Issue.record("restart exhaustion did not publish unavailable")
        return
    }
    #expect(reason.contains("restart exhausted"))
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

    #expect(await testWaitUntil("if case .off = coordinator.readiness { return true } return false") {
        if case .off = coordinator.readiness { return true }
        return false
    })
    #expect(state.prepareCount == 0)
}

@MainActor
@Test
func exactCoordinatorTrustUIStateFlowsGrantAndRevoke() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let coordinator = fixture.coordinator(state: state)
    let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)

    await coordinator.refreshTrust()
    #expect(coordinator.trustedRepositories.isEmpty)

    try await coordinator.grantTrust(fixture.root, grantedAt: grantedAt)
    #expect(coordinator.trustedRepositories.count == 1)
    #expect(coordinator.trustedRepositories.first?.path == fixture.root.path)
    #expect(coordinator.trustedRepositories.first?.grantedAt == grantedAt)
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 1)
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })
    #expect(state.trustModes.last == "trusted")
    #expect(coordinator.trustMode == .trusted)

    coordinator.invalidate(generation: 2)
    #expect(coordinator.trustMode == nil)
    try await coordinator.revokeTrust(fixture.root)
    #expect(coordinator.trustedRepositories.isEmpty)
    coordinator.prepare(projectURL: fixture.root, revision: nil, generation: 2)
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })
    #expect(state.trustModes.last == "safe")
    #expect(coordinator.trustMode == .safe)
}

@MainActor
@Test
func appModelTrustActionsRebuildExactSessionImmediately() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let coordinator = fixture.coordinator(state: state)
    let model = AppModel(exactCoordinator: coordinator)

    model.openProject(root: fixture.root)
    #expect(await testWaitUntil("guard case .ready = model.projectState else { return false } return coordinator.readiness == .ready") {
        guard case .ready = model.projectState else { return false }
        return coordinator.readiness == .ready
    })
    #expect(state.trustModes == ["safe"])

    try await model.grantCurrentRepositoryTrust()
    #expect(await testWaitUntil("state.prepareCount == 2 && coordinator.readiness == .ready") {
        state.prepareCount == 2 && coordinator.readiness == .ready
    })
    #expect(state.trustModes == ["safe", "trusted"])

    try await model.revokeRepositoryTrust(fixture.root)
    #expect(await testWaitUntil("state.prepareCount == 3 && coordinator.readiness == .ready") {
        state.prepareCount == 3 && coordinator.readiness == .ready
    })
    #expect(state.trustModes == ["safe", "trusted", "safe"])
}

@MainActor
@Test
func exactOverlaySeparatesTrustModesAndReusesWithinEachMode() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let coordinator = fixture.coordinator(state: state)
    let model = AppModel(exactCoordinator: coordinator)

    model.openProject(root: fixture.root)
    #expect(await testWaitUntil("guard case .ready = model.projectState else { return false } return coordinator.readiness == .ready") {
        guard case .ready = model.projectState else { return false }
        return coordinator.readiness == .ready
    })
    let generation = model.generation

    let safe = try #require(exactCompletedEntry(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: generation
    )))
    #expect(safe.attribution.environment.trustMode == .safe)
    #expect(safe.attribution.environment.limitations
        == [.buildScriptsDisabled, .procMacrosDisabled])
    #expect(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: generation
    ) != nil)
    #expect(state.definitionCount == 1)

    try await model.grantCurrentRepositoryTrust()
    #expect(await testWaitUntil("state.prepareCount == 2 && coordinator.readiness == .ready") {
        state.prepareCount == 2 && coordinator.readiness == .ready
    })
    let trustedNew = try #require(exactCompletedEntry(await coordinator.definition(
        file: "main.rs", byteOffset: 1, generation: generation
    )))
    #expect(trustedNew.attribution.environment.trustMode == .trusted)
    #expect(trustedNew.attribution.environment.limitations.isEmpty)
    let trustedOld = try #require(exactCompletedEntry(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: generation
    )))
    #expect(trustedOld.attribution.environment.trustMode == .trusted)
    #expect(trustedOld.attribution.environment.limitations.isEmpty)
    #expect(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: generation
    ) != nil)
    #expect(state.definitionCount == 3)

    try await model.revokeRepositoryTrust(fixture.root)
    #expect(await testWaitUntil("state.prepareCount == 3 && coordinator.readiness == .ready") {
        state.prepareCount == 3 && coordinator.readiness == .ready
    })
    let safeAgain = try #require(exactCompletedEntry(await coordinator.definition(
        file: "main.rs", byteOffset: 1, generation: generation
    )))
    #expect(safeAgain.attribution.environment.trustMode == .safe)
    #expect(safeAgain.attribution.environment.limitations
        == [.buildScriptsDisabled, .procMacrosDisabled])
    #expect(await coordinator.definition(
        file: "main.rs", byteOffset: 1, generation: generation
    ) != nil)
    #expect(state.definitionCount == 4)
}

@MainActor
@Test
func appModelFeatureSwitchReprofilesAndRepreparesExactWithoutExtraction()
    async throws
{
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let coordinator = fixture.coordinator(state: state)
    let model = AppModel(exactCoordinator: coordinator)

    model.openProject(root: fixture.root)
    #expect(await testWaitUntil("guard case .ready = model.projectState else { return false } return coordinator.readiness == .ready") {
        guard case .ready = model.projectState else { return false }
        return coordinator.readiness == .ready
    })
    guard case let .ready(original, _) = model.projectState else {
        Issue.record("expected original ready session")
        return
    }
    let originalGeneration = model.generation
    let relationGeneration = model.relationTree.generation
    let main = try #require(
        original.definitions(
            of: "main",
            context: exactQueryContext(
                for: original,
                generation: originalGeneration
            )
        ).first?.0
    )
    _ = model.relationTree.setRoot(target: .engine(main), direction: .calls)
    #expect(await testWaitUntil("model.relationTree.root?.title == \"main\" && model.relationTree.root?.children?.contains { $0.kind == .loading } == false") {
        model.relationTree.root?.title == "main"
            && model.relationTree.root?.children?.contains {
                $0.kind == .loading
            } == false
    })

    model.switchFeatureSelection(.allFeatures)

    #expect(await testWaitUntil("state.prepareCount == 2 && coordinator.readiness == .ready") {
        state.prepareCount == 2 && coordinator.readiness == .ready
    })
    guard case let .ready(reprofiled, context) = model.projectState else {
        Issue.record("expected reprofiled ready session")
        return
    }
    #expect(model.generation == originalGeneration + 1)
    #expect(reprofiled.snapshotID == original.snapshotID)
    #expect(reprofiled.stats.extractedCount == 0)
    #expect(reprofiled.analysisProfile.featureSelection == .allFeatures)
    #expect(context.analysisProfileID == reprofiled.analysisProfile.id)
    #expect(context.generation == model.generation)
    #expect(model.relationTree.generation > relationGeneration)
    #expect(await testWaitUntil("model.relationTree.root?.title == \"main\" && model.relationTree.root?.children?.isEmpty == false && model.relationTree.root?.children?.contains { $0.kind == .loading } == false") {
        model.relationTree.root?.title == "main"
            && model.relationTree.root?.children?.isEmpty == false
            && model.relationTree.root?.children?.contains {
                $0.kind == .loading
            } == false
    })
    #expect(model.currentFeatureSelection == .allFeatures)
    #expect(model.availableFeatureSelections == [
        .defaultFeatures, .allFeatures, .noDefaultFeatures,
    ])
    #expect(state.featureSelections == [.defaultFeatures, .allFeatures])
    #expect(coordinator.attribution?.featureSelection == .allFeatures)
}

@MainActor
@Test
func appModelRevokeTrustClearsRegistryClosesTrustedSessionAndPreparesSafe()
    async throws
{
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let coordinator = fixture.coordinator(state: state)
    let model = AppModel(exactCoordinator: coordinator)

    model.openProject(root: fixture.root)
    #expect(await testWaitUntil("guard case .ready = model.projectState else { return false } return coordinator.readiness == .ready") {
        guard case .ready = model.projectState else { return false }
        return coordinator.readiness == .ready
    })

    try await model.grantCurrentRepositoryTrust()
    #expect(await testWaitUntil("state.prepareCount == 2 && coordinator.readiness == .ready") {
        state.prepareCount == 2 && coordinator.readiness == .ready
    })
    let trustedRepository: TrustedRepository = try #require(
        coordinator.trustedRepositories.first
    )
    #expect(trustedRepository.path == fixture.root.path)

    try await model.revokeRepositoryTrust(fixture.root)
    #expect(await testWaitUntil("state.prepareCount == 3 && coordinator.readiness == .ready && state.closedSessions.contains(2)") {
        state.prepareCount == 3
            && coordinator.readiness == .ready
            && state.closedSessions.contains(2)
    })
    #expect(coordinator.trustedRepositories.isEmpty)
    #expect(state.trustModes == ["safe", "trusted", "safe"])
    let trustObject = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.trustFile))
            as? [String: Any]
    )
    #expect(trustObject.isEmpty)

    coordinator.shutdown()
    #expect(state.closedSessions.contains(3))
    #expect(coordinator.readiness == .off("application terminating"))
}

@MainActor
@Test
func exactOverlayReusesVersionProfileAndToolButNotSnapshotID() async throws {
    let fixture = try ExactTestFixture()
    defer { fixture.remove() }
    let state = ExactProviderState()
    let versions = ExactVersionBox("fake-1")
    let snapshots = ExactSnapshotFactoryState(files: fixture.files)
    let exactProfile = try ExactProfileKey(projectURL: fixture.root)
    let analysisProfile = exactAnalysisProfile(
        language: .rust,
        configFingerprint: exactProfile.configFingerprint,
        environmentFingerprint: exactProfile.environmentFingerprint
    )
    let coordinator = ExactCoordinator(
        providerFactory: { _ in
            ExactTestProvider(toolVersion: versions.value, state: state)
        },
        snapshotFactory: snapshots.make,
        sandboxAvailable: { true },
        trustRegistry: fixture.trustRegistry
    )

    try coordinator.prepare(
        projectURL: fixture.root,
        revision: nil,
        analysisProfile: analysisProfile,
        generation: 1
    )
    #expect(await testWaitUntil("coordinator leaves preparing") {
        coordinator.readiness != .preparing
    })
    if case .unavailable(let reason) = coordinator.readiness {
        Issue.record("Exact overlay reuse became unavailable: \(reason)")
        return
    }
    #expect(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: 1
    ) != nil)

    try coordinator.prepare(
        projectURL: fixture.root,
        revision: nil,
        analysisProfile: analysisProfile,
        generation: 2
    )
    #expect(await testWaitUntil("coordinator leaves preparing") {
        coordinator.readiness != .preparing
    })
    if case .unavailable(let reason) = coordinator.readiness {
        Issue.record("Exact overlay reuse became unavailable: \(reason)")
        return
    }
    #expect(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: 2
    ) != nil)
    #expect(state.definitionCount == 1)
    #expect(Set(snapshots.snapshotIDs).count == 2)

    try coordinator.prepare(
        projectURL: fixture.root,
        revision: nil,
        analysisProfile: exactAnalysisProfile(
            language: .rust,
            projectUnitName: "other-unit",
            configFingerprint: exactProfile.configFingerprint,
            environmentFingerprint: exactProfile.environmentFingerprint
        ),
        generation: 3
    )
    #expect(await testWaitUntil("coordinator leaves preparing") {
        coordinator.readiness != .preparing
    })
    if case .unavailable(let reason) = coordinator.readiness {
        Issue.record("Exact overlay reuse became unavailable: \(reason)")
        return
    }
    #expect(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: 3
    ) != nil)
    #expect(state.definitionCount == 2)

    try "version = 3\n".write(
        to: fixture.root.appendingPathComponent("Cargo.lock"),
        atomically: true,
        encoding: .utf8
    )
    let exactProfileAfterLock = try ExactProfileKey(
        projectURL: fixture.root
    )
    let analysisProfileAfterLock = exactAnalysisProfile(
        language: .rust,
        configFingerprint: exactProfileAfterLock.configFingerprint,
        environmentFingerprint: exactProfileAfterLock.environmentFingerprint
    )
    try coordinator.prepare(
        projectURL: fixture.root,
        revision: nil,
        analysisProfile: analysisProfileAfterLock,
        generation: 4
    )
    #expect(await testWaitUntil("coordinator leaves preparing") {
        coordinator.readiness != .preparing
    })
    if case .unavailable(let reason) = coordinator.readiness {
        Issue.record("Exact overlay reuse became unavailable: \(reason)")
        return
    }
    #expect(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: 4
    ) != nil)
    #expect(state.definitionCount == 3)

    versions.value = "fake-2"
    try coordinator.prepare(
        projectURL: fixture.root,
        revision: nil,
        analysisProfile: analysisProfileAfterLock,
        generation: 5
    )
    #expect(await testWaitUntil("coordinator leaves preparing") {
        coordinator.readiness != .preparing
    })
    if case .unavailable(let reason) = coordinator.readiness {
        Issue.record("Exact overlay reuse became unavailable: \(reason)")
        return
    }
    #expect(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: 5
    ) != nil)
    #expect(state.definitionCount == 4)

    try "[package]\nname='changed'\nversion='0.1.0'\n".write(
        to: fixture.root.appendingPathComponent("Cargo.toml"),
        atomically: true,
        encoding: .utf8
    )
    let exactProfileAfterCargo = try ExactProfileKey(
        projectURL: fixture.root
    )
    try coordinator.prepare(
        projectURL: fixture.root,
        revision: nil,
        analysisProfile: exactAnalysisProfile(
            language: .rust,
            configFingerprint: exactProfileAfterCargo.configFingerprint,
            environmentFingerprint: exactProfileAfterCargo.environmentFingerprint
        ),
        generation: 6
    )
    #expect(await testWaitUntil("coordinator leaves preparing") {
        coordinator.readiness != .preparing
    })
    if case .unavailable(let reason) = coordinator.readiness {
        Issue.record("Exact overlay reuse became unavailable: \(reason)")
        return
    }
    #expect(await coordinator.definition(
        file: "main.rs", byteOffset: 0, generation: 6
    ) != nil)
    #expect(state.definitionCount == 5)
}

@Test
func exactOverlayDoesNotReuseDefinitionsAcrossFeatureSelections() {
    var overlay = ExactOverlay()
    var providerCallCount = 0
    let defaultKey = exactReuseKey(featureSelection: .defaultFeatures)
    let allKey = exactReuseKey(featureSelection: .allFeatures)

    func resolve(_ key: ExactOverlay.ReuseKey) -> ExactOverlay.Entry? {
        if let cached = overlay.definition(
            for: key,
            file: "main.rs",
            byteOffset: 0
        ) {
            return cached.first
        }
        providerCallCount += 1
        let entry = exactEntry(file: "main.rs", byteOffset: 0)
        overlay.store([entry], for: key, file: "main.rs", byteOffset: 0)
        return entry
    }

    #expect(resolve(defaultKey) != nil)
    #expect(resolve(allKey) != nil)
    #expect(providerCallCount == 2)
}

@Test
func exactOverlayDoesNotReuseAcrossLanguageProfileOrEnvironment() {
    var overlay = ExactOverlay()
    var providerCallCount = 0
    let profileID = exactAnalysisProfile(language: .rust).id
    let keys = [
        exactReuseKey(analysisProfileID: profileID),
        exactReuseKey(language: .python, analysisProfileID: profileID),
        exactReuseKey(
            analysisProfileID: exactAnalysisProfile(
                language: .rust,
                projectUnitName: "other-unit"
            ).id
        ),
        exactReuseKey(
            analysisProfileID: profileID,
            environmentFingerprint: "other-environment"
        ),
    ]

    func resolve(_ key: ExactOverlay.ReuseKey) -> ExactOverlay.Entry? {
        if let cached = overlay.definition(
            for: key,
            file: "main.rs",
            byteOffset: 0
        ) {
            return cached.first
        }
        providerCallCount += 1
        let entry = exactEntry(file: "main.rs", byteOffset: 0)
        overlay.store([entry], for: key, file: "main.rs", byteOffset: 0)
        return entry
    }

    for key in keys {
        #expect(resolve(key) != nil)
    }
    #expect(providerCallCount == 4)
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
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })

    let request = Task {
        await coordinator.definition(file: "main.rs", byteOffset: 0, generation: 1)
    }
    #expect(await testWaitUntil("blocker.started") { blocker.started })
    coordinator.invalidate(generation: 2)
    blocker.release()

    #expect(await request.value == nil)
}

@MainActor
@Test
func exactCoordinatorMaterializesCommitRootAndMapsResultPath() async throws {
    let root = try exactTemporaryProject([
        "src/lib.rs": "pub fn target() {}\n",
        "src/main.rs": "use exact_test::target;\nfn main() { target(); }\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    try exactGit(root, "init", "-q")
    try exactGit(root, "config", "user.name", "CodeInsight Tests")
    try exactGit(root, "config", "user.email", "tests@codeinsight.invalid")
    try exactGit(root, "add", "-A")
    try exactGit(root, "commit", "-q", "-m", "fixture")
    let snapshot = try CommitSnapshot(repositoryURL: root)
    let profile = try ExactProfileKey(snapshot: snapshot)
    let materializer = Materializer(
        rootURL: root.appendingPathComponent("cache/materialized")
    )
    let expectedRoot = materializer.rootURL
        .appendingPathComponent(snapshot.commitOID.hex)
        .appendingPathComponent(profile.configFingerprint)
    let providerRoot = ExactVersionBox("")
    let state = ExactProviderState { _, _, _ in
        ExactLocation(
            file: expectedRoot.appendingPathComponent("src/lib.rs").path,
            byteOffset: 4,
            line: 1,
            column: 5
        )
    }
    let coordinator = ExactCoordinator(
        providerFactory: { root in
            providerRoot.value = root.path
            return ExactTestProvider(state: state)
        },
        snapshotFactory: { root, revision in
            try CommitSnapshot(
                repositoryURL: root,
                revision: revision ?? "HEAD"
            )
        },
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        ),
        materializer: materializer
    )

    try coordinator.prepare(
        projectURL: root,
        revision: "HEAD",
        analysisProfile: exactAnalysisProfile(
            language: .rust,
            projectUnitName: "exact-test",
            configFingerprint: profile.configFingerprint,
            environmentFingerprint: profile.environmentFingerprint
        ),
        generation: 1
    )
    #expect(await testWaitUntil("coordinator.readiness == .ready") { coordinator.readiness == .ready })
    let result = await coordinator.definition(
        file: "src/main.rs",
        byteOffset: 0,
        generation: 1
    )

    #expect(providerRoot.value == expectedRoot.path)
    #expect(providerRoot.value.contains(
        "materialized/\(snapshot.commitOID.hex)/"
    ))
    #expect(exactCompletedEntry(result)?.location.file == "src/lib.rs")
    #expect(exactCompletedEntry(result)?.origin == .materialized(
        commitOID: snapshot.commitOID.hex
    ))
}

@MainActor
@Test
func exactCoordinatorMaterializesNoConfigPythonCommitAndMapsResultPath()
    async throws
{
    let root = try exactTemporaryPythonProject([
        "main.py": "def target():\n    pass\n\ntarget()\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    try exactGit(root, "init", "-q")
    try exactGit(root, "config", "user.name", "CodeInsight Tests")
    try exactGit(root, "config", "user.email", "tests@codeinsight.invalid")
    try exactGit(root, "add", "-A")
    try exactGit(root, "commit", "-q", "-m", "fixture")
    let snapshot = try CommitSnapshot(repositoryURL: root)
    let profile = try ExactProfileKey(
        snapshot: snapshot,
        language: .python
    )
    let materializer = Materializer(
        rootURL: root.appendingPathComponent("cache/materialized")
    )
    let expectedRoot = materializer.rootURL
        .appendingPathComponent(snapshot.commitOID.hex)
        .appendingPathComponent(profile.configFingerprint)
    let providerRoot = ExactVersionBox("")
    let state = ExactProviderState { _, _, _ in
        ExactLocation(
            file: expectedRoot.appendingPathComponent("main.py").path,
            byteOffset: 4,
            line: 1,
            column: 5
        )
    }
    let coordinator = ExactCoordinator(
        providerFactory: { root, language in
            providerRoot.value = root.path
            return ExactTestProvider(language: language, state: state)
        },
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        ),
        materializer: materializer
    )

    try coordinator.prepare(
        projectURL: root,
        revision: "HEAD",
        analysisProfile: exactPythonProfile(
            language: .python,
            projectUnitName: root.lastPathComponent,
            configFingerprint: profile.configFingerprint,
            environmentFingerprint: profile.environmentFingerprint
        ),
        generation: 1
    )
    #expect(await testWaitUntil("coordinator.readiness == .ready") {
        coordinator.readiness == .ready
    })
    let result = await coordinator.definition(
        file: "main.py",
        byteOffset: 0,
        generation: 1
    )

    #expect(providerRoot.value == expectedRoot.path)
    #expect(exactCompletedEntry(result)?.location.file == "main.py")
    #expect(exactCompletedEntry(result)?.origin == .materialized(
        commitOID: snapshot.commitOID.hex
    ))
}

@MainActor
@Test
func exactCoordinatorMaterializesTypeScriptCommitAndMapsResultPath() async throws {
    let root = try exactTemporaryTypeScriptProject([
        "tools/ts/tsconfig.json": "{ \"compilerOptions\": {} }\n",
        "tools/ts/package.json": "{}\n",
        "tools/ts/src/lib.ts": "export function target(): void {}\n",
        "tools/ts/src/main.ts": "import { target } from './lib'; target();\n",
    ])
    let profilePrefix = "tools/ts"
    defer { try? FileManager.default.removeItem(at: root) }
    try exactGit(root, "init", "-q")
    try exactGit(root, "config", "user.name", "CodeInsight Tests")
    try exactGit(root, "config", "user.email", "tests@codeinsight.invalid")
    try exactGit(root, "add", "-A")
    try exactGit(root, "commit", "-q", "-m", "fixture")
    let snapshot = try CommitSnapshot(repositoryURL: root)
    let profile = try ExactProfileKey(
        snapshot: snapshot,
        language: .typescript,
        pathPrefix: profilePrefix
    )
    let materializer = Materializer(
        rootURL: root.appendingPathComponent("cache/materialized")
    )
    let expectedRoot = materializer.rootURL
        .appendingPathComponent(snapshot.commitOID.hex)
        .appendingPathComponent(profile.configFingerprint)
    let expectedProviderRoot = expectedRoot.appendingPathComponent(
        profilePrefix,
        isDirectory: true
    )
    let providerRoot = ExactVersionBox("")
    let state = ExactProviderState { _, _, _ in
        ExactLocation(
            file: expectedProviderRoot.appendingPathComponent("src/lib.ts").path,
            byteOffset: 4,
            line: 1,
            column: 5
        )
    }
    let coordinator = ExactCoordinator(
        providerFactory: { root, language in
            providerRoot.value = root.path
            return ExactTestProvider(language: language, state: state)
        },
        snapshotFactory: { root, revision in
            try CommitSnapshot(
                repositoryURL: root,
                revision: revision ?? "HEAD"
            )
        },
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(
            fileURL: root.appendingPathComponent("trust.json")
        ),
        materializer: materializer
    )

    try coordinator.prepare(
        projectURL: root,
        revision: "HEAD",
        analysisProfile: exactTypeScriptProfile(
            language: .typescript,
            projectUnitName: profilePrefix,
            configFingerprint: profile.configFingerprint,
            environmentFingerprint: profile.environmentFingerprint
        ),
        profileRoot: profilePrefix,
        generation: 1
    )
    #expect(await testWaitUntil("ts commit ready") {
        coordinator.readiness == .ready
    })
    let result = await coordinator.definition(
        file: "tools/ts/src/main.ts",
        byteOffset: 0,
        generation: 1
    )

    #expect(providerRoot.value == expectedProviderRoot.path)
    #expect(exactCompletedEntry(result)?.location.file == "tools/ts/src/lib.ts")
    #expect(exactCompletedEntry(result)?.origin == .materialized(
        commitOID: snapshot.commitOID.hex
    ))
}

@MainActor
@Test
func contextExactUpgradeKeepsEveryFuzzyCandidateAndSelectsExact() async throws {
    let source = """
        struct A; impl A { fn close(&self) {} }
        struct B; impl B { fn close(&self) {} }
        fn f<T>(value: T) { value.close(); }
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
    #expect(await testWaitUntil("model.candidateCount == 2 && gate.count == 1") { model.candidateCount == 2 && gate.count == 1 })
    let fuzzySymbols = exactSymbols(model)
    #expect(model.selectedCandidate?.provenanceBadge.contains("Exact") == false)

    gate.complete(0, with: exactEntry(
        file: "main.rs",
        byteOffset: secondDefinition
    ))

    #expect(await testWaitUntil("model.selectedCandidate?.provenanceBadge.contains(\"Exact\") == true") {
        model.selectedCandidate?.provenanceBadge.contains("Exact") == true
    })
    #expect(model.candidateCount == 2)
    #expect(Set(exactSymbols(model)) == Set(fuzzySymbols))
    #expect(model.selectedCandidate?.targetByteOffset == secondDefinition)
    #expect(model.selectedCandidate?.certainty == .exact)
    #expect(model.selectedCandidate?.exactAttribution?.environment.limitations
        == [.buildScriptsDisabled, .procMacrosDisabled])
    #expect(model.selectedCandidate?.exactOrigin == .worktree)
    #expect(model.selectedCandidate?.provenanceBadge.contains("materialized") == false)
    #expect(model.selectedCandidate?.provenanceBadge.contains(
        "features: default"
    ) == true)
    guard case .lsp = model.selectedCandidate?.provenance else {
        Issue.record("exact candidate did not carry LSP provenance")
        return
    }

    let commitOID = "0123456789abcdef"
    model.setMode(.pinned)
    #expect(await testWaitUntil("gate.count == 2") { gate.count == 2 })
    gate.complete(1, with: exactEntry(
        file: "main.rs",
        byteOffset: secondDefinition,
        origin: .materialized(commitOID: commitOID)
    ))
    #expect(await testWaitUntil("model.selectedCandidate?.provenanceBadge.contains(\"@0123456\") == true") {
        model.selectedCandidate?.provenanceBadge.contains("@0123456") == true
    })
    #expect(model.selectedCandidate?.exactOrigin == .materialized(
        commitOID: commitOID
    ))
    #expect(model.selectedCandidate?.provenanceBadge.contains("materialized") == true)
}

@MainActor
@Test
func pythonContextExactBadgeOmitsCargoFeatureDetail() async throws {
    let source = "def target():\n    pass\n\ntarget()\n"
    let root = try exactTemporaryPythonProject(["main.py": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root, language: .python)
    let context = exactQueryContext(for: session, generation: 1)
    let gate = ContextExactGate()
    let model = ContextWindowModel(
        { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        },
        exactResolver: gate.resolve
    )
    model.updateProjectState(.ready(session, context), root: root)

    model.tokenClicked(
        file: "main.py",
        offset: exactByteOffset(of: "target()", in: source)
    )
    #expect(await testWaitUntil("model.candidateCount == 1 && gate.count == 1") { model.candidateCount == 1 && gate.count == 1 })
    gate.complete(0, with: exactEntry(
        file: "main.py",
        byteOffset: exactByteOffset(of: "def target", in: source)
            + UInt32("def ".utf8.count),
        featureSelection: .allFeatures
    ))
    #expect(await testWaitUntil("model.selectedCandidate?.certainty == .exact") {
        model.selectedCandidate?.certainty == .exact
    })
    #expect(model.selectedCandidate?.provenanceBadge.contains("Exact") == true)
    #expect(model.selectedCandidate?.provenanceBadge.contains(
        "features:"
    ) == false)
    #expect(model.selectedCandidate?.provenanceBadge.contains(
        "fake-exact"
    ) == true)
}

@MainActor
@Test
func contextExactDependencyTargetProducesAnHonestCardAndExcerpt() async throws {
    let source = "fn target() {}\nfn main() { target(); }\n"
    let root = try exactTemporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let dependency = exactDependencyFixture()
    let dependencySource = try String(contentsOf: dependency, encoding: .utf8)
    let dependencyExcerptBytes = Array(
        dependencySource.trimmingCharacters(in: .newlines).utf8
    )
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

    model.tokenClicked(
        file: "main.rs",
        offset: exactByteOffset(of: "target();", in: source)
    )
    #expect(await testWaitUntil("model.candidateCount == 1 && gate.count == 1") { model.candidateCount == 1 && gate.count == 1 })
    gate.complete(0, with: exactEntry(
        file: dependency.path,
        byteOffset: exactByteOffset(
            of: "dependency_target",
            in: dependencySource
        )
    ))
    #expect(await testWaitUntil("model.selectedCandidate?.path == dependency.path") {
        model.selectedCandidate?.path == dependency.path
    })
    let candidate = try #require(model.selectedCandidate)

    #expect(model.candidateCount == 2)
    #expect(Array(candidate.excerpt.utf8) == dependencyExcerptBytes)
    #expect(candidate.label == "External · in dependency")
    #expect(candidate.provenanceBadge.contains("dependency-fixture"))
    #expect(candidate.provenanceBadge.contains("fake-exact"))
    #expect(candidate.provenanceBadge.contains("fake-1"))
    #expect(candidate.provenanceBadge.contains(
        "limitations: build scripts disabled; proc macros disabled"
    ))
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
    #expect(await testWaitUntil("gate.count == 1") { gate.count == 1 })
    model.tokenClicked(file: "main.rs", offset: betaCall)
    #expect(await testWaitUntil("gate.count == 2") { gate.count == 2 })
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
    let dependency = exactDependencyFixture()
    let dependencySource = try String(contentsOf: dependency, encoding: .utf8)
    let dependencyDefinition = exactByteOffset(
        of: "dependency_target",
        in: dependencySource
    )
    model.tokenClicked(file: "main.rs", offset: alphaCall)
    #expect(await testWaitUntil("model.candidateCount == 1 && gate.count == 1") { model.candidateCount == 1 && gate.count == 1 })
    let original = try #require(model.selectedCandidate)

    model.setMode(.pinned)
    #expect(await testWaitUntil("gate.count == 2") { gate.count == 2 })
    gate.complete(1, with: exactEntry(
        file: dependency.path,
        byteOffset: dependencyDefinition
    ))
    for _ in 0..<10 { await Task.yield() }
    #expect(model.selectedCandidate?.symbol == original.symbol)
    #expect(model.selectedCandidate?.targetByteOffset == original.targetByteOffset)
    #expect(model.candidateCount == 1)
    #expect(model.selectedCandidate?.certainty != .exact)

    model.setMode(.follow)
    model.setMode(.pinned)
    #expect(await testWaitUntil("gate.count == 3") { gate.count == 3 })
    gate.complete(2, with: exactEntry(
        file: "main.rs",
        byteOffset: alphaDefinition
    ))
    #expect(await testWaitUntil("model.selectedCandidate?.certainty == .exact") { model.selectedCandidate?.certainty == .exact })
    #expect(model.selectedCandidate?.symbol == original.symbol)
    #expect(model.selectedCandidate?.targetByteOffset == original.targetByteOffset)
    #expect(model.candidateCount == 1)

    gate.complete(0, with: exactEntry(
        file: dependency.path,
        byteOffset: dependencyDefinition
    ))
    for _ in 0..<10 { await Task.yield() }
    #expect(model.selectedCandidate?.symbol == original.symbol)
    #expect(model.selectedCandidate?.targetByteOffset == original.targetByteOffset)
    #expect(model.candidateCount == 1)
}

@MainActor
@Test
func dependencyCardFallsBackToTheAbsolutePathWhenCrateNameIsUnknown()
    async throws
{
    let source = "fn target() {}\nfn main() { target(); }\n"
    let root = try exactTemporaryProject(["main.rs": source])
    let dependencyRoot = try exactTemporaryProject([
        "release-1.2.3/src/lib.rs": "pub fn unknown_dependency() {}\n",
    ])
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: dependencyRoot)
    }
    let dependency = dependencyRoot.appendingPathComponent(
        "release-1.2.3/src/lib.rs"
    )
    let dependencySource = try String(contentsOf: dependency, encoding: .utf8)
    let session = try ProjectIndexer().index(root: root)
    let context = exactQueryContext(for: session, generation: 1)
    let model = ContextWindowModel(
        { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        },
        exactResolver: { _, _, _, _ in
            .completed([exactEntry(
                file: dependency.path,
                byteOffset: exactByteOffset(
                    of: "unknown_dependency",
                    in: dependencySource
                )
            )])
        }
    )
    model.updateProjectState(.ready(session, context), root: root)

    model.tokenClicked(
        file: "main.rs",
        offset: exactByteOffset(of: "target();", in: source)
    )
    #expect(await testWaitUntil("model.selectedCandidate?.path == dependency.path") {
        model.selectedCandidate?.path == dependency.path
    })

    #expect(model.selectedCandidate?.provenanceBadge.contains(dependency.path) == true)
}

private final class ExactTestProvider: ExactProvider, @unchecked Sendable {
    var capabilities: ExactCapabilities {
        state.hasReferencesCapability
            ? [.definition, .references]
            : [.definition]
    }
    let language: LanguageID
    let toolVersion: String
    private let state: ExactProviderState

    init(
        language: LanguageID = .rust,
        toolVersion: String = "fake-1",
        state: ExactProviderState
    ) {
        self.language = language
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
                featureSelection: profile.featureSelection,
                environment: ExactAnalysisEnvironment(
                    trustMode: trustMode,
                    limitations: trustMode == .safe
                        ? [.buildScriptsDisabled, .procMacrosDisabled]
                        : []
                ),
                generatedAt: Date(timeIntervalSince1970: 0)
            )
        )
    }
}

private final class ExactProviderState: @unchecked Sendable {
    typealias Behavior = @Sendable (Int, String, Int) throws -> ExactLocation?

    private let lock = NSLock()
    private let behavior: Behavior
    private let referencesValue: [ExactLocation]?
    private var prepares = 0
    private var definitions = 0
    private var modes: [String] = []
    private var features: [FeatureSelection] = []
    private var languages: [LanguageID] = []
    private var roots: [URL] = []
    private var requestFiles: [String] = []
    private var closed: Set<Int> = []
    private weak var latestSession: ExactStateSession?

    init(
        behavior: @escaping Behavior = { _, _, _ in
            ExactLocation(file: "main.rs", byteOffset: 0, line: 1, column: 1)
        },
        references: [ExactLocation]? = nil
    ) {
        self.behavior = behavior
        referencesValue = references
    }

    var prepareCount: Int { locked { prepares } }
    var definitionCount: Int { locked { definitions } }
    var filesRequested: [String] { locked { requestFiles } }
    var prepareLanguages: [LanguageID] { locked { languages } }
    var prepareRoots: [URL] { locked { roots } }
    var trustModes: [String] { locked { modes } }
    var featureSelections: [FeatureSelection] { locked { features } }
    var closedSessions: Set<Int> { locked { closed } }
    var references: [ExactLocation]? { referencesValue }
    var hasReferencesCapability: Bool { referencesValue != nil }

    func makeSession(
        attribution: ExactAttribution
    ) -> ExactStateSession {
        let ordinal = locked {
            prepares += 1
            let mode = switch attribution.environment.trustMode {
            case .safe: "safe"
            case .trusted: "trusted"
            }
            modes.append(mode)
            features.append(attribution.featureSelection)
            return prepares
        }
        let session = ExactStateSession(
            attribution: attribution,
            ordinal: ordinal,
            state: self
        )
        locked { latestSession = session }
        return session
    }

    func recordPrepare(language: LanguageID, root: URL) {
        locked {
            languages.append(language)
            roots.append(root)
        }
    }

    func define(ordinal: Int, file: String, byteOffset: Int) throws -> ExactLocation? {
        locked {
            definitions += 1
            requestFiles.append(file)
        }
        return try behavior(ordinal, file, byteOffset)
    }

    func close(ordinal: Int) {
        _ = locked { closed.insert(ordinal) }
    }

    func publishEnvironment(_ environment: ExactAnalysisEnvironment) {
        locked { latestSession }?.publishEnvironment(environment)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ExactStateSession: ExactSession, @unchecked Sendable {
    var negotiatedCapabilities: ExactCapabilities {
        state.hasReferencesCapability
            ? [.definition, .references]
            : [.definition]
    }
    let readiness: ExactReadiness = .ready
    private let lock = NSLock()
    private var storedAttribution: ExactAttribution
    private var environmentObserver: (@Sendable (ExactAnalysisEnvironment) -> Void)?
    private let ordinal: Int
    private let state: ExactProviderState

    var attribution: ExactAttribution {
        lock.lock()
        defer { lock.unlock() }
        return storedAttribution
    }

    var onEnvironmentChange: (@Sendable (ExactAnalysisEnvironment) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return environmentObserver
        }
        set {
            lock.lock()
            environmentObserver = newValue
            let environment = storedAttribution.environment
            lock.unlock()
            newValue?(environment)
        }
    }

    init(
        attribution: ExactAttribution,
        ordinal: Int,
        state: ExactProviderState
    ) {
        storedAttribution = attribution
        self.ordinal = ordinal
        self.state = state
    }

    func definition(
        file: String,
        byteOffset: Int
    ) throws -> ExactDefinitionQueryResult {
        .completed(try state.define(
            ordinal: ordinal,
            file: file,
            byteOffset: byteOffset
        ).map { [ExactTarget(location: $0)] } ?? [])
    }

    func implementations(
        file: String,
        byteOffset: Int
    ) throws -> [ExactLocation]? {
        nil
    }

    func references(
        file: String,
        byteOffset: Int,
        includeDeclaration: Bool
    ) throws -> [ExactLocation]? {
        state.references
    }

    func prepareCallHierarchy(
        file: String,
        byteOffset: Int
    ) throws -> [ExactCallHierarchyItem]? {
        nil
    }

    func incomingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]? {
        nil
    }

    func outgoingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]? {
        nil
    }

    func publishEnvironment(_ environment: ExactAnalysisEnvironment) {
        lock.lock()
        storedAttribution = ExactAttribution(
            provider: storedAttribution.provider,
            toolVersion: storedAttribution.toolVersion,
            configFingerprint: storedAttribution.configFingerprint,
            environmentFingerprint: storedAttribution.environmentFingerprint,
            featureSelection: storedAttribution.featureSelection,
            environment: environment,
            generatedAt: storedAttribution.generatedAt
        )
        let observer = environmentObserver
        lock.unlock()
        observer?(environment)
    }

    func cancel() {}
    func close() { state.close(ordinal: ordinal) }
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
    let language: LanguageID = .rust
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
            featureSelection: profile.featureSelection,
            environment: ExactAnalysisEnvironment(
                trustMode: trustMode,
                limitations: [.buildScriptsDisabled, .procMacrosDisabled]
            ),
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        return session
    }
}

private final class BlockingExactSession: ExactSession, @unchecked Sendable {
    let negotiatedCapabilities: ExactCapabilities = [.definition]
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

    func definition(
        file: String,
        byteOffset: Int
    ) throws -> ExactDefinitionQueryResult {
        condition.lock()
        didStart = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
        return .completed([ExactTarget(location: ExactLocation(
            file: file,
            byteOffset: 0,
            line: 1,
            column: 1
        ))])
    }

    func implementations(
        file: String,
        byteOffset: Int
    ) throws -> [ExactLocation]? {
        nil
    }

    func references(
        file: String,
        byteOffset: Int,
        includeDeclaration: Bool
    ) throws -> [ExactLocation]? {
        nil
    }

    func prepareCallHierarchy(
        file: String,
        byteOffset: Int
    ) throws -> [ExactCallHierarchyItem]? {
        nil
    }

    func incomingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]? {
        nil
    }

    func outgoingCalls(
        item: ExactCallHierarchyItem
    ) throws -> [ExactCallRelation]? {
        nil
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
    private var continuations: [
        Int: CheckedContinuation<ExactCoordinator.DefinitionResult?, Never>
    ] = [:]
    private var nextID = 0

    var count: Int { nextID }
    private(set) var batches: [ExactRequestBatch] = []

    func resolve(
        file: String,
        offset: UInt32,
        generation: UInt64,
        batch: ExactRequestBatch
    ) async -> ExactCoordinator.DefinitionResult? {
        let id = nextID
        nextID += 1
        batches.append(batch)
        return await withCheckedContinuation { continuations[id] = $0 }
    }

    func complete(_ id: Int, with entry: ExactOverlay.Entry?) {
        continuations.removeValue(forKey: id)?.resume(
            returning: .completed(entry.map { [$0] } ?? [])
        )
    }
}

private struct ExactTestFixture {
    let root: URL
    let files = [
        "Cargo.toml": "[package]\nname='exact-test'\nversion='0.1.0'\n",
        "main.rs": "fn target() {}\nfn main() { target(); }\n",
    ]
    let trustRegistry: TrustRegistry
    let trustFile: URL

    init() throws {
        root = try exactTemporaryProject(files)
        trustFile = root.appendingPathComponent("trust.json")
        trustRegistry = TrustRegistry(fileURL: trustFile)
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

private func exactEntry(
    file: String,
    byteOffset: UInt32,
    origin: ExactOrigin = .worktree,
    featureSelection: FeatureSelection = .defaultFeatures
) -> ExactOverlay.Entry {
    ExactOverlay.Entry(
        location: ExactLocation(
            file: file,
            byteOffset: Int(byteOffset),
            line: 1,
            column: Int(byteOffset) + 1
        ),
        attribution: ExactAttribution(
            provider: "fake-exact",
            toolVersion: "fake-1",
            configFingerprint: "config",
            environmentFingerprint: "environment",
            featureSelection: featureSelection,
            environment: exactAttribution().environment,
            generatedAt: Date(timeIntervalSince1970: 0)
        ),
        origin: origin
    )
}

private func exactAttribution() -> ExactAttribution {
    ExactAttribution(
        provider: "fake-exact",
        toolVersion: "fake-1",
        configFingerprint: "config",
        environmentFingerprint: "environment",
        environment: ExactAnalysisEnvironment(
            trustMode: .safe,
            limitations: [.buildScriptsDisabled, .procMacrosDisabled]
        ),
        generatedAt: Date(timeIntervalSince1970: 0)
    )
}

private func exactAnalysisProfile(
    language: LanguageID,
    projectUnitName: String = "exact-test",
    configFingerprint: String = "analysis-config",
    environmentFingerprint: String = "analysis-environment",
    featureSelection: FeatureSelection = .defaultFeatures
) -> AnalysisProfile {
    AnalysisProfile(
        language: language,
        projectRoot: PathID(rawValue: 0),
        projectUnitName: projectUnitName,
        configFingerprint: configFingerprint,
        environmentFingerprint: environmentFingerprint,
        featureSelection: featureSelection,
        featureNames: [],
        edition: nil,
        trustMode: .safe
    )
}

private func exactReuseKey(
    language: LanguageID = .rust,
    analysisProfileID: AnalysisProfileID = exactAnalysisProfile(language: .rust).id,
    environmentFingerprint: String = "environment",
    featureSelection: FeatureSelection = .defaultFeatures
) -> ExactOverlay.ReuseKey {
    return ExactOverlay.ReuseKey(
        versionIdentity: "worktree:/fixture",
        language: language,
        analysisProfileID: analysisProfileID,
        configFingerprint: "config",
        environmentFingerprint: environmentFingerprint,
        featureSelection: featureSelection,
        trustMode: .safe,
        toolVersion: "fake-1"
    )
}

@MainActor
private func exactSymbols(_ model: ContextWindowModel) -> [SymbolOccurrenceID] {
    guard case let .candidates(candidates, _) = model.stage else { return [] }
    return candidates.compactMap(\.symbol)
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

private func exactTemporaryPythonProject(
    _ files: [String: String]
) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightExactCoordinatorPythonTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
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

private func exactTemporaryTypeScriptProject(
    _ files: [String: String]
) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightExactCoordinatorTypeScriptTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
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

private func exactPythonProfile(
    language: LanguageID,
    projectUnitName: String = "python-test",
    configFingerprint: String,
    environmentFingerprint: String
) -> AnalysisProfile {
    AnalysisProfile(
        language: language,
        projectRoot: PathID(rawValue: 0),
        projectUnitName: projectUnitName,
        configFingerprint: configFingerprint,
        environmentFingerprint: environmentFingerprint,
        featureSelection: .defaultFeatures,
        featureNames: [],
        edition: nil,
        trustMode: .safe
    )
}

private func exactTypeScriptProfile(
    language: LanguageID,
    projectUnitName: String = "typescript-test",
    configFingerprint: String,
    environmentFingerprint: String
) -> AnalysisProfile {
    AnalysisProfile(
        language: language,
        projectRoot: PathID(rawValue: 0),
        projectUnitName: projectUnitName,
        configFingerprint: configFingerprint,
        environmentFingerprint: environmentFingerprint,
        featureSelection: .defaultFeatures,
        featureNames: [],
        edition: nil,
        trustMode: .safe
    )
}

func exactDependencyFixture() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            "Tests/CodeInsightExactTests/Fixtures/fake-registry/registry/src/"
                + "index.crates.io-1949cf8c6b5b557f/"
                + "dependency-fixture-1.2.3/src/lib.rs"
        )
}

private func exactGit(_ root: URL, _ arguments: String...) throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ExactTestError.git(
            String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "git failed"
        )
    }
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

private func exactCompletedEntry(
    _ result: ExactCoordinator.DefinitionResult?
) -> ExactOverlay.Entry? {
    guard case .completed(let entries) = result else { return nil }
    return entries.first
}

private enum ExactTestError: Error {
    case missing(String)
    case git(String)
}
