import CodeInsightCore
import CodeInsightReaderCore

@MainActor
public final class OutlinePanelModel {
    public private(set) var facets: [OutlineFacet] = []
    public private(set) var selectedIndex: Int?

    private var parentIndices: [Int?] = []

    public init() {}

    public func setDocument(_ facets: [OutlineFacet]) {
        self.facets = facets.sorted {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound > $1.range.upperBound
        }
        selectedIndex = nil
        parentIndices = Array(repeating: nil, count: facets.count)
        var stack: [Int] = []
        for index in self.facets.indices {
            while let parent = stack.last,
                  !Self.contains(self.facets[parent].range, self.facets[index].range)
            {
                stack.removeLast()
            }
            parentIndices[index] = stack.last
            stack.append(index)
        }
    }

    @discardableResult
    public func highlight(at byteOffset: UInt32) -> Int? {
        var lower = 0
        var upper = facets.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if facets[middle].range.lowerBound <= byteOffset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        var candidate = lower > 0 ? lower - 1 : nil
        while let index = candidate {
            if facets[index].range.contains(byteOffset) {
                selectedIndex = index
                return index
            }
            candidate = parentIndices[index]
        }
        selectedIndex = nil
        return nil
    }

    public func open(_ index: Int) -> UInt32? {
        guard facets.indices.contains(index) else { return nil }
        selectedIndex = index
        return facets[index].nameRange.lowerBound
    }

    private static func contains(
        _ outer: CodeInsightCore.ByteRange,
        _ inner: CodeInsightCore.ByteRange
    ) -> Bool {
        outer != inner
            && outer.lowerBound <= inner.lowerBound
            && inner.upperBound <= outer.upperBound
    }
}
