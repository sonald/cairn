import CodeInsightCore
import CodeInsightReaderCore
import Foundation
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

@Test
func projectIndexServiceRejectsJavaScriptBeforeIO() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightUnsupportedService-\(UUID().uuidString)")
    let resolvedPath = root.resolvingSymlinksInPath().standardizedFileURL.path
    let digest = ContentID.sha256(of: Data(resolvedPath.utf8)).bytes
        .map { String(format: "%02x", $0) }
        .joined()
    guard let applicationSupport = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first else {
        Issue.record("application support directory unavailable")
        return
    }
    let cache = applicationSupport
        .appendingPathComponent("CodeInsight/index-cache")
        .appendingPathComponent("\(digest).sqlite3")
    let cachePaths = ["", "-wal", "-shm"].map { cache.path + $0 }
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

    func resolve(
        session: EngineSession,
        file: PathID,
        offset: UInt32,
        context: QueryContext
    ) async throws -> [ResolutionCandidate] {
        await withCheckedContinuation { pending[offset] = $0 }
    }

    func isPending(_ offset: UInt32) -> Bool {
        pending[offset] != nil
    }

    func complete(_ offset: UInt32, with candidates: [ResolutionCandidate]) {
        pending.removeValue(forKey: offset)?.resume(returning: candidates)
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
