import CodeInsightCore
import Foundation
import TreeSitterKit

package struct FoldID: Hashable, Sendable {
    package let rawValue: UInt32

    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

package enum FoldKind: UInt8, Sendable {
    case cfgTest = 0
    case container = 1
    case declaration = 2
    case block = 3
    case comment = 4
    case imports = 5
    case attributes = 6
}

package struct FoldSummary: Equatable, Sendable {
    package let hiddenLineCount: Int
    package let memberCounts: [OutlineKind: Int]
    package let itemCount: Int?
    package let leadingText: String?

    package init(
        hiddenLineCount: Int,
        memberCounts: [OutlineKind: Int] = [:],
        itemCount: Int? = nil,
        leadingText: String? = nil
    ) {
        self.hiddenLineCount = hiddenLineCount
        self.memberCounts = memberCounts
        self.itemCount = itemCount
        self.leadingText = leadingText
    }
}

package struct FoldRegion: Equatable, Sendable {
    package let id: FoldID
    package let kind: FoldKind
    package let headerRange: CodeInsightCore.ByteRange
    package let bodyRange: CodeInsightCore.ByteRange
    package let outlineDepth: Int
    package let summary: FoldSummary

    package init(
        id: FoldID,
        kind: FoldKind,
        headerRange: CodeInsightCore.ByteRange,
        bodyRange: CodeInsightCore.ByteRange,
        outlineDepth: Int,
        summary: FoldSummary
    ) {
        self.id = id
        self.kind = kind
        self.headerRange = headerRange
        self.bodyRange = bodyRange
        self.outlineDepth = outlineDepth
        self.summary = summary
    }
}

internal struct FoldCandidate: Equatable, Sendable {
    internal let kind: FoldKind
    internal let headerRange: CodeInsightCore.ByteRange
    internal let bodyRange: CodeInsightCore.ByteRange
    internal let outlineDepth: Int
    internal let summary: FoldSummary
}

internal struct FoldCandidateAccumulator {
    private var candidates: [FoldCandidate] = []

    internal init() {}

    internal mutating func visit(
        node: Node,
        foldDepth: Int,
        bytes: [UInt8]
    ) {
        appendStructuralCandidate(node: node, foldDepth: foldDepth, bytes: bytes)
        appendSiblingRunCandidates(parent: node, foldDepth: foldDepth, bytes: bytes)
    }

    internal func resolve(
        outlineFacets: [OutlineFacet],
        observer: (@Sendable (Double, Int, Int) -> Void)?
    ) -> [FoldRegion] {
        let summarized = candidates.map { candidate in
            guard candidate.kind == .container || candidate.kind == .cfgTest else {
                return candidate
            }
            var counts: [OutlineKind: Int] = [:]
            for facet in outlineFacets where
                facet.depth == candidate.outlineDepth + 1
                    && candidate.bodyRange.lowerBound <= facet.range.lowerBound
                    && facet.range.upperBound <= candidate.bodyRange.upperBound
            {
                counts[facet.kind, default: 0] += 1
            }
            return FoldCandidate(
                kind: candidate.kind,
                headerRange: candidate.headerRange,
                bodyRange: candidate.bodyRange,
                outlineDepth: candidate.outlineDepth,
                summary: FoldSummary(
                    hiddenLineCount: candidate.summary.hiddenLineCount,
                    memberCounts: counts,
                    itemCount: candidate.summary.itemCount,
                    leadingText: candidate.summary.leadingText
                )
            )
        }

        let clock = ContinuousClock()
        let started = clock.now
        let regions = resolveFoldCandidates(summarized)
        let elapsed = started.duration(to: clock.now).components
        let milliseconds = Double(elapsed.seconds) * 1_000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000
        observer?(milliseconds, summarized.count, regions.count)
        return regions
    }

    private mutating func appendStructuralCandidate(
        node: Node,
        foldDepth: Int,
        bytes: [UInt8]
    ) {
        switch node.kind {
        case "function_item":
            appendBracedCandidate(
                kind: .declaration,
                owner: node,
                bodyKinds: ["block"],
                foldDepth: foldDepth,
                bytes: bytes
            )
        case "impl_item", "trait_item", "mod_item":
            appendBracedCandidate(
                kind: .container,
                owner: node,
                bodyKinds: ["declaration_list"],
                foldDepth: foldDepth,
                bytes: bytes
            )
        case "struct_item":
            appendBracedCandidate(
                kind: .container,
                owner: node,
                bodyKinds: ["field_declaration_list"],
                foldDepth: foldDepth,
                bytes: bytes
            )
        case "enum_item":
            appendBracedCandidate(
                kind: .container,
                owner: node,
                bodyKinds: ["enum_variant_list"],
                foldDepth: foldDepth,
                bytes: bytes
            )
        case "if_expression", "else_clause", "for_expression", "loop_expression",
             "while_expression", "async_block", "unsafe_block", "const_block",
             "try_block", "gen_block", "closure_expression":
            appendBracedCandidate(
                kind: .block,
                owner: node,
                bodyKinds: ["block"],
                foldDepth: foldDepth,
                bytes: bytes
            )
        case "match_expression":
            let armCount = node.namedChildren
                .first(where: { $0.kind == "match_block" })?
                .namedChildren.lazy.filter { $0.kind == "match_arm" }.count
            appendBracedCandidate(
                kind: .block,
                owner: node,
                bodyKinds: ["match_block"],
                foldDepth: foldDepth,
                bytes: bytes,
                itemCount: armCount
            )
        case "match_arm":
            appendMatchArmCandidate(node: node, foldDepth: foldDepth, bytes: bytes)
        default:
            break
        }
    }

    private mutating func appendBracedCandidate(
        kind: FoldKind,
        owner: Node,
        bodyKinds: Set<String>,
        foldDepth: Int,
        bytes: [UInt8],
        headerLowerBound: UInt32? = nil,
        itemCount: Int? = nil
    ) {
        guard let body = owner.namedChildren.last(where: {
            bodyKinds.contains($0.kind)
        }) else { return }
        let bodyNodeRange = body.byteRange
        guard bodyNodeRange.upperBound >= bodyNodeRange.lowerBound,
              bodyNodeRange.upperBound - bodyNodeRange.lowerBound >= 2,
              byte(at: bodyNodeRange.lowerBound, in: bytes) == UInt8(ascii: "{"),
              byte(at: bodyNodeRange.upperBound - 1, in: bytes) == UInt8(ascii: "}")
        else { return }

        let headerRange = CodeInsightCore.ByteRange(
            lowerBound: headerLowerBound ?? owner.byteRange.lowerBound,
            upperBound: bodyNodeRange.lowerBound + 1
        )
        let bodyRange = CodeInsightCore.ByteRange(
            lowerBound: bodyNodeRange.lowerBound + 1,
            upperBound: bodyNodeRange.upperBound - 1
        )
        appendCandidate(
            kind: kind,
            headerRange: headerRange,
            bodyRange: bodyRange,
            foldDepth: foldDepth,
            bytes: bytes,
            itemCount: itemCount
        )
    }

    private mutating func appendMatchArmCandidate(
        node: Node,
        foldDepth: Int,
        bytes: [UInt8]
    ) {
        var arrowUpperBound: UInt32?
        var bodyUpperBound = node.byteRange.upperBound
        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            if child.kind == "=>" {
                arrowUpperBound = child.byteRange.upperBound
            } else if child.kind == ",", index + 1 == node.childCount {
                bodyUpperBound = child.byteRange.lowerBound
            }
        }
        guard let arrowUpperBound else { return }
        appendCandidate(
            kind: .block,
            headerRange: CodeInsightCore.ByteRange(
                lowerBound: node.byteRange.lowerBound,
                upperBound: arrowUpperBound
            ),
            bodyRange: CodeInsightCore.ByteRange(
                lowerBound: arrowUpperBound,
                upperBound: bodyUpperBound
            ),
            foldDepth: foldDepth,
            bytes: bytes
        )
    }

    private mutating func appendSiblingRunCandidates(
        parent: Node,
        foldDepth: Int,
        bytes: [UInt8]
    ) {
        let children = parent.namedChildren
        appendRuns(
            in: children,
            matching: { $0.kind == "use_declaration" },
            kind: .imports,
            foldDepth: foldDepth,
            bytes: bytes
        )
        appendRuns(
            in: children,
            matching: { $0.kind == "attribute_item" },
            kind: .attributes,
            foldDepth: foldDepth,
            bytes: bytes
        )
        appendRuns(
            in: children,
            matching: { $0.kind == "line_comment" || $0.kind == "block_comment" },
            kind: .comment,
            foldDepth: foldDepth,
            bytes: bytes
        )

        for index in children.indices where children[index].kind == "mod_item" {
            var attributeStart = index
            while attributeStart > children.startIndex,
                  children[attributeStart - 1].kind == "attribute_item"
            {
                attributeStart -= 1
            }
            guard attributeStart < index else { continue }
            let attributes = children[attributeStart..<index]
            guard attributes.contains(where: { attribute in
                normalizedAttributeText(attribute, bytes: bytes).contains("#[cfg(test)]")
            }) else { continue }
            appendBracedCandidate(
                kind: .cfgTest,
                owner: children[index],
                bodyKinds: ["declaration_list"],
                foldDepth: foldDepth,
                bytes: bytes,
                headerLowerBound: children[attributeStart].byteRange.lowerBound
            )
        }
    }

    private mutating func appendRuns(
        in children: [Node],
        matching predicate: (Node) -> Bool,
        kind: FoldKind,
        foldDepth: Int,
        bytes: [UInt8]
    ) {
        var start = children.startIndex
        while start < children.endIndex {
            guard predicate(children[start]) else {
                start += 1
                continue
            }
            var end = start + 1
            while end < children.endIndex, predicate(children[end]) {
                end += 1
            }
            if end - start >= 2 {
                let first = children[start].byteRange
                let last = children[end - 1].byteRange
                var headerUpperBound = first.upperBound
                var bodyLowerBound = first.upperBound
                var bodyUpperBound = last.upperBound
                if kind == .comment {
                    while bodyLowerBound < bodyUpperBound,
                          let separator = byte(at: bodyLowerBound, in: bytes),
                          separator == UInt8(ascii: "\n")
                            || separator == UInt8(ascii: "\r")
                    {
                        bodyLowerBound += 1
                        headerUpperBound += 1
                    }
                    while bodyUpperBound > first.upperBound,
                          let trailing = byte(at: bodyUpperBound - 1, in: bytes),
                          trailing == UInt8(ascii: "\n")
                            || trailing == UInt8(ascii: "\r")
                    {
                        bodyUpperBound -= 1
                    }
                }
                appendCandidate(
                    kind: kind,
                    headerRange: CodeInsightCore.ByteRange(
                        lowerBound: first.lowerBound,
                        upperBound: headerUpperBound
                    ),
                    bodyRange: CodeInsightCore.ByteRange(
                        lowerBound: bodyLowerBound,
                        upperBound: bodyUpperBound
                    ),
                    foldDepth: foldDepth,
                    bytes: bytes,
                    itemCount: end - start
                )
            }
            start = end
        }
    }

    private mutating func appendCandidate(
        kind: FoldKind,
        headerRange: CodeInsightCore.ByteRange,
        bodyRange: CodeInsightCore.ByteRange,
        foldDepth: Int,
        bytes: [UInt8],
        itemCount: Int? = nil
    ) {
        guard bodyRange.lowerBound < bodyRange.upperBound else { return }
        candidates.append(FoldCandidate(
            kind: kind,
            headerRange: headerRange,
            bodyRange: bodyRange,
            outlineDepth: foldDepth,
            summary: FoldSummary(
                hiddenLineCount: newlineCount(in: bodyRange, bytes: bytes)
                    + (kind == .comment ? 1 : 0),
                itemCount: itemCount,
                leadingText: kind == .declaration || kind == .comment
                    ? leadingText(in: bodyRange, bytes: bytes)
                    : nil
            )
        ))
    }
}

internal func resolveFoldCandidates(_ input: [FoldCandidate]) -> [FoldRegion] {
    let nonempty = input.filter { $0.bodyRange.lowerBound < $0.bodyRange.upperBound }
        .sorted(by: geometryPrecedes)
    var consistent: [FoldCandidate] = []
    var index = 0
    while index < nonempty.count {
        var end = index + 1
        while end < nonempty.count, sameGeometry(nonempty[index], nonempty[end]) {
            end += 1
        }
        let group = nonempty[index..<end]
        if group.dropFirst().allSatisfy({ $0.summary == group.first!.summary }) {
            consistent.append(group.first!)
        } else {
            emitFoldDiagnostic("rejected contradictory summaries for one fold geometry")
        }
        index = end
    }

    var accepted: [FoldCandidate] = []
    for candidate in consistent.sorted(by: winnerPrecedes) {
        guard accepted.allSatisfy({ laminar(candidate.bodyRange, $0.bodyRange) }) else {
            continue
        }
        accepted.append(candidate)
    }
    #if DEBUG
    for left in accepted.indices {
        for right in accepted.indices where left < right {
            assert(laminar(accepted[left].bodyRange, accepted[right].bodyRange))
        }
    }
    #endif
    accepted.sort(by: finalPrecedes)
    return accepted.enumerated().map { offset, candidate in
        FoldRegion(
            id: FoldID(rawValue: UInt32(offset)),
            kind: candidate.kind,
            headerRange: candidate.headerRange,
            bodyRange: candidate.bodyRange,
            outlineDepth: candidate.outlineDepth,
            summary: candidate.summary
        )
    }
}

private func sameGeometry(_ lhs: FoldCandidate, _ rhs: FoldCandidate) -> Bool {
    lhs.kind == rhs.kind
        && lhs.headerRange == rhs.headerRange
        && lhs.bodyRange == rhs.bodyRange
        && lhs.outlineDepth == rhs.outlineDepth
}

private func geometryPrecedes(_ lhs: FoldCandidate, _ rhs: FoldCandidate) -> Bool {
    compare(lhs.kind.rawValue, rhs.kind.rawValue)
        ?? compare(lhs.headerRange.lowerBound, rhs.headerRange.lowerBound)
        ?? compare(lhs.headerRange.upperBound, rhs.headerRange.upperBound)
        ?? compare(lhs.bodyRange.lowerBound, rhs.bodyRange.lowerBound)
        ?? compare(lhs.bodyRange.upperBound, rhs.bodyRange.upperBound)
        ?? compare(lhs.outlineDepth, rhs.outlineDepth)
        ?? false
}

private func winnerPrecedes(_ lhs: FoldCandidate, _ rhs: FoldCandidate) -> Bool {
    compare(lhs.kind.rawValue, rhs.kind.rawValue)
        ?? compare(rhs.summary.hiddenLineCount, lhs.summary.hiddenLineCount)
        ?? compare(lhs.headerRange.lowerBound, rhs.headerRange.lowerBound)
        ?? compare(lhs.headerRange.upperBound, rhs.headerRange.upperBound)
        ?? compare(lhs.bodyRange.lowerBound, rhs.bodyRange.lowerBound)
        ?? compare(lhs.bodyRange.upperBound, rhs.bodyRange.upperBound)
        ?? compare(lhs.outlineDepth, rhs.outlineDepth)
        ?? false
}

private func finalPrecedes(_ lhs: FoldCandidate, _ rhs: FoldCandidate) -> Bool {
    compare(lhs.bodyRange.lowerBound, rhs.bodyRange.lowerBound)
        ?? compare(rhs.bodyRange.upperBound, lhs.bodyRange.upperBound)
        ?? compare(lhs.kind.rawValue, rhs.kind.rawValue)
        ?? false
}

private func laminar(
    _ lhs: CodeInsightCore.ByteRange,
    _ rhs: CodeInsightCore.ByteRange
) -> Bool {
    if lhs.upperBound <= rhs.lowerBound || rhs.upperBound <= lhs.lowerBound {
        return true
    }
    let lhsContains = lhs.lowerBound <= rhs.lowerBound
        && rhs.upperBound <= lhs.upperBound
        && lhs != rhs
    let rhsContains = rhs.lowerBound <= lhs.lowerBound
        && lhs.upperBound <= rhs.upperBound
        && lhs != rhs
    return lhsContains || rhsContains
}

private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> Bool? {
    if lhs < rhs { return true }
    if rhs < lhs { return false }
    return nil
}

private func coreRange(_ range: TreeSitterKit.ByteRange) -> CodeInsightCore.ByteRange {
    CodeInsightCore.ByteRange(
        lowerBound: range.lowerBound,
        upperBound: range.upperBound
    )
}

private func byte(at offset: UInt32, in bytes: [UInt8]) -> UInt8? {
    guard let index = Int(exactly: offset), bytes.indices.contains(index) else {
        return nil
    }
    return bytes[index]
}

private func newlineCount(
    in range: CodeInsightCore.ByteRange,
    bytes: [UInt8]
) -> Int {
    let lower = Int(range.lowerBound)
    let upper = min(Int(range.upperBound), bytes.count)
    guard lower <= upper, bytes.indices.contains(lower) || lower == bytes.endIndex else {
        return 0
    }
    return bytes[lower..<upper].lazy.filter { $0 == 0x0A }.count
}

private func leadingText(
    in range: CodeInsightCore.ByteRange,
    bytes: [UInt8]
) -> String? {
    let lower = Int(range.lowerBound)
    let upper = min(Int(range.upperBound), bytes.count)
    guard lower <= upper,
          let value = String(bytes: bytes[lower..<upper], encoding: .utf8)
    else { return nil }
    return value.split(separator: "\n", omittingEmptySubsequences: false)
        .lazy
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })
}

private func normalizedAttributeText(_ node: Node, bytes: [UInt8]) -> String {
    let range = node.byteRange
    let lower = Int(range.lowerBound)
    let upper = min(Int(range.upperBound), bytes.count)
    guard lower <= upper else { return "" }
    return String(decoding: bytes[lower..<upper], as: UTF8.self)
        .filter { !$0.isWhitespace }
}

private func emitFoldDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data("CodeInsightReaderCore: \(message)\n".utf8))
}
