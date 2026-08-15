import CodeInsightCore
import CodeInsightExact
import CodeInsightGit
import CodeInsightReaderCore
import Foundation
import os
import Testing
@testable import CodeInsightAppModel
@testable import CodeInsightEngine

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@MainActor
@Test
func navigationHistoryTruncatesForwardEntriesAfterNewPush() {
    let history = NavigationHistory()
    let a = jumpRecord("a.rs", offset: 10)
    let b = jumpRecord("b.rs", offset: 20)
    let c = jumpRecord("c.rs", offset: 30)

    history.push(a)
    history.push(b)
    #expect(history.goBack(from: c) == b)
    history.push(b)

    #expect(history.records == [a, b])
    #expect(!history.canGoForward)
}

@MainActor
@Test
func navigationHistoryReplacesCurrentRecordWhenBranchingAfterBack() {
    let history = NavigationHistory()
    let a = jumpRecord("a.rs", offset: 10)
    let b = jumpRecord("b.rs", offset: 20)
    let movedB = jumpRecord("b.rs", offset: 21)
    let c = jumpRecord("c.rs", offset: 30)

    history.push(a)
    history.push(b)
    #expect(history.goBack(from: c) == b)
    history.push(movedB)

    #expect(history.records == [a, movedB])
    #expect(!history.canGoForward)
}

@MainActor
@Test
func navigationHistoryDeduplicatesAdjacentRecords() {
    let history = NavigationHistory()
    let record = jumpRecord("main.rs", offset: 7)

    history.push(record)
    history.push(record)

    #expect(history.records == [record])
}

@MainActor
@Test
func navigationHistoryEvictsTheOldestRecordAboveTwoHundred() {
    let history = NavigationHistory()

    for index in 0...200 {
        history.push(jumpRecord("\(index).rs", offset: UInt32(index)))
    }

    #expect(history.records.count == 200)
    #expect(history.records.first?.path == "1.rs")
    #expect(history.records.last?.path == "200.rs")
}

@MainActor
@Test
func navigationHistoryBackAndForwardDoNotPush() {
    let history = NavigationHistory()
    let a = jumpRecord("a.rs", offset: 10)
    let b = jumpRecord("b.rs", offset: 20)
    let c = jumpRecord("c.rs", offset: 30)
    history.push(a)
    history.push(b)
    let count = history.records.count

    #expect(history.goBack(from: c) == b)
    #expect(history.goBack(from: b) == a)
    #expect(history.goForward() == b)
    #expect(history.records.count == count)
}

@MainActor
@Test
func navigationReplayFallsBackToLineAndColumnAfterFileShrinks() async throws {
    let root = try temporaryProject([
        "a.rs": "first line\nsecond line is initially long\n",
        "b.rs": "fn b() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var opened: [(String, UInt32?)] = []
    let model = AppModel(indexService: FailingIndexService()) { file, offset in
        opened.append((file.lastPathComponent, offset))
    }
    model.openProject(root: root)
    #expect(await testWaitUntil("model.fileTree != nil") { model.fileTree != nil })
    let a = root.appendingPathComponent("a.rs")
    let b = root.appendingPathComponent("b.rs")
    let oldA = jumpRecord("a.rs", offset: 100, line: 2, column: 2)

    model.navigate(to: a)
    model.navigate(to: b, leaving: oldA)
    try write("x\ny", to: a)
    model.goBack(from: jumpRecord("b.rs", offset: 0))

    #expect(opened.last?.0 == "b.rs")
    #expect(await testWaitUntil("opened.last?.0 == \"a.rs\" && opened.last?.1 == 3") { opened.last?.0 == "a.rs" && opened.last?.1 == 3 })
    #expect(model.replayNotice == "restored by line and column")
}

@Test
func replayOffsetUsesFiveHonestFallbacksAndRejectsInvalidScalars() throws {
    let source = "fn target() {}\nlet value = \"世\";\n"
    let root = try temporaryProject(["a.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("a.rs")
    let contentID = ContentID.sha256(of: Array(source.utf8))
    let mismatch = ContentID.sha256(of: [0])
    let targetOffset = byteOffset(of: "target", in: source)

    let exact = try AppModel.replayOffset(
        jumpRecord(
            "a.rs",
            contentID: contentID,
            offset: targetOffset,
            line: 1,
            column: targetOffset + 1
        ),
        file: file,
        source: nil
    )
    #expect(exact.offset == targetOffset)
    #expect(exact.fallback == .exact)
    let explicitVariant = try AppModel.replayOffset(
        jumpRecord(
            "a.rs",
            contentID: contentID,
            offset: targetOffset,
            line: 1,
            column: targetOffset + 1
        ),
        file: file,
        source: nil,
        languageMode: LanguageMode(language: .rust, variant: "reader-test")
    )
    #expect(explicitVariant.offset == exact.offset)
    #expect(explicitVariant.fallback == exact.fallback)

    let unverified = try AppModel.replayOffset(
        jumpRecord("a.rs", offset: targetOffset),
        file: file,
        source: nil
    )
    #expect(unverified.offset == targetOffset)
    #expect(unverified.fallback == .byteUnverified)

    let line = try AppModel.replayOffset(
        jumpRecord(
            "a.rs",
            contentID: mismatch,
            offset: targetOffset,
            line: 2,
            column: 2
        ),
        file: file,
        source: nil
    )
    #expect(line.offset == UInt32("fn target() {}\nl".utf8.count))
    #expect(line.fallback == .line)

    let symbol = try AppModel.replayOffset(
        jumpRecord(
            "a.rs",
            contentID: mismatch,
            offset: 999,
            line: 99,
            column: 99,
            symbolAnchor: "target"
        ),
        file: file,
        source: nil
    )
    #expect(symbol.offset == targetOffset)
    #expect(symbol.fallback == .symbol)

    let fileHead = try AppModel.replayOffset(
        jumpRecord(
            "a.rs",
            contentID: mismatch,
            offset: 999,
            line: 99,
            column: 99
        ),
        file: file,
        source: nil
    )
    #expect(fileHead.offset == 0)
    #expect(fileHead.fallback == .fileHead)

    let scalarStart = byteOffset(of: "世", in: source)
    let invalidScalar = try AppModel.replayOffset(
        jumpRecord(
            "a.rs",
            contentID: contentID,
            offset: scalarStart + 1,
            line: 99,
            column: 99
        ),
        file: file,
        source: nil
    )
    #expect(invalidScalar.offset == 0)
    #expect(invalidScalar.fallback == .fileHead)
}

@Test
func replayOffsetUsesASymbolOnlyWhenItsDeclarationIsUnique() throws {
    let source = "fn repeated() {}\nfn repeated() {}\n"
    let root = try temporaryProject(["a.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let restored = try AppModel.replayOffset(
        jumpRecord(
            "a.rs",
            contentID: ContentID.sha256(of: [0]),
            offset: 999,
            line: 99,
            column: 99,
            symbolAnchor: "repeated"
        ),
        file: root.appendingPathComponent("a.rs"),
        source: nil
    )

    #expect(restored.offset == 0)
    #expect(restored.fallback == .fileHead)
}

@MainActor
@Test
func appModelRoutesEveryNavigationAndHistoryReplayThroughOnePipeline() async throws {
    let source = String(repeating: "0123456789", count: 10)
    let root = try temporaryProject([
        "a.rs": source,
        "b.rs": source,
        "c.rs": source,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var opened: [(String, UInt32?)] = []
    let model = AppModel(indexService: FailingIndexService()) { file, offset in
        opened.append((file.lastPathComponent, offset))
    }
    model.openProject(root: root)
    #expect(await testWaitUntil("model.fileTree != nil") { model.fileTree != nil })

    model.navigate(to: root.appendingPathComponent("a.rs"), byteOffset: 10)
    model.navigate(
        to: root.appendingPathComponent("b.rs"),
        byteOffset: 20,
        leaving: jumpRecord("a.rs", offset: 10)
    )
    model.navigate(
        to: root.appendingPathComponent("c.rs"),
        byteOffset: 30,
        leaving: jumpRecord("b.rs", offset: 20)
    )
    model.goBack(from: jumpRecord("c.rs", offset: 30))
    #expect(await testWaitUntil("opened.count == 4") { opened.count == 4 })
    model.goBack(from: jumpRecord("b.rs", offset: 20))
    #expect(await testWaitUntil("opened.count == 5") { opened.count == 5 })
    model.goForward()
    #expect(await testWaitUntil("opened.count == 6") { opened.count == 6 })

    #expect(opened.map { "\($0.0):\($0.1 ?? 0)" } == [
        "a.rs:10", "b.rs:20", "c.rs:30", "b.rs:20", "a.rs:10", "b.rs:20",
    ])
}

@MainActor
@Test
func navigationRequestKeepsCausePolicyAndReplaySemantics() async throws {
    let root = try temporaryProject([
        "a.rs": "fn a() {}\n",
        "b.rs": "fn b() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: FailingIndexService())
    model.openProject(root: root)
    #expect(await testWaitUntil("model.fileTree != nil") { model.fileTree != nil })
    let request = NavigationRequest(
        destination: SourceDestination(
            file: root.appendingPathComponent("b.rs"),
            byteOffset: 4
        ),
        cause: .relation,
        policy: .explicitSemantic
    )

    model.navigate(request, leaving: jumpRecord("a.rs", offset: 0))

    #expect(model.activeNavigationRequest?.cause == .relation)
    #expect(model.activeNavigationRequest?.policy == .explicitSemantic)
    model.goBack(from: jumpRecord("b.rs", offset: 4))
    #expect(await testWaitUntil("replay request published") {
        model.activeNavigationRequest?.cause == .historyReplay
    })
    #expect(model.activeNavigationRequest?.policy == .replay)
}

@MainActor
@Test
func readingTrailBranchesFromRestoredHistoryIdentity() async throws {
    let root = try temporaryProject([
        "a.rs": "fn a() {}\n",
        "b.rs": "fn b() {}\n",
        "c.rs": "fn c() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: FailingIndexService())
    model.openProject(root: root)
    #expect(await testWaitUntil("model.fileTree != nil") {
        model.fileTree != nil
    })
    let a = root.appendingPathComponent("a.rs")
    let b = root.appendingPathComponent("b.rs")
    let c = root.appendingPathComponent("c.rs")
    let aJump = jumpRecord("a.rs", offset: 3)
    let bJump = jumpRecord("b.rs", offset: 3)

    model.navigate(to: a, byteOffset: 3)
    let aNodeID = try #require(model.readingTrail.activeNodeID)
    model.navigate(to: b, byteOffset: 3, leaving: aJump)
    let bNodeID = try #require(model.readingTrail.activeNodeID)
    #expect(model.readingTrail.edges.map(\.from) == [aNodeID])
    #expect(model.readingTrail.edges.map(\.to) == [bNodeID])
    #expect(model.navigationHistory.navigationRecords.first?.trailNodeID == aNodeID)

    model.goBack(from: bJump)
    #expect(await testWaitUntil("trail restores the prior visit identity") {
        model.readingTrail.activeNodeID == aNodeID
            && model.selectedFile == a
    })
    model.navigate(to: c, byteOffset: 3, leaving: aJump)

    #expect(model.readingTrail.nodes.count == 3)
    #expect(model.readingTrail.edges.count == 2)
    #expect(model.readingTrail.edges.allSatisfy { $0.from == aNodeID })
    #expect(Set(model.readingTrail.edges.map(\.to)) == [
        bNodeID,
        try #require(model.readingTrail.activeNodeID),
    ])
    #expect(model.readingTrail.edges.map(\.cause) == [
        .fileSelection,
        .fileSelection,
    ])

    model.restoreTrailNode(bNodeID)
    #expect(await testWaitUntil("trail node replay restores the selected visit") {
        model.readingTrail.activeNodeID == bNodeID
            && model.selectedFile == b
    })
    #expect(model.activeNavigationRequest?.cause == .historyReplay)
    #expect(model.readingTrail.edges.count == 2)
}

@MainActor
@Test
func trailExplanationSnapshotStaysFixedWhileStoreAdvances() throws {
    let store = ResolutionExplanationStore()
    let trail = ReadingTrail()
    let candidate = CandidateObservation(
        target: .unresolved(UnresolvedSymbolRef(
            nameID: NameID(rawValue: 1),
            hintKind: .unqualified
        )),
        certainty: .possible,
        dispatch: .direct,
        provenance: .fuzzyResolver,
        completeness: .partial,
        evidence: []
    )
    let observed = MaterializedResolutionExplanation(
        trace: .candidateOnly(candidate)
    )
    let explanationID = store.create(observed)
    let navigationExplanation = NavigationExplanation(
        explanationID: explanationID,
        observedAtNavigation: ResolutionExplanationSnapshot(
            explanation: observed,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    )
    let a = jumpRecord("a.rs", offset: 1)
    let b = jumpRecord("b.rs", offset: 2)
    _ = trail.recordNavigation(
        from: a,
        to: b,
        explanation: navigationExplanation
    )
    let upgradedCandidate = CandidateObservation(
        target: candidate.target,
        certainty: .strong,
        dispatch: candidate.dispatch,
        provenance: candidate.provenance,
        completeness: .complete,
        evidence: candidate.evidence
    )
    store.update(explanationID, to: MaterializedResolutionExplanation(
        trace: .candidateOnly(upgradedCandidate)
    ))

    let edge = try #require(trail.edges.first)
    guard case .candidateOnly(let observedCandidate) =
        edge.observedAtNavigation?.explanation.trace,
          case .candidateOnly(let currentCandidate) =
            store.value(for: explanationID)?.trace
    else {
        Issue.record("expected materialized candidate-only traces")
        return
    }
    #expect(edge.currentExplanationID == explanationID)
    #expect(observedCandidate.certainty == .possible)
    #expect(currentCandidate.certainty == .strong)
}

@MainActor
@Test
func relationRootResetRetainsTrailMaterializationsWithoutLiveReferences()
    async throws
{
    let root = try temporaryProject([
        "main.rs": "fn b() {}\nfn a() { b(); }\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
    let a = try #require(
        session.definitions(of: "a", context: context).first?.0
    )
    let model = AppModel(indexService: FailingIndexService())
    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
    #expect(model.transition(to: .ready(session, context)))
    await model.relationTree.setRoot(
        target: .engine(a),
        direction: .calls
    )?.value
    let children = model.relationTree.root?.children ?? []
    let rows = children.flatMap {
        $0.kind == .group ? $0.children ?? [] : [$0]
    }
    let row = try #require(rows.first {
        $0.kind == .edge && $0.title == "b"
    })
    let candidateNavigation = try #require(
        model.navigationExplanation(for: row)
    )
    let oldContextID = try #require(row.explanation?.contextID)
    let source = jumpRecord(
        "main.rs",
        offset: 14,
        snapshotID: session.snapshotID
    )
    let destination = jumpRecord(
        "main.rs",
        offset: 3,
        snapshotID: session.snapshotID
    )
    _ = model.readingTrail.recordNavigation(
        from: source,
        to: destination,
        explanation: candidateNavigation
    )

    guard case .candidateOnly(let candidate) =
        candidateNavigation.observedAtNavigation.explanation.trace
    else {
        Issue.record("expected a candidate-only relation trace")
        return
    }
    let conflict = MaterializedResolutionExplanation(trace: .conflict(
        candidate: candidate,
        reconciliation: ReconciliationSnapshot(CallSiteReconciliation(
            querySite: SourceLocation(path: "main.rs", byteOffset: 18),
            candidates: [candidate],
            providerTargets: [],
            roles: [.correctedCandidate(candidateIndex: 0)]
        ))
    ))
    let conflictID = model.resolutionExplanations.create(conflict)
    _ = model.readingTrail.recordNavigation(
        from: destination,
        to: source,
        explanation: NavigationExplanation(
            explanationID: conflictID,
            observedAtNavigation: ResolutionExplanationSnapshot(
                explanation: conflict
            )
        )
    )

    model.relationTree.setRoot(target: .engine(a), direction: .callers)

    #expect(model.relationTree.relationQueryContexts[oldContextID] == nil)
    #expect(model.resolutionExplanations.value(
        for: candidateNavigation.explanationID
    ) != nil)
    guard case .conflict = model.resolutionExplanations.value(
        for: conflictID
    )?.trace else {
        Issue.record("materialized conflict must survive without a live context")
        return
    }
}

@MainActor
@Test
func outlineFollowArbitrationClearsOnlyOnLiveScroll() {
    var arbitration = OutlineFollowArbitration()
    arbitration.apply(NavigationRequest(
        destination: SourceDestination(file: URL(fileURLWithPath: "/tmp/a.rs")),
        cause: .outline,
        policy: .explicitSemantic
    ))
    #expect(arbitration.suppressedBy == .outline)

    arbitration.didLiveScroll()

    #expect(arbitration.suppressedBy == nil)
}

@MainActor
@Test
func navigationHistoryReplaysAnAbsoluteDependencyPath() async throws {
    let root = try temporaryProject(["main.rs": "fn main() {}\n"])
    let dependencyRoot = try temporaryProject([
        "dependency.rs": "pub fn dependency() {}\n",
    ])
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: dependencyRoot)
    }
    let dependency = dependencyRoot.appendingPathComponent("dependency.rs")
    var opened: [URL] = []
    let model = AppModel(indexService: FailingIndexService()) { file, _ in
        opened.append(file.standardizedFileURL)
    }
    model.openProject(root: root)
    #expect(await testWaitUntil("model.fileTree != nil") { model.fileTree != nil })

    let projectFile = root.appendingPathComponent("main.rs")
    model.navigate(to: projectFile)
    model.navigate(
        to: dependency,
        leaving: jumpRecord("main.rs", offset: 0, snapshotID: nil)
    )
    model.goBack(from: jumpRecord(
        dependency.path,
        offset: 0,
        snapshotID: nil
    ))
    #expect(await testWaitUntil("opened.count == 3") { opened.count == 3 })
    model.goForward()
    #expect(await testWaitUntil("opened.count == 4") { opened.count == 4 })

    #expect(opened == [
        projectFile.standardizedFileURL,
        dependency.standardizedFileURL,
        projectFile.standardizedFileURL,
        dependency.standardizedFileURL,
    ])
}

@MainActor
@Test
func projectStateAcceptsLegalTransitions() {
    let model = AppModel()
    let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
    #expect(model.transition(to: .failed))
    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
}

@MainActor
@Test
func projectStateRejectsIllegalTransitions() {
    let model = AppModel()
    let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

    #expect(!model.transition(to: .failed))
    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
    #expect(!model.transition(to: .indexing(root: root, startedAt: .now)))
}

@MainActor
@Test
func navigationPushesWhileProjectIsIndexing() {
    let model = AppModel()
    let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
    let a = jumpRecord("a.rs", offset: 10, snapshotID: nil)

    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
    model.navigate(to: root.appendingPathComponent("a.rs"))
    model.navigate(to: root.appendingPathComponent("b.rs"), leaving: a)

    #expect(model.navigationHistory.records == [a])
}

@Test
func fileTreeUsesTheSharedRustClassifierAcrossBothSources() throws {
    let root = try temporaryProject([
        "z.rs": "",
        "a.rs": "",
        "README.md": "ignored",
        "src/z.rs": "",
        "src/a.rs": "",
        "empty/note.txt": "ignored",
        "upper.RS": "ignored",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    for skipped in ProjectIndexer.skippedDirectories {
        try write("", to: root.appendingPathComponent(skipped).appendingPathComponent("skip.rs"))
    }

    let compatibility = try FileTreeModel(root: root)
    let tree = try FileTreeModel(root: root, language: .rust)

    #expect(tree.children.map(\.name) == ["src", "a.rs", "z.rs"])
    #expect(tree.children[0].children.map(\.name) == ["a.rs", "z.rs"])
    #expect(tree.fileCount == 4)
    #expect(
        tree.selectionPath(for: root.appendingPathComponent("src/a.rs"))?
            .map(\.name) == ["src", "a.rs"]
    )
    #expect(tree.selectionPath(for: root.appendingPathComponent("missing.rs")) == nil)
    #expect(tree.selectionPath(for: nil) == nil)
    #expect(tree.children.map(\.name) == compatibility.children.map(\.name))
    #expect(tree.fileCount == compatibility.fileCount)

    let snapshot = FileTreeModel(
        root: root,
        snapshotPaths: ["src/a.rs", "src/ignored.py", "README.md"],
        language: .rust
    )
    #expect(snapshot.children.map(\.name) == ["src"])
    #expect(snapshot.children[0].children.map(\.name) == ["a.rs"])
    #expect(snapshot.fileCount == 1)
}

@MainActor
@Test
func projectOpenPublishesFileTreeAsynchronously() async throws {
    let root = try temporaryProject(["main.rs": "fn main() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: FailingIndexService())

    model.openProject(root: root)

    #expect(model.fileTree == nil)
    #expect(await testWaitUntil("model.fileTree?.fileCount == 1") { model.fileTree?.fileCount == 1 })
}

@MainActor
@Test
func unsupportedJavaScriptOpenIsSynchronousAndAtomic() async {
    let service = ControlledIndexService()
    let model = AppModel(indexService: service)
    let root = URL(fileURLWithPath: "/tmp/javascript-project", isDirectory: true)
    let originalGeneration = model.generation

    do {
        try model.openProject(root: root, language: .javascript)
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

    guard case .empty = model.projectState else {
        Issue.record("unsupported open changed project state")
        return
    }
    #expect(model.projectLanguage == nil)
    #expect(model.projectRoot == nil)
    #expect(model.generation == originalGeneration)
    #expect(await service.requestedLanguages().isEmpty)
}

@MainActor
@Test
func realIndexServiceOpensTypeScriptProjectAndPublishesTypeScriptSession() async throws {
    let root = try temporaryProject([
        "src/a.ts": "export const a = 1\n",
        "src/b.tsx": "export const b = <div />\n",
        "ignored.js": "export const js = 1\n",
        "ignored.rs": "fn main() {}",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: ProjectIndexService())

    try model.openProject(root: root, language: .typescript)

    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") {
        model.snapshotPhase == .fullReady
    })
    #expect(model.projectLanguage == .typescript)
    #expect(model.fileTree?.fileCount == 2)
    #expect(model.fileTree?.selectionPath(
        for: root.appendingPathComponent("src/a.ts")
    )?.map(\.name) == ["src", "a.ts"])
    guard case let .ready(session, _) = model.projectState else {
        Issue.record("expected ready TypeScript session")
        return
    }
    #expect(session.analysisProfile.language == .typescript)
    let manifestFiles = session.manifest.files.map {
        session.paths.resolve($0.pathID)
    }.sorted()
    #expect(manifestFiles == ["src/a.ts", "src/b.tsx"])
    #expect(model.availableFeatureSelections == [.defaultFeatures])
}

@MainActor
@Test
func realIndexServiceOpensPythonProjectAndPublishesPythonSession() async throws {
    let root = try temporaryProject([
        "main.py": "def hello():\n    return 1\n",
        "ignored.rs": "fn main() {}",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: ProjectIndexService())

    try model.openProject(root: root, language: .python)

    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") {
        model.snapshotPhase == .fullReady
    })
    #expect(model.projectLanguage == .python)
    #expect(model.fileTree?.children.map(\.name) == ["main.py"])
    #expect(model.fileTree?.fileCount == 1)
    guard case let .ready(session, _) = model.projectState else {
        Issue.record("expected ready Python session")
        return
    }
    #expect(session.analysisProfile.language == .python)
    #expect(session.manifest.files.map {
        session.paths.resolve($0.pathID)
    } == ["main.py"])
    let context = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: model.generation
    )
    #expect(try session.searchSymbols(
        query: "hello",
        limit: 10,
        boost: SearchBoost(),
        context: context
    ).map(\.path) == ["main.py"])
    var contentMatches: [SearchMatch] = []
    for try await batch in try session.search(
        ContentSearchQuery(pattern: "return 1"),
        context: context
    ) {
        contentMatches.append(contentsOf: batch.matchesByPath.values.flatMap { $0 })
    }
    #expect(contentMatches.map { session.paths.resolve($0.pathID) } == ["main.py"])
    #expect(model.availableFeatureSelections == [.defaultFeatures])
}

@MainActor
@Test
func pythonProfileLimitsFeatureChoicesAndSwitchingIsNoOp() async throws {
    let root = try temporaryProject(["main.rs": "fn main() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    let rustSession = try ProjectIndexer().index(root: root)
    let pythonSession = EngineSession(
        store: rustSession.store,
        snapshotView: SnapshotView(
            reprofiling: rustSession.snapshotView,
            analysisProfile: .placeholder(
                language: .python,
                root: rustSession.analysisProfile.projectRoot
            )
        )
    )
    let service = ControlledIndexService()
    let model = AppModel(indexService: service)

    model.openProject(root: root)
    #expect(await service.waitUntilRequested(root: root))
    await service.complete(root: root, result: .success(rustSession))
    #expect(await testWaitUntil("model.snapshotPhase == .fullReady") {
        model.snapshotPhase == .fullReady
    })

    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
    #expect(model.transition(to: .ready(
        pythonSession,
        QueryContext(
            snapshotID: pythonSession.snapshotID,
            analysisProfileID: pythonSession.analysisProfile.id,
            generation: model.generation
        )
    )))
    #expect(model.availableFeatureSelections == [.defaultFeatures])
    #expect(model.currentFeatureSelection == .defaultFeatures)

    let generationBeforeSwitch = model.generation
    model.switchFeatureSelection(.allFeatures)

    #expect(model.generation == generationBeforeSwitch)
    guard case let .ready(session, _) = model.projectState else {
        Issue.record("expected python ready session")
        return
    }
    #expect(session.analysisProfile.id == pythonSession.analysisProfile.id)
    #expect(session.analysisProfile.featureSelection == .defaultFeatures)
    #expect(model.currentFeatureSelection == .defaultFeatures)
}

@MainActor
@Test
func openingAnotherProjectDiscardsLateSession() async throws {
    let rootA = try temporaryProject(["a.rs": "fn a() {}"])
    let rootB = try temporaryProject(["b.rs": "fn b() {}"])
    defer {
        try? FileManager.default.removeItem(at: rootA)
        try? FileManager.default.removeItem(at: rootB)
    }
    let sessionA = try ProjectIndexer().index(root: rootA)
    let sessionB = try ProjectIndexer().index(root: rootB)
    let service = ControlledIndexService()
    let model = AppModel(indexService: service)

    model.openProject(root: rootA)
    #expect(model.fileTree == nil)
    #expect(await testWaitUntil("model.fileTree?.root == rootA.standardizedFileURL") {
        model.fileTree?.root == rootA.standardizedFileURL
    })
    #expect(await service.waitUntilRequested(root: rootA))
    try model.openProject(root: rootB, language: .rust)

    #expect(model.generation == 2)
    #expect(model.fileTree == nil)
    guard case let .indexing(root, _) = model.projectState else {
        Issue.record("expected indexing")
        return
    }
    #expect(root == rootB.standardizedFileURL)
    #expect(await testWaitUntil("model.fileTree?.root == rootB.standardizedFileURL") {
        model.fileTree?.root == rootB.standardizedFileURL
    })

    await service.complete(root: rootB, result: .success(sessionB))
    #expect(await testWaitUntil("if case .ready = model.projectState { return true } return false") {
        if case .ready = model.projectState { return true }
        return false
    })

    await service.complete(root: rootA, result: .success(sessionA))
    #expect(await service.waitUntilDelivered(root: rootA))
    for _ in 0..<10 { await Task.yield() }

    guard case let .ready(session, context) = model.projectState else {
        Issue.record("expected ready")
        return
    }
    #expect(session.snapshotID == sessionB.snapshotID)
    #expect(context.snapshotID == sessionB.snapshotID)
    #expect(context.analysisProfileID == sessionB.analysisProfile.id)
    #expect(context.generation == 2)
    #expect(await service.requestedLanguage(root: rootA) == .rust)
    #expect(await service.requestedLanguage(root: rootB) == .rust)
}

@MainActor
@Test
func indexingFailureMovesProjectToFailed() async throws {
    let root = try temporaryProject(["main.rs": "fn main() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: FailingIndexService())

    model.openProject(root: root)
    guard case .indexing = model.projectState else {
        Issue.record("expected indexing")
        return
    }
    #expect(await testWaitUntil("if case .failed = model.projectState { return true } return false") {
        if case .failed = model.projectState { return true }
        return false
    })
    #expect(model.projectLanguage == .rust)
    #expect(model.projectRoot == root.standardizedFileURL)
}

@MainActor
@Test
func mismatchedSessionLanguageFailsWithoutPublishingSessionState() async throws {
    let root = try temporaryProject(["main.rs": "fn main() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    let base = try ProjectIndexer().index(root: root)
    let mismatched = EngineSession(
        store: base.store,
        snapshotView: SnapshotView(
            reprofiling: base.snapshotView,
            analysisProfile: .placeholder(
                language: .python,
                root: base.analysisProfile.projectRoot
            )
        )
    )
    let service = ControlledIndexService()
    let model = AppModel(indexService: service)

    model.openProject(root: root)
    #expect(await service.waitUntilRequested(root: root))
    await service.complete(root: root, result: .success(mismatched))
    #expect(await testWaitUntil("mismatched session rejected") {
        if case .failed = model.projectState { return true }
        return false
    })

    #expect(model.projectLanguage == .rust)
    #expect(model.currentSnapshotID == nil)
    #expect(model.snapshotPhase == nil)
    #expect(model.coverage.filesIndexed == 0)
    #expect(model.coverage.filesTotal == 1)
}

@Test
func realIndexServiceBuildsFixtureSession() async throws {
    let fixture = repositoryRoot
        .appendingPathComponent("Tests/RustExtractorTests/Fixtures/use_alias")

    let session = try await ProjectIndexService().index(root: fixture)

    #expect(session.stats.fileCount == 2)
    #expect(session.stats.uniqueContentCount == 2)
    #expect(session.stats.symbolCount == 3)
    #expect(session.stats.callCount == 1)
    #expect(session.stats.importCount == 1)
}

@MainActor
@Test
func mixedOpenInstallsNormalizedWorkspaceSessionsAndRoutesByLanguage() async throws {
    let root = try temporaryGitProject([
        "crates/r/src/lib.rs": "pub fn f() {}\n",
        "crates/r/Cargo.toml": "[package]\nname = \"r\"\n",
        "pkg.py": "def f():\n    pass\n",
        "pyproject.toml": "[project]\nname = \"p\"\n",
        "tools/ts/src/a.ts": "export function a() {}\n",
        "tools/ts/src/b.tsx": "export const b = 1\n",
        "tools/ts/tsconfig.json": "{}",
    ])
    let cachePaths = try indexCachePaths(for: root)
    defer {
        try? FileManager.default.removeItem(at: root)
        for path in cachePaths { try? FileManager.default.removeItem(atPath: path) }
    }
    let model = AppModel(indexService: ProjectIndexService())
    try await model.openProject(root: root, languages: [.typescript, .rust, .python])

    #expect(model.projectLanguages == [.rust, .python, .typescript])
    #expect(model.querySessions.map { $0.0.analysisProfile.language }
        == [.rust, .python, .typescript])
    #expect(Set(model.querySessions.map { $0.0.snapshotID }).count == 1)
    #expect(model.fileTree?.fileCount == 4)
    if case .failed = model.projectState {
        Issue.record("mixed open failed unexpectedly")
    }

    func activeLanguage() -> LanguageID? {
        guard case let .ready(session, _) = model.projectState else { return nil }
        return session.analysisProfile.language
    }

    model.navigate(to: root.appendingPathComponent("crates/r/src/lib.rs"))
    #expect(activeLanguage() == .rust)
    #expect(model.languageMode(for: root.appendingPathComponent("crates/r/src/lib.rs"))
        == LanguageMode(language: .rust))

    model.navigate(to: root.appendingPathComponent("pkg.py"))
    #expect(activeLanguage() == .python)
    #expect(model.languageMode(for: root.appendingPathComponent("pkg.py"))
        == LanguageMode(language: .python))
    let pySource = try #require(model.capturedProjectSource(at: "pkg.py")?.bytes)
    #expect(String(bytes: pySource, encoding: .utf8) == "def f():\n    pass\n")

    model.navigate(to: root.appendingPathComponent("tools/ts/src/a.ts"))
    #expect(activeLanguage() == .typescript)
    #expect(model.languageMode(for: root.appendingPathComponent("tools/ts/src/a.ts"))
        == LanguageMode(language: .typescript))

    model.navigate(to: root.appendingPathComponent("tools/ts/src/b.tsx"))
    #expect(activeLanguage() == .typescript)
    #expect(model.languageMode(for: root.appendingPathComponent("tools/ts/src/b.tsx"))
        == LanguageMode(language: .typescript, variant: "tsx"))
    let tsxSource = try #require(model.capturedProjectSource(at: "tools/ts/src/b.tsx")?.bytes)
    #expect(String(bytes: tsxSource, encoding: .utf8) == "export const b = 1\n")

    guard case let .ready(_, beforeUnsupported) = model.projectState else {
        Issue.record("missing ready before unsupported navigation")
        return
    }
    let unsupported = root.appendingPathComponent("notes.js")
    model.navigate(to: unsupported)
    #expect(model.languageMode(for: unsupported) == nil)
    guard case let .ready(_, afterUnsupported) = model.projectState else {
        Issue.record("unsupported navigation must not clear active project state")
        return
    }
    #expect(beforeUnsupported.analysisProfileID == afterUnsupported.analysisProfileID)

    model.navigate(to: root.appendingPathComponent("tools/ts/src/a.ts"))
    guard case let .ready(_, sameModeContext) = model.projectState else {
        Issue.record("Expected ready after same-mode navigation")
        return
    }
    #expect(sameModeContext.analysisProfileID == afterUnsupported.analysisProfileID)
    #expect(sameModeContext.generation == afterUnsupported.generation)
}

@MainActor
@Test
func staleRustContextCompletionDoesNotPublishAfterPythonRoute() async throws {
    let rustSource = "fn target() {}\nfn use_rust() { target(); }\n"
    let pySource = "def target():\n    pass\n\ndef use_py():\n    target()\n"
    let root = try temporaryGitProject([
        "main.rs": rustSource,
        "lib.py": pySource,
    ])
    let cachePaths = try indexCachePaths(for: root)
    defer {
        try? FileManager.default.removeItem(at: root)
        for path in cachePaths { try? FileManager.default.removeItem(atPath: path) }
    }
    let gate = ControlledContextResolver()
    let model = AppModel(
        indexService: ProjectIndexService(),
        contextWindow: ContextWindowModel(gate.resolve)
    )
    try await model.openProject(root: root, languages: [.rust, .python])

    let rustURL = root.appendingPathComponent("main.rs")
    let pythonURL = root.appendingPathComponent("lib.py")
    let rustOffset = byteOffset(of: "target();", in: rustSource)
    let pythonOffset = byteOffset(of: "target()\n", in: pySource)
    model.navigate(to: rustURL)
    model.contextWindow.tokenClicked(file: "main.rs", offset: rustOffset)
    #expect(await testWaitUntil("gate.isPending(rustOffset)") {
        gate.isPending(rustOffset)
    })

    model.navigate(to: pythonURL)
    let rustSession = try #require(model.querySessions.first {
        $0.0.analysisProfile.language == .rust
    }.map(\.0))
    let pythonSession = try #require(model.querySessions.first {
        $0.0.analysisProfile.language == .python
    }.map(\.0))
    let rustPath = try #require(pathID("main.rs", in: rustSession))
    let pythonPath = try #require(pathID("lib.py", in: pythonSession))
    let rustContext = QueryContext(
        snapshotID: rustSession.snapshotID,
        analysisProfileID: rustSession.analysisProfile.id,
        generation: model.generation
    )
    let pythonContext = QueryContext(
        snapshotID: pythonSession.snapshotID,
        analysisProfileID: pythonSession.analysisProfile.id,
        generation: model.generation
    )
    gate.complete(
        rustOffset,
        with: try rustSession.resolve(
            file: rustPath,
            offset: rustOffset,
            context: rustContext
        )
    )
    #expect(await testWaitUntil("gate.hasCompleted(rustOffset)") {
        gate.hasCompleted(rustOffset)
    })
    #expect(model.contextWindow.candidateCount == 0)

    model.contextWindow.tokenClicked(file: "lib.py", offset: pythonOffset)
    #expect(await testWaitUntil("gate.isPending(pythonOffset)") {
        gate.isPending(pythonOffset)
    })
    #expect(gate.callLanguages().last == .python)
    gate.complete(
        pythonOffset,
        with: try pythonSession.resolve(
            file: pythonPath,
            offset: pythonOffset,
            context: pythonContext
        )
    )
    #expect(await testWaitUntil("model.contextWindow.selectedCandidate != nil") {
        model.contextWindow.selectedCandidate != nil
    })
    #expect(model.contextWindow.selectedCandidate?.path == "lib.py")
}


@MainActor
@Test
func crossLanguageSameNameContextStaysInActivePythonSession() async throws {
    let rustSource = "pub fn shared() {}\n"
    let pySource = "def shared():\n    pass\n\ndef use_py():\n    shared()\n"
    let root = try temporaryGitProject([
        "main.rs": rustSource,
        "lib.py": pySource,
    ])
    let cachePaths = try indexCachePaths(for: root)
    defer {
        try? FileManager.default.removeItem(at: root)
        for path in cachePaths { try? FileManager.default.removeItem(atPath: path) }
    }
    let model = AppModel(indexService: ProjectIndexService())
    try await model.openProject(root: root, languages: [.rust, .python])

    model.navigate(to: root.appendingPathComponent("lib.py"))
    let offset = byteOffset(of: "shared()\n", in: pySource)
    model.contextWindow.tokenClicked(file: "lib.py", offset: offset)
    #expect(await testWaitUntil("model.contextWindow.selectedCandidate != nil") {
        model.contextWindow.selectedCandidate != nil
    })
    #expect(model.contextWindow.selectedCandidate?.path == "lib.py")
    #expect(model.contextWindow.selectedCandidate?.excerpt.isEmpty != true)
    #expect(model.contextWindow.selectedCandidate?.symbol?.snapshotID == model.currentSnapshotID)
    let pythonSession = try #require(model.querySessions.first {
        $0.0.analysisProfile.language == .python
    }.map(\.0))
    let pythonContext = QueryContext(
        snapshotID: pythonSession.snapshotID,
        analysisProfileID: pythonSession.analysisProfile.id,
        generation: model.generation
    )
    let pythonPath = try #require(pathID("lib.py", in: pythonSession))
    let resolved = try pythonSession.resolve(
        file: pythonPath,
        offset: offset,
        context: pythonContext
    )
    let resolvedPaths = resolved.map {
        pythonSession.paths.resolve($0.target.pathID)
    }
    #expect(!resolvedPaths.isEmpty)
    #expect(resolvedPaths.allSatisfy { $0 == "lib.py" })
}

@MainActor
@Test
func rustFeatureSwitchReplacesOnlyRustWorkspaceEntry() async throws {
    let root = try temporaryGitProject([
        "main.rs": "fn a() {}\n",
        "lib.py": "def b():\n    pass\n",
    ])
    let cachePaths = try indexCachePaths(for: root)
    defer {
        try? FileManager.default.removeItem(at: root)
        for path in cachePaths { try? FileManager.default.removeItem(atPath: path) }
    }
    let model = AppModel(indexService: ProjectIndexService())
    try await model.openProject(root: root, languages: [.rust, .python])

    let pythonBefore = model.querySessions.filter {
        $0.0.analysisProfile.language == .python
    }.map { $0.1.analysisProfileID }
    model.switchFeatureSelection(.allFeatures)
    guard case let .ready(active, context) = model.projectState else {
        Issue.record("Expected ready after Rust feature switch")
        return
    }
    #expect(active.analysisProfile.featureSelection == .allFeatures)
    #expect(model.querySessions.count == 2)
    #expect(model.querySessions.filter {
        $0.0.analysisProfile.language == .python
    }.map { $0.1.analysisProfileID } == pythonBefore)
    #expect(context.analysisProfileID == active.analysisProfile.id)

    model.navigate(to: root.appendingPathComponent("lib.py"))
    guard case let .ready(pythonSession, pythonContext) = model.projectState else {
        Issue.record("Expected Python route after Rust feature switch")
        return
    }
    let pythonProfileID = pythonSession.analysisProfile.id
    let pythonProfileGeneration = pythonContext.generation
    model.switchFeatureSelection(.defaultFeatures)
    guard case let .ready(session, context) = model.projectState else {
        Issue.record("Expected active state preserved after non-Rust no-op")
        return
    }
    #expect(session.analysisProfile.language == .python)
    #expect(session.analysisProfile.id == pythonProfileID)
    #expect(context.generation == pythonProfileGeneration)
}

@MainActor
@Test
func sameProfileNavigationDoesNotResetContextOrRelationIdentity() async throws {
    let root = try temporaryGitProject([
        "main.rs": "fn a() {}\n",
        "other.rs": "fn c() {}\n",
        "lib.py": "def b():\n    pass\n",
    ])
    let cachePaths = try indexCachePaths(for: root)
    defer {
        try? FileManager.default.removeItem(at: root)
        for path in cachePaths { try? FileManager.default.removeItem(atPath: path) }
    }
    let exactCalls = OSAllocatedUnfairLock(initialState: 0)
    let model = AppModel(
        indexService: ProjectIndexService(),
        exactCoordinator: ExactCoordinator(
            providerFactory: { _, _ in
                exactCalls.withLock { $0 += 1 }
                throw ExactError.unavailable("test")
            },
            sandboxAvailable: { true },
            trustRegistry: TrustRegistry(
                fileURL: root.appendingPathComponent("trust.json")
            )
        )
    )
    try await model.openProject(root: root, languages: [.rust, .python])

    let firstURL = root.appendingPathComponent("main.rs")
    model.navigate(to: firstURL)
    guard case let .ready(_, firstContext) = model.projectState else {
        Issue.record("expected ready Rust context")
        return
    }
    let relationGeneration = model.relationTree.generation
    #expect(await testWaitUntil("Exact readiness settles") {
        if case .unavailable = model.exactCoordinator.readiness { return true }
        return false
    })
    let beforeCalls = exactCalls.withLock { $0 }
    model.navigate(to: root.appendingPathComponent("other.rs"), byteOffset: 2)
    guard case let .ready(_, nextContext) = model.projectState else {
        Issue.record("expected ready Rust context after same profile navigation")
        return
    }
    #expect(nextContext.analysisProfileID == firstContext.analysisProfileID)
    #expect(model.relationTree.generation == relationGeneration)
    #expect(exactCalls.withLock { $0 } == beforeCalls)
    #expect(model.generation == firstContext.generation)
}

@Test
func projectIndexServiceRejectsJavaScriptBeforeIO() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightUnsupportedService-\(UUID().uuidString)")
    let cachePaths = try indexCachePaths(for: root)
    defer {
        for path in cachePaths { try? FileManager.default.removeItem(atPath: path) }
    }
    #expect(cachePaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })

    let service = ProjectIndexService()
    for operation in [
        { try await service.index(root: root, language: .javascript) as Any },
        {
            try await service.captureSnapshot(
                root: root,
                revision: "HEAD",
                language: .javascript
            ) as Any
        },
    ] {
        do {
            _ = try await operation()
            Issue.record("unsupported JavaScript service operation unexpectedly succeeded")
        } catch let error as CocoaError {
            #expect(error.code == .featureUnsupported)
        } catch {
            Issue.record("unsupported JavaScript service operation reached I/O: \(error)")
        }
    }
    #expect(cachePaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test
func projectIndexServiceCapturesAndPreparesMixedSessionsWithSharedIdentity() async throws {
    let root = try temporaryGitProject([
        "crates/r/src/lib.rs": "pub fn f() {}\n",
        "crates/r/Cargo.toml": "[package]\nname = \"r\"\n",
        "pkg.py": "def f():\n    pass\n",
        "pyproject.toml": "[project]\nname = \"p\"\n",
        "tools/ts/src/a.ts": "export function a() {}\n",
        "tools/ts/src/b.tsx": "export const b = 1\n",
        "tools/ts/tsconfig.json": "{}",
    ])
    let cachePaths = try indexCachePaths(for: root)
    defer {
        for path in cachePaths { try? FileManager.default.removeItem(atPath: path) }
        try? FileManager.default.removeItem(at: root)
    }

    let service = ProjectIndexService()
    let snapshot = try await service.captureSnapshot(
        root: root,
        revision: nil,
        languages: [.typescript, .rust, .python]
    )
    let paths = snapshot.listFiles().map(\.path)
    #expect(Set(paths) == Set([
        "crates/r/src/lib.rs",
        "pkg.py",
        "tools/ts/src/a.ts",
        "tools/ts/src/b.tsx",
    ]))

    let prepared = try await service.prepareSnapshots(
        snapshot,
        root: root,
        languages: [.typescript, .rust, .python]
    )
    #expect(prepared.map { $0.cachedSession.analysisProfile.language }
        == [.rust, .python, .typescript])
    #expect(Set(prepared.map { $0.cachedSession.snapshotID }).count == 1)
    #expect(Set(prepared.map { ObjectIdentifier($0.cachedSession.store) }).count == 1)
    #expect(Set(prepared.map { ObjectIdentifier($0.cachedSession.paths) }).count == 1)
    #expect(Set(prepared.map { ObjectIdentifier($0.cachedSession.names) }).count == 1)
    #expect(Set(prepared.map { ObjectIdentifier($0.cachedSession.strings) }).count == 1)
    #expect(prepared.map {
        $0.cachedSession.paths.resolve($0.cachedSession.analysisProfile.projectRoot)
    } == ["crates/r", ".", "tools/ts"])

    let cached = prepared.map(\.cachedSession)
    var full: [EngineSession] = []
    for item in prepared {
        full.append(try await service.completeSnapshot(item))
    }
    #expect(full.map { $0.analysisProfile.language }
        == cached.map { $0.analysisProfile.language })
    #expect(full.map { $0.analysisProfile.projectRoot }
        == cached.map { $0.analysisProfile.projectRoot })
    #expect(full.map { $0.analysisProfile.id }
        == cached.map { $0.analysisProfile.id })
    #expect(full.map { $0.stats.extractedCount } == [1, 1, 2])

    service.flushPersistentIndexCache()
}

@Test
func singletonCollectionPreparePreservesLegacyRootWithoutUnitDiscovery() async throws {
    let root = try temporaryGitProject([
        "a/src/main.rs": "fn a() {}\n",
        "b/src/main.rs": "fn b() {}\n",
        "a/Cargo.toml": "[package]\nname = \"a\"\n",
        "b/Cargo.toml": "[package]\nname = \"b\"\n",
    ])
    let cachePaths = try indexCachePaths(for: root)
    defer {
        for path in cachePaths { try? FileManager.default.removeItem(atPath: path) }
        try? FileManager.default.removeItem(at: root)
    }
    let service = ProjectIndexService()
    let snapshot = try await service.captureSnapshot(
        root: root,
        revision: nil,
        languages: [.rust]
    )
    let prepared = try await service.prepareSnapshots(
        snapshot,
        root: root,
        languages: [.rust]
    )

    #expect(prepared.count == 1)
    #expect(prepared[0].cachedSession.analysisProfile.language == .rust)
    #expect(prepared[0].cachedSession.paths.resolve(
        prepared[0].cachedSession.analysisProfile.projectRoot
    ) == ".")
}

@Test
func ambiguousAndNonGitFailBeforePersistentCache() async throws {
    let nonGit = try temporaryProject([
        "a.rs": "fn a() {}\n",
    ])
    let nonGitCache = try indexCachePaths(for: nonGit)
    defer {
        for path in nonGitCache { try? FileManager.default.removeItem(atPath: path) }
        try? FileManager.default.removeItem(at: nonGit)
    }
    do {
        _ = try await ProjectIndexService().captureSnapshot(
            root: nonGit,
            revision: nil,
            languages: [.rust, .python]
        )
        Issue.record("mixed non-Git capture unexpectedly succeeded")
    } catch is GitError {
    } catch {
        Issue.record("unexpected mixed non-Git error: \(error)")
    }
    do {
        _ = try await ProjectIndexService().prepareSnapshots(
            CountingIndexSnapshot(
                files: ["a.rs": Array("fn a() {}\n".utf8)],
                configurationPaths: []
            ),
            root: nonGit,
            languages: [.rust, .python]
        )
        Issue.record("mixed non-Git prepare unexpectedly succeeded")
    } catch is GitError {
    } catch {
        Issue.record("unexpected mixed non-Git prepare error: \(error)")
    }
    #expect(nonGitCache.allSatisfy { !FileManager.default.fileExists(atPath: $0) })

    let ambiguousRoot = try temporaryGitProject([
        "a/src/main.rs": "fn a() {}\n",
        "b/src/main.rs": "fn b() {}\n",
        "a/Cargo.toml": "[package]\nname = \"a\"\n",
        "b/Cargo.toml": "[package]\nname = \"b\"\n",
        "p.py": "def p():\n    pass\n",
    ])
    let ambiguousPaths = try indexCachePaths(for: ambiguousRoot)
    defer {
        for path in ambiguousPaths { try? FileManager.default.removeItem(atPath: path) }
        try? FileManager.default.removeItem(at: ambiguousRoot)
    }
    let snapshot = try await ProjectIndexService().captureSnapshot(
        root: ambiguousRoot,
        revision: nil,
        languages: [.rust, .python]
    )
    do {
        _ = try await ProjectIndexService().prepareSnapshots(
            snapshot,
            root: ambiguousRoot,
            languages: [.rust, .python]
        )
        Issue.record("ambiguous mixed prepare unexpectedly succeeded")
    } catch let error as CocoaError {
        #expect(error.code == .featureUnsupported)
    } catch {
        Issue.record("ambiguous mixed prepare threw unexpected error: \(error)")
    }
    #expect(ambiguousPaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
}

@Test
func preparedSnapshotIdentityMismatchFailsWithoutPartial() async throws {
    let root = try temporaryGitProject([
        "src/lib.rs": "fn f() {}\n",
        "Cargo.toml": "[package]\nname = \"x\"\n",
    ])
    let cachePaths = try indexCachePaths(for: root)
    defer {
        try? FileManager.default.removeItem(at: root)
        for path in cachePaths { try? FileManager.default.removeItem(atPath: path) }
    }
    let snapshot = CountingIndexSnapshot(
        files: ["src/lib.rs": Array("fn f() {}\n".utf8)],
        configurationPaths: ["Cargo.toml"],
        stableIdentity: false
    )
    do {
        _ = try await ProjectIndexService().prepareSnapshots(
            snapshot,
            root: root,
            languages: [.rust, .python]
        )
        Issue.record("identity mismatch unexpectedly prepared")
    } catch let error as CocoaError {
        #expect(error.code == .coderInvalidValue)
    }
    #expect(cachePaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
}

@Test
func indexServiceDefaultRequirementsForwardSingletonsAndRejectMixedInvalidSets() async throws {
    let service = CountingIndexService()
    let root = try temporaryProject([:])
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        _ = try await service.captureSnapshot(
            root: root,
            revision: nil,
            languages: [.rust]
        )
    } catch {
        Issue.record("singleton capture forward failed: \(String(describing: error))")
    }
    #expect(await service.capturedLanguages == [.rust])

    do {
        _ = try await service.prepareSnapshots(
            CountingIndexSnapshot(files: [:], configurationPaths: []),
            root: root,
            languages: [.python]
        )
    } catch Failure.expected {
        // CountingIndexService intentionally throws after recording scalar call.
    } catch {
        Issue.record("singleton prepare forward failed: \(error)")
    }
    #expect(await service.preparedLanguages == [.python])

    let invalid: [[LanguageID]] = [
        [],
        [.rust, .rust],
        [.javascript],
        [.rust, .python],
    ]
    for languages in invalid {
        do {
            _ = try await service.captureSnapshot(
                root: root,
                revision: nil,
                languages: languages
            )
            Issue.record("invalid/mixed capture unexpectedly succeeded: \(languages)")
        } catch let error as CocoaError {
            #expect(error.code == .featureUnsupported)
        } catch {
            Issue.record("unexpected invalid capture error: \(error)")
        }
    }
    #expect(await service.capturedLanguages == [.rust])

    for languages in invalid {
        do {
            _ = try await service.prepareSnapshots(
                CountingIndexSnapshot(files: [:], configurationPaths: []),
                root: root,
                languages: languages
            )
            Issue.record("invalid/mixed prepare unexpectedly succeeded: \(languages)")
        } catch let error as CocoaError {
            #expect(error.code == .featureUnsupported)
        } catch {
            Issue.record("unexpected invalid prepare error: \(error)")
        }
    }
    #expect(await service.preparedLanguages == [.python])
}

@MainActor
@Test
func symbolSearchPanelBuildsRowsWrapsSelectionAndOpens() async throws {
    let root = try temporaryProject([
        "main.rs": "fn alpha() {}\nfn alpine() {}",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
    let model = SymbolSearchPanelModel()

    model.updateQuery("al", projectState: .ready(session, context))
    #expect(await testWaitUntil("model.rows.count == 2") { model.rows.count == 2 })
    #expect(model.selectedIndex == 0)

    model.selectPrevious()
    #expect(model.selectedIndex == 1)
    model.selectNext()
    #expect(model.selectedIndex == 0)

    let request = try #require(model.openSelection())
    #expect(request.path == "main.rs")
    #expect(request.byteOffset == 3)

    model.reset()
    #expect(model.query.isEmpty)
    #expect(model.rows.isEmpty)
    #expect(model.selectedIndex == nil)

    model.updateQuery(
        "alpha",
        projectState: .indexing(root: root, startedAt: .now)
    )
    #expect(model.rows.count == 1)
    if case let .placeholder(message) = model.rows[0] {
        #expect(message == "Indexing symbols…")
    } else {
        Issue.record("expected indexing placeholder")
    }
}

@MainActor
@Test
func symbolSearchPathCacheRefreshesForANewSession() async throws {
    let firstRoot = try temporaryProject(["z.rs": "fn one() {}"])
    let secondRoot = try temporaryProject([
        "a.rs": "fn target() {}",
        "z.rs": "fn target() {}",
    ])
    defer {
        try? FileManager.default.removeItem(at: firstRoot)
        try? FileManager.default.removeItem(at: secondRoot)
    }
    let first = try ProjectIndexer().index(root: firstRoot)
    let second = try ProjectIndexer().index(root: secondRoot)
    let model = SymbolSearchPanelModel()

    model.updateQuery(
        "one",
        projectState: .ready(first, queryContext(for: first)),
        currentPath: "z.rs"
    )
    #expect(await testWaitUntil("!model.rows.isEmpty") { !model.rows.isEmpty })

    model.updateQuery(
        "target",
        projectState: .ready(second, queryContext(for: second)),
        currentPath: "z.rs"
    )
    #expect(await testWaitUntil("guard case let .result(name, hit) = model.rows.first else { return false } return name == \"target\" && hit.path == \"z.rs\"") {
        guard case let .result(name, hit) = model.rows.first else { return false }
        return name == "target" && hit.path == "z.rs"
    })
}

@MainActor
private func makeMixedSymbolWorkspace() async throws -> (
    root: URL,
    model: AppModel,
    sessions: [(EngineSession, QueryContext)],
    cachePaths: [String]
) {
    let root = try temporaryGitProject([
        "main.rs": "pub fn alpha() {}\npub fn target() {}\n",
        "lib.py": "def alpha():\n    pass\n\ndef target():\n    pass\n",
        "app.ts": "export function alpha() {}\nexport function target() {}\n",
        "pyproject.toml": "[project]\nname = \"fixture\"\n",
        "Cargo.toml": "[package]\nname = \"fixture\"\n",
    ])
    let cachePaths = try indexCachePaths(for: root)
    let model = AppModel(indexService: ProjectIndexService())
    try await model.openProject(root: root, languages: [.rust, .python, .typescript])
    let sessions = model.querySessions
    guard sessions.count == 3 else {
        for path in cachePaths { try? FileManager.default.removeItem(atPath: path) }
        try? FileManager.default.removeItem(at: root)
        throw CocoaError(.featureUnsupported)
    }
    return (root, model, sessions, cachePaths)
}

@MainActor
@Test
func symbolSearchWorkspaceMergesAllSessionsWithStableOrdering() async throws {
    let fixture = try await makeMixedSymbolWorkspace()
    defer {
        for path in fixture.cachePaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        try? FileManager.default.removeItem(at: fixture.root)
    }
    let model = SymbolSearchPanelModel()

    model.updateQuery("alpha", sessions: fixture.sessions)
    #expect(await testWaitUntil("model.rows.count == 3") { model.rows.count == 3 })
    let paths = model.rows.compactMap { row -> String? in
        guard case let .result(_, hit) = row else { return nil }
        return hit.path
    }
    #expect(paths == ["app.ts", "lib.py", "main.rs"])
}

@MainActor
@Test
func symbolSearchWorkspaceKeepsSameNamesAndUsesSharedPathBoost() async throws {
    let fixture = try await makeMixedSymbolWorkspace()
    defer {
        for path in fixture.cachePaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        try? FileManager.default.removeItem(at: fixture.root)
    }
    let model = SymbolSearchPanelModel()

    model.updateQuery(
        "target",
        sessions: fixture.sessions,
        currentPath: "main.rs"
    )
    #expect(await testWaitUntil("model.rows.count == 3") { model.rows.count == 3 })
    let rows = model.rows.compactMap { row -> (name: String, path: String)? in
        guard case let .result(name, hit) = row else { return nil }
        return (name, hit.path)
    }
    #expect(rows.map(\.path) == ["main.rs", "app.ts", "lib.py"])
    #expect(rows.map(\.name).allSatisfy { $0 == "target" })
}

@MainActor
@Test
func symbolSearchNewQueryDropsStaleWorkspaceDetachedCompletion() async throws {
    let fixture = try await makeMixedSymbolWorkspace()
    defer {
        for path in fixture.cachePaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        try? FileManager.default.removeItem(at: fixture.root)
    }
    let gate = SymbolSearchGate()
    let model = SymbolSearchPanelModel(symbolSearcher: gate.search)

    await gate.blockFirst("old")
    model.updateQuery("old", sessions: fixture.sessions)
    #expect(await testWaitUntil("gate.isPending(\"old\")") {
        await gate.isPending("old")
    })
    model.updateQuery("new", sessions: Array(fixture.sessions.prefix(1)))
    #expect(await testWaitUntil("model.rows.count == 1") { model.rows.count == 1 })
    await gate.release("old", fixture: fixture, count: 3)
    #expect(await testWaitUntil("gate.completed(\"old\")") {
        await gate.completed("old")
    })
    #expect(model.rows.count == 1)
}

private actor SymbolSearchGate {
    private var blocked: Set<String> = []
    private var continuations: [String: CheckedContinuation<[SymbolSearchHit], Error>] = [:]
    private var completedQueries: [String: Int] = [:]

    func search(
        session: EngineSession,
        query: String,
        boost: SearchBoost,
        context: QueryContext
    ) async throws -> [SymbolSearchHit] {
        if !blocked.contains(query) {
            completedQueries[query, default: 0] += 1
            return try session.searchSymbols(
                query: "target",
                limit: .max,
                boost: boost,
                context: context
            )
        }
        blocked.remove(query)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[query] = continuation
        }
    }

    func isPending(_ query: String) -> Bool {
        continuations[query] != nil
    }

    func blockFirst(_ query: String) {
        blocked.insert(query)
    }

    func completed(_ query: String) -> Bool {
        completedQueries[query] ?? 0 >= 3
    }

    func release(
        _ query: String,
        fixture: (
            root: URL,
            model: AppModel,
            sessions: [(EngineSession, QueryContext)],
            cachePaths: [String]
        ),
        count: Int
    ) {
        guard let session = fixture.sessions.first(where: {
            $0.0.analysisProfile.language == .rust
        })?.0 else { return }
        let context = fixture.sessions.first(where: {
            $0.0.analysisProfile.language == .rust
        })?.1
        guard let context else { return }
        let hits = (try? session.searchSymbols(
            query: "target",
            limit: count,
            boost: SearchBoost(),
            context: context
        )) ?? []
        completedQueries[query, default: 0] += 1
        continuations[query]?.resume(returning: hits)
        continuations[query] = nil
    }
}

@MainActor
@Test
func contextWindowDebouncesClicksInsideTheSameToken() async throws {
    let root = try temporaryProject([
        "main.rs": "fn target() {}\nfn main() { target(); }",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    var resolveCount = 0
    let model = ContextWindowModel { session, file, offset, context in
        resolveCount += 1
        return try session.resolve(file: file, offset: offset, context: context)
    }
    model.updateProjectState(.ready(session, context), root: root)
    let offset = byteOffset(of: "target();", in: "fn target() {}\nfn main() { target(); }")

    model.tokenClicked(file: "main.rs", offset: offset)
    #expect(await testWaitUntil("model.candidateCount == 1") { model.candidateCount == 1 })
    model.tokenClicked(file: "main.rs", offset: offset)
    model.tokenClicked(file: "main.rs", offset: offset + 2)
    for _ in 0..<10 { await Task.yield() }

    #expect(resolveCount == 1)
}

@MainActor
@Test
func contextWindowUpdatesForASecondSymbolInsideTheSameCall() async throws {
    let source = """
        struct Config;
        impl Config { fn set() {} }
        enum ConfigKey { Backend }
        fn f() { Config::set(ConfigKey::Backend, 1); }
        """
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    let model = ContextWindowModel()
    model.updateProjectState(.ready(session, context), root: root)

    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "set(ConfigKey", in: source)
    )
    #expect(await testWaitUntil("model.selectedCandidate?.targetByteOffset == byteOffset(of: \"set() {}\", in: source)") {
        model.selectedCandidate?.targetByteOffset
            == byteOffset(of: "set() {}", in: source)
    })

    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "ConfigKey::Backend", in: source)
    )
    #expect(await testWaitUntil("model.selectedCandidate?.targetByteOffset == byteOffset(of: \"ConfigKey {\", in: source)") {
        model.selectedCandidate?.targetByteOffset
            == byteOffset(of: "ConfigKey {", in: source)
    })
}

@MainActor
@Test
func contextWindowReusesLoadedTargetDocumentAcrossClicks() async throws {
    let source = "fn target() {}\nfn main() { target(); target(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    let loader = CountingContextLoader()
    let model = ContextWindowModel(
        { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        },
        loader: { file, languageMode in
            await loader.load(file, languageMode: languageMode)
        }
    )
    model.updateProjectState(.ready(session, context), root: root)
    let first = byteOffset(of: "target();", in: source)
    let second = first + UInt32("target(); ".utf8.count)

    #expect(await model.explicitJump(file: "main.rs", offset: first) != nil)
    #expect(await model.explicitJump(file: "main.rs", offset: second) != nil)
    #expect(await loader.loadCount == 1)
    #expect(await loader.languageModes == [LanguageMode(language: .rust)])
}

@MainActor
@Test
func contextWindowRecoversAfterClickOnUnresolvableLocation() async throws {
    let source = "fn target() {}\nfn main() { target(); }\n// plain comment\n"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    var resolveCount = 0
    let model = ContextWindowModel { session, file, offset, context in
        resolveCount += 1
        return try session.resolve(file: file, offset: offset, context: context)
    }
    model.updateProjectState(.ready(session, context), root: root)
    let tokenOffset = byteOffset(of: "target();", in: source)
    let commentOffset = byteOffset(of: "plain comment", in: source)

    model.tokenClicked(file: "main.rs", offset: tokenOffset)
    #expect(await testWaitUntil("model.candidateCount == 1") { model.candidateCount == 1 })

    // Click a location with no resolvable token: stage empties and the stale
    // located token must be cleared, not retained.
    model.tokenClicked(file: "main.rs", offset: commentOffset)
    for _ in 0..<10 { await Task.yield() }

    // Clicking the original token again must re-resolve instead of hitting the
    // debounce guard with a stale locatedToken and staying blank forever.
    model.tokenClicked(file: "main.rs", offset: tokenOffset)
    #expect(await testWaitUntil("model.candidateCount == 1") { model.candidateCount == 1 })
    #expect(resolveCount == 2)
}

@MainActor
@Test
func contextWindowDiscardsOutOfOrderRequests() async throws {
    let source = "fn alpha() {}\nfn beta() {}\nfn main() { alpha(); beta(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    let path = try #require(pathID("main.rs", in: session))
    let alpha = byteOffset(of: "alpha();", in: source)
    let beta = byteOffset(of: "beta();", in: source)
    let gate = ControlledContextResolver()
    let model = ContextWindowModel(gate.resolve)
    model.updateProjectState(.ready(session, context), root: root)

    model.tokenClicked(file: "main.rs", offset: alpha)
    #expect(await testWaitUntil("gate.isPending(alpha)") { gate.isPending(alpha) })
    model.tokenClicked(file: "main.rs", offset: beta)
    #expect(await testWaitUntil("gate.isPending(beta)") { gate.isPending(beta) })
    gate.complete(
        beta,
        with: try session.resolve(file: path, offset: beta, context: context)
    )
    #expect(await testWaitUntil("model.selectedCandidate?.line == 2") { model.selectedCandidate?.line == 2 })
    gate.complete(
        alpha,
        with: try session.resolve(file: path, offset: alpha, context: context)
    )
    for _ in 0..<10 { await Task.yield() }

    #expect(model.selectedCandidate?.line == 2)
}

@MainActor
@Test
func contextWindowDiscardsFuzzyResultFromAnOlderProfileGeneration()
    async throws
{
    let source = "fn alpha() {}\nfn beta() {}\nfn main() { alpha(); beta(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let firstContext = queryContext(for: session)
    let secondContext = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: firstContext.generation + 1
    )
    let path = try #require(pathID("main.rs", in: session))
    let alpha = byteOffset(of: "alpha();", in: source)
    let beta = byteOffset(of: "beta();", in: source)
    let gate = ControlledContextResolver()
    let model = ContextWindowModel(gate.resolve)
    model.updateProjectState(.ready(session, firstContext), root: root)

    model.tokenClicked(file: "main.rs", offset: alpha)
    #expect(await testWaitUntil("gate.isPending(alpha)") { gate.isPending(alpha) })
    model.updateProjectState(.ready(session, secondContext), root: root)
    gate.complete(
        alpha,
        with: try session.resolve(
            file: path,
            offset: alpha,
            context: firstContext
        )
    )
    for _ in 0..<10 { await Task.yield() }
    #expect(model.candidateCount == 0)

    model.tokenClicked(file: "main.rs", offset: beta)
    #expect(await testWaitUntil("gate.isPending(beta)") { gate.isPending(beta) })
    gate.complete(
        beta,
        with: try session.resolve(
            file: path,
            offset: beta,
            context: secondContext
        )
    )
    #expect(await testWaitUntil("model.selectedCandidate?.targetByteOffset == byteOffset(of: \"beta() {}\", in: source)") {
        model.selectedCandidate?.targetByteOffset
            == byteOffset(of: "beta() {}", in: source)
    })
}

@MainActor
@Test
func contextWindowDiscardsResultAfterProfileChangeAtSameGeneration() async throws {
    let source = "fn alpha() {}\nfn beta() {}\nfn main() { alpha(); beta(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let secondSession = session.reprofiled(featureSelection: .allFeatures)
    let firstProfile = queryContext(for: session)
    let secondProfile = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: secondSession.analysisProfile.id,
        generation: firstProfile.generation
    )
    let path = try #require(pathID("main.rs", in: session))
    let alpha = byteOffset(of: "alpha();", in: source)
    let beta = byteOffset(of: "beta();", in: source)
    let gate = ControlledContextResolver()
    let model = ContextWindowModel(gate.resolve)
    model.updateProjectState(.ready(session, firstProfile), root: root)

    model.tokenClicked(file: "main.rs", offset: alpha)
    #expect(await testWaitUntil("gate.isPending(alpha)") { gate.isPending(alpha) })
    model.updateProjectState(.ready(secondSession, secondProfile), root: root)
    gate.complete(
        alpha,
        with: try session.resolve(
            file: path,
            offset: alpha,
            context: firstProfile
        )
    )
    #expect(await testWaitUntil("gate.hasCompleted(alpha)") { gate.hasCompleted(alpha) })
    #expect(model.candidateCount == 0)

    model.tokenClicked(file: "main.rs", offset: beta)
    #expect(await testWaitUntil("gate.isPending(beta)") { gate.isPending(beta) })
    gate.complete(
        beta,
        with: try secondSession.resolve(
            file: path,
            offset: beta,
            context: secondProfile
        )
    )
    #expect(await testWaitUntil("model.selectedCandidate?.targetByteOffset != nil") {
        model.selectedCandidate?.targetByteOffset != nil
    })
}

@MainActor
@Test
func resolvedContextCandidateRejectsAnOlderProfileGeneration() async throws {
    let source = "fn target() {}\nfn main() { target(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let firstContext = queryContext(for: session)
    let secondContext = QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: firstContext.generation + 1
    )
    let path = try #require(pathID("main.rs", in: session))
    let offset = byteOffset(of: "target();", in: source)
    let gate = ControlledContextResolver()
    let model = ContextWindowModel(gate.resolve)
    model.updateProjectState(.ready(session, firstContext), root: root)

    let pending = Task {
        await model.resolvedCandidate(file: "main.rs", offset: offset)
    }
    #expect(await testWaitUntil("gate.isPending(offset)") {
        gate.isPending(offset)
    })
    model.updateProjectState(.ready(session, secondContext), root: root)
    gate.complete(
        offset,
        with: try session.resolve(
            file: path,
            offset: offset,
            context: firstContext
        )
    )

    #expect(await pending.value == nil)
}

@MainActor
@Test
func pinnedContextIgnoresClickButExplicitJumpStillResolves() async throws {
    let source = "fn alpha() {}\nfn beta() {}\nfn main() { alpha(); beta(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    var resolveCount = 0
    let model = ContextWindowModel { session, file, offset, context in
        resolveCount += 1
        return try session.resolve(file: file, offset: offset, context: context)
    }
    model.updateProjectState(.ready(session, context), root: root)
    let alpha = byteOffset(of: "alpha();", in: source)
    let beta = byteOffset(of: "beta();", in: source)

    let first = try #require(await model.explicitJump(file: "main.rs", offset: alpha))
    model.setMode(.pinned)
    let pinnedStage = model.stage
    let pinnedCandidate = try #require(model.selectedCandidate)
    let pinnedRequestID = model.requestID

    model.tokenClicked(file: "main.rs", offset: beta)
    for _ in 0..<10 { await Task.yield() }
    #expect(resolveCount == 1)

    let target = try #require(await model.explicitJump(file: "main.rs", offset: beta))
    #expect(target.symbol != first.symbol)
    #expect(resolveCount == 2)
    #expect(model.requestID == pinnedRequestID)
    #expect(model.selectedIndex == 0)
    #expect(model.candidateCount == 1)
    #expect(model.selectedCandidate?.symbol == pinnedCandidate.symbol)
    #expect(model.selectedCandidate?.path == pinnedCandidate.path)
    #expect(model.selectedCandidate?.line == pinnedCandidate.line)
    #expect(model.selectedCandidate?.column == pinnedCandidate.column)
    #expect(model.selectedCandidate?.label == pinnedCandidate.label)
    #expect(model.selectedCandidate?.excerpt == pinnedCandidate.excerpt)
    #expect(model.selectedCandidate?.bindingKind == pinnedCandidate.bindingKind)
    #expect(model.selectedCandidate?.targetByteOffset == pinnedCandidate.targetByteOffset)
    guard case let .candidates(pinnedCandidates, pinnedSelected) = pinnedStage,
          case let .candidates(currentCandidates, currentSelected) = model.stage
    else {
        Issue.record("pinned explicit jump changed the context stage")
        return
    }
    #expect(currentSelected == pinnedSelected)
    #expect(currentCandidates.map(\.symbol) == pinnedCandidates.map(\.symbol))

    model.setMode(.follow)
    #expect(await model.explicitJump(file: "main.rs", offset: beta) != nil)
    #expect(model.selectedCandidate?.symbol == target.symbol)

    let followedRequestID = model.requestID
    #expect(await model.resolvedCandidate(file: "main.rs", offset: alpha) != nil)
    #expect(model.requestID == followedRequestID)
    #expect(model.selectedCandidate?.symbol == target.symbol)
}

@MainActor
@Test
func relationSelectionUpdatesContextUnlessPinned() async throws {
    let source = "fn target() {}\nfn caller() { target(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    var requests: [(path: String, offset: UInt32)] = []
    let contextWindow = ContextWindowModel { session, file, offset, context in
        requests.append((session.paths.resolve(file), offset))
        return try session.resolve(file: file, offset: offset, context: context)
    }
    let model = AppModel(
        indexService: FailingIndexService(),
        contextWindow: contextWindow
    )
    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
    #expect(model.transition(to: .ready(session, context)))
    let caller = try #require(
        session.definitions(of: "caller", context: context).first?.0
    )

    let loadTask = model.relationTree.setRoot(
        target: .engine(caller),
        direction: .calls
    )
    if let loadTask { await loadTask.value }
    let edge = try #require(
        appRelationRows(model.relationTree.root).first { $0.title == "target" }
    )

    contextWindow.setMode(.pinned)
    model.relationTree.select(edge)
    for _ in 0..<10 { await Task.yield() }
    #expect(requests.isEmpty)

    contextWindow.setMode(.follow)
    model.relationTree.select(edge)
    #expect(await testWaitUntil("requests.count == 1") { requests.count == 1 })
    #expect(requests.first?.path == "main.rs")
    #expect(requests.first?.offset == byteOffset(of: "target() {}", in: source))
}

@MainActor
@Test
func relationSelectionUpdatesContextOnConsecutiveCallerRows() async throws {
    let source = """
        fn target() {}
        fn first() { target(); }
        fn second() { target(); }
        """
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    var requests: [(path: String, offset: UInt32)] = []
    let contextWindow = ContextWindowModel { session, file, offset, context in
        requests.append((session.paths.resolve(file), offset))
        return try session.resolve(file: file, offset: offset, context: context)
    }
    let model = AppModel(
        indexService: FailingIndexService(),
        contextWindow: contextWindow
    )
    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
    #expect(model.transition(to: .ready(session, context)))
    let target = try #require(
        session.definitions(of: "target", context: context).first?.0
    )

    await model.relationTree.setRoot(
        target: .engine(target),
        direction: .callers
    )?.value
    let edges = appRelationRows(model.relationTree.root)
    let first = try #require(edges.first { $0.title == "first" })
    let second = try #require(edges.first { $0.title == "second" })

    model.relationTree.select(first)
    #expect(await testWaitUntil("contextWindow.selectedCandidate != nil") { contextWindow.selectedCandidate != nil })
    let firstCandidate = try #require(contextWindow.selectedCandidate)

    model.relationTree.select(second)
    #expect(await testWaitUntil("contextWindow.selectedCandidate?.symbol != firstCandidate.symbol") {
        contextWindow.selectedCandidate?.symbol != firstCandidate.symbol
    })
    #expect(requests.map(\.path) == ["main.rs", "main.rs"])
    #expect(requests.map(\.offset) == [
        byteOffset(of: "first() {", in: source),
        byteOffset(of: "second() {", in: source),
    ])
}

@MainActor
@Test
func relationSelectionUpdatesContextOnConsecutiveCallRows() async throws {
    let source = """
        fn first() {}
        fn second() {}
        fn root() { first(); second(); }
        """
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    var requests: [(path: String, offset: UInt32)] = []
    let contextWindow = ContextWindowModel { session, file, offset, context in
        requests.append((session.paths.resolve(file), offset))
        return try session.resolve(file: file, offset: offset, context: context)
    }
    let model = AppModel(
        indexService: FailingIndexService(),
        contextWindow: contextWindow
    )
    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
    #expect(model.transition(to: .ready(session, context)))
    let rootSymbol = try #require(
        session.definitions(of: "root", context: context).first?.0
    )

    await model.relationTree.setRoot(
        target: .engine(rootSymbol),
        direction: .calls
    )?.value
    let edges = appRelationRows(model.relationTree.root)
    let first = try #require(edges.first { $0.title == "first" })
    let second = try #require(edges.first { $0.title == "second" })

    model.relationTree.select(first)
    #expect(await testWaitUntil("contextWindow.selectedCandidate != nil") { contextWindow.selectedCandidate != nil })
    let firstCandidate = try #require(contextWindow.selectedCandidate)
    model.relationTree.select(second)
    #expect(await testWaitUntil("contextWindow.selectedCandidate?.symbol != firstCandidate.symbol") {
        contextWindow.selectedCandidate?.symbol != firstCandidate.symbol
    })
    #expect(requests.map(\.path) == ["main.rs", "main.rs"])
    #expect(requests.map(\.offset) == [
        byteOffset(of: "first() {}", in: source),
        byteOffset(of: "second() {}", in: source),
    ])
}

@MainActor
@Test
func relationSelectionUpdatesContextOnConsecutiveImplementationRows() async throws {
    let source = """
        trait Render { fn render(&self); }
        struct First;
        struct Second;
        impl Render for First { fn render(&self) {} }
        impl Render for Second { fn render(&self) {} }
        """
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let context = queryContext(for: session)
    var requests: [(path: String, offset: UInt32)] = []
    let contextWindow = ContextWindowModel { session, file, offset, context in
        requests.append((session.paths.resolve(file), offset))
        return try session.resolve(file: file, offset: offset, context: context)
    }
    let model = AppModel(
        indexService: FailingIndexService(),
        contextWindow: contextWindow
    )
    #expect(model.transition(to: .indexing(root: root, startedAt: .now)))
    #expect(model.transition(to: .ready(session, context)))
    let trait = try #require(
        session.definitions(of: "Render", context: context).first?.0
    )

    await model.relationTree.setRoot(
        target: .engine(trait),
        direction: .implementations
    )?.value
    let edges = appRelationRows(model.relationTree.root)
    let first = try #require(edges.first { $0.title == "First" })
    let second = try #require(edges.first { $0.title == "Second" })

    model.relationTree.select(first)
    #expect(await testWaitUntil("!requests.isEmpty") { !requests.isEmpty })
    let firstCandidate = contextWindow.selectedCandidate
    model.relationTree.select(second)
    #expect(await testWaitUntil("requests.count == 2") { requests.count == 2 })
    #expect(contextWindow.selectedCandidate?.symbol != firstCandidate?.symbol)
    #expect(requests.map(\.path) == ["main.rs", "main.rs"])
    #expect(requests[0].offset != requests[1].offset)
}

@MainActor
@Test
func contextCandidateSelectionWraps() async throws {
    let source = """
        struct A; impl A { fn close(&self) {} }
        struct B; impl B { fn close(&self) {} }
        fn f<T>(value: T) { value.close(); }
        """
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let model = ContextWindowModel()
    model.updateProjectState(.ready(session, queryContext(for: session)), root: root)
    model.tokenClicked(file: "main.rs", offset: byteOffset(of: "close();", in: source))
    #expect(await testWaitUntil("model.candidateCount == 2") { model.candidateCount == 2 })

    model.selectPrevious()
    #expect(model.selectedIndex == 1)
    model.selectNext()
    #expect(model.selectedIndex == 0)
}

@MainActor
@Test
func contextPendingTokenResolvesWhenIndexBecomesReady() async throws {
    let source = "fn target() {}\nfn main() { target(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    var resolveCount = 0
    let model = ContextWindowModel { session, file, offset, context in
        resolveCount += 1
        return try session.resolve(file: file, offset: offset, context: context)
    }
    model.updateProjectState(
        .indexing(root: root, startedAt: .now),
        root: root
    )

    model.tokenClicked(file: "main.rs", offset: byteOffset(of: "target();", in: source))
    #expect(model.isIndexBuilding)
    #expect(resolveCount == 0)

    model.updateProjectState(
        .ready(session, queryContext(for: session)),
        root: root
    )
    #expect(await testWaitUntil("model.candidateCount == 1") { model.candidateCount == 1 })
    #expect(resolveCount == 1)
}

@MainActor
@Test
func contextWindowResolvesUseAliasFixtureWithPresentationLabel() async throws {
    let root = repositoryRoot
        .appendingPathComponent("Tests/RustExtractorTests/Fixtures/use_alias")
    let source = try String(
        contentsOf: root.appendingPathComponent("main.rs"),
        encoding: .utf8
    )
    let session = try ProjectIndexer().index(root: root)
    let model = ContextWindowModel()
    model.updateProjectState(.ready(session, queryContext(for: session)), root: root)

    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "open_db();", in: source)
    )
    #expect(await testWaitUntil("model.candidateCount == 1") { model.candidateCount == 1 })
    let candidate = try #require(model.selectedCandidate)

    #expect(candidate.label.lowercased().contains("strong"))
    #expect(candidate.path == "db.rs")
}

@MainActor
@Test
func contextWindowPresentsLocalBindingKind() async throws {
    let source = "fn f() {\n    let local = 1;\n    local;\n}"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let model = ContextWindowModel()
    model.updateProjectState(.ready(session, queryContext(for: session)), root: root)

    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "local;", in: source)
    )
    #expect(await testWaitUntil("model.candidateCount == 1") { model.candidateCount == 1 })

    #expect(model.selectedCandidate?.bindingKind == "letBinding")
    #expect(model.selectedCandidate?.line == 2)
}

@MainActor
@Test
func contextWindowExplainsUnresolvedExternalCrate() async throws {
    let source = "use std::io::Read;\nfn f() { Read(); }"
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let model = ContextWindowModel()
    model.updateProjectState(.ready(session, queryContext(for: session)), root: root)

    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "Read();", in: source)
    )
    #expect(await testWaitUntil("model.candidateCount == 1") { model.candidateCount == 1 })

    #expect(model.selectedCandidate?.excerpt == "external crate — not resolved (M1)")
}

private actor ControlledIndexService: IndexService {
    typealias Outcome = Result<EngineSession, any Error>
    private var pending: [String: CheckedContinuation<Outcome, Never>] = [:]
    private var completed: [String: Outcome] = [:]
    private var delivered: Set<String> = []
    private var languagesByRoot: [String: LanguageID] = [:]

    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        let key = root.standardizedFileURL.path
        languagesByRoot[key] = language
        let result: Outcome
        if let completed = completed.removeValue(forKey: key) {
            result = completed
        } else {
            result = await withCheckedContinuation { pending[key] = $0 }
        }
        delivered.insert(key)
        return try result.get()
    }

    func complete(root: URL, result: Outcome) {
        let key = root.standardizedFileURL.path
        if let continuation = pending.removeValue(forKey: key) {
            continuation.resume(returning: result)
        } else {
            completed[key] = result
        }
    }

    func waitUntilDelivered(root: URL) async -> Bool {
        let key = root.standardizedFileURL.path
        return await waitUntil("index result delivered for \(key)") {
            delivered.contains(key)
        }
    }

    func waitUntilRequested(root: URL) async -> Bool {
        let key = root.standardizedFileURL.path
        return await waitUntil("index request received for \(key)") {
            pending[key] != nil
        }
    }

    func requestedLanguage(root: URL) -> LanguageID? {
        languagesByRoot[root.standardizedFileURL.path]
    }

    func requestedLanguages() -> [LanguageID] {
        Array(languagesByRoot.values)
    }

    private func waitUntil(
        _ description: String,
        _ condition: () -> Bool
    ) async -> Bool {
        // This wall-clock bound is only a hang fuse; performance has separate budget tests.
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                Issue.record("Cancelled while waiting for: \(description)")
                return false
            }
        }
        if condition() { return true }
        Issue.record("Hang fuse expired while waiting for: \(description)")
        return false
    }
}

@MainActor
private final class ControlledContextResolver {
    private var pending: [UInt32: CheckedContinuation<[ResolutionCandidate], Never>] = [:]
    private var completed: Set<UInt32> = []
    private var calls: [(language: LanguageID, profileID: AnalysisProfileID, offset: UInt32)] = []

    func resolve(
        session: EngineSession,
        file: PathID,
        offset: UInt32,
        context: QueryContext
    ) async throws -> [ResolutionCandidate] {
        calls.append((session.analysisProfile.language, session.analysisProfile.id, offset))
        let result = await withCheckedContinuation { pending[offset] = $0 }
        completed.insert(offset)
        return result
    }

    func isPending(_ offset: UInt32) -> Bool {
        pending[offset] != nil
    }

    func complete(_ offset: UInt32, with candidates: [ResolutionCandidate]) {
        pending.removeValue(forKey: offset)?.resume(returning: candidates)
    }

    func hasCompleted(_ offset: UInt32) -> Bool {
        completed.contains(offset)
    }

    func callLanguages() -> [LanguageID] {
        calls.map(\.language)
    }

}

private actor CountingContextLoader {
    private(set) var loadCount = 0
    private(set) var languageModes: [LanguageMode] = []

    func load(_ file: URL, languageMode: LanguageMode) -> ReaderDocument? {
        loadCount += 1
        languageModes.append(languageMode)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return ReaderDocument(bytes: Array(data), languageMode: languageMode)
    }
}

private struct FailingIndexService: IndexService {
    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        throw Failure.expected
    }
}

private actor CountingIndexService: IndexService {
    private(set) var capturedLanguages: [LanguageID] = []
    private(set) var preparedLanguages: [LanguageID] = []

    func index(root: URL, language: LanguageID) async throws -> EngineSession {
        throw Failure.expected
    }

    func captureSnapshot(
        root: URL,
        revision: String?,
        language: LanguageID
    ) async throws -> any Snapshot {
        capturedLanguages.append(language)
        return CountingIndexSnapshot(files: [:], configurationPaths: [])
    }

    func prepareSnapshot(
        _ snapshot: any Snapshot,
        language: LanguageID
    ) async throws -> ProjectIndexer.PreparedSnapshot {
        preparedLanguages.append(language)
        throw Failure.expected
    }

    func completeSnapshot(
        _ prepared: ProjectIndexer.PreparedSnapshot
    ) async throws -> EngineSession {
        throw Failure.expected
    }

    nonisolated func flushPersistentIndexCache() {}
}

private struct CountingIndexSnapshot: Snapshot {
    var snapshotID: SnapshotID {
        stableIdentity ? SnapshotID(rawValue: stableUUID) : SnapshotID(rawValue: UUID())
    }
    let objectFormat = GitObjectFormat.sha1
    let sourceKind = SourceKind.tracked
    let configurationPaths: [String]
    private let files: [String: [UInt8]]
    private let stableIdentity: Bool
    private let stableUUID: UUID

    init(
        files: [String: [UInt8]],
        configurationPaths: [String],
        stableIdentity: Bool = true
    ) {
        self.files = files
        self.configurationPaths = configurationPaths
        self.stableIdentity = stableIdentity
        stableUUID = UUID()
    }

    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)] {
        files.map {
            ($0.key, ContentID.sha256(of: $0.value), .regular)
        }.sorted { $0.path < $1.path }
    }

    func readBytes(path: String) throws -> [UInt8] {
        guard let bytes = files[path] else { throw Failure.expected }
        return bytes
    }
}

private enum Failure: Error {
    case expected
}

private func temporaryProject(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightAppModelTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, contents) in files {
        try write(contents, to: root.appendingPathComponent(path))
    }
    return root
}

private func temporaryGitProject(_ files: [String: String]) throws -> URL {
    let root = try temporaryProject(files)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path, "init", "-q"]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
    return root
}

private func indexCachePaths(for root: URL) throws -> [String] {
    let resolvedPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    let digest = ContentID.sha256(of: Data(resolvedPath.utf8)).bytes
        .map { String(format: "%02x", $0) }
        .joined()
    let rootDir: URL
    if let envRoot = ProcessInfo.processInfo.environment["CODEINSIGHT_INDEX_CACHE_ROOT"],
       !envRoot.isEmpty
    {
        rootDir = URL(fileURLWithPath: envRoot, isDirectory: true)
    } else if let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first {
        rootDir = applicationSupport.appendingPathComponent(
            "CodeInsight/index-cache",
            isDirectory: true
        )
    } else {
        throw CocoaError(.fileNoSuchFile)
    }
    let cache = rootDir.appendingPathComponent("\(digest).sqlite3")
    return ["", "-wal", "-shm"].map { cache.path + $0 }
}

private func write(_ contents: String, to file: URL) throws {
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try contents.write(to: file, atomically: true, encoding: .utf8)
}

private func queryContext(for session: EngineSession) -> QueryContext {
    QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
}

private func appRelationRows(
    _ root: RelationTreeModel.Node?
) -> [RelationTreeModel.Node] {
    root?.children?.flatMap { child in
        child.kind == .edge
            ? [child]
            : (child.children ?? []).filter { $0.kind == .edge }
    } ?? []
}

private func pathID(_ path: String, in session: EngineSession) -> PathID? {
    session.manifest.files.first {
        session.paths.resolve($0.pathID) == path
    }?.pathID
}

private func byteOffset(of needle: String, in source: String) -> UInt32 {
    let range = source.range(of: needle)!
    return UInt32(source[..<range.lowerBound].utf8.count)
}

private func jumpRecord(
    _ path: String,
    contentID: ContentID? = nil,
    offset: UInt32,
    line: UInt32 = 1,
    column: UInt32? = nil,
    symbolAnchor: String? = nil,
    snapshotID: SnapshotID? = SnapshotID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    )
) -> JumpRecord {
    JumpRecord(
        path: path,
        contentID: contentID,
        byteOffset: offset,
        line: line,
        column: column ?? offset + 1,
        symbolAnchor: symbolAnchor,
        snapshotID: snapshotID
    )
}
