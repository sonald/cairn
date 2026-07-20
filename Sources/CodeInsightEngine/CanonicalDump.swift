import CodeInsightCore

public enum CanonicalDump {
    public static func render(
        _ index: ContentIndex,
        names: Interner<NameID>,
        strings: Interner<StringID>
    ) -> String {
        var lines: [String] = ["scopes:"]
        let children = Dictionary(grouping: index.scopes, by: \.parent)

        func appendScopes(parent: ScopeID?, depth: Int) {
            for scope in (children[parent] ?? []).sorted(by: {
                ordered($0.range, Int($0.id.rawValue), $1.range, Int($1.id.rawValue))
            }) {
                lines.append("\(String(repeating: "  ", count: depth + 1))- #\(scope.id.rawValue) \(scope.kind) \(format(scope.range, table: index.lineTable))")
                appendScopes(parent: scope.id, depth: depth + 1)
            }
        }
        appendScopes(parent: nil, depth: 0)
        appendNoneIfNeeded(to: &lines, count: index.scopes.count)

        lines.append("bindings:")
        for (bindingIndex, binding) in index.bindings.enumerated().sorted(by: {
            ordered($0.element.declarationRange, $0.offset, $1.element.declarationRange, $1.offset)
        }) {
            lines.append("  - #\(bindingIndex) scope=#\(binding.scopeID.rawValue) kind=\(binding.kind) name=\(names.resolve(binding.localNameID)) at=\(format(binding.declarationRange, table: index.lineTable))")
        }
        appendNoneIfNeeded(to: &lines, count: index.bindings.count)

        lines.append("regions:")
        for (regionIndex, region) in index.executableRegions.enumerated().sorted(by: {
            ordered($0.element.range, $0.offset, $1.element.range, $1.offset)
        }) {
            let facet = region.associatedFacetIndex.map { "#\($0)" } ?? "-"
            lines.append("  - #\(regionIndex) kind=\(region.kind) scope=#\(region.enclosingScopeID.rawValue) facet=\(facet) range=\(format(region.range, table: index.lineTable))")
        }
        appendNoneIfNeeded(to: &lines, count: index.executableRegions.count)

        lines.append("facets:")
        for (facetIndex, facet) in index.symbols.enumerated().sorted(by: {
            ordered($0.element.range, $0.offset, $1.element.range, $1.offset)
        }) {
            let parent = parentChain(of: facet, in: index.symbols, names: names)
            lines.append("  - #\(facetIndex) kind=\(facet.kind) space=\(facet.space) name=\(names.resolve(facet.nameID)) parent=\(parent) nameAt=\(format(facet.nameRange, table: index.lineTable)) range=\(format(facet.range, table: index.lineTable))")
        }
        appendNoneIfNeeded(to: &lines, count: index.symbols.count)

        lines.append("calls:")
        for (callIndex, call) in index.calls.enumerated().sorted(by: {
            ordered($0.element.range, $0.offset, $1.element.range, $1.offset)
        }) {
            lines.append("  - #\(callIndex) kind=\(call.syntacticKind) name=\(names.resolve(call.nameID)) region=#\(call.regionID.rawValue) range=\(format(call.range, table: index.lineTable))")
        }
        appendNoneIfNeeded(to: &lines, count: index.calls.count)

        lines.append("imports:")
        for (importIndex, binding) in index.imports.enumerated().sorted(by: {
            ordered($0.element.range, $0.offset, $1.element.range, $1.offset)
        }) {
            let imported = binding.importedName.map(names.resolve) ?? "-"
            let local = binding.localName.map(names.resolve) ?? "-"
            lines.append("  - #\(importIndex) kind=\(binding.kind) module=\(strings.resolve(binding.moduleSpecifier)) imported=\(imported) local=\(local) flags=\(flags(binding.flags)) scope=#\(binding.scopeID.rawValue) range=\(format(binding.range, table: index.lineTable))")
        }
        appendNoneIfNeeded(to: &lines, count: index.imports.count)

        lines.append("exports:")
        for (exportIndex, export) in index.exports.enumerated().sorted(by: {
            ordered($0.element.range, $0.offset, $1.element.range, $1.offset)
        }) {
            let source = export.sourceBindingIndex.map { "#\($0)" } ?? "-"
            lines.append("  - #\(exportIndex) name=\(names.resolve(export.exportedName)) sourceBinding=\(source) range=\(format(export.range, table: index.lineTable))")
        }
        appendNoneIfNeeded(to: &lines, count: index.exports.count)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func format(_ range: ByteRange, table: LineTable) -> String {
        let start = table.lineColumn(at: range.lowerBound)
            .map { "\($0.line):\($0.column)" } ?? "?:?"
        let end = table.lineColumn(at: range.upperBound)
            .map { "\($0.line):\($0.column)" } ?? "?:?"
        return "\(start)..\(end) bytes=\(range.lowerBound)..<\(range.upperBound)"
    }

    private static func ordered(
        _ lhsRange: ByteRange,
        _ lhsIndex: Int,
        _ rhsRange: ByteRange,
        _ rhsIndex: Int
    ) -> Bool {
        lhsRange.lowerBound == rhsRange.lowerBound
            ? lhsIndex < rhsIndex
            : lhsRange.lowerBound < rhsRange.lowerBound
    }

    private static func parentChain(
        of facet: DeclarationFacet,
        in facets: [DeclarationFacet],
        names: Interner<NameID>
    ) -> String {
        var chain: [String] = []
        var parent = facet.parentFacetIndex
        while let index = parent, facets.indices.contains(Int(index)) {
            let facet = facets[Int(index)]
            chain.append(names.resolve(facet.nameID))
            parent = facet.parentFacetIndex
        }
        let result = chain.reversed().joined(separator: "/")
        return result.isEmpty ? "-" : result
    }

    private static func flags(_ flags: ImportFlags) -> String {
        var names: [String] = []
        if flags.contains(.wildcard) { names.append("wildcard") }
        if flags.contains(.reexport) { names.append("reexport") }
        if flags.contains(.typeOnly) { names.append("typeOnly") }
        if flags.contains(.conditional) { names.append("conditional") }
        if flags.contains(.dynamic) { names.append("dynamic") }
        let result = names.joined(separator: ",")
        return result.isEmpty ? "-" : result
    }

    private static func appendNoneIfNeeded(to lines: inout [String], count: Int) {
        if count == 0 { lines.append("  (none)") }
    }
}
