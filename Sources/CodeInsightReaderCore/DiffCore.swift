import CodeInsightCore
import CodeInsightPythonExtractor
import CodeInsightRustExtractor
import CodeInsightTypeScriptExtractor
import Foundation

public struct DiffCore: Sendable {
    public static let maximumLineCount = 20_000
    public static let maximumChangeCount = 5_000

    public enum MarkerKind: UInt8, Sendable {
        case added
        case removed
        case changed
    }

    public struct Line: Equatable, Sendable {
        public enum Kind: UInt8, Sendable {
            case added
            case removed
            case context
        }

        public let kind: Kind
        public let leftLine: Int?
        public let rightLine: Int?
        public let leftByteRange: Range<Int>?
        public let rightByteRange: Range<Int>?
    }

    public struct Hunk: Equatable, Sendable {
        public let lines: [Line]

        public var leftStartLine: Int? { lines.lazy.compactMap(\.leftLine).first }
        public var rightStartLine: Int? { lines.lazy.compactMap(\.rightLine).first }
    }

    public struct Result: Equatable, Sendable {
        public let hunks: [Hunk]
        public let leftMarkers: [Int: MarkerKind]
        public let rightMarkers: [Int: MarkerKind]
        public let leftLineCount: Int
        public let rightLineCount: Int
        public let changeCount: Int
        public let truncated: Bool

        public var gutterCounts: [MarkerKind: Int] {
            Dictionary(grouping: Array(leftMarkers.values) + rightMarkers.values, by: { $0 })
                .mapValues(\.count)
        }
    }

    public struct FunctionChange: Equatable, Sendable {
        public enum Kind: UInt8, Sendable {
            case added
            case removed
            case signatureChanged
            case bodyChanged
        }

        public let kind: Kind
        public let nameChain: [String]
        public let declarationKind: DeclarationKind
        public let leftRange: CodeInsightCore.ByteRange?
        public let rightRange: CodeInsightCore.ByteRange?

        public var displayName: String {
            switch declarationKind {
            case .pythonFunction, .typescriptFunction:
                return nameChain.joined(separator: ".")
            case _:
                return nameChain.joined(separator: "::")
            }
        }
    }

    public init() {}

    public func compare(left: [UInt8], right: [UInt8]) -> Result {
        compareSupported(left: left, right: right)
    }

    public func compare(
        left: [UInt8],
        right: [UInt8],
        languageMode: LanguageMode
    ) throws -> Result {
        try requireSupported(languageMode)
        return compareSupported(left: left, right: right)
    }

    private func compareSupported(left: [UInt8], right: [UInt8]) -> Result {
        let leftLines = splitLines(left)
        let rightLines = splitLines(right)
        guard max(leftLines.count, rightLines.count) <= Self.maximumLineCount else {
            return Result(
                hunks: [],
                leftMarkers: [:],
                rightMarkers: [:],
                leftLineCount: leftLines.count,
                rightLineCount: rightLines.count,
                changeCount: 0,
                truncated: true
            )
        }

        let difference = rightLines.difference(from: leftLines) {
            $0.hash == $1.hash && $0.bytes.elementsEqual($1.bytes)
        }
        guard difference.count <= Self.maximumChangeCount else {
            return Result(
                hunks: [],
                leftMarkers: [:],
                rightMarkers: [:],
                leftLineCount: leftLines.count,
                rightLineCount: rightLines.count,
                changeCount: difference.count,
                truncated: true
            )
        }

        var removals: Set<Int> = []
        var insertions: Set<Int> = []
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removals.insert(offset)
            case let .insert(offset, _, _): insertions.insert(offset)
            }
        }

        var lines: [Line] = []
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < leftLines.count || rightIndex < rightLines.count {
            if removals.contains(leftIndex) {
                lines.append(Line(
                    kind: .removed,
                    leftLine: leftIndex + 1,
                    rightLine: nil,
                    leftByteRange: leftLines[leftIndex].range,
                    rightByteRange: nil
                ))
                leftIndex += 1
            } else if insertions.contains(rightIndex) {
                lines.append(Line(
                    kind: .added,
                    leftLine: nil,
                    rightLine: rightIndex + 1,
                    leftByteRange: nil,
                    rightByteRange: rightLines[rightIndex].range
                ))
                rightIndex += 1
            } else {
                guard leftIndex < leftLines.count, rightIndex < rightLines.count else {
                    break
                }
                lines.append(Line(
                    kind: .context,
                    leftLine: leftIndex + 1,
                    rightLine: rightIndex + 1,
                    leftByteRange: leftLines[leftIndex].range,
                    rightByteRange: rightLines[rightIndex].range
                ))
                leftIndex += 1
                rightIndex += 1
            }
        }

        let hunks = makeHunks(lines)
        let markers = makeMarkers(hunks)
        return Result(
            hunks: hunks,
            leftMarkers: markers.left,
            rightMarkers: markers.right,
            leftLineCount: leftLines.count,
            rightLineCount: rightLines.count,
            changeCount: difference.count,
            truncated: false
        )
    }

    public func functionChanges(
        left: [UInt8],
        right: [UInt8]
    ) throws -> [FunctionChange] {
        try functionChanges(
            left: left,
            right: right,
            languageMode: LanguageMode(language: .rust)
        )
    }

    public func functionChanges(
        left: [UInt8],
        right: [UInt8],
        languageMode: LanguageMode
    ) throws -> [FunctionChange] {
        try requireSupported(languageMode)
        let old = try extractFunctions(left, languageMode: languageMode)
        let new = try extractFunctions(right, languageMode: languageMode)
        let keys = Set(old.keys).union(new.keys).sorted()
        var changes: [FunctionChange] = []

        for key in keys {
            let leftFunctions = old[key] ?? []
            let rightFunctions = new[key] ?? []
            let pairedCount = min(leftFunctions.count, rightFunctions.count)
            for index in 0..<pairedCount {
                let lhs = leftFunctions[index]
                let rhs = rightFunctions[index]
                if lhs.facet.signatureFingerprint != rhs.facet.signatureFingerprint {
                    changes.append(change(.signatureChanged, key, lhs.facet, rhs.facet))
                }
                if lhs.facet.bodyFingerprint != rhs.facet.bodyFingerprint {
                    changes.append(change(.bodyChanged, key, lhs.facet, rhs.facet))
                }
            }
            for function in leftFunctions.dropFirst(pairedCount) {
                changes.append(change(.removed, key, function.facet, nil))
            }
            for function in rightFunctions.dropFirst(pairedCount) {
                changes.append(change(.added, key, nil, function.facet))
            }
        }
        return changes
    }

    private struct HashedLine {
        let bytes: ArraySlice<UInt8>
        let range: Range<Int>
        let hash: Int
    }

    private struct FunctionKey: Hashable, Comparable {
        let names: [String]
        let kind: UInt8

        static func < (lhs: FunctionKey, rhs: FunctionKey) -> Bool {
            let left = lhs.names.joined(separator: "\u{0}")
            let right = rhs.names.joined(separator: "\u{0}")
            return left == right ? lhs.kind < rhs.kind : left < right
        }
    }

    private struct ExtractedFunction {
        let facet: DeclarationFacet
    }

    private func splitLines(_ bytes: [UInt8]) -> [HashedLine] {
        guard !bytes.isEmpty else { return [] }
        var result: [HashedLine] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 0x0A {
            result.append(line(bytes, range: start..<(index + 1)))
            start = index + 1
        }
        if start < bytes.count { result.append(line(bytes, range: start..<bytes.count)) }
        return result
    }

    private func line(_ bytes: [UInt8], range: Range<Int>) -> HashedLine {
        let slice = bytes[range]
        var hasher = Hasher()
        for byte in slice { hasher.combine(byte) }
        return HashedLine(bytes: slice, range: range, hash: hasher.finalize())
    }

    private func makeHunks(_ lines: [Line]) -> [Hunk] {
        let changed = lines.indices.filter { lines[$0].kind != .context }
        guard let first = changed.first else { return [] }
        var ranges: [ClosedRange<Int>] = []
        var current = max(0, first - 3)...min(lines.count - 1, first + 3)
        for index in changed.dropFirst() {
            let next = max(0, index - 3)...min(lines.count - 1, index + 3)
            if next.lowerBound <= current.upperBound + 1 {
                current = current.lowerBound...max(current.upperBound, next.upperBound)
            } else {
                ranges.append(current)
                current = next
            }
        }
        ranges.append(current)
        return ranges.map { Hunk(lines: Array(lines[$0])) }
    }

    private func makeMarkers(
        _ hunks: [Hunk]
    ) -> (left: [Int: MarkerKind], right: [Int: MarkerKind]) {
        var left: [Int: MarkerKind] = [:]
        var right: [Int: MarkerKind] = [:]
        for hunk in hunks {
            var index = 0
            while index < hunk.lines.count {
                guard hunk.lines[index].kind != .context else {
                    index += 1
                    continue
                }
                let start = index
                while index < hunk.lines.count, hunk.lines[index].kind != .context {
                    index += 1
                }
                let block = hunk.lines[start..<index]
                let removed = block.compactMap(\.leftLine)
                let added = block.compactMap(\.rightLine)
                let paired = min(removed.count, added.count)
                for line in removed.prefix(paired) { left[line] = .changed }
                for line in added.prefix(paired) { right[line] = .changed }
                for line in removed.dropFirst(paired) { left[line] = .removed }
                for line in added.dropFirst(paired) { right[line] = .added }
            }
        }
        return (left, right)
    }

    private func extractFunctions(
        _ bytes: [UInt8],
        languageMode: LanguageMode
    ) throws -> [FunctionKey: [ExtractedFunction]] {
        let names = Interner<NameID>()
        let strings = Interner<StringID>()
        let key = ContentIndexKey(
            contentID: ContentID.sha256(of: bytes),
            languageMode: languageMode,
            grammarVersion: extractor(for: languageMode).grammarVersion,
            extractorVersion: extractor(for: languageMode).extractorVersion
        )
        let contentIndex = try extractor(for: languageMode).extract(
            bytes: bytes,
            key: key,
            interner: ExtractionInterners(names: names, strings: strings)
        )
        var result: [FunctionKey: [ExtractedFunction]] = [:]
        for facet in contentIndex.symbols where isFunction(facet.kind) {
            var chain = [names.resolve(facet.nameID)]
            var parent = facet.parentFacetIndex
            while let parentIndex = parent,
                  contentIndex.symbols.indices.contains(Int(parentIndex))
            {
                let parentFacet = contentIndex.symbols[Int(parentIndex)]
                if languageMode.language == .python {
                    guard isFunction(parentFacet.kind) || parentFacet.kind == .pythonClass else {
                        parent = parentFacet.parentFacetIndex
                        continue
                    }
                    chain.append(names.resolve(parentFacet.nameID))
                } else if languageMode.language == .typescript {
                    guard isFunction(parentFacet.kind) || parentFacet.kind == .typescriptClass else {
                        parent = parentFacet.parentFacetIndex
                        continue
                    }
                    chain.append(names.resolve(parentFacet.nameID))
                } else {
                    chain.append(names.resolve(parentFacet.nameID))
                }
                parent = parentFacet.parentFacetIndex
            }
            let key = FunctionKey(names: chain.reversed(), kind: facet.kind.rawValue)
            result[key, default: []].append(ExtractedFunction(facet: facet))
        }
        return result.mapValues { functions in
            functions.sorted { $0.facet.range.lowerBound < $1.facet.range.lowerBound }
        }
    }

    private func requireSupported(_ languageMode: LanguageMode) throws {
        switch languageMode.language {
        case .rust, .python:
            return
        case .typescript:
            guard languageMode.variant == nil || languageMode.variant == "tsx" else {
                throw CocoaError(.featureUnsupported, userInfo: [
                    NSLocalizedFailureReasonErrorKey:
                        "DiffCore does not support TypeScript variant '\(languageMode.variant ?? "")'",
                ])
            }
            return
        case .javascript:
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedFailureReasonErrorKey:
                    "DiffCore does not support \(String(describing: languageMode.language))",
            ])
        }
    }

    private func extractor(for languageMode: LanguageMode) -> any LanguageExtractor {
        switch languageMode.language {
        case .python:
            PythonExtractor()
        case .rust:
            RustExtractor()
        case .typescript:
            TypeScriptExtractor()
        case .javascript:
            preconditionFailure("DiffCore requireSupported must reject \(languageMode.language)")
        }
    }

    private func isFunction(_ kind: DeclarationKind) -> Bool {
        kind == .rustFn || kind == .rustMethod || kind == .pythonFunction
            || kind == .typescriptFunction
    }

    private func change(
        _ kind: FunctionChange.Kind,
        _ key: FunctionKey,
        _ left: DeclarationFacet?,
        _ right: DeclarationFacet?
    ) -> FunctionChange {
        FunctionChange(
            kind: kind,
            nameChain: key.names,
            declarationKind: DeclarationKind(rawValue: key.kind)!,
            leftRange: left?.range,
            rightRange: right?.range
        )
    }
}
