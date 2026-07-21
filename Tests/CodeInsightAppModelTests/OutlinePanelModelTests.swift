import CodeInsightCore
import CodeInsightReaderCore
import Testing
@testable import CodeInsightAppModel

@MainActor
@Test
func outlinePanelSortsLocatesInnermostAndOpensRows() {
    let model = OutlinePanelModel()
    model.setDocument([
        facet("second", .method, 60, 80, 2),
        facet("nested", .method, 20, 30, 2),
        facet("outer", .mod, 0, 100, 0),
        facet("first", .impl, 10, 40, 1),
    ])

    #expect(model.facets.map(\.name) == ["outer", "first", "nested", "second"])
    #expect(model.highlight(at: 0) == 0)
    #expect(model.highlight(at: 99) == 0)
    #expect(model.highlight(at: 25) == 2)
    #expect(model.highlight(at: 50) == 0)
    #expect(model.highlight(at: 65) == 3)
    #expect(model.highlight(at: 100) == nil)
    #expect(model.open(2) == 21)
    #expect(model.selectedIndex == 2)
    #expect(model.open(4) == nil)
}

private func facet(
    _ name: String,
    _ kind: OutlineKind,
    _ lowerBound: UInt32,
    _ upperBound: UInt32,
    _ depth: Int
) -> OutlineFacet {
    OutlineFacet(
        kind: kind,
        name: name,
        range: ByteRange(lowerBound: lowerBound, upperBound: upperBound),
        nameRange: ByteRange(lowerBound: lowerBound + 1, upperBound: lowerBound + 2),
        depth: depth
    )
}
