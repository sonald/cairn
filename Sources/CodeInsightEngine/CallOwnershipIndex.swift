import CodeInsightCore

/// Syntax ownership only; resolution remains local to the querying session.
struct CallOwnershipIndex: Sendable {
    let regionIndexByID: [ExecutableRegionID: Int]
    let callIndicesByFacet: [[Int]]

    init(content: ContentIndex) {
        self.init(regions: content.executableRegions, callRanges: content.calls.map(\.range),
                  facetRanges: content.symbols.map(\.range))
    }

    init(regions: [ExecutableRegionRecord], callRanges: [ByteRange], facetRanges: [ByteRange]) {
        ReaderWorkCounters.record(\.ownershipBuildCount)
        var byID: [ExecutableRegionID: Int] = [:]
        for (offset, region) in regions.enumerated() where byID[region.id] == nil {
            byID[region.id] = offset // Match first(where:) even for duplicate IDs.
        }
        regionIndexByID = byID
        let sortedRegions = regions.indices.filter {
            regions[$0].associatedFacetIndex != nil && regions[$0].range.length > 0
        }.sorted {
            let lhs = regions[$0].range.lowerBound
            let rhs = regions[$1].range.lowerBound
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        var calls = Array(callRanges.indices)
        if zip(callRanges, callRanges.dropFirst()).contains(where: {
            $0.0.lowerBound > $0.1.lowerBound
        }) {
            calls.sort {
                let lhs = callRanges[$0].lowerBound
                let rhs = callRanges[$1].lowerBound
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
        }
        var grouped = [[Int]](repeating: [], count: facetRanges.count)
        var heap: [Int] = []
        var regionCursor = 0
        func precedes(_ a: Int, _ b: Int) -> Bool {
            if regions[a].range.length != regions[b].range.length {
                return regions[a].range.length < regions[b].range.length
            }
            if regions[a].id != regions[b].id {
                return regions[a].id.rawValue > regions[b].id.rawValue
            }
            return a < b
        }
        for call in calls {
            let range = callRanges[call]
            while regionCursor < sortedRegions.count,
                  regions[sortedRegions[regionCursor]].range.lowerBound <= range.lowerBound {
                heap.append(sortedRegions[regionCursor])
                regionCursor += 1
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard precedes(heap[child], heap[parent]) else { break }
                    heap.swapAt(child, parent)
                    child = parent
                }
            }
            // Expired entries may stay below the minimum until they reach the
            // root. Every region enters and leaves the heap at most once.
            while let root = heap.first, regions[root].range.upperBound <= range.lowerBound {
                let last = heap.removeLast()
                guard !heap.isEmpty else { break }
                heap[0] = last
                var parent = 0
                while parent * 2 + 1 < heap.count {
                    var child = parent * 2 + 1
                    if child + 1 < heap.count, precedes(heap[child + 1], heap[child]) {
                        child += 1
                    }
                    guard precedes(heap[child], heap[parent]) else { break }
                    heap.swapAt(child, parent)
                    parent = child
                }
            }
            guard let root = heap.first, let owner = regions[root].associatedFacetIndex else { continue }
            guard facetRanges.indices.contains(Int(owner)) else { continue }
            let facet = facetRanges[Int(owner)]
            guard facet.lowerBound <= range.lowerBound, range.upperBound <= facet.upperBound else { continue }
            grouped[Int(owner)].append(call)
        }
        callIndicesByFacet = grouped
    }
}
