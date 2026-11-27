import AppKit
import CodeInsightAI
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightApp

/// Overview lays a Rust or Python file's skeleton over the source reader.
/// Every position that leaves the reader must still be a source position,
/// and a late skeleton must never land on another file.
@MainActor
@Suite(.serialized)
struct ReaderSkeletonTests {
    @Test(.timeLimit(.minutes(2)))
    func overviewSkeletonKeepsSourcePositionsAcrossLevelsFocusAndFiles() async throws {
        let file = URL(fileURLWithPath: "/skeleton.rs")
        let source = skeletonSource(helpers: 80, prefix: "helper")
        let bytes = Array(source.utf8)
        let sourceLines = source.components(separatedBy: "\n")
        let lineStarts = LineTable(bytes: bytes).lineStarts
        let skeleton = try #require(distillSkeleton(bytes: bytes, language: .rust))
        let map = SkeletonLineMap(skeleton)
        func header(_ name: String) throws -> Int {
            try #require(sourceLines.firstIndex { $0.hasPrefix("fn \(name)(") }) + 1
        }

        let controller = ReaderViewController()
        controller.display(file, source: { _ in bytes })
        let window = makeWindow(controller)
        defer { window.close() }

        // Overview: a regular file's skeleton is there in the same turn (no
        // blank frame), numbered only on rows that stand for source.
        controller.setReadingHeightLevel(.overview)
        let shown = try #require(controller.selfTestSkeleton)
        #expect(shown.text == skeleton.map(\.text).joined(separator: "\n"))
        let blank = try #require(skeleton.firstIndex { $0.sourceLines == nil }) + 1
        #expect((1..<blank).allSatisfy(shown.numberedLines.contains))
        #expect(!shown.numberedLines.contains(blank))
        #expect(shown.numberedLines.allSatisfy { map.label(ofRow: $0 - 1) != nil })
        #expect(controller.readingHeightLevel == .overview)

        // The caret is on the skeleton, so caret-driven source commands are off.
        #expect(controller.currentSelectionByteOffset == nil)
        #expect(controller.aiAskTarget() == nil)
        #expect(controller.hoverRequestAtSelection() == nil)
        #expect(controller.identifierAtCaret == nil)

        // Navigating into the file lands on the row standing for the target;
        // the recorded position is that row's source line.
        let helper = try header("helper_20")
        controller.navigate(to: file, byteOffset: lineStarts[helper])
        let position = try #require(controller.currentReadingPosition())
        #expect(Int(position.line) == helper)
        #expect(position.byteOffset == lineStarts[helper - 1])
        #expect(position.contentID == ContentID.sha256(of: bytes))

        // Leaving lands Full on the top row's source line; entering comes back.
        controller.setReadingHeightLevel(.full)
        #expect(!controller.isShowingSkeleton)
        #expect(controller.currentReadingPosition().map { Int($0.line) } == helper)
        controller.setReadingHeightLevel(.overview)
        #expect(controller.isShowingSkeleton)
        #expect(controller.currentReadingPosition().map { Int($0.line) } == helper)

        // Under the scope header: entering takes Full's first line visible
        // below it, which lands on top of the skeleton.
        controller.setReadingHeightLevel(.full)
        // The covered line ends helper_30, so the first visible one starts a later row.
        let covered = try header("helper_30") + 3
        controller.restoreReadingPosition(
            scrollByteOffset: lineStarts[covered - 1], selectionByteOffset: lineStarts[covered - 2]
        )
        #expect(await waitUntil { controller.selfTestSourceTop.atTop == covered })
        let full = controller.selfTestSourceTop
        #expect(full.headerShown && full.atTop == covered, "\(full) covered \(covered)")
        let visible = try #require(full.belowHeader)
        #expect(visible > covered)
        controller.setReadingHeightLevel(.overview)
        let landed = try #require(map.row(forSourceLine: visible))
        #expect(landed != map.row(forSourceLine: covered))
        #expect(controller.currentReadingPosition().map { Int($0.line) } == map.label(ofRow: landed))
        let skeletonTop = try #require(map.label(ofRow: landed))
        // Leaving without scrolling the skeleton goes back exactly: the
        // covered line on top again, not the skeleton's top line.
        controller.setReadingHeightLevel(.full)
        let unscrolled = controller.selfTestSourceTop
        #expect(unscrolled.atTop == covered && unscrolled.belowHeader == visible, "\(unscrolled)")
        // After scrolling the skeleton, leaving puts its top line below the header.
        controller.setReadingHeightLevel(.overview)
        #expect(controller.currentReadingPosition().map { Int($0.line) } == skeletonTop)
        controller.selfTestScrollSkeleton(toRow: landed + 1)
        let scrolledTop = try #require(map.label(ofRow: landed + 1))
        #expect(controller.currentReadingPosition().map { Int($0.line) } == scrolledTop)
        controller.setReadingHeightLevel(.full)
        let back = controller.selfTestSourceTop
        #expect(back.headerShown && back.belowHeader == scrolledTop, "\(back) top \(scrolledTop)")
        #expect((back.atTop ?? .max) < scrolledTop)
        // A top edge under the header by a point or two still reads as visible.
        controller.selfTestScrollSource(toLine: covered, topInset: 26 - 1.5)
        #expect(controller.selfTestSourceTop.belowHeader == covered)
        controller.selfTestScrollSource(toLine: covered, topInset: 26 - 6)
        #expect(controller.selfTestSourceTop.belowHeader == covered + 1)
        controller.setReadingHeightLevel(.overview)

        // Focus from the skeleton takes the caret row's scope and keeps the
        // level; leaving focus comes back to the skeleton.
        #expect(controller.toggleFocusCurrentScope())
        #expect(controller.isFocusMode && !controller.isShowingSkeleton)
        #expect(controller.readingHeightLevel == .overview)
        #expect(controller.toggleFocusCurrentScope())
        #expect(!controller.isFocusMode && controller.isShowingSkeleton)

        // The context menu: Copy (only with a selection) and View This Line
        // in Full (not on a blank row), which acts like the line's number.
        let step = try header("step")
        let stepRow = try #require(skeleton.firstIndex { $0.sourceLines?.lowerBound == step })
        let openTitle = localized("main.overview.open.line")
        let blankMenu = controller.selfTestSkeletonContextMenu(line: blank)
        #expect(blankMenu.map(\.title) == [localized("app.menu.copy"), openTitle])
        #expect(blankMenu.map(\.enabled) == [false, false])
        #expect(controller.selfTestSkeletonContextMenu(line: stepRow + 1).map(\.enabled) == [false, true])
        controller.selfTestChooseSkeletonContextItem(1)
        // A navigation: Full, caret on the line, which is not hidden at the top
        // under the scope header.
        #expect(controller.readingHeightLevel == .full && !controller.isShowingSkeleton)
        #expect(controller.currentSelectionByteOffset == lineStarts[step - 1])
        #expect(try #require(controller.currentReadingPosition()).line < step)

        // A gutter number does the same.
        controller.setReadingHeightLevel(.overview)
        let helperRow = try #require(skeleton.firstIndex { $0.sourceLines?.lowerBound == helper })
        controller.selfTestClickSkeletonGutter(line: helperRow + 1)
        #expect(controller.readingHeightLevel == .full && !controller.isShowingSkeleton)
        #expect(controller.currentSelectionByteOffset == lineStarts[helper - 1])
        #expect(try #require(controller.currentReadingPosition()).line < helper)

        // Find searches the source: from the skeleton it leaves to Full on the
        // same line, then opens the find bar.
        controller.setReadingHeightLevel(.overview)
        let top = try #require(controller.currentReadingPosition()).line
        #expect(controller.showFindBar())
        #expect(controller.readingHeightLevel == .full && !controller.isShowingSkeleton)
        #expect(controller.isFindBarVisible)
        #expect(controller.selfTestSourceTop.belowHeader == Int(top))
        controller.closeFindBar()

        // Leaving a skeleton that was not scrolled goes back to the place
        // Overview was entered from, even where no row stands for the top
        // line: the middle of an omitted statement, a leading comment.
        let omitted = try #require(sourceLines.firstIndex { $0.contains("println!") }) + 1
        #expect(map.ranges.allSatisfy { $0?.contains(omitted) != true })
        controller.restoreReadingPosition(scrollByteOffset: nil, selectionByteOffset: lineStarts[covered - 2])
        #expect(await waitUntil { controller.selfTestSourceTop.headerShown })
        controller.selfTestScrollSource(toLine: omitted, topInset: 26 + 7)
        let before = controller.selfTestSourceTop
        #expect(before.belowHeader == omitted && (before.intoLine ?? 0) > 1, "\(before)")
        controller.setReadingHeightLevel(.overview)
        #expect(controller.currentReadingPosition().map { Int($0.line) } != omitted)
        controller.setReadingHeightLevel(.full)
        let after = controller.selfTestSourceTop
        #expect(after.atTop == before.atTop && after.belowHeader == omitted, "\(after) vs \(before)")
        #expect(abs((after.intoLine ?? -9) - (before.intoLine ?? 0)) < 0.5, "\(after) vs \(before)")

        // Another file does not take the place remembered for this one, even
        // when its skeleton's top row has the same line number (2 here).
        controller.selfTestScrollSource(toLine: 2, topInset: 26)
        controller.setReadingHeightLevel(.overview)
        #expect(controller.currentReadingPosition().map { Int($0.line) } == 2)
        let commented = URL(fileURLWithPath: "/commented.rs")
        let commentedBytes = Array(("// A leading comment.\n" + source).utf8)
        controller.display(commented, source: { _ in commentedBytes })
        controller.setReadingHeightLevel(.full)
        #expect(controller.selfTestSourceTop.atTop == 2, "\(controller.selfTestSourceTop)")
        controller.selfTestScrollSource(toLine: 1, topInset: 0)
        #expect(controller.selfTestSourceTop.atTop == 1 && !controller.selfTestSourceTop.headerShown)
        controller.setReadingHeightLevel(.overview)
        #expect(controller.currentReadingPosition().map { Int($0.line) } == 2)
        controller.setReadingHeightLevel(.full)
        #expect(controller.selfTestSourceTop.atTop == 1, "\(controller.selfTestSourceTop)")

        // A large file distils off the main thread with a notice instead of a
        // blank reader; a regular file displayed meanwhile shows its own
        // skeleton at once, and the large one never lands afterwards.
        controller.setReadingHeightLevel(.overview)
        let large = Array(skeletonSource(helpers: 2_100, prefix: "large").utf8)
        let small = Array(skeletonSource(helpers: 5, prefix: "small").utf8)
        #expect(FileTier(lineCount: LineTable(bytes: large).lineStarts.count) != .regular)
        controller.display(URL(fileURLWithPath: "/large.rs"), source: { _ in large })
        #expect(controller.selfTestSkeleton == nil)
        #expect(controller.selfTestSkeletonPendingText == localized("main.overview.distilling"))
        controller.display(URL(fileURLWithPath: "/small.rs"), source: { _ in small })
        let expected = try #require(distillSkeleton(bytes: small, language: .rust))
            .map(\.text).joined(separator: "\n")
        #expect(controller.selfTestSkeleton?.text == expected)
        #expect(controller.selfTestSkeletonPendingText == nil)
        try await Task.sleep(for: .seconds(2))
        #expect(controller.selfTestSkeleton?.text == expected)

        // A tab restored while its skeleton still distils lands on its line
        // once the skeleton arrives, which replaces the notice.
        let largeSource = String(decoding: large, as: UTF8.self).components(separatedBy: "\n")
        let restored = try #require(largeSource.firstIndex { $0.hasPrefix("fn large_1000(") }) + 1
        controller.display(URL(fileURLWithPath: "/large.rs"), source: { _ in large })
        controller.restoreReadingPosition(
            scrollByteOffset: LineTable(bytes: large).lineStarts[restored - 1], selectionByteOffset: nil
        )
        #expect(controller.selfTestSkeletonPendingText != nil)
        #expect(await waitUntil { controller.selfTestSkeleton?.text.hasPrefix("fn main()") == true })
        #expect(controller.selfTestSkeletonPendingText == nil)
        #expect(controller.currentReadingPosition().map { Int($0.line) } == restored)

        // JavaScript, not analysed, distils like TypeScript.
        let script = Array("function main() {\n  helper();\n}\nfunction helper() {\n  return <div />;\n}\n".utf8)
        controller.display(
            URL(fileURLWithPath: "/main.jsx"), source: { _ in script }, languageMode: LanguageMode(language: .javascript)
        )
        let scriptSkeleton = try #require(distillSkeleton(bytes: script, language: .javascript))
        #expect(controller.selfTestSkeleton?.text == scriptSkeleton.map(\.text).joined(separator: "\n"))
        // A minified bundle past the preview's colouring limit stays a plain preview.
        let bundle = Array(String(repeating: "function f(a){return a};", count: 9_000).utf8)
        controller.display(
            URL(fileURLWithPath: "/bundle.min.js"), source: { _ in bundle }, languageMode: LanguageMode(language: .javascript)
        )
        #expect(controller.displayedBytes == nil)
        #expect(!controller.isShowingSkeleton)

        // Go has a skeleton; a file with nothing to distil keeps the folded Overview.
        controller.display(
            URL(fileURLWithPath: "/main.go"),
            source: { _ in Array("package main\n\nfunc main() {}\n".utf8) },
            languageMode: LanguageMode(language: .go)
        )
        #expect(controller.isShowingSkeleton)
        controller.display(
            URL(fileURLWithPath: "/doc.go"),
            source: { _ in Array("package main\n".utf8) },
            languageMode: LanguageMode(language: .go)
        )
        #expect(!controller.isShowingSkeleton)
        #expect(controller.readingHeightLevel == .overview)
    }

    /// Jev scoring with a fake service: the rule skeleton first, replaced in
    /// place; a late answer never lands; a failure notifies once; saved
    /// scores need no request; nothing is sent without a key, outside the
    /// project or for an excluded file.
    @Test(.timeLimit(.minutes(2)))
    func overviewScoringReplacesTheRuleSkeletonInPlaceAndOnlyWhenAllowed() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("overview-scoring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("excluded"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
        var sources: [URL: [UInt8]] = [:]
        func file(_ path: String, _ prefix: String, under directory: URL? = nil) throws -> URL {
            let url = (directory ?? root).appendingPathComponent(path)
            let bytes = Array(skeletonSource(helpers: 80, prefix: prefix).utf8)
            try Data(bytes).write(to: url)
            sources[url] = bytes
            return url
        }
        let a = try file("a.rs", "alpha"), b = try file("b.rs", "beta"), failing = try file("e.rs", "echo")
        let leaving = try file("g.rs", "golf"), late = try file("h.rs", "hotel"), unkeyed = try file("u.rs", "uniform")
        let restarted = try file("r.rs", "romeo")
        let excluded = try file("excluded/x.rs", "xray")
        let outside = try file("o.rs", "oscar", under: base.appendingPathComponent("elsewhere"))
        let rules = ProjectPathRules(lines: ["excluded/"])

        let fake = FakeJev()
        let cache = JevScoreCache(directory: base.appendingPathComponent("cache"))
        var configured = true
        var revision = 0
        var notices: [String] = []
        let controller = ReaderViewController()
        controller.overviewScoring = OverviewScoring(
            keyRevision: { revision },
            isConfigured: { configured },
            allows: { MainWindowController.allowsOverviewScoring($0, root: root, rules: rules, appliesDefaults: true) },
            cache: cache,
            score: { try await fake.score($0) }
        )
        controller.onNotice = { notices.append($0) }
        func show(_ url: URL) {
            let bytes = sources[url]!
            controller.display(url, source: { _ in bytes })
        }
        func ruled(_ url: URL) throws -> String {
            try #require(distillSkeleton(bytes: sources[url]!, language: .rust)).map(\.text).joined(separator: "\n")
        }
        func scored(_ url: URL) throws -> String {
            let questions = try #require(SkeletonQuestions(bytes: sources[url]!, language: .rust))
            let ones = Dictionary(uniqueKeysWithValues: questions.questions.map { ($0.id, 1.0) })
            return try #require(distillSkeleton(bytes: sources[url]!, language: .rust, scores: ones))
                .map(\.text).joined(separator: "\n")
        }
        func answerAll(_ url: URL) throws -> Result<[String: Double], any Error> {
            let questions = try #require(SkeletonQuestions(bytes: sources[url]!, language: .rust))
            return .success(Dictionary(uniqueKeysWithValues: questions.questions.map { ($0.id, 1.0) }))
        }
        let refining = localized("main.overview.refining")
        #expect(try ruled(a) != scored(a))

        show(a)
        let window = makeWindow(controller)
        defer { window.close() }

        // The rule skeleton shows at once with the indicator; then the file is sent.
        controller.setReadingHeightLevel(.overview)
        #expect(controller.selfTestSkeleton?.text == (try ruled(a)))
        #expect(controller.selfTestScoringText == refining)
        #expect(await waitUntil { fake.callCount == 1 })
        let lines = String(decoding: sources[a]!, as: UTF8.self).components(separatedBy: "\n")
        let helper = try #require(lines.firstIndex { $0.hasPrefix("fn alpha_30(") }) + 1
        controller.navigate(to: a, byteOffset: LineTable(bytes: sources[a]!).lineStarts[helper - 1])
        let top = try #require(controller.currentReadingPosition()).line
        #expect(Int(top) == helper)

        // The answer replaces it in place: same top source line, indicator gone.
        fake.answer(try answerAll(a))
        let scoredA = try scored(a)
        #expect(await waitUntil { controller.selfTestSkeleton?.text == scoredA })
        #expect(controller.selfTestScoringText == nil)
        #expect(controller.selfTestSourceTop.belowHeader == Int(top))
        #expect(notices.isEmpty)

        // Leaving and entering again reuses it; nothing more is sent.
        controller.setReadingHeightLevel(.full)
        controller.setReadingHeightLevel(.overview)
        #expect(controller.selfTestSkeleton?.text == (try scored(a)))
        #expect(fake.callCount == 1)

        // Switching files cancels: b's late answer never lands on the file shown next.
        show(b)
        #expect(controller.selfTestSkeleton?.text == (try ruled(b)))
        #expect(await waitUntil { fake.callCount == 2 })
        show(outside)
        #expect(controller.selfTestScoringText == nil)
        fake.answer(try answerAll(b))
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.selfTestSkeleton?.text == (try ruled(outside)))
        #expect(fake.callCount == 2, "a file outside the project was sent")

        // Saved scores give the scored skeleton directly, with no request,
        // also in a reader that never saw the file.
        show(a)
        #expect(controller.selfTestSkeleton?.text == (try scored(a)))
        let fresh = ReaderViewController()
        fresh.overviewScoring = controller.overviewScoring
        let aBytes = try #require(sources[a])
        fresh.display(a, source: { _ in aBytes })
        let freshWindow = makeWindow(fresh)
        defer { freshWindow.close() }
        fresh.setReadingHeightLevel(.overview)
        #expect(fresh.selfTestSkeleton?.text == (try scored(a)))
        #expect(fresh.selfTestScoringText == nil)
        #expect(fake.callCount == 2)

        // A failure keeps the rule skeleton and says why once; the same
        // content is not sent again until the key changes.
        show(failing)
        #expect(await waitUntil { fake.callCount == 3 })
        fake.answer(.failure(JevClient.Failure.status(529)))
        #expect(await waitUntil { controller.selfTestScoringText == nil })
        #expect(controller.selfTestSkeleton?.text == (try ruled(failing)))
        #expect(notices == [localized("main.overview.refine.busy")])
        controller.setReadingHeightLevel(.full)
        controller.setReadingHeightLevel(.overview)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.callCount == 3 && notices.count == 1)
        revision += 1
        controller.setReadingHeightLevel(.full)
        controller.setReadingHeightLevel(.overview)
        #expect(await waitUntil { fake.callCount == 4 })
        fake.answer(.failure(JevClient.Failure.transport))
        #expect(await waitUntil { notices.count == 2 })
        #expect(notices.last == localized("main.overview.refine.network"))

        // Leaving and coming back at once sends again; the cancelled first
        // request ending late does not end the second one.
        show(restarted)
        #expect(await waitUntil { fake.callCount == 5 })
        controller.setReadingHeightLevel(.full)
        controller.setReadingHeightLevel(.overview)
        #expect(await waitUntil { fake.callCount == 6 })
        fake.answer(.failure(CancellationError()))
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.selfTestScoringText == refining)
        fake.answer(try answerAll(restarted))
        let scoredRestarted = try scored(restarted)
        #expect(await waitUntil { controller.selfTestSkeleton?.text == scoredRestarted })
        #expect(controller.selfTestScoringText == nil)

        // Leaving Overview cancels: a late failure says nothing and the
        // reader stays in Full.
        show(leaving)
        #expect(await waitUntil { fake.callCount == 7 })
        controller.setReadingHeightLevel(.full)
        fake.answer(.failure(JevClient.Failure.status(500)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!controller.isShowingSkeleton && controller.readingHeightLevel == .full)
        #expect(notices.count == 2, "a late failure was reported: \(notices)")

        // Excluded by the project's rules: nothing is sent; a late failure
        // of the file shown before says nothing.
        show(late)
        controller.setReadingHeightLevel(.overview)
        #expect(await waitUntil { fake.callCount == 8 })
        show(excluded)
        fake.answer(.failure(JevClient.Failure.status(500)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(controller.selfTestSkeleton?.text == (try ruled(excluded)))
        #expect(controller.selfTestScoringText == nil)
        #expect(notices.count == 2, "a late failure was reported: \(notices)")

        // Without a key: rule skeletons only, saved scores unused, nothing sent.
        configured = false
        revision += 1
        show(unkeyed)
        #expect(controller.selfTestSkeleton?.text == (try ruled(unkeyed)))
        show(a)
        #expect(controller.selfTestSkeleton?.text == (try ruled(a)))
        #expect(controller.selfTestScoringText == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.callCount == 8)
    }
}

/// Answers each scoring call when the test says so, in call order. It
/// ignores cancellation, as a slow service might, so a late answer can
/// arrive after the reader moved on.
private final class FakeJev: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var waiting: [CheckedContinuation<[String: Double], any Error>] = []

    var callCount: Int { lock.withLock { calls } }

    func score(_ questions: SkeletonQuestions) async throws -> [String: Double] {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                calls += 1
                waiting.append(continuation)
            }
        }
    }

    func answer(_ result: Result<[String: Double], any Error>) {
        let next = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
        next?.resume(with: result)
    }
}

/// `main` → `run` → `step`, then many small helpers: a skeleton long enough
/// to scroll, with blank separators.
private func skeletonSource(helpers: Int, prefix: String) -> String {
    var lines = [
        "fn main() {", "    let total = run(3);", "    println!(\"{total}\");", "}", "",
        "fn run(n: u32) -> u32 {", "    let a = step(n);", "    let b = step(a);", "    a + b", "}", "",
        "fn step(n: u32) -> u32 {", "    n + 1", "}",
    ]
    for index in 0..<helpers {
        lines += ["", "fn \(prefix)_\(index)(x: u32) -> u32 {", "    let y = x + \(index);", "    y * 2", "}"]
    }
    return lines.joined(separator: "\n") + "\n"
}

private func makeWindow(_ controller: ReaderViewController) -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    // The controller's fitting size is tiny; a skeleton must be tall enough to scroll.
    window.setContentSize(NSSize(width: 900, height: 640))
    window.contentView?.layoutSubtreeIfNeeded()
    return window
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    // A regression must fail the test, not hang the run.
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        do {
            try await Task.sleep(for: .milliseconds(10))
        } catch {
            return false
        }
    }
    return true
}
