import CodeInsightReaderCore
import Testing

@Test
func lineDiffMarksAddedRemovedAndChangedLines() {
    let diff = DiffCore().compare(
        left: Array("keep\nold\nstable\ndelete\nstable-2\n".utf8),
        right: Array("keep\nnew\nstable\nstable-2\nadd\n".utf8)
    )

    #expect(!diff.truncated)
    #expect(diff.hunks.count == 1)
    #expect(diff.leftMarkers == [2: .changed, 4: .removed])
    #expect(diff.rightMarkers == [2: .changed, 5: .added])
}

@Test
func lineDiffHandlesEmptyFiles() {
    let unchanged = DiffCore().compare(left: [], right: [])
    #expect(unchanged.hunks.isEmpty)
    #expect(!unchanged.truncated)

    let added = DiffCore().compare(left: [], right: Array("one\n".utf8))
    #expect(added.rightMarkers == [1: .added])
}

@Test
func lineDiffPreservesCRLFAndUnterminatedEOFBytes() {
    let left = Array("a\r\nb\n".utf8)
    let right = Array("a\nb".utf8)
    let diff = DiffCore().compare(left: left, right: right)
    let changed = diff.hunks.flatMap(\.lines).filter { $0.kind != .context }

    #expect(changed.compactMap(\.leftByteRange).map { Array(left[$0]) } == [
        Array("a\r\n".utf8), Array("b\n".utf8),
    ])
    #expect(changed.compactMap(\.rightByteRange).map { Array(right[$0]) } == [
        Array("a\n".utf8), Array("b".utf8),
    ])
}

@Test
func lineDiffHandlesAGiantLine() {
    var left = [UInt8](repeating: 0x61, count: 1_000_000)
    var right = left
    left.append(0x62)
    right.append(0x63)

    let diff = DiffCore().compare(left: left, right: right)
    #expect(!diff.truncated)
    #expect(diff.leftMarkers == [1: .changed])
    #expect(diff.rightMarkers == [1: .changed])
}

@Test
func lineDiffTruncatesAboveChangeOrLineBudget() {
    let tooManyChanges = DiffCore().compare(
        left: [],
        right: Array(String(repeating: "x\n", count: 5_001).utf8)
    )
    #expect(tooManyChanges.truncated)
    #expect(tooManyChanges.changeCount == 5_001)
    #expect(tooManyChanges.hunks.isEmpty)
    #expect(tooManyChanges.rightMarkers.isEmpty)

    let tooManyLines = DiffCore().compare(
        left: Array(String(repeating: "x\n", count: 20_001).utf8),
        right: []
    )
    #expect(tooManyLines.truncated)
    #expect(tooManyLines.leftLineCount == 20_001)
}

@Test
func functionSummaryReportsSignatureBodyAddedAndRemoved() throws {
    let changes = try DiffCore().functionChanges(
        left: Array("fn sig(a: i32) {}\nfn body() { old(); }\nfn gone() {}\n".utf8),
        right: Array("fn sig(a: i64) {}\nfn body() { new(); }\nfn added() {}\n".utf8)
    )
    let summaries = Set(changes.map { "\($0.kind):\($0.displayName)" })

    #expect(summaries.contains("signatureChanged:sig"))
    #expect(summaries.contains("bodyChanged:body"))
    #expect(summaries.contains("removed:gone"))
    #expect(summaries.contains("added:added"))
}

@Test
func functionSummaryTreatsRenameAsRemovedAndAdded() throws {
    let changes = try DiffCore().functionChanges(
        left: Array("mod nested { fn old_name() {} }".utf8),
        right: Array("mod nested { fn new_name() {} }".utf8)
    )

    #expect(changes.map(\.kind) == [.added, .removed])
    #expect(Set(changes.map(\.displayName)) == [
        "nested::new_name", "nested::old_name",
    ])
}
