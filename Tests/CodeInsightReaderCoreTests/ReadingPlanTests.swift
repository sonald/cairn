import CodeInsightCore
import Foundation
import Testing
@testable import CodeInsightReaderCore

// Reading decisions run on plain documents, without a text view.

private let planSource = """
    use std::fmt;
    use std::io;
    use std::fs;

    /// First doc line.
    /// Second doc line.
    /// Third doc line.
    struct S {
        a: u8,
        b: u8,
        c: u8,
    }

    impl S {
        fn one(&self) -> u8 {
            let x = self.a;
            let y = self.b;
            x + y
        }

        fn two(&self) -> u8 {
            let x = self.b;
            let y = self.c;
            x + y
        }
    }

    """

private func planDocument() throws -> ReaderDocument {
    try DocumentLoader().loadSyntax(for: ReaderDocument(
        bytes: Array(planSource.utf8),
        languageMode: LanguageMode(language: .rust)
    ))
}

private func offset(of needle: String) -> UInt32 {
    UInt32(planSource[..<planSource.range(of: needle)!.lowerBound].utf8.count)
}

private func region(
    _ kind: FoldKind,
    containing needle: String,
    in document: ReaderDocument
) throws -> FoldRegion {
    let target = offset(of: needle)
    return try #require(document.foldRegions
        .filter { $0.kind == kind && $0.bodyRange.contains(target) }
        .min { $0.bodyRange.length < $1.bodyRange.length })
}

@Test
func readingPlanBaselinesFoldDeclarationsAtStructureAndContainersOnlyAtOverview() throws {
    let document = try planDocument()
    let one = try region(.declaration, containing: "let x = self.a", in: document)
    let two = try region(.declaration, containing: "let y = self.c", in: document)
    let impl = try region(.container, containing: "fn one", in: document)

    #expect(ReadingPlan.baselineFoldIDs(for: .full, in: document.foldRegions).isEmpty)

    let structure = ReadingPlan.baselineFoldIDs(for: .structure, in: document.foldRegions)
    #expect(structure.isSuperset(of: [one.id, two.id]))
    #expect(!structure.contains(impl.id))

    let overview = ReadingPlan.baselineFoldIDs(for: .overview, in: document.foldRegions)
    #expect(overview.isSuperset(of: [one.id, two.id, impl.id]))
    // Only the outermost folds render: the container hides both bodies.
    let rendered = ReadingPlan.maximalFoldIDs(overview, in: document)
    #expect(rendered.contains(impl.id))
    #expect(!rendered.contains(one.id) && !rendered.contains(two.id))
}

@Test
func readingPlanOverridesCancelAgainstTheBaselineInBothDirections() throws {
    let document = try planDocument()
    let one = try region(.declaration, containing: "let x = self.a", in: document)
    let impl = try region(.container, containing: "fn one", in: document)
    let baseline = ReadingPlan.baselineFoldIDs(for: .structure, in: document.foldRegions)
    var overrides = FoldOverrides()

    ReadingPlan.setFold(one.id, folded: false, baseline: baseline, overrides: &overrides)
    ReadingPlan.setFold(impl.id, folded: true, baseline: baseline, overrides: &overrides)
    #expect(overrides.forcedUnfolded == [one.id])
    #expect(overrides.forcedFolded == [impl.id])
    let logical = ReadingPlan.logicalFoldIDs(overrides: overrides, baseline: baseline)
    #expect(!logical.contains(one.id) && logical.contains(impl.id))

    // Returning each fold to its baseline state leaves no override behind.
    ReadingPlan.setFold(one.id, folded: true, baseline: baseline, overrides: &overrides)
    ReadingPlan.setFold(impl.id, folded: false, baseline: baseline, overrides: &overrides)
    #expect(overrides == FoldOverrides())
    #expect(ReadingPlan.logicalFoldIDs(overrides: overrides, baseline: baseline) == baseline)
}

@Test
func readingPlanFocusKeepsOnlyTheSmallestEnclosingDeclarationOpen() throws {
    let document = try planDocument()
    let one = try region(.declaration, containing: "let x = self.a", in: document)
    let two = try region(.declaration, containing: "let y = self.c", in: document)
    let impl = try region(.container, containing: "fn one", in: document)

    let target = try #require(ReadingPlan.focusTarget(at: offset(of: "let y = self.c"), in: document))
    #expect(target.facet.name == "two")
    #expect(target.region.id == two.id)

    let folded = ReadingPlan.focusFoldIDs(around: target.facet, in: document)
    #expect(folded.contains(one.id))
    #expect(!folded.contains(two.id) && !folded.contains(impl.id))

    let enclosing = ReadingPlan.enclosingAssociatedFacets(at: offset(of: "let y = self.c"), in: document)
    #expect(enclosing.map(\.name) == ["S", "two"])
    #expect(enclosing.map(\.depth) == enclosing.map(\.depth).sorted())
}
