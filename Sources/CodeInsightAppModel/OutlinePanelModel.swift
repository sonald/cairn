import CodeInsightCore
import CodeInsightReaderCore

/// One row of the sidebar outline. Producers decide identity and the
/// navigation target; the sidebar only renders and reports rows.
public struct OutlineNode: Equatable, Sendable {
    /// Stable across reloads of the same document; keys collapsed state.
    public let key: UInt32
    public let title: String
    public let detail: String
    public let kind: OutlineKind
    /// Rows nest by range containment and follow the caret by range.
    public let range: CodeInsightCore.ByteRange
    public let navigationOffset: UInt32

    public init(
        key: UInt32,
        title: String,
        detail: String,
        kind: OutlineKind,
        range: CodeInsightCore.ByteRange,
        navigationOffset: UInt32
    ) {
        self.key = key
        self.title = title
        self.detail = detail
        self.kind = kind
        self.range = range
        self.navigationOffset = navigationOffset
    }

    /// The symbol outline of one document: rows open at the declared name.
    public init(facet: OutlineFacet) {
        self.init(
            key: facet.range.lowerBound,
            title: facet.name,
            detail: facet.detail,
            kind: facet.kind,
            range: facet.range,
            navigationOffset: facet.nameRange.lowerBound
        )
    }
}

@MainActor
public final class OutlinePanelModel {
    public private(set) var nodes: [OutlineNode] = []
    public private(set) var selectedIndex: Int?

    public private(set) var parentIndices: [Int?] = []
    public private(set) var rootIndices: [Int] = []
    public private(set) var childIndices: [[Int]] = []

    public init() {}

    public func setDocument(_ nodes: [OutlineNode]) {
        self.nodes = nodes.sorted {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.range.upperBound > $1.range.upperBound
        }
        selectedIndex = nil
        parentIndices = Array(repeating: nil, count: nodes.count)
        rootIndices = []
        childIndices = Array(repeating: [], count: nodes.count)
        var stack: [Int] = []
        for index in self.nodes.indices {
            while let parent = stack.last,
                  !Self.contains(self.nodes[parent].range, self.nodes[index].range)
            {
                stack.removeLast()
            }
            parentIndices[index] = stack.last
            if let parent = stack.last {
                childIndices[parent].append(index)
            } else {
                rootIndices.append(index)
            }
            stack.append(index)
        }
    }

    @discardableResult
    public func highlight(at byteOffset: UInt32) -> Int? {
        var lower = 0
        var upper = nodes.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if nodes[middle].range.lowerBound <= byteOffset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        var candidate = lower > 0 ? lower - 1 : nil
        while let index = candidate {
            if nodes[index].range.contains(byteOffset) {
                selectedIndex = index
                return index
            }
            candidate = parentIndices[index]
        }
        selectedIndex = nil
        return nil
    }

    public func open(_ index: Int) -> UInt32? {
        guard nodes.indices.contains(index) else { return nil }
        selectedIndex = index
        return nodes[index].navigationOffset
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
