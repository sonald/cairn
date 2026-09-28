import CodeInsightCore

package enum ReadingHeightLevel: Int, CaseIterable, Sendable {
    case full
    case structure
    case overview
}

/// Explicit fold choices layered over a reading level's baseline.
package struct FoldOverrides: Equatable, Sendable {
    package var forcedFolded: Set<FoldID> = []
    package var forcedUnfolded: Set<FoldID> = []

    package init() {}
}

/// Pure fold and focus decisions for one document. The reader view keeps
/// TextKit, geometry and the viewport; it asks this which folds apply.
package enum ReadingPlan {
    package static func logicalFoldIDs(
        overrides: FoldOverrides,
        baseline: Set<FoldID>
    ) -> Set<FoldID> {
        baseline.subtracting(overrides.forcedUnfolded)
            .union(overrides.forcedFolded)
    }

    package static func baselineFoldIDs(
        for level: ReadingHeightLevel,
        in regions: [FoldRegion]
    ) -> Set<FoldID> {
        guard level != .full else { return [] }
        return Set(
            regions.compactMap { region in
                guard region.summary.hiddenLineCount >= 2 else { return nil }
                switch region.kind {
                case .declaration, .imports, .cfgTest:
                    return region.id
                case .container:
                    return level == .overview ? region.id : nil
                case .comment:
                    return region.id
                case .block, .attributes:
                    return nil
                }
            })
    }

    package static func focusTarget(
        at byteOffset: UInt32,
        in document: ReaderDocument
    ) -> (facet: OutlineFacet, region: FoldRegion)? {
        document.foldTopology?.focusTarget(at: byteOffset)
    }

    package static func enclosingAssociatedFacets(
        at byteOffset: UInt32,
        in document: ReaderDocument
    ) -> [OutlineFacet] {
        let result = (document.foldTopology?.associatedFacets ?? []).filter {
            facetContainsCaret(byteOffset, facet: $0, in: document)
        }
        return result.sorted { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            if lhs.range.upperBound != rhs.range.upperBound {
                return lhs.range.upperBound > rhs.range.upperBound
            }
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.name < rhs.name
        }
    }

    private static func facetContainsCaret(
        _ byteOffset: UInt32,
        facet: OutlineFacet,
        in document: ReaderDocument
    ) -> Bool {
        if facet.range.lowerBound <= byteOffset,
           byteOffset < facet.range.upperBound
        {
            return true
        }
        guard let caretLine = document.lineTable.lineColumn(at: byteOffset)?.line,
              let firstLine = document.lineTable.lineColumn(
                  at: facet.range.lowerBound
              )?.line
        else { return false }
        let finalByte = facet.range.upperBound > facet.range.lowerBound
            ? facet.range.upperBound - 1
            : facet.range.lowerBound
        guard let lastLine = document.lineTable.lineColumn(at: finalByte)?.line
        else { return false }
        return firstLine <= caretLine && caretLine <= lastLine
    }

    package static func focusFoldIDs(
        around facet: OutlineFacet,
        in document: ReaderDocument
    ) -> Set<FoldID> {
        Set(document.foldRegions.compactMap { region in
            guard region.summary.hiddenLineCount >= 2 else { return nil }
            let intersects = region.bodyRange.lowerBound < facet.range.upperBound
                && facet.range.lowerBound < region.bodyRange.upperBound
            return intersects ? nil : region.id
        })
    }

    package static func maximalFoldIDs(
        _ logical: Set<FoldID>,
        in document: ReaderDocument
    ) -> Set<FoldID> {
        document.foldTopology?.maximalFoldIDs(logical) ?? []
    }

    package static func setFold(
        _ id: FoldID,
        folded: Bool,
        baseline: Set<FoldID>,
        overrides: inout FoldOverrides
    ) {
        if folded {
            overrides.forcedUnfolded.remove(id)
            if baseline.contains(id) {
                overrides.forcedFolded.remove(id)
            } else {
                overrides.forcedFolded.insert(id)
            }
        } else {
            overrides.forcedFolded.remove(id)
            if baseline.contains(id) {
                overrides.forcedUnfolded.insert(id)
            } else {
                overrides.forcedUnfolded.remove(id)
            }
        }
    }
}
