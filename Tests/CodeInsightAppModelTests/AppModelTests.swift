import CodeInsightCore
import CodeInsightExact
import CodeInsightGit
import CodeInsightReaderCore
import Foundation
import os
import Testing
@testable import CodeInsightAppModel
@testable import CodeInsightEngine

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

@MainActor
@Test
func semanticNavigationVerifiesContentIdentityBeforeCommitting() async throws {
    let source = "pub fn target() -> i32 { 42 }\n"
    let root = try temporaryProject([
        "src/lib.rs": source,
        "src/other.rs": "pub fn other() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var opened: [(String, UInt32?)] = []
    let model = AppModel(indexService: FailingIndexService()) { file, offset in
        opened.append((file.lastPathComponent, offset))
    }
    model.openProject(root: root)
    #expect(await testWaitUntil("model.fileTree != nil") { model.fileTree != nil })
    let lib = root.appendingPathComponent("src/lib.rs")
    let indexIdentity = ContentID.sha256(of: Array(source.utf8))
    let targetOffset = byteOffset(of: "target", in: source)

    func indexJump(to file: URL) -> NavigationRequest {
        NavigationRequest(
            destination: SourceDestination(
                file: file,
                byteOffset: targetOffset,
                expectedContentID: indexIdentity
            ),
            cause: .search,
            policy: .explicitSemantic
        )
    }

    // Unchanged content: the index jump commits and lands on the offset.
    let openedBeforeFirst = opened.count
    model.navigate(indexJump(to: lib))
    #expect(await testWaitUntil("lib.rs opened at target offset") {
        opened.count == openedBeforeFirst + 1
            && opened.last?.0 == "lib.rs" && opened.last?.1 == targetOffset
    })
    #expect(model.staleIndexNotice == nil)
    let committedHistory = model.navigationHistory.navigationRecords.count
    let committedTrailEdges = model.readingTrail.edges.count

    // Disk drifts behind the index's back (review repro: prefix comment
    // lines plus a rename). The stale offset must not move the viewport.
    let drifted = String(repeating: "// review drift\n", count: 8)
        + "pub fn renamed() -> i32 { 42 }\n"
    try write(drifted, to: lib)
    let openedBeforeStale = opened.count
    model.navigate(
        indexJump(to: lib),
        leaving: jumpRecord("src/other.rs", offset: 1)
    )
    try await Task.sleep(for: .milliseconds(300))
    #expect(model.staleIndexNotice == "File changed since indexing")
    #expect(opened.count == openedBeforeStale)
    #expect(
        model.navigationHistory.navigationRecords.count == committedHistory,
        "rejected navigation must not add history"
    )
    #expect(
        model.readingTrail.edges.count == committedTrailEdges,
        "rejected navigation must not extend the trail"
    )

    // Content matches the index again: the same jump resumes working.
    try write(source, to: lib)
    let openedBeforeRestore = opened.count
    model.navigate(indexJump(to: lib))
    #expect(await testWaitUntil("lib.rs reopened at target offset") {
        opened.count == openedBeforeRestore + 1
            && opened.last?.0 == "lib.rs" && opened.last?.1 == targetOffset
    })
    #expect(model.staleIndexNotice == nil)
}

@MainActor
@Test
func semanticNavigationChecksDisplayedDocumentWithoutRereading() async throws {
    let source = "pub fn target() -> i32 { 42 }\n"
    let root = try temporaryProject([
        "src/lib.rs": source,
        "src/other.rs": "pub fn other() {}\n",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var opened: [(String, UInt32?)] = []
    let model = AppModel(indexService: FailingIndexService()) { file, offset in
        opened.append((file.lastPathComponent, offset))
    }
    model.openProject(root: root)
    #expect(await testWaitUntil("model.fileTree != nil") { model.fileTree != nil })
    let lib = root.appendingPathComponent("src/lib.rs")
    let indexIdentity = ContentID.sha256(of: Array(source.utf8))
    let targetOffset = byteOffset(of: "target", in: source)
    let rust = LanguageMode(language: .rust)

    // Simulate the Reader already showing the drifted file.
    model.navigate(to: lib)
    let drifted = String(repeating: "// review drift\n", count: 8)
        + "pub fn renamed() -> i32 { 42 }\n"
    model.tabStrip.setActiveDocument(
        ReaderDocument(bytes: Array(drifted.utf8), languageMode: rust),
        for: lib
    )
    let openedBeforeStale = opened.count
    let historyBeforeStale = model.navigationHistory.navigationRecords.count
    model.navigate(
        NavigationRequest(
            destination: SourceDestination(
                file: lib,
                byteOffset: targetOffset,
                expectedContentID: indexIdentity
            ),
            cause: .search,
            policy: .explicitSemantic
        ),
        leaving: jumpRecord("src/other.rs", offset: 1)
    )
    #expect(opened.count == openedBeforeStale)
    #expect(model.staleIndexNotice == "File changed since indexing")
    #expect(model.navigationHistory.navigationRecords.count == historyBeforeStale)

    // The displayed document matches the index again: jumps resume.
    model.tabStrip.setActiveDocument(
        ReaderDocument(bytes: Array(source.utf8), languageMode: rust),
        for: lib
    )
    model.navigate(NavigationRequest(
        destination: SourceDestination(
            file: lib,
            byteOffset: targetOffset,
            expectedContentID: indexIdentity
        ),
        cause: .search,
        policy: .explicitSemantic
    ))
    #expect(opened.last?.0 == "lib.rs" && opened.last?.1 == targetOffset)
    #expect(model.staleIndexNotice == nil)
}

@MainActor
@Test
func semanticNavigationRejectsDeletedInvalidUTF8AndOutOfRangeTargets() async throws {
    let source = "pub fn target() -> i32 { 42 }\n"
    let root = try temporaryProject([
        "src/lib.rs": source,
        "src/gone.rs": source,
        "src/binary.rs": source,
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    var opened: [(String, UInt32?)] = []
    let model = AppModel(indexService: FailingIndexService()) { file, offset in
        opened.append((file.lastPathComponent, offset))
    }
    model.openProject(root: root)
    #expect(await testWaitUntil("model.fileTree != nil") { model.fileTree != nil })
    let lib = root.appendingPathComponent("src/lib.rs")
    let gone = root.appendingPathComponent("src/gone.rs")
    let binary = root.appendingPathComponent("src/binary.rs")
    let indexIdentity = ContentID.sha256(of: Array(source.utf8))
    let targetOffset = byteOffset(of: "target", in: source)
    let openedBefore = opened.count

    // Offset beyond the indexed content: no navigation even though the
    // identity itself matches.
    model.navigate(NavigationRequest(
        destination: SourceDestination(
            file: lib,
            byteOffset: 10_000,
            expectedContentID: indexIdentity
        ),
        cause: .search,
        policy: .explicitSemantic
    ))
    try await Task.sleep(for: .milliseconds(300))
    #expect(opened.count == openedBefore)
    #expect(model.staleIndexNotice != nil)

    // Invalid UTF-8 content cannot produce a readable jump target.
    try Data([0xFF, 0xFE, 0x00, 0xD8, 0x41]).write(to: binary)
    model.navigate(NavigationRequest(
        destination: SourceDestination(
            file: binary,
            byteOffset: 1,
            expectedContentID: indexIdentity
        ),
        cause: .search,
        policy: .explicitSemantic
    ))
    try await Task.sleep(for: .milliseconds(300))
    #expect(opened.count == openedBefore)
    #expect(model.staleIndexNotice != nil)

    // Deleted target: the jump is rejected instead of failing mid-display.
    try FileManager.default.removeItem(at: gone)
    model.navigate(NavigationRequest(
        destination: SourceDestination(
            file: gone,
            byteOffset: targetOffset,
            expectedContentID: indexIdentity
        ),
        cause: .search,
        policy: .explicitSemantic
    ))
    try await Task.sleep(for: .milliseconds(300))
    #expect(opened.count == openedBefore)
    #expect(model.staleIndexNotice != nil)
}

@MainActor
@Test
func semanticValidationCannotPublishAfterNewerNavigationOrProjectSwitch() async throws {
    let source = "pub fn target() -> i32 { 42 }\n"
    let first = try temporaryProject([
        "src/lib.rs": source,
        "src/other.rs": "pub fn other() {}\n",
    ])
    let second = try temporaryProject(["src/second.rs": source])
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    var opened: [(String, UInt32?)] = []
    let model = AppModel(indexService: FailingIndexService()) { file, offset in
        opened.append((file.lastPathComponent, offset))
    }
    model.openProject(root: first)
    #expect(await testWaitUntil("model.fileTree != nil") { model.fileTree != nil })
    let lib = first.appendingPathComponent("src/lib.rs")
    let other = first.appendingPathComponent("src/other.rs")
    let indexIdentity = ContentID.sha256(of: Array(source.utf8))
    let targetOffset = byteOffset(of: "target", in: source)

    // The target drifted, so its validation can only end in rejection; the
    // user navigates elsewhere before the background check completes.
    try write(String(repeating: "// drift\n", count: 4), to: lib)
    model.navigate(NavigationRequest(
        destination: SourceDestination(
            file: lib,
            byteOffset: targetOffset,
            expectedContentID: indexIdentity
        ),
        cause: .search,
        policy: .explicitSemantic
    ))
    model.navigate(to: other)
    try await Task.sleep(for: .milliseconds(300))
    #expect(opened.last?.0 == "other.rs")
    #expect(
        !opened.contains { $0.0 == "lib.rs" && $0.1 == targetOffset },
        "a validation started before a newer navigation must not publish"
    )

    // A validation from a previous project must not survive a project switch.
    opened.removeAll()
    model.openProject(root: second)
    #expect(await testWaitUntil("second project fileTree") {
        model.fileTree?.root.standardizedFileURL
            == second.standardizedFileURL
    })
    let secondLib = second.appendingPathComponent("src/second.rs")
    try write(String(repeating: "// drift\n", count: 4), to: secondLib)
    model.navigate(NavigationRequest(
        destination: SourceDestination(
            file: secondLib,
            byteOffset: targetOffset,
            expectedContentID: indexIdentity
        ),
        cause: .search,
        policy: .explicitSemantic
    ))
    model.openProject(root: first)
    try await Task.sleep(for: .milliseconds(300))
    #expect(
        !opened.contains { $0.0 == "second.rs" && $0.1 == targetOffset },
        "a validation from the previous project must not publish"
    )
}

@MainActor
@Test
func semanticNavigationCommitsUnicodeOffsetsAgainstMatchingContent() async throws {
    let source = "// 注释😀\npub fn 目标函数() -> i32 { 42 }\n"
    let root = try temporaryProject(["src/lib.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    var opened: [(String, UInt32?)] = []
    let model = AppModel(indexService: FailingIndexService()) { file, offset in
        opened.append((file.lastPathComponent, offset))
    }
    model.openProject(root: root)
    #expect(await testWaitUntil("model.fileTree != nil") { model.fileTree != nil })
    let lib = root.appendingPathComponent("src/lib.rs")
    let indexIdentity = ContentID.sha256(of: Array(source.utf8))
    let targetOffset = byteOffset(of: "目标函数", in: source)

    model.navigate(NavigationRequest(
        destination: SourceDestination(
            file: lib,
            byteOffset: targetOffset,
            expectedContentID: indexIdentity
        ),
        cause: .search,
        policy: .explicitSemantic
    ))
    #expect(await testWaitUntil("unicode offset lands") {
        opened.last?.0 == "lib.rs" && opened.last?.1 == targetOffset
    })

    // Positions produced from the current document (outline-style, no index
    // identity) keep working even after the index bytes went stale.
    try write("// 注释😀\npub fn 改名函数() -> i32 { 42 }\n", to: lib)
    model.navigate(NavigationRequest(
        destination: SourceDestination(
            file: lib,
            byteOffset: byteOffset(of: "改名函数", in: "// 注释😀\npub fn 改名函数() -> i32 { 42 }\n")
        ),
        cause: .outline,
        policy: .explicitSemantic
    ))
    #expect(opened.last?.0 == "lib.rs")
    #expect(opened.last?.1 != nil)
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

@Test
func replayOffsetReturnsToTheOriginalFunctionWhenCodeMovedAboveIt() throws {
    // Saved position points inside `target` as it was; a function has
    // since been inserted above it, so the saved line/column would land
    // inside the wrong function. The unique symbol anchor must win.
    let previous = "fn target() {}\n"
    let updated = "fn inserted() {}\nfn target() {}\n"
    let root = try temporaryProject(["a.rs": updated])
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("a.rs")

    let restored = try AppModel.replayOffset(
        jumpRecord(
            "a.rs",
            contentID: ContentID.sha256(of: Array(previous.utf8)),
            offset: 11,
            line: 1,
            column: 12,
            symbolAnchor: "target"
        ),
        file: file,
        source: nil
    )
    #expect(restored.offset == byteOffset(of: "target", in: updated))
    #expect(restored.fallback == .symbol)

    // An ambiguous anchor (two overloads) must degrade to the saved
    // line/column instead of guessing a declaration.
    let ambiguous = "fn dup() {}\nfn dup() {}\nfn tail() {}\n"
    let ambiguousRoot = try temporaryProject(["b.rs": ambiguous])
    defer { try? FileManager.default.removeItem(at: ambiguousRoot) }
    let degraded = try AppModel.replayOffset(
        jumpRecord(
            "b.rs",
            contentID: ContentID.sha256(of: [0]),
            offset: 99,
            line: 3,
            column: 4,
            symbolAnchor: "dup"
        ),
        file: ambiguousRoot.appendingPathComponent("b.rs"),
        source: nil
    )
    #expect(degraded.offset == byteOffset(of: "tail", in: ambiguous))
    #expect(degraded.fallback == .line)
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

@Test
func fileTreeShowsRegularFilesAndExcludesMetadataAndSymlinks() throws {
    let root = try temporaryProject([
        "z.rs": "",
        "a.rs": "",
        "README.md": "markdown",
        "guide.html": "html",
        "image.png": "png",
        "paper.pdf": "pdf",
        "notes.txt": "text",
        "payload.bin": "binary",
        "src/z.rs": "",
        "src/a.rs": "",
        "empty/note.txt": "text",
        "upper.RS": "case",
        ".DS_Store": "metadata",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(
        atPath: root.appendingPathComponent("linked.md").path,
        withDestinationPath: "README.md"
    )
    for skipped in ProjectPathRules.alwaysSkippedDirectories + ProjectPathRules.defaultSkippedDirectories {
        try write("", to: root.appendingPathComponent(skipped).appendingPathComponent("skip.rs"))
    }

    let tree = try FileTreeModel(root: root)

    func relativeFiles(in nodes: [FileTreeNode]) -> Set<String> {
        Set(nodes.flatMap { node in
            if node.isDirectory {
                return relativeFiles(in: node.children).map {
                    "\(node.name)/\($0)"
                }
            }
            return [node.name]
        })
    }

    let expected = Set([
        "README.md", "guide.html", "image.png", "paper.pdf", "notes.txt",
        "payload.bin", "upper.RS", "z.rs", "a.rs", "empty/note.txt",
        "src/a.rs", "src/z.rs",
    ])
    #expect(relativeFiles(in: tree.children) == expected)
    #expect(tree.fileCount == expected.count)
    #expect(tree.children.first { $0.name == "src" }?.children.map(\.name)
        == ["a.rs", "z.rs"])
    #expect(
        tree.selectionPath(for: root.appendingPathComponent("src/a.rs"))?
            .map(\.name) == ["src", "a.rs"]
    )
    #expect(tree.selectionPath(for: root.appendingPathComponent("missing.rs")) == nil)
    #expect(tree.selectionPath(for: root.appendingPathComponent("linked.md")) == nil)
    #expect(tree.selectionPath(for: root.appendingPathComponent(".DS_Store")) == nil)
    #expect(tree.selectionPath(for: nil) == nil)

    let snapshot = FileTreeModel(
        root: root,
        snapshotPaths: ["src/a.rs", "README.md"]
    )
    #expect(snapshot.children.map(\.name) == ["src", "README.md"])
    #expect(snapshot.children.first { $0.name == "src" }?.children.map(\.name)
        == ["a.rs"])
    #expect(snapshot.fileCount == 2)
}

@MainActor
@Test
func projectOpenPublishesFileTreeAsynchronously() async throws {
    let root = try temporaryProject([
        "main.rs": "fn main() {}",
        "README.md": "read me",
        "payload.bin": "binary",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: FailingIndexService())

    model.openProject(root: root)

    #expect(model.fileTree == nil)
    #expect(await testWaitUntil("model.fileTree?.fileCount == 3") { model.fileTree?.fileCount == 3 })
    #expect(model.coverage.filesTotal == 1)
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
    let service = ControlledIndexService()
    let model = AppModel(indexService: service)

    model.openProject(root: rootA)
    #expect(model.fileTree == nil)
    #expect(await service.waitUntilRequested(root: rootA))
    model.openProject(root: rootB)

    #expect(model.generation == 2)
    #expect(model.fileTree == nil)
    guard case let .indexing(root, _) = model.projectState else {
        Issue.record("expected indexing")
        return
    }
    #expect(root == rootB.standardizedFileURL)

    await service.complete(root: rootB)
    #expect(await testWaitUntil("if case .ready = model.projectState { return true } return false") {
        if case .ready = model.projectState { return true }
        return false
    })
    let readySnapshotID = model.currentSnapshotID

    await service.complete(root: rootA)
    #expect(await service.waitUntilDelivered(root: rootA))
    for _ in 0..<10 { await Task.yield() }

    guard case let .ready(session, context) = model.projectState else {
        Issue.record("expected ready")
        return
    }
    #expect(model.fileTree?.root == rootB.standardizedFileURL)
    #expect(model.fileTree?.children.map(\.name) == ["b.rs"])
    #expect(session.snapshotID == readySnapshotID)
    #expect(context.snapshotID == readySnapshotID)
    #expect(context.generation == 2)
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
    #expect(model.projectLanguages == [.rust])
    #expect(model.projectRoot == root.standardizedFileURL)
}

@MainActor
@Test
func mismatchedSessionLanguageFailsWithoutPublishingSessionState() async throws {
    let root = try temporaryProject(["main.rs": "fn main() {}"])
    defer { try? FileManager.default.removeItem(at: root) }
    // The service prepares Python sessions for a Rust worktree.
    let service = ControlledIndexService(preparing: [.python])
    let model = AppModel(indexService: service)

    model.openProject(root: root)
    #expect(await service.waitUntilRequested(root: root))
    await service.complete(root: root)
    #expect(await testWaitUntil("mismatched session rejected") {
        if case .failed = model.projectState { return true }
        return false
    })

    #expect(model.projectLanguages == [.rust])
    #expect(model.querySessions.isEmpty)
    #expect(model.snapshotPhase == .firstPaint)
    #expect(model.coverage.filesIndexed == 0)
    #expect(model.coverage.filesTotal == 1)
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
    await model.openProject(root: root).value

    #expect(model.projectLanguages == [.rust, .python, .typescript])
    #expect(model.querySessions.map { $0.0.analysisProfile.language }
        == [.rust, .python, .typescript])
    #expect(Set(model.querySessions.map { $0.0.snapshotID }).count == 1)
    #expect(model.fileTree?.fileCount == 7)
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
func twoRustUnitsRouteByContainingUnitAndSwitchProfileOnFileChange() async throws {
    let root = try temporaryGitProject([
        "crates/a/Cargo.toml": "[package]\nname = \"a\"\n",
        "crates/a/src/lib.rs": "pub fn a() {}\n",
        "crates/b/Cargo.toml": "[package]\nname = \"b\"\n",
        "crates/b/src/lib.rs": "pub fn b() {}\n",
        "pkg.py": "def f():\n    pass\n",
    ])
    let cachePaths = try indexCachePaths(for: root)
    defer {
        try? FileManager.default.removeItem(at: root)
        for path in cachePaths { try? FileManager.default.removeItem(atPath: path) }
    }
    let model = AppModel(indexService: ProjectIndexService())
    await model.openProject(root: root).value

    #expect(model.querySessions.count == 3)
    let rustUnits = model.detectedLanguageUnits.filter { $0.language == .rust }
    #expect(rustUnits.map(\.unitRoot) == ["crates/a", "crates/b"])
    #expect(rustUnits.map(\.sourceFiles) == [1, 1])

    func activeUnit() -> (root: String, id: AnalysisProfileID)? {
        guard case let .ready(session, context) = model.projectState else { return nil }
        return (session.paths.resolve(session.analysisProfile.projectRoot), context.analysisProfileID)
    }
    model.navigate(to: root.appendingPathComponent("crates/a/src/lib.rs"))
    let first = try #require(activeUnit())
    #expect(first.root == "crates/a")
    model.navigate(to: root.appendingPathComponent("crates/b/src/lib.rs"))
    let second = try #require(activeUnit())
    #expect(second.root == "crates/b")
    #expect(second.id != first.id)
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
    await model.openProject(root: root).value

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
    #expect(await testWaitUntil("model.contextWindow.displayedCandidate != nil") {
        model.contextWindow.displayedCandidate != nil
    })
    #expect(model.contextWindow.displayedCandidate?.path == "lib.py")
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
    await model.openProject(root: root).value

    model.navigate(to: root.appendingPathComponent("lib.py"))
    let offset = byteOffset(of: "shared()\n", in: pySource)
    model.contextWindow.tokenClicked(file: "lib.py", offset: offset)
    #expect(await testWaitUntil("model.contextWindow.displayedCandidate != nil") {
        model.contextWindow.displayedCandidate != nil
    })
    #expect(model.contextWindow.displayedCandidate?.path == "lib.py")
    #expect(model.contextWindow.displayedCandidate?.excerpt.isEmpty != true)
    #expect(model.contextWindow.displayedCandidate?.symbol?.snapshotID == model.currentSnapshotID)
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
    await model.openProject(root: root).value

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
func restartExactAnalysisRetriesFailedProviderWithoutChangingReadingState() async throws {
    let root = try temporaryGitProject([
        "main.rs": "fn main() {}\n",
        "Cargo.toml": "[package]\nname = \"retry-test\"\nversion = \"0.1.0\"\n"
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let coordinator = ExactCoordinator(
        providerFactory: { _, _ in
            calls.withLock { $0 += 1 }
            throw ExactError.unavailable("test provider failed")
        },
        sandboxAvailable: { true },
        trustRegistry: TrustRegistry(fileURL: root.appendingPathComponent("trust.json"))
    )
    let model = AppModel(indexService: ProjectIndexService(), exactCoordinator: coordinator)
    defer { coordinator.shutdown() }
    await model.openProject(root: root).value
    try #require(model.snapshotPhase == .fullReady, "\(String(describing: model.projectFailureReason))")
    model.navigate(to: root.appendingPathComponent("main.rs"))
    #expect(await testWaitUntil("initial provider fails") {
        if case .unavailable = coordinator.readiness { return true }
        return false
    })
    let generation = model.generation
    let selectedFile = model.selectedFile
    let trust = coordinator.trustMode
    let before = calls.withLock { $0 }
    try #require(before > 0)
    model.restartExactAnalysis()
    #expect(await testWaitUntil("manual retry finishes") {
        if case .unavailable = coordinator.readiness {
            return calls.withLock { $0 } == before + 1
        }
        return false
    })
    #expect(model.generation == generation)
    #expect(model.selectedFile == selectedFile)
    #expect(coordinator.trustMode == trust)
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
    await model.openProject(root: root).value

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
    let snapshot = try await service.captureSnapshot(root: root, revision: nil)
    #expect(snapshot.languages == [.rust, .python, .typescript])
    let paths = snapshot.listFiles().map(\.path)
    #expect(Set(paths) == Set([
        "crates/r/Cargo.toml",
        "crates/r/src/lib.rs",
        "pkg.py",
        "pyproject.toml",
        "tools/ts/src/a.ts",
        "tools/ts/src/b.tsx",
        "tools/ts/tsconfig.json",
    ]))

    let prepared = try await service.prepareSnapshots(
        snapshot,
        root: root,
        languages: snapshot.languages
    )
    #expect(prepared.map { $0.cachedSessions[0].analysisProfile.language }
        == [.rust, .python, .typescript])
    #expect(Set(prepared.map { $0.cachedSessions[0].snapshotID }).count == 1)
    #expect(Set(prepared.map { ObjectIdentifier($0.cachedSessions[0].store) }).count == 1)
    #expect(Set(prepared.map { ObjectIdentifier($0.cachedSessions[0].paths) }).count == 1)
    #expect(Set(prepared.map { ObjectIdentifier($0.cachedSessions[0].names) }).count == 1)
    #expect(Set(prepared.map { ObjectIdentifier($0.cachedSessions[0].strings) }).count == 1)
    #expect(prepared.map {
        $0.cachedSessions[0].paths.resolve($0.cachedSessions[0].analysisProfile.projectRoot)
    } == ["crates/r", ".", "tools/ts"])

    let cached = prepared.map { $0.cachedSessions[0] }
    var full: [EngineSession] = []
    for item in prepared {
        full.append(contentsOf: try await service.completeSnapshot(item))
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
    await model.openProject(root: root).value
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

    // R4.3 (T4): a click with no resolvable token KEEPS the previous content
    // and the located token — the lens stays usable and flags the miss.
    model.tokenClicked(file: "main.rs", offset: commentOffset)
    for _ in 0..<10 { await Task.yield() }
    #expect(model.candidateCount == 1)
    #expect(model.isShowingPreviousToken)

    // Re-clicking the retained token is deduped (no re-resolve)…
    model.tokenClicked(file: "main.rs", offset: tokenOffset)
    for _ in 0..<10 { await Task.yield() }
    #expect(model.candidateCount == 1)
    #expect(resolveCount == 1)
    // …and a genuinely new token still resolves after the miss.
    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "fn main() {", in: source) + 4
    )
    #expect(await testWaitUntil("model.candidateCount == 1 && !model.isShowingPreviousToken") {
        model.candidateCount == 1 && !model.isShowingPreviousToken
    })
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
    #expect(await testWaitUntil("model.displayedCandidate?.line == 2") { model.displayedCandidate?.line == 2 })
    gate.complete(
        alpha,
        with: try session.resolve(file: path, offset: alpha, context: context)
    )
    for _ in 0..<10 { await Task.yield() }

    #expect(model.displayedCandidate?.line == 2)
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
    #expect(await testWaitUntil("model.displayedCandidate?.targetByteOffset == byteOffset(of: \"beta() {}\", in: source)") {
        model.displayedCandidate?.targetByteOffset
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
    #expect(await testWaitUntil("model.displayedCandidate?.targetByteOffset != nil") {
        model.displayedCandidate?.targetByteOffset != nil
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

/// Holds each worktree capture until the test completes it, then captures
/// and indexes for real (no persistent cache).
private actor ControlledIndexService: IndexService {
    private var pending: [String: CheckedContinuation<(any Error)?, Never>] = [:]
    private var completed: [String: (any Error)?] = [:]
    private var delivered: Set<String> = []
    private let preparedLanguages: [LanguageID]?

    /// `preparing` replaces the requested languages, to feed the model
    /// sessions that do not match its set.
    init(preparing preparedLanguages: [LanguageID]? = nil) {
        self.preparedLanguages = preparedLanguages
    }

    func captureSnapshot(root: URL, revision: String?) async throws -> any Snapshot {
        let key = root.standardizedFileURL.path
        let failure: (any Error)?
        if let completed = completed.removeValue(forKey: key) {
            failure = completed
        } else {
            failure = await withCheckedContinuation { pending[key] = $0 }
        }
        delivered.insert(key)
        if let failure { throw failure }
        return try WorktreeSnapshot(repositoryURL: root)
    }

    func prepareSnapshots(
        _ snapshot: any Snapshot,
        root: URL,
        languages: [LanguageID]
    ) async throws -> [ProjectIndexer.PreparedSnapshot] {
        try ProjectIndexer().prepareSnapshots(
            snapshot,
            into: ProjectIndexStore(),
            languages: preparedLanguages ?? languages
        )
    }

    func completeSnapshot(
        _ prepared: ProjectIndexer.PreparedSnapshot
    ) async throws -> [EngineSession] {
        try ProjectIndexer().completeSnapshot(prepared)
    }

    func complete(root: URL, failure: (any Error)? = nil) {
        let key = root.standardizedFileURL.path
        if let continuation = pending.removeValue(forKey: key) {
            continuation.resume(returning: failure)
        } else {
            completed[key] = failure
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

/// Captures the real worktree (so the file tree and coverage publish) and
/// fails indexing.
private struct FailingIndexService: IndexService {
    func captureSnapshot(root: URL, revision: String?) async throws -> any Snapshot {
        CurrentTestSnapshot(wrapped: try WorktreeSnapshot(repositoryURL: root))
    }

    func prepareSnapshots(
        _ snapshot: any Snapshot,
        root: URL,
        languages: [LanguageID]
    ) async throws -> [ProjectIndexer.PreparedSnapshot] {
        throw Failure.expected
    }

    func completeSnapshot(
        _ prepared: ProjectIndexer.PreparedSnapshot
    ) async throws -> [EngineSession] {
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

private func pathID(_ path: String, in session: EngineSession) -> PathID? {
    session.manifest.files.first {
        session.paths.resolve($0.pathID) == path
    }?.pathID
}

private func byteOffset(of needle: String, in source: String) -> UInt32 {
    let range = source.range(of: needle)!
    return UInt32(source[..<range.lowerBound].utf8.count)
}

private let currentTestSnapshotID = SnapshotID(
    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
)

/// A worktree under the identity `jumpRecord` stamps by default, so records
/// a test makes belong to the snapshot the model shows.
private struct CurrentTestSnapshot: Snapshot {
    let wrapped: WorktreeSnapshot
    var snapshotID: SnapshotID { currentTestSnapshotID }
    var objectFormat: GitObjectFormat { wrapped.objectFormat }
    var sourceKind: SourceKind { wrapped.sourceKind }
    var projectRootName: String { wrapped.projectRootName }
    var configurationPaths: [String] { wrapped.configurationPaths }
    var ruleExcludedPaths: [String] { wrapped.ruleExcludedPaths }
    var languages: [LanguageID] { wrapped.languages }

    func listFiles() -> [(path: String, contentID: ContentID, fileMode: FileMode)] {
        wrapped.listFiles()
    }

    func readBytes(path: String) throws -> [UInt8] {
        try wrapped.readBytes(path: path)
    }
}

private func jumpRecord(
    _ path: String,
    contentID: ContentID? = nil,
    offset: UInt32,
    line: UInt32 = 1,
    column: UInt32? = nil,
    symbolAnchor: String? = nil,
    snapshotID: SnapshotID? = currentTestSnapshotID
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

@MainActor
@Test
func openingASecondProjectPublishesOnlyTheSecondForSingleLanguage() async throws {
    let first = try temporaryProject(["a.rs": "fn a() {}\n"])
    let second = try temporaryProject(["b.rs": "fn b() {}\n"])
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    let service = ControlledIndexService()
    let model = AppModel(indexService: service)

    model.openProject(root: first)
    #expect(await service.waitUntilRequested(root: first))

    // The first open is still awaiting its session when the user opens the
    // second project; only the second one may publish.
    await service.complete(root: second)
    model.openProject(root: second)
    #expect(await testWaitUntil("second project published") {
        model.snapshotPhase == .fullReady
            && model.projectRoot?.standardizedFileURL
                == second.standardizedFileURL
    })
    #expect(model.fileTree?.children.map(\.name) == ["b.rs"])

    await service.complete(root: first)
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.projectRoot?.standardizedFileURL
        == second.standardizedFileURL)
    #expect(model.fileTree?.children.map(\.name) == ["b.rs"])
}

@MainActor
@Test
func openAndSwitchFailuresSurfaceTheirUnderlyingReasons() async throws {
    // Missing path: the real service fails and the reason is preserved.
    let missing = URL(
        fileURLWithPath: "/nonexistent-\(UUID().uuidString)",
        isDirectory: true
    )
    let missingModel = AppModel(indexService: ProjectIndexService())
    missingModel.openProject(root: missing)
    #expect(await testWaitUntil("missing path failed") {
        if case .failed = missingModel.projectState { return true }
        return false
    })
    #expect(missingModel.projectFailureReason?.isEmpty == false)

    // Denied read: the underlying CocoaError reaches the failure state.
    let deniedRoot = try temporaryProject(["a.rs": "fn a() {}\n"])
    defer { try? FileManager.default.removeItem(at: deniedRoot) }
    let deniedService = ControlledIndexService()
    let deniedModel = AppModel(indexService: deniedService)
    deniedModel.openProject(root: deniedRoot)
    #expect(await deniedService.waitUntilRequested(root: deniedRoot))
    await deniedService.complete(root: deniedRoot, failure: CocoaError(.fileReadNoPermission))
    #expect(await testWaitUntil("permission failure surfaced") {
        if case .failed = deniedModel.projectState { return true }
        return false
    })
    #expect(deniedModel.projectFailureReason?.isEmpty == false)

    // Invalid Git revision on a ready repository fails with its reason.
    let gitRoot = try temporaryGitProject(["src/lib.rs": "pub fn a() {}\n"])
    defer { try? FileManager.default.removeItem(at: gitRoot) }
    let gitModel = AppModel(indexService: ProjectIndexService())
    gitModel.openProject(root: gitRoot)
    #expect(await testWaitUntil("git project ready") {
        gitModel.snapshotPhase == .fullReady
    })
    gitModel.switchToCommit(String(repeating: "0", count: 40))
    #expect(await testWaitUntil("invalid revision failed") {
        if case .failed = gitModel.projectState { return true }
        return false
    })
    #expect(gitModel.projectFailureReason?.isEmpty == false)

    // A successful reopen clears the previous reason.
    gitModel.openProject(root: gitRoot)
    #expect(await testWaitUntil("git project reopened") {
        gitModel.snapshotPhase == .fullReady
    })
    #expect(gitModel.projectFailureReason == nil)

    // Unbounded provider stderr stays bounded in the surfaced reason.
    let huge = LSPError.processExited(
        1,
        String(repeating: "stderr noise; ", count: 200)
    )
    let summary = AppModel.failureSummary(huge)
    #expect(summary.count <= 281)
    #expect(summary.hasSuffix("…"))
}

/// Captures and fully indexes the worktree; returns its first language's session.
private func indexWorktree(_ service: ProjectIndexService, root: URL) async throws -> EngineSession {
    let snapshot = try await service.captureSnapshot(root: root, revision: nil)
    let prepared = try await service.prepareSnapshots(snapshot, root: root, languages: snapshot.languages)
    return try await service.completeSnapshot(prepared[0])[0]
}

@MainActor
@Test
func projectBoundaryReplacesTheServiceStoreButKeepsOldSessionsUsable() async throws {
    let first = try temporaryGitProject([
        "src/lib.rs": "pub fn first_only() {}\n",
    ])
    let second = try temporaryGitProject([
        "src/lib.rs": "pub fn second_only() {}\n",
    ])
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    let service = ProjectIndexService()
    let firstSession = try await indexWorktree(service, root: first)
    let firstIdentity = ContentID.sha256(
        of: Array("pub fn first_only() {}\n".utf8)
    )
    #expect(
        service.retainedContentIDsForDiagnostics.contains(firstIdentity),
        "the open project's content must be retained"
    )

    // Crossing the project boundary replaces the service store; the old
    // project's bytes must not stay retained by the service.
    let secondSession = try await indexWorktree(service, root: second)
    #expect(
        !service.retainedContentIDsForDiagnostics.contains(firstIdentity),
        "a closed project's content must leave the service store"
    )
    let secondIdentity = ContentID.sha256(
        of: Array("pub fn second_only() {}\n".utf8)
    )
    #expect(service.retainedContentIDsForDiagnostics.contains(secondIdentity))

    // Already-published sessions keep working through their own references.
    let firstContext = QueryContext(
        snapshotID: firstSession.snapshotID,
        analysisProfileID: firstSession.analysisProfile.id,
        generation: 1
    )
    let firstHits = try await firstSession.searchSymbols(
        query: "first_only",
        limit: 10,
        boost: SearchBoost(),
        context: firstContext
    )
    #expect(!firstHits.isEmpty)
    let secondContext = QueryContext(
        snapshotID: secondSession.snapshotID,
        analysisProfileID: secondSession.analysisProfile.id,
        generation: 2
    )
    let secondHits = try await secondSession.searchSymbols(
        query: "second_only",
        limit: 10,
        boost: SearchBoost(),
        context: secondContext
    )
    #expect(!secondHits.isEmpty)

    // Reopening the first project rebuilds through cache/capture as before.
    _ = try await indexWorktree(service, root: first)
    #expect(service.retainedContentIDsForDiagnostics.contains(firstIdentity))
}

@MainActor
@Test
func multiLanguageProjectBoundaryAlsoReplacesTheServiceStore() async throws {
    let first = try temporaryGitProject([
        "main.rs": "fn m1() {}\n",
        "lib.py": "def p1():\n    pass\n",
    ])
    let second = try temporaryGitProject([
        "main.rs": "fn m2() {}\n",
        "lib.py": "def p2():\n    pass\n",
    ])
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }
    let service = ProjectIndexService()
    let model = AppModel(indexService: service)
    await model.openProject(root: first).value
    #expect(await testWaitUntil("first multi ready") {
        model.snapshotPhase == .fullReady
    })
    let firstIdentity = ContentID.sha256(of: Array("fn m1() {}\n".utf8))
    #expect(service.retainedContentIDsForDiagnostics.contains(firstIdentity))

    await model.openProject(root: second).value
    #expect(await testWaitUntil("second multi ready") {
        model.snapshotPhase == .fullReady
            && model.projectRoot?.standardizedFileURL
                == second.standardizedFileURL
    })
    #expect(
        !service.retainedContentIDsForDiagnostics.contains(firstIdentity),
        "multi-language boundary must also drop the old project"
    )
}

@MainActor
@Test
func sameProjectRevisionsDoNotAccumulateInServiceStore() async throws {
    let root = try temporaryGitProject(["src/lib.rs": "pub fn revision_0() {}\n"])
    defer { try? FileManager.default.removeItem(at: root) }
    let service = ProjectIndexService()
    let original = try await indexWorktree(service, root: root)
    let originalID = ContentID.sha256(of: Array("pub fn revision_0() {}\n".utf8))
    for revision in 1...20 {
        let source = "pub fn revision_\(revision)() {}\n"
        try source.write(to: root.appendingPathComponent("src/lib.rs"), atomically: true, encoding: .utf8)
        let snapshot = try await service.captureSnapshot(root: root, revision: nil)
        let prepared = try await service.prepareSnapshots(snapshot, root: root, languages: [.rust])
        _ = try await service.completeSnapshot(prepared[0])
        #expect(!service.retainedContentIDsForDiagnostics.contains(originalID))
        #expect(service.retainedContentIDsForDiagnostics.count == 1)
    }
    let hits = try await original.searchSymbols(query: "revision_0", limit: 10, boost: SearchBoost(), context: QueryContext(snapshotID: original.snapshotID, analysisProfileID: original.analysisProfile.id, generation: 1))
    #expect(hits.count == 1)
}

/// P0 baseline (R2): before the type hop lands, the lens displays the very
/// symbol the user pointed at; navigation keeps acting on it. In P1 the two
/// concepts diverge for value bindings — this locks the pre-hop behavior.

// MARK: P1 — lens type hop

/// R1.1/R2: clicking a value binding shows its type in the window, while the
/// pointed-at symbol (and every "act on the symbol" entry point) stays the
/// binding itself.

/// R7.2: toggling the displayed side sticks and blocks later auto-switching.

/// Q3: a primitive-typed field does not hop; the lens stays on the
/// declaration with an explanatory note.

// MARK: P2 — exact typeDefinition in the lens

private final class ExactTypeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<ExactCoordinator.TypeDefinitionResult?, Never>] = []

    var suspendedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    func suspend() async -> ExactCoordinator.TypeDefinitionResult? {
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    /// Resumes callers in suspension order: the first gets `first`, the rest
    /// get `others`. Keeps stale-reply tests deterministic.
    func resumeFirst(
        _ first: ExactCoordinator.TypeDefinitionResult?,
        others: ExactCoordinator.TypeDefinitionResult?
    ) {
        lock.lock()
        let pending = continuations
        continuations = []
        lock.unlock()
        for (index, continuation) in pending.enumerated() {
            continuation.resume(returning: index == 0 ? first : others)
        }
    }

    func resumeAll(with result: ExactCoordinator.TypeDefinitionResult?) {
        lock.lock()
        let pending = continuations
        continuations = []
        lock.unlock()
        pending.forEach { $0.resume(returning: result) }
    }
}

private func exactTypeEntry(
    file: String, offset: UInt32
) -> ExactOverlay.Entry {
    ExactOverlay.Entry(
        location: ExactLocation(
            file: file,
            byteOffset: Int(offset),
            line: 1,
            column: 1
        ),
        attribution: ExactAttribution(
            provider: "fake-exact",
            toolVersion: "test",
            configFingerprint: "config",
            environmentFingerprint: "",
            environment: ExactAnalysisEnvironment(
                trustMode: .safe,
                limitations: []
            ),
            generatedAt: Date(timeIntervalSince1970: 0)
        ),
        origin: .worktree
    )
}

@MainActor
private func makeLensTypeHopModel(
    _ source: String,
    typeDefinitionResult: ExactCoordinator.TypeDefinitionResult?
) throws -> (ContextWindowModel, ExactTypeGate, URL) {
    let root = try temporaryProject(["main.rs": source])
    let session = try ProjectIndexer().index(root: root)
    let gate = ExactTypeGate()
    let model = ContextWindowModel(
        { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        },
        exactResolver: { _, _, _, _ in .completed([]) },
        typeHopResolver: { session, file, offset, context in
            let result = try session.typeHop(file: file, offset: offset, context: context)
            let spelling = try? session.bindingSpelling(
                file: file, offset: offset, context: context
            )
            return ContextWindowModel.TypeHopAnswer(
                result: result,
                viaText: spelling?.text,
                viaKind: spelling?.kind,
                boundNote: spelling?.boundNote
            )
        },
        typeDefinitionResolver: { _, _, _, _ in
            await gate.suspend()
        },
        typeDefinitionReadiness: { nil }
    )
    model.updateProjectState(.ready(session, queryContext(for: session)), root: root)
    return (model, gate, root)
}

/// R1.2 item 4: an inferred binding (`let made = make_s();`) parks the lens
/// in a pending type hop; the Exact reply promotes it to the type in place.
@MainActor
@Test
func lensPromotesInferredBindingWhenExactTypeArrives() async throws {
    let source = """
        pub struct S { pub n: u32 }
        fn make_s() -> S { S { n: 1 } }
        fn main() {
            let made = make_s();
            let _ = made;
        }
        """
    let (model, gate, root) = try makeLensTypeHopModel(
        source,
        typeDefinitionResult: .completed([
            exactTypeEntry(file: "main.rs", offset: byteOffset(of: "pub struct S", in: source) + 11)
        ])
    )
    defer { try? FileManager.default.removeItem(at: root) }
    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "let _ = made", in: source) + UInt32("let _ = ".utf8.count)
    )
    #expect(await testWaitUntil("model.activeTypeHop?.pendingExact == true") {
        model.activeTypeHop?.pendingExact == true
    })
    #expect(await testWaitUntil("typeDefinition requested") { gate.suspendedCount == 1 })
    gate.resumeAll(with: .completed([
        exactTypeEntry(file: "main.rs", offset: byteOffset(of: "pub struct S", in: source) + 11)
    ]))
    let sOffset = byteOffset(of: "pub struct S", in: source) + 11
    #expect(await testWaitUntil(
        "model.displayedCandidate?.targetByteOffset == \(sOffset)"
    ) {
        model.displayedCandidate?.targetByteOffset == sOffset
    })
}

/// 2026-10-03 (superseding M7-S0A): a click on a method call's receiver
/// points at the receiver — the lens shows its type and ⌘-click jumps to
/// its declaration; the method name still points at the method.

/// R1.1 (Python): clicking a class attribute (`h.repo`) shows its type
/// through the class-body declaration; the declaration is labelled a field
/// and carries no engine symbol, so relations never act on a wrong facet.
@MainActor
@Test
func lensShowsPythonAttributeTypeThroughTheReceiversClass() async throws {
    let models = """
        class Repository:
            pass

        class Holder:
            repo: Repository
        """
    let use = """
        from models import Holder

        def go(h: Holder):
            keep = h.repo
        """
    let root = try temporaryProject(["models.py": models, "use.py": use])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root, language: .python)
    let model = ContextWindowModel(
        { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        },
        typeHopResolver: { session, file, offset, context in
            let result = try session.typeHop(file: file, offset: offset, context: context)
            let spelling = try? session.bindingSpelling(file: file, offset: offset, context: context)
            return ContextWindowModel.TypeHopAnswer(
                result: result,
                viaText: spelling?.text,
                viaKind: spelling?.kind,
                boundNote: spelling?.boundNote
            )
        }
    )
    model.updateProjectState(.ready(session, queryContext(for: session)), root: root)

    model.tokenClicked(file: "use.py", offset: byteOffset(of: "h.repo", in: use) + 2)
    #expect(await testWaitUntil("type hop") { model.activeTypeHop != nil })
    let hop = try #require(model.activeTypeHop)
    #expect(hop.viaText == "repo: Repository")
    #expect(hop.viaKind == localized("model.typehop.field"))
    #expect(hop.via.bindingKind == localized("model.typehop.field"))
    #expect(hop.via.symbol == nil)
    #expect(model.displayedCandidate?.path == "models.py")
    #expect(model.displayedCandidate?.targetByteOffset
        == byteOffset(of: "class Repository", in: models) + 6)
}

/// R3.1: "跳到类型定义" on a binding the syntax gives no type for asks the
/// Exact layer, so an inferred binding still jumps to its type.
@MainActor
@Test
func typeDefinitionCommandFallsBackToExactForInferredBinding() async throws {
    let source = """
        pub struct S { pub n: u32 }
        fn make_s() -> S { S { n: 1 } }
        fn main() {
            let made = make_s();
            let _ = made;
        }
        """
    let sOffset = byteOffset(of: "pub struct S", in: source) + 11
    let (model, gate, root) = try makeLensTypeHopModel(source, typeDefinitionResult: nil)
    defer { try? FileManager.default.removeItem(at: root) }
    let use = byteOffset(of: "let _ = made", in: source) + UInt32("let _ = ".utf8.count)
    let jump = Task { await model.typeDefinitionTarget(file: "main.rs", offset: use) }
    #expect(await testWaitUntil("typeDefinition requested") { gate.suspendedCount == 1 })
    gate.resumeAll(with: .completed([exactTypeEntry(file: "main.rs", offset: sOffset)]))
    guard case let .target(target) = await jump.value else {
        Issue.record("inferred binding found no type target")
        return
    }
    #expect(target.targetByteOffset == sOffset)
}

/// R4.3 + R1.7 (native acceptance, 2026-10-03): a click that lands on no
/// symbol keeps the displayed type hop — and its in-flight Exact request,
/// so the hop still resolves instead of spinning forever.
@MainActor
@Test
func lensBlankClickKeepsThePendingTypeHopResolving() async throws {
    let source = """
        pub struct S { pub n: u32 }
        fn make_s() -> S { S { n: 1 } }
        fn main() {
            let made = make_s();
            let _ = made;

        }
        """
    let sOffset = byteOffset(of: "pub struct S", in: source) + 11
    let (model, gate, root) = try makeLensTypeHopModel(source, typeDefinitionResult: nil)
    defer { try? FileManager.default.removeItem(at: root) }
    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "let _ = made", in: source) + UInt32("let _ = ".utf8.count)
    )
    #expect(await testWaitUntil("typeDefinition requested") { gate.suspendedCount == 1 })
    // A click on the blank line below.
    model.tokenClicked(file: "main.rs", offset: byteOffset(of: "made;\n", in: source) + 7)
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.isShowingPreviousToken)
    gate.resumeAll(with: .completed([exactTypeEntry(file: "main.rs", offset: sOffset)]))
    #expect(await testWaitUntil("resolved to S") {
        model.displayedCandidate?.targetByteOffset == sOffset
    })
}

/// R4.3: the "keeping the previous" flag belongs to content on screen — a
/// later lookup that finds nothing clears it instead of leaving it over an
/// empty lens.
@MainActor
@Test
func lensEmptyResultClearsThePreviousTokenFlag() async throws {
    let source = """
        fn f(x: u32) {
            x.nothing();

        }
        """
    let log = ExactRequestLog()
    let (model, root) = try makeCaretLensModel(source, requestLog: log)
    defer { try? FileManager.default.removeItem(at: root) }
    // The blank line: nothing under the caret.
    model.tokenClicked(file: "main.rs", offset: byteOffset(of: "();\n", in: source) + 4)
    #expect(await testWaitUntil("miss flagged") { model.isShowingPreviousToken })
    // An unknown method name: located, but nothing resolves.
    model.tokenClicked(file: "main.rs", offset: byteOffset(of: "nothing", in: source))
    #expect(await testWaitUntil("flag cleared") { !model.isShowingPreviousToken })
    #expect(model.displayedCandidate == nil)
}

/// R1.7: when the Exact layer gives no answer at all (nil), the hop stops
/// "resolving" and shows "not ready" instead of spinning forever.
@MainActor
@Test
func lensStopsResolvingWhenExactGivesNoAnswer() async throws {
    let source = """
        pub struct S { pub n: u32 }
        fn make_s() -> S { S { n: 1 } }
        fn main() {
            let made = make_s();
            let _ = made;
        }
        """
    let (model, gate, root) = try makeLensTypeHopModel(source, typeDefinitionResult: nil)
    defer { try? FileManager.default.removeItem(at: root) }
    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "let _ = made", in: source) + UInt32("let _ = ".utf8.count)
    )
    #expect(await testWaitUntil("pending") { model.activeTypeHop?.pendingExact == true })
    #expect(await testWaitUntil("typeDefinition requested") { gate.suspendedCount == 1 })
    gate.resumeAll(with: nil)
    #expect(await testWaitUntil("no longer resolving") {
        model.activeTypeHop != nil && model.activeTypeHop?.pendingExact == false
    })
}

/// Q4: a manual declaration/type toggle before the Exact reply blocks the
/// auto-switch.
@MainActor
@Test
func lensKeepsDeclarationWhenUserToggledBeforeExactArrives() async throws {
    let source = """
        pub struct S { pub n: u32 }

        fn use_it(ps: &S) -> u32 {
            ps.n
        }
        """
    let (model, gate, root) = try makeLensTypeHopModel(
        source,
        typeDefinitionResult: .completed([
            exactTypeEntry(file: "main.rs", offset: byteOffset(of: "pub struct S", in: source) + 11)
        ])
    )
    defer { try? FileManager.default.removeItem(at: root) }
    model.tokenClicked(file: "main.rs", offset: byteOffset(of: "ps.n", in: source))
    #expect(await testWaitUntil("model.activeTypeHop != nil") { model.activeTypeHop != nil })
    // The user toggles to the declaration before the Exact reply arrives.
    model.showTypeHop(.declaration)
    #expect(await testWaitUntil("typeDefinition requested") { gate.suspendedCount == 1 })
    gate.resumeAll(with: .completed([
        exactTypeEntry(file: "main.rs", offset: byteOffset(of: "pub struct S", in: source) + 11)
    ]))
    try await Task.sleep(for: .milliseconds(120))
    let hop = try #require(model.activeTypeHop)
    #expect(hop.showing == .declaration)
    #expect(model.displayedCandidate?.targetByteOffset
        == model.symbolCandidate?.targetByteOffset)
}

/// The syntactic type target upgrades to Exact in place, keeping the
/// selection (P2.4).
@MainActor
@Test
func lensUpgradesSyntacticTypeTargetToExactInPlace() async throws {
    let source = """
        pub struct S { pub n: u32 }

        fn use_it(ps: &S) -> u32 {
            ps.n
        }
        """
    let (model, gate, root) = try makeLensTypeHopModel(
        source,
        typeDefinitionResult: .completed([
            exactTypeEntry(file: "main.rs", offset: byteOffset(of: "pub struct S", in: source) + 11)
        ])
    )
    defer { try? FileManager.default.removeItem(at: root) }
    model.tokenClicked(file: "main.rs", offset: byteOffset(of: "ps.n", in: source))
    #expect(await testWaitUntil("model.activeTypeHop != nil") { model.activeTypeHop != nil })
    let selectedBefore = model.selectedIndex
    #expect(await testWaitUntil("typeDefinition requested") { gate.suspendedCount == 1 })
    gate.resumeAll(with: .completed([
        exactTypeEntry(file: "main.rs", offset: byteOffset(of: "pub struct S", in: source) + 11)
    ]))
    #expect(await testWaitUntil("model.displayedCandidate?.certainty == .exact") {
        model.displayedCandidate?.certainty == .exact
    })
    #expect(model.selectedIndex == selectedBefore)
    #expect(model.activeTypeHop?.targets.count == 1)
}

/// Q3: primitive-typed bindings never fire a typeDefinition request.
@MainActor
@Test
func lensSkipsTypeDefinitionForPrimitiveTypeRef() async throws {
    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
    let requests = RequestLog()
    let source = """
        pub struct S { pub n: u32 }
        impl S {
            fn get(&self) -> u32 {
                self.n
            }
        }
        """
    let root = try temporaryProject(["main.rs": source])
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try ProjectIndexer().index(root: root)
    let model = ContextWindowModel(
        { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        },
        exactResolver: { _, _, _, _ in .completed([]) },
        typeHopResolver: { session, file, offset, context in
            let result = try session.typeHop(file: file, offset: offset, context: context)
            return ContextWindowModel.TypeHopAnswer(result: result, viaText: nil, viaKind: nil, boundNote: nil)
        },
        typeDefinitionResolver: { _, _, _, _ in
            requests.increment()
            return .completed([])
        },
        typeDefinitionReadiness: { nil }
    )
    model.updateProjectState(.ready(session, queryContext(for: session)), root: root)

    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "self.n", in: source) + UInt32("self.".utf8.count)
    )
    #expect(await testWaitUntil("model.displayedCandidate != nil") {
        model.displayedCandidate != nil
    })
    try await Task.sleep(for: .milliseconds(120))
    #expect(requests.value == 0)
}

/// A stale typeDefinition reply (a newer click already changed the token)
/// is dropped (P2.4). The gate hands the S entry to the FIRST suspended
/// request (the retired click) and cancels the second, so a missing
/// request-id check would land the stale entry on the newest stage.
@MainActor
@Test
func lensDropsStaleTypeDefinitionReply() async throws {
    let source = """
        pub struct S { pub n: u32 }

        fn use_it(ps: &S) -> u32 {
            let local = 1;
            ps.n + local
        }
        """
    let (model, gate, root) = try makeLensTypeHopModel(
        source,
        typeDefinitionResult: .completed([
            exactTypeEntry(file: "main.rs", offset: byteOffset(of: "pub struct S", in: source) + 11)
        ])
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let sOffset = byteOffset(of: "pub struct S", in: source) + 11

    // Click 1 on `ps.n` — its upgrade request suspends at the gate first.
    model.tokenClicked(file: "main.rs", offset: byteOffset(of: "ps.n", in: source))
    #expect(await testWaitUntil("model.activeTypeHop != nil") { model.activeTypeHop != nil })
    #expect(await testWaitUntil("gate.suspendedCount == 1") { gate.suspendedCount >= 1 })

    // Click 2 retires that request; its own request suspends second.
    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "ps.n + local", in: source)
            + UInt32("ps.n + ".utf8.count)
    )
    #expect(await testWaitUntil("model.activeTypeHop?.pendingExact == true") {
        model.activeTypeHop?.pendingExact == true
    })
    #expect(await testWaitUntil("gate.suspendedCount == 2") { gate.suspendedCount >= 2 })

    // First (stale) request receives the S entry; the newest is cancelled.
    gate.resumeFirst(
        .completed([exactTypeEntry(file: "main.rs", offset: sOffset)]),
        others: .cancelled
    )
    #expect(await testWaitUntil(
        "model.activeTypeHop?.pendingExact == false"
    ) {
        model.activeTypeHop?.pendingExact == false
    })
    // The lens still shows the newest click's declaration, not the stale S.
    #expect(model.displayedCandidate?.targetByteOffset != sOffset)
}

// MARK: P3 — caret follow, dwell, enclosing mode, pin

private final class ExactRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var offsets: [UInt32] = []
    func append(_ offset: UInt32) {
        lock.lock()
        offsets.append(offset)
        lock.unlock()
    }
    var recorded: [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return offsets
    }
}

@MainActor
private func makeCaretLensModel(
    _ source: String,
    requestLog: ExactRequestLog
) throws -> (ContextWindowModel, URL) {
    let root = try temporaryProject(["main.rs": source])
    let session = try ProjectIndexer().index(root: root)
    let model = ContextWindowModel(
        { session, file, offset, context in
            try session.resolve(file: file, offset: offset, context: context)
        },
        exactResolver: { _, offset, _, _ in
            requestLog.append(offset)
            return .completed([])
        },
        typeHopResolver: { session, file, offset, context in
            let result = try session.typeHop(file: file, offset: offset, context: context)
            return ContextWindowModel.TypeHopAnswer(
                result: result, viaText: nil, viaKind: nil, boundNote: nil
            )
        },
        typeDefinitionResolver: nil,
        typeDefinitionReadiness: { nil }
    )
    model.exactDwell = .milliseconds(250)
    model.updateProjectState(.ready(session, queryContext(for: session)), root: root)
    return (model, root)
}

/// R4.2: a caret trigger sends no exact request before the dwell elapses,
/// then sends it once.
@MainActor
@Test
func caretTriggerDelaysExactUntilDwell() async throws {
    let source = """
        fn alpha() {}
        fn main() {
            alpha();
        }
        """
    let log = ExactRequestLog()
    let (model, root) = try makeCaretLensModel(source, requestLog: log)
    defer { try? FileManager.default.removeItem(at: root) }

    model.tokenClicked(
        file: "main.rs",
        offset: byteOffset(of: "alpha();", in: source),
        trigger: .caret
    )
    try await Task.sleep(for: .milliseconds(80))
    #expect(log.recorded.isEmpty)

    #expect(await testWaitUntil("exact request sent after the dwell") {
        !log.recorded.isEmpty
    })
    try await Task.sleep(for: .milliseconds(100))
    #expect(log.recorded == [byteOffset(of: "alpha();", in: source)])
}

/// R4.2: leaving the token before the dwell cancels the pending request.
@MainActor
@Test
func caretLeavingTokenCancelsPendingExact() async throws {
    let source = """
        fn alpha() {}
        fn beta() {}
        fn main() {
            alpha();
            beta();
        }
        """
    let log = ExactRequestLog()
    let (model, root) = try makeCaretLensModel(source, requestLog: log)
    defer { try? FileManager.default.removeItem(at: root) }

    let alphaUse = byteOffset(of: "alpha();", in: source)
    let betaUse = byteOffset(of: "beta();", in: source)
    model.tokenClicked(file: "main.rs", offset: alphaUse, trigger: .caret)
    try await Task.sleep(for: .milliseconds(80))
    // The caret moves on before alpha's dwell elapses.
    model.tokenClicked(file: "main.rs", offset: betaUse, trigger: .caret)
    try await Task.sleep(for: .milliseconds(700))

    // alpha's pending request never fired; only beta's did.
    #expect(log.recorded == [betaUse])
}

/// A click schedules the exact request immediately; the caret event on the
/// same token does not schedule a second one (locatedToken dedup).
@MainActor
@Test
func clickDoesNotDoubleScheduleCaretExact() async throws {
    let source = """
        fn alpha() {}
        fn main() {
            alpha();
        }
        """
    let log = ExactRequestLog()
    let (model, root) = try makeCaretLensModel(source, requestLog: log)
    defer { try? FileManager.default.removeItem(at: root) }

    let use = byteOffset(of: "alpha();", in: source)
    model.tokenClicked(file: "main.rs", offset: use, trigger: .click)
    #expect(await testWaitUntil("log.recorded.count == 1") { log.recorded.count == 1 })

    // The caret event the same click produces arrives later on the same token.
    model.tokenClicked(file: "main.rs", offset: use, trigger: .caret)
    try await Task.sleep(for: .milliseconds(500))
    #expect(log.recorded.count == 1)
}

/// R4.3/T4: the caret onto whitespace keeps the previous content and flags it.
@MainActor
@Test
func lensKeepsPreviousContentWhenCaretLeavesSymbols() async throws {
    let source = """
        fn alpha() {}
        fn main() {
            alpha();
        }
        """
    let log = ExactRequestLog()
    let (model, root) = try makeCaretLensModel(source, requestLog: log)
    defer { try? FileManager.default.removeItem(at: root) }

    model.tokenClicked(file: "main.rs", offset: byteOffset(of: "alpha();", in: source))
    #expect(await testWaitUntil("model.symbolCandidate != nil") {
        model.symbolCandidate != nil
    })
    let stageBefore = model.stage
    // The caret moves to the blank line before `fn main`.
    let blank = byteOffset(of: "fn main() {", in: source) - 2
    model.tokenClicked(file: "main.rs", offset: blank, trigger: .caret)
    try await Task.sleep(for: .milliseconds(80))

    if case .candidates = stageBefore {} else if case .typeHop = stageBefore {} else {
        Issue.record("unexpected pre-stage")
    }
    #expect(model.isShowingPreviousToken)
    // The previous candidate content survives.
    #expect(model.displayedCandidate != nil)
    // A later hit clears the flag.
    model.tokenClicked(
        file: "main.rs", offset: byteOffset(of: "fn main() {", in: source) + 4
    )
    #expect(await testWaitUntil("model.isShowingPreviousToken == false") {
        !model.isShowingPreviousToken
    })
}
