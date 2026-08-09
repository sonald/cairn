import CodeInsightAppModel
import CodeInsightCore
import CodeInsightEngine
import Foundation
import Testing

@MainActor
@Test
func readingSetWorktreeActionsUseCapturedGenerationAndPreserveTheSetTab() async throws {
    let source = "fn before() {}\nfn target() {}\n"
    let root = try readingSetTemporaryProject(source: source)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: ReadingSetIndexService())
    model.openProject(root: root)
    #expect(await testWaitUntil("Reading Set project ready") {
        if case .ready = model.projectState { return true }
        return false
    })
    let bytes = Array(source.utf8)
    let target = try #require(LineTable(bytes: bytes).byteOffset(line: 2, column: 4))
    let frozen = try #require(frozenReadingSetSource(
        bytes: bytes,
        targetByte: target
    ))
    let excerpt = readingSetTestExcerpt(
        source: source,
        line: 2,
        column: 4,
        frozen: frozen
    )
    model.openReadingSet(title: "target", excerpts: [excerpt])

    try "fn drifted() {}\n".write(
        to: root.appendingPathComponent("src/lib.rs"),
        atomically: true,
        encoding: .utf8
    )
    let captured = try #require(model.readingSetSources(for: [excerpt]).first ?? nil)
    #expect(captured == bytes)
    model.openReadingSetExcerpt(excerpt)

    #expect(model.tabStrip.tabs.count == 2)
    #expect(model.tabStrip.activeTab?.fileURL == root.appendingPathComponent("src/lib.rs"))
    #expect(model.tabStrip.activeTab?.selectionByteOffset == target)
    model.activateTab(0)
    guard case .readingSet(_, let restored) = model.tabStrip.activeTab?.content else {
        Issue.record("Expected the original Reading Set tab")
        return
    }
    #expect(restored[0].sourceText == excerpt.sourceText)
}

@MainActor
@Test
func readingSetCommitOpenInstallsTheCapturedRevisionInANewFileTab() async throws {
    let oldSource = "fn before() {}\nfn target() {}\n"
    let newSource = "fn current() {}\n"
    let root = try readingSetTemporaryProject(source: oldSource)
    defer { try? FileManager.default.removeItem(at: root) }
    try readingSetGit(root, "init", "-q")
    try readingSetGit(root, "add", "src/lib.rs")
    try readingSetGit(
        root,
        "-c", "user.name=CodeInsight",
        "-c", "user.email=codeinsight@example.com",
        "commit", "-q", "-m", "old"
    )
    let oldRevision = try readingSetGit(root, "rev-parse", "HEAD")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try newSource.write(
        to: root.appendingPathComponent("src/lib.rs"),
        atomically: true,
        encoding: .utf8
    )
    try readingSetGit(root, "add", "src/lib.rs")
    try readingSetGit(
        root,
        "-c", "user.name=CodeInsight",
        "-c", "user.email=codeinsight@example.com",
        "commit", "-q", "-m", "current"
    )

    let model = AppModel(indexService: ProjectIndexService())
    model.openProject(root: root)
    #expect(await testWaitUntil("current commit worktree ready") {
        model.snapshotPhase == .fullReady
    })
    let bytes = Array(oldSource.utf8)
    let target = try #require(LineTable(bytes: bytes).byteOffset(line: 2, column: 4))
    let frozen = try #require(frozenReadingSetSource(
        bytes: bytes,
        targetByte: target
    ))
    let base = readingSetTestExcerpt(
        source: oldSource,
        line: 2,
        column: 4,
        frozen: frozen
    )
    let excerpt = ReadingSetExcerpt(
        role: base.role,
        symbol: base.symbol,
        path: base.path,
        line: base.line,
        column: base.column,
        firstLine: base.firstLine,
        byteRange: base.byteRange,
        sourceText: base.sourceText,
        contentID: base.contentID,
        revision: oldRevision,
        capturedAt: base.capturedAt,
        sourceKind: .projectCommit,
        inspector: base.inspector,
        caveat: base.caveat,
        partialLine: base.partialLine
    )
    model.openReadingSet(title: "target", excerpts: [excerpt])
    let captured = try #require(model.readingSetSources(for: [excerpt]).first ?? nil)
    #expect(captured == bytes)

    model.openReadingSetExcerpt(excerpt)
    #expect(await testWaitUntil("captured commit opened") {
        model.currentRevision == oldRevision
            && model.snapshotPhase == .fullReady
            && model.tabStrip.activeTab?.fileURL
                == root.appendingPathComponent("src/lib.rs")
    })
    #expect(model.tabStrip.tabs.count == 2)
    #expect(model.tabStrip.activeTab?.selectionByteOffset == target)
    #expect(model.tabStrip.tabs.contains {
        if case .readingSet = $0.content { return true }
        return false
    })
}

@MainActor
@Test
func readingSetDependencyExpansionRequiresTheCapturedAbsoluteFile() throws {
    let source = (1...100).map { "dependency line \($0)\n" }.joined()
    let root = try readingSetTemporaryProject(source: source)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("src/lib.rs")
    let bytes = Array(source.utf8)
    let target = try #require(LineTable(bytes: bytes).byteOffset(line: 50, column: 3))
    let frozen = try #require(frozenReadingSetSource(
        bytes: bytes,
        targetByte: target
    ))
    let base = readingSetTestExcerpt(
        source: source,
        line: 50,
        column: 3,
        frozen: frozen
    )
    let excerpt = ReadingSetExcerpt(
        role: base.role,
        symbol: base.symbol,
        path: file.path,
        line: base.line,
        column: base.column,
        firstLine: base.firstLine,
        byteRange: base.byteRange,
        sourceText: base.sourceText,
        contentID: base.contentID,
        revision: nil,
        capturedAt: base.capturedAt,
        sourceKind: .dependencyCaptured,
        inspector: base.inspector,
        partialLine: base.partialLine
    )
    let model = AppModel()
    let captured = try #require(model.readingSetSources(for: [excerpt]).first ?? nil)
    #expect(expandedReadingSetExcerpt(excerpt, bytes: captured) != nil)

    try "dependency drift\n".write(
        to: file,
        atomically: true,
        encoding: .utf8
    )
    #expect(model.readingSetSources(for: [excerpt]).first! == nil)
}

@Test
func readingSetCaptureKeepsTargetAtFileEdgesAndWithinFrozenCaps() throws {
    let source = (1...120).map { "line \($0)\n" }.joined()
    let bytes = Array(source.utf8)
    let table = LineTable(bytes: bytes)
    let first = try #require(frozenReadingSetSource(
        bytes: bytes,
        targetByte: 0
    ))
    let lastOffset = try #require(table.byteOffset(line: 120, column: 1))
    let last = try #require(frozenReadingSetSource(
        bytes: bytes,
        targetByte: lastOffset
    ))

    #expect(first.firstLine == 1)
    #expect(!first.sourceText.hasPrefix("…"))
    #expect(first.byteRange.contains(0))
    #expect(last.firstLine == 100)
    #expect(!last.sourceText.hasSuffix("…"))
    #expect(last.byteRange.contains(lastOffset))
    #expect(first.sourceText.utf8.count <= 8 * 1_024)
    #expect(last.sourceText.utf8.count <= 8 * 1_024)
}

@Test
func readingSetLongFacetExpandsAroundTargetWithoutBreakingLines() throws {
    let source = (1...300).map {
        String(repeating: "x", count: 96) + " line \($0)\n"
    }.joined()
    let bytes = Array(source.utf8)
    let table = LineTable(bytes: bytes)
    let target = try #require(table.byteOffset(line: 150, column: 30))
    let captured = try #require(frozenReadingSetSource(
        bytes: bytes,
        targetByte: target,
        enclosingRange: ByteRange(
            lowerBound: 0,
            upperBound: UInt32(bytes.count)
        )
    ))
    let excerpt = readingSetTestExcerpt(
        source: source,
        line: 150,
        column: 30,
        frozen: captured
    )
    let expanded = try #require(expandedReadingSetExcerpt(excerpt, bytes: bytes))

    #expect(captured.byteRange.contains(target))
    #expect(captured.sourceText.hasPrefix("…\n"))
    #expect(captured.sourceText.hasSuffix("…"))
    #expect(captured.sourceText.utf8.count <= 8 * 1_024)
    #expect(!captured.partialLine)
    #expect(expanded.byteRange.contains(target))
    #expect(expanded.byteRange.length > captured.byteRange.length)
    #expect(expanded.sourceText.utf8.count <= 16 * 1_024)
    #expect(expanded.sourceText.split(separator: "\n").count <= 202)
    #expect(String(
        bytes: bytes[Int(expanded.byteRange.lowerBound)..<Int(expanded.byteRange.upperBound)],
        encoding: .utf8
    ) != nil)
}

@Test
@MainActor
func readingSetLongMultibyteLineUsesScalarSafePersistentSlices() throws {
    let source = String(repeating: "界", count: 7_000)
    let bytes = Array(source.utf8)
    let target = UInt32(3 * 3_500)
    let coordinate = try #require(LineTable(bytes: bytes).lineColumn(at: target))
    let captured = try #require(frozenReadingSetSource(
        bytes: bytes,
        targetByte: target,
        enclosingRange: ByteRange(
            lowerBound: 0,
            upperBound: UInt32(bytes.count)
        )
    ))
    let excerpt = readingSetTestExcerpt(
        source: source,
        line: coordinate.line,
        column: coordinate.column,
        frozen: captured
    )
    let expanded = try #require(expandedReadingSetExcerpt(excerpt, bytes: bytes))

    #expect(captured.partialLine)
    #expect(captured.byteRange.contains(target))
    #expect(captured.sourceText.hasPrefix("…"))
    #expect(captured.sourceText.hasSuffix("…"))
    #expect(captured.sourceText.utf8.count <= 8 * 1_024)
    #expect(expanded.partialLine)
    #expect(expanded.byteRange.contains(target))
    #expect(expanded.byteRange.length > captured.byteRange.length)
    #expect(expanded.sourceText.utf8.count <= 16 * 1_024)
    #expect(String(
        bytes: bytes[Int(expanded.byteRange.lowerBound)..<Int(expanded.byteRange.upperBound)],
        encoding: .utf8
    ) != nil)
    #expect(expandedReadingSetExcerpt(excerpt, bytes: Array("drift".utf8)) == nil)

    let tabs = TabStripModel()
    tabs.openReadingSet(title: "multibyte", excerpts: [excerpt])
    tabs.updateActiveReadingSetExcerpt(at: 0, to: expanded)
    guard case .readingSet(_, let persisted) = tabs.activeTab?.content else {
        Issue.record("Expected a Reading Set tab")
        return
    }
    #expect(persisted[0].sourceText == expanded.sourceText)
    #expect(persisted[0].byteRange == expanded.byteRange)
    #expect(persisted[0].partialLine)
}

@MainActor
@Test
func trailReadingSetKeepsFiveObservedEdgesInPathOrderAndSkipsOldWorktree()
    async throws
{
    let symbols = ["definition", "verified", "inferred", "contract", "test"]
    let roles = [
        "DEFINITION",
        "VERIFIED CALLER",
        "INFERRED CALLER",
        "TRAIT CONTRACT",
        "TEST",
    ]
    let source = symbols.map { "fn \($0)() {}" }.joined(separator: "\n") + "\n"
    let root = try readingSetTemporaryProject(source: source)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(indexService: ReadingSetIndexService())
    model.openProject(root: root)
    #expect(await testWaitUntil("Trail Reading Set project ready") {
        if case .ready = model.projectState { return true }
        return false
    })
    let captured = try #require(model.capturedProjectSource(at: "src/lib.rs"))
    let snapshotID = try #require(model.currentSnapshotID)
    let table = LineTable(bytes: captured.bytes)
    var previous = JumpRecord(
        path: "src/lib.rs",
        contentID: captured.contentID,
        byteOffset: 0,
        line: 1,
        column: 1,
        symbolAnchor: "root",
        snapshotID: snapshotID
    )
    var selectedID: TrailNodeID?
    for (index, symbol) in symbols.enumerated() {
        let range = try #require(source.range(of: "fn \(symbol)"))
        let byteOffset = UInt32(source[..<range.lowerBound].utf8.count)
        let coordinate = try #require(table.lineColumn(at: byteOffset))
        let destination = JumpRecord(
            path: "src/lib.rs",
            contentID: captured.contentID,
            byteOffset: byteOffset,
            line: coordinate.line,
            column: coordinate.column,
            symbolAnchor: symbol,
            snapshotID: snapshotID
        )
        let display = readingSetInspector(
            symbol: symbol,
            badge: index == 2 ? .inferred : .verified
        )
        selectedID = model.readingTrail.recordNavigation(
            from: previous,
            to: destination,
            explanation: NavigationExplanation(
                explanationID: ResolutionExplanationID(),
                observedAtNavigation: readingSetExplanationSnapshot(),
                frozenInspectorDisplay: display,
                readingSetRole: roles[index]
            )
        )
        previous = destination
    }
    try "fn disk_drift() {}\n".write(
        to: root.appendingPathComponent("src/lib.rs"),
        atomically: true,
        encoding: .utf8
    )

    let frozen = model.trailReadingSet(to: try #require(selectedID))
    #expect(frozen.title == "test")
    #expect(frozen.excerpts.map(\.role) == roles)
    #expect(frozen.excerpts.map(\.symbol) == symbols)
    #expect(frozen.excerpts.allSatisfy { !$0.sourceText.contains("disk_drift") })
    #expect(frozen.skippedReasons.isEmpty)

    let oldDestination = JumpRecord(
        path: "src/lib.rs",
        contentID: captured.contentID,
        byteOffset: previous.byteOffset,
        line: previous.line,
        column: previous.column,
        symbolAnchor: "old",
        snapshotID: SnapshotID(rawValue: UUID())
    )
    let oldID = model.readingTrail.recordNavigation(
        from: previous,
        to: oldDestination,
        explanation: NavigationExplanation(
            explanationID: ResolutionExplanationID(),
            observedAtNavigation: readingSetExplanationSnapshot(),
            frozenInspectorDisplay: readingSetInspector(symbol: "old"),
            readingSetRole: "OLD WORKTREE"
        )
    )
    let withOldWorktree = model.trailReadingSet(to: oldID)
    #expect(withOldWorktree.excerpts.map(\.role) == roles)
    #expect(withOldWorktree.skippedReasons == [
        "recorded worktree snapshot is unavailable",
    ])
}

private func readingSetTestExcerpt(
    source: String,
    line: UInt32,
    column: UInt32,
    frozen: (
        byteRange: ByteRange,
        sourceText: String,
        firstLine: UInt32,
        partialLine: Bool
    )
) -> ReadingSetExcerpt {
    let bytes = Array(source.utf8)
    let capturedAt = Date(timeIntervalSince1970: 1_786_200_000)
    return ReadingSetExcerpt(
        role: "Definition",
        symbol: "target",
        path: "src/lib.rs",
        line: line,
        column: column,
        firstLine: frozen.firstLine,
        byteRange: frozen.byteRange,
        sourceText: frozen.sourceText,
        contentID: .sha256(of: bytes),
        revision: nil,
        capturedAt: capturedAt,
        sourceKind: .worktreeCaptured,
        inspector: readingSetInspector(symbol: "target", capturedAt: capturedAt),
        partialLine: frozen.partialLine
    )
}

private func readingSetInspector(
    symbol: String,
    badge: ReadingSetExcerpt.FrozenInspectorDisplay.Badge = .verified,
    capturedAt: Date = Date(timeIntervalSince1970: 1_786_200_000)
) -> ReadingSetExcerpt.FrozenInspectorDisplay {
    .init(
        nodeTitle: symbol,
        badge: badge,
        why: "Captured target.",
        sourceBody: "Captured source.",
        verificationTitle: "VERIFICATION",
        verificationBody: "Verified at capture.",
        correctionBody: "",
        availabilityBody: "Ready at capture.",
        environmentBody: "Trusted at capture.",
        auditRows: [],
        accessibilityValue: "Verified target",
        capturedAt: capturedAt,
        formerCandidateAvailable: false
    )
}

private func readingSetExplanationSnapshot() -> ResolutionExplanationSnapshot {
    let candidate = CandidateObservation(
        target: .unresolved(UnresolvedSymbolRef(
            nameID: NameID(rawValue: 1),
            hintKind: .unqualified
        )),
        certainty: .strong,
        dispatch: .direct,
        provenance: .fuzzyResolver,
        completeness: .complete,
        evidence: [.nameOnly(nameID: NameID(rawValue: 1))]
    )
    return ResolutionExplanationSnapshot(
        explanation: MaterializedResolutionExplanation(
            trace: .candidateOnly(candidate)
        )
    )
}

private struct ReadingSetIndexService: IndexService {
    func index(root: URL) async throws -> EngineSession {
        try ProjectIndexer().index(root: root)
    }
}

private func readingSetTemporaryProject(source: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReadingSetTests-\(UUID().uuidString)")
    let file = root.appendingPathComponent("src/lib.rs")
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try source.write(to: file, atomically: true, encoding: .utf8)
    return root
}

@discardableResult
private func readingSetGit(
    _ root: URL,
    _ arguments: String...
) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileReadUnknown, userInfo: [
            NSLocalizedDescriptionKey: String(
                data: error.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "git failed",
        ])
    }
    return String(
        data: output.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
}
