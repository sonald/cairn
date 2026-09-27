import CodeInsightCore

/// Immutable relationships for one analysis; arrays retain original-order tie breaks.
package struct FoldTopology: Sendable {
    package let regions: [FoldRegion]
    package let usesCompatibilityRelations: Bool
    package let compatibilityReason: String?
    package let compatibilityRecordVisits: Int
    package let associationRecordVisits: Int
    package let preorder: [Int]
    package let parentIndices: [Int?]
    package let children: [[Int]]
    package let subtreeEnds: [Int]
    private let positions: [Int]
    private let indicesByID: [FoldID: Int]
    private let headerLines: [Int?]
    private let semanticParents: [Int?]
    private let siblingGroups: [Int: [Int: [Int]]]
    private let compatibilityDescendants: [[Int]]?
    private let compatibilityBoundaries: [UInt32]
    private let compatibilityContaining: [[Int]]
    private let facets: [OutlineFacet]
    private let associatedFacetIndices: [Int?]
    private let bestRegionByFacet: [Int: Int]
    package let associatedFacets: [OutlineFacet]

    /// Duplicate IDs, empty bodies and invalid UTF-8 boundaries cannot form a valid index.
    /// Crossing/equal intervals remain supported through one-time compatibility analysis.
    package init?(
        regions: [FoldRegion], facets: [OutlineFacet],
        lineTable: LineTable, sourceMap: ByteUTF16Map
    ) {
        var byID: [FoldID: Int] = [:]
        for (i, region) in regions.enumerated() {
            guard byID.updateValue(i, forKey: region.id) == nil,
                  region.bodyRange.lowerBound < region.bodyRange.upperBound,
                  region.headerRange.lowerBound <= region.headerRange.upperBound,
                  sourceMap.utf16Offset(forByte: Int(region.bodyRange.lowerBound)) != nil,
                  sourceMap.utf16Offset(forByte: Int(region.bodyRange.upperBound)) != nil,
                  sourceMap.utf16Offset(forByte: Int(region.headerRange.lowerBound)) != nil,
                  sourceMap.utf16Offset(forByte: Int(region.headerRange.upperBound)) != nil
            else { return nil }
        }
        ReaderWorkCounters.record(\.topologyBuildCount)
        self.regions = regions
        self.facets = facets
        indicesByID = byID
        headerLines = regions.map { lineTable.lineColumn(at: $0.headerRange.lowerBound).map { Int($0.line) } }
        let order = regions.indices.sorted {
            let a = regions[$0].bodyRange, b = regions[$1].bodyRange
            if a.lowerBound != b.lowerBound { return a.lowerBound < b.lowerBound }
            if a.upperBound != b.upperBound { return a.upperBound > b.upperBound }
            return $0 < $1
        }
        preorder = order
        var positions = Array(repeating: 0, count: regions.count)
        var ends = Array(repeating: order.count, count: regions.count)
        var parents = Array<Int?>(repeating: nil, count: regions.count)
        var semantic = parents
        var children = Array(repeating: [Int](), count: regions.count)
        var stack: [Int] = []
        var bestAncestors: [Int] = []
        var laminar = true
        for (position, index) in order.enumerated() {
            positions[index] = position
            let range = regions[index].bodyRange
            while let last = stack.last, regions[last].bodyRange.upperBound <= range.lowerBound {
                ends[last] = position
                stack.removeLast()
                bestAncestors.removeLast()
            }
            if let parent = stack.last {
                let outer = regions[parent].bodyRange
                if outer.upperBound < range.upperBound || outer == range
                    || regions[parent].outlineDepth >= regions[index].outlineDepth { laminar = false }
                parents[index] = parent
                children[parent].append(index)
                semantic[index] = bestAncestors.last
            }
            let best: Int
            if let previous = bestAncestors.last,
               regions[previous].outlineDepth > regions[index].outlineDepth
                || (regions[previous].outlineDepth == regions[index].outlineDepth && previous < index) {
                best = previous
            } else { best = index }
            stack.append(index)
            bestAncestors.append(best)
        }
        usesCompatibilityRelations = !laminar
        compatibilityReason = laminar ? nil : "crossing, equal, or nonmonotone-depth intervals"
        self.positions = positions
        subtreeEnds = ends
        // Tree-only geometry is explicitly unavailable for crossing/equal custom inputs.
        parentIndices = laminar ? parents : Array(repeating: nil, count: regions.count)
        self.children = laminar ? children : Array(repeating: [], count: regions.count)
        var visits = 0
        if !laminar {
            // ponytail: malformed/custom interval sets use O(n²) once; normalized parser output uses the stack above.
            semantic = regions.map { child in
                regions.indices.filter {
                    visits += 1
                    return regions[$0].id != child.id && Self.contains(regions[$0].bodyRange, child.bodyRange)
                }
                    .max { regions[$0].outlineDepth < regions[$1].outlineDepth }
            }
            compatibilityDescendants = regions.map { outer in
                regions.indices.filter {
                    visits += 1
                    return Self.contains(outer.bodyRange, regions[$0].bodyRange)
                }
            }
        } else { compatibilityDescendants = nil }
        semanticParents = semantic
        var groups: [Int: [Int: [Int]]] = [:]
        for i in regions.indices { groups[semantic[i] ?? -1, default: [:]][regions[i].outlineDepth, default: []].append(i) }
        siblingGroups = groups
        if laminar {
            compatibilityBoundaries = []
            compatibilityContaining = []
        } else {
            let boundaries = Set(regions.flatMap { [$0.bodyRange.lowerBound, $0.bodyRange.upperBound] }).sorted()
            compatibilityBoundaries = boundaries
            compatibilityContaining = boundaries.map { byte in
                regions.indices.filter { visits += 1; return regions[$0].bodyRange.contains(byte) }
            }
        }
        compatibilityRecordVisits = visits

        // A balanced interval index avoids visiting every unrelated declaration for each fold.
        let facetOrder = facets.indices.sorted {
            if facets[$0].range.lowerBound != facets[$1].range.lowerBound {
                return facets[$0].range.lowerBound < facets[$1].range.lowerBound
            }
            return $0 < $1
        }
        var facetSubtreeUpper = Array(repeating: UInt32(0), count: facets.count)
        @discardableResult
        func prepareFacetIntervals(_ lower: Int, _ upper: Int) -> UInt32 {
            guard lower < upper else { return 0 }
            let middle = (lower + upper) / 2
            let maximum = max(facets[facetOrder[middle]].range.upperBound,
                              max(prepareFacetIntervals(lower, middle), prepareFacetIntervals(middle + 1, upper)))
            facetSubtreeUpper[middle] = maximum
            return maximum
        }
        prepareFacetIntervals(0, facetOrder.count)
        var associationVisits = 0
        func findAssociation(_ region: FoldRegion, _ lower: Int, _ upper: Int, best: inout Int?) {
            guard lower < upper else { return }
            let middle = (lower + upper) / 2
            associationVisits += 1
            guard facetSubtreeUpper[middle] >= region.bodyRange.upperBound,
                  facets[facetOrder[lower]].range.lowerBound <= region.bodyRange.lowerBound else { return }
            findAssociation(region, lower, middle, best: &best)
            let index = facetOrder[middle]
            let facet = facets[index]
            if Self.canAssociate(region, facet) {
                if let old = best {
                    if Self.facetPrecedes(facet, facets[old])
                        || (!Self.facetPrecedes(facets[old], facet) && index < old) { best = index }
                } else { best = index }
            }
            if facet.range.lowerBound <= region.bodyRange.lowerBound {
                findAssociation(region, middle + 1, upper, best: &best)
            }
        }
        let associations = regions.map { region in
            var best: Int?
            findAssociation(region, 0, facetOrder.count, best: &best)
            return best
        }
        associationRecordVisits = associationVisits
        associatedFacetIndices = associations
        var bestByFacet: [Int: Int] = [:]
        var associated: [OutlineFacet] = []
        var associatedIndices: Set<Int> = []
        for i in regions.indices {
            guard let facet = associations[i] else { continue }
            if associatedIndices.insert(facet).inserted { associated.append(facets[facet]) }
            if let old = bestByFacet[facet], regions[old].bodyRange.length <= regions[i].bodyRange.length { continue }
            bestByFacet[facet] = i
        }
        bestRegionByFacet = bestByFacet
        associatedFacets = associated
    }

    package func region(for id: FoldID) -> FoldRegion? { indicesByID[id].map { regions[$0] } }
    package func headerLine(for id: FoldID) -> Int? { indicesByID[id].flatMap { headerLines[$0] } }
    package func parent(of id: FoldID) -> FoldID? {
        indicesByID[id].flatMap { semanticParents[$0] }.map { regions[$0].id }
    }

    package func recursiveSiblings(of id: FoldID) -> [FoldID] {
        guard let index = indicesByID[id] else { return [] }
        let siblings = siblingGroups[semanticParents[index] ?? -1]?[regions[index].outlineDepth] ?? []
        var affected: Set<Int> = []
        for sibling in siblings {
            if let compatibilityDescendants { affected.formUnion(compatibilityDescendants[sibling]) }
            else { affected.formUnion(preorder[positions[sibling]..<subtreeEnds[sibling]]) }
        }
        return affected.sorted().map { regions[$0].id }
    }

    package func containing(_ byteOffset: UInt32) -> [FoldRegion] {
        var low = 0, high = preorder.count
        while low < high {
            let mid = (low + high) / 2
            if regions[preorder[mid]].bodyRange.lowerBound <= byteOffset { low = mid + 1 }
            else { high = mid }
        }
        if usesCompatibilityRelations {
            var lower = 0, upper = compatibilityBoundaries.count
            while lower < upper {
                let mid = (lower + upper) / 2
                if compatibilityBoundaries[mid] <= byteOffset { lower = mid + 1 }
                else { upper = mid }
            }
            return lower == 0 ? [] : compatibilityContaining[lower - 1].map { regions[$0] }
        }
        var found: [Int] = []
        var index: Int? = low > 0 ? preorder[low - 1] : nil
        while let current = index {
            if regions[current].bodyRange.contains(byteOffset) { found.append(current) }
            index = parentIndices[current]
        }
        return found.sorted().map { regions[$0] }
    }

    package func maximalFoldIDs(_ logical: Set<FoldID>) -> Set<FoldID> {
        var result: Set<FoldID> = []
        var upper: UInt32?
        for index in preorder {
            let region = regions[index]
            guard logical.contains(region.id) else { continue }
            if let upper, region.bodyRange.upperBound <= upper { continue }
            result.insert(region.id)
            upper = region.bodyRange.upperBound
        }
        return result
    }

    package func associatedFacet(for id: FoldID) -> OutlineFacet? {
        indicesByID[id].flatMap { associatedFacetIndices[$0] }.map { facets[$0] }
    }

    package func focusTarget(at byteOffset: UInt32) -> (facet: OutlineFacet, region: FoldRegion)? {
        let containing = facets.indices.filter { facets[$0].range.contains(byteOffset) }
        let declarations = containing.filter { facets[$0].kind == .fn || facets[$0].kind == .method }
        let containers = containing.filter {
            switch facets[$0].kind {
            case .struct, .enum, .trait, .impl, .mod, .class: true
            default: false
            }
        }
        guard let facet = (declarations.isEmpty ? containers : declarations).min(by: {
            Self.facetPrecedes(facets[$0], facets[$1])
        }), let region = bestRegionByFacet[facet] else { return nil }
        return (facets[facet], regions[region])
    }

    package static func rejectionReason(regions: [FoldRegion], sourceMap: ByteUTF16Map) -> String? {
        var ids: Set<FoldID> = []
        for region in regions {
            guard ids.insert(region.id).inserted else { return "duplicate fold ID" }
            guard region.bodyRange.lowerBound < region.bodyRange.upperBound else { return "empty fold body" }
            guard region.headerRange.lowerBound <= region.headerRange.upperBound else { return "invalid fold header" }
            for boundary in [region.bodyRange.lowerBound, region.bodyRange.upperBound,
                             region.headerRange.lowerBound, region.headerRange.upperBound] {
                guard sourceMap.utf16Offset(forByte: Int(boundary)) != nil else { return "invalid fold source boundary" }
            }
        }
        return nil
    }

    private static func contains(_ outer: ByteRange, _ inner: ByteRange) -> Bool {
        outer.lowerBound <= inner.lowerBound && inner.upperBound <= outer.upperBound
    }

    private static func facetPrecedes(_ a: OutlineFacet, _ b: OutlineFacet) -> Bool {
        if a.range.length != b.range.length { return a.range.length < b.range.length }
        return a.depth > b.depth
    }

    private static func canAssociate(_ region: FoldRegion, _ facet: OutlineFacet) -> Bool {
        guard contains(facet.range, region.bodyRange) else { return false }
        return switch (region.kind, facet.kind) {
        case (.declaration, .fn), (.declaration, .method),
             (.container, .struct), (.container, .enum), (.container, .trait), (.container, .impl), (.container, .mod),
             (.cfgTest, .struct), (.cfgTest, .enum), (.cfgTest, .trait), (.cfgTest, .impl), (.cfgTest, .mod): true
        default: false
        }
    }
}
