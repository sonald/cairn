// Frozen from f5e116d6477fe20ed9bd83b08b82f4a0512594a7 (S0).
// Test-only reference: preserve input-order ties in the original fold scans.
import CodeInsightCore
import CodeInsightReaderCore

enum ReadonlyStructuralOracle {
    static func recursiveSiblings(of region: FoldRegion, in regions: [FoldRegion]) -> [FoldID] {
        func parent(of child: FoldRegion) -> FoldRegion? {
            regions.filter {
                $0.id != child.id
                    && $0.bodyRange.lowerBound <= child.bodyRange.lowerBound
                    && child.bodyRange.upperBound <= $0.bodyRange.upperBound
            }.max { $0.outlineDepth < $1.outlineDepth }
        }
        let parentID = parent(of: region)?.id
        let siblings = regions.filter {
            $0.outlineDepth == region.outlineDepth && parent(of: $0)?.id == parentID
        }
        return regions.filter { candidate in
            siblings.contains {
                $0.bodyRange.lowerBound <= candidate.bodyRange.lowerBound
                    && candidate.bodyRange.upperBound <= $0.bodyRange.upperBound
            }
        }.map(\.id)
    }

    static func callOwner(at lowerBound: UInt32, regions: [ExecutableRegionRecord]) -> UInt32? {
        regions.filter {
            $0.associatedFacetIndex != nil && $0.range.contains(lowerBound)
        }.min {
            if $0.range.length != $1.range.length { return $0.range.length < $1.range.length }
            return $0.id.rawValue > $1.id.rawValue
        }?.associatedFacetIndex
    }

    static func outgoingCallIndices(
        facet: UInt32, range: ByteRange, calls: [ByteRange], regions: [ExecutableRegionRecord]
    ) -> (indices: [Int], truncated: Bool) {
        let matching = calls.enumerated().filter { _, call in
            range.lowerBound <= call.lowerBound && call.upperBound <= range.upperBound
                && callOwner(at: call.lowerBound, regions: regions) == facet
        }.sorted {
            if $0.element.lowerBound != $1.element.lowerBound {
                return $0.element.lowerBound < $1.element.lowerBound
            }
            return $0.offset < $1.offset
        }
        return (matching.prefix(512).map(\.offset), matching.count > 512)
    }

    static func focusTarget(
        at byteOffset: UInt32,
        in document: ReaderDocument
    ) -> (facet: OutlineFacet, region: FoldRegion)? {
        let containing = document.outlineFacets.filter {
            $0.range.lowerBound <= byteOffset && byteOffset < $0.range.upperBound
        }
        let declarations = containing.filter {
            $0.kind == .fn || $0.kind == .method
        }
        let containers = containing.filter {
            switch $0.kind {
            case .struct, .enum, .trait, .impl, .mod, .class: true
            case .fn, .method, .const, .static, .typeAlias, .field, .enumMember: false
            }
        }
        guard let facet = (declarations.isEmpty ? containers : declarations)
            .min(by: { lhs, rhs in
                let lhsLength = lhs.range.upperBound - lhs.range.lowerBound
                let rhsLength = rhs.range.upperBound - rhs.range.lowerBound
                if lhsLength != rhsLength { return lhsLength < rhsLength }
                return lhs.depth > rhs.depth
            })
        else { return nil }
        guard let region = document.foldRegions.filter({
            associatedFacet(for: $0, in: document.outlineFacets) == facet
        }).min(by: {
            ($0.bodyRange.upperBound - $0.bodyRange.lowerBound)
                < ($1.bodyRange.upperBound - $1.bodyRange.lowerBound)
        }) else { return nil }
        return (facet, region)
    }


    static func associatedFacet(
        for region: FoldRegion,
        in facets: [OutlineFacet]
    ) -> OutlineFacet? {
        facets.filter { facet in
            guard facet.range.lowerBound <= region.bodyRange.lowerBound,
                  region.bodyRange.upperBound <= facet.range.upperBound
            else { return false }
            switch (region.kind, facet.kind) {
            case (.declaration, .fn), (.declaration, .method):
                return true
            case (.container, .struct), (.container, .enum),
                (.container, .trait), (.container, .impl), (.container, .mod),
                (.cfgTest, .struct), (.cfgTest, .enum), (.cfgTest, .trait),
                (.cfgTest, .impl), (.cfgTest, .mod):
                return true
            default:
                return false
            }
        }.min { lhs, rhs in
            let lhsLength = lhs.range.upperBound - lhs.range.lowerBound
            let rhsLength = rhs.range.upperBound - rhs.range.lowerBound
            if lhsLength != rhsLength { return lhsLength < rhsLength }
            return lhs.depth > rhs.depth
        }
    }


    static func maximalFoldIDs(
        _ logical: Set<FoldID>,
        in regions: [FoldRegion]
    ) -> Set<FoldID> {
        let active = regions.filter { logical.contains($0.id) }.sorted {
            if $0.bodyRange.lowerBound != $1.bodyRange.lowerBound {
                return $0.bodyRange.lowerBound < $1.bodyRange.lowerBound
            }
            return $0.bodyRange.upperBound > $1.bodyRange.upperBound
        }
        var result: Set<FoldID> = []
        result.reserveCapacity(active.count)
        var maximalUpper: UInt32?
        for region in active {
            if let maximalUpper,
               region.bodyRange.upperBound <= maximalUpper
            {
                continue
            }
            result.insert(region.id)
            maximalUpper = region.bodyRange.upperBound
        }
        return result
    }

}
