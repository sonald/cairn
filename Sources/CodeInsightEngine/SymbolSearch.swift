import CodeInsightCore

public struct SearchBoost: Sendable {
    public let currentFile: PathID?
    public let recentFiles: [PathID]

    public init(currentFile: PathID? = nil, recentFiles: [PathID] = []) {
        self.currentFile = currentFile
        self.recentFiles = recentFiles
    }
}

public struct SymbolSearchHit: Sendable {
    public let nameID: NameID
    public let facet: DeclarationFacet
    public let occurrence: SymbolOccurrenceID
    public let path: String
    public let line: UInt32
    public let column: UInt32
    public let score: Double
    /// UTF-16 ranges in the symbol name, suitable for attributed-string styling.
    public let matchRanges: [Range<Int>]
}

public struct SymbolSearchIndex: Sendable {
    struct NormalizedName: Sendable {
        let text: String
        let characters: [Character]
        let wordStarts: Set<Int>
        let originalUTF16Ranges: [Range<Int>]
        let acronym: String
    }

    struct Candidate: Sendable {
        let nameID: NameID
        let score: Double
        let matchRanges: [Range<Int>]
    }

    private struct Entry: Sendable {
        let nameID: NameID
        let normalized: NormalizedName
    }

    private let entriesSortedByNormalized: [Entry]
    private let acronymBuckets: [String: [Int]]
    private let trigramPostings: [String: [Int]]

    init(nameIDs: [NameID], names: Interner<NameID>) {
        entriesSortedByNormalized = nameIDs.map {
            Entry(nameID: $0, normalized: Self.normalize(names.resolve($0)))
        }.sorted {
            if $0.normalized.text != $1.normalized.text {
                return $0.normalized.text < $1.normalized.text
            }
            return $0.nameID.rawValue < $1.nameID.rawValue
        }

        var acronymBuckets: [String: [Int]] = [:]
        var trigramPostings: [String: [Int]] = [:]
        for (index, entry) in entriesSortedByNormalized.enumerated() {
            if !entry.normalized.acronym.isEmpty {
                acronymBuckets[entry.normalized.acronym, default: []].append(index)
            }
            for trigram in Set(Self.trigrams(entry.normalized.characters)) {
                trigramPostings[trigram, default: []].append(index)
            }
        }
        self.acronymBuckets = acronymBuckets
        self.trigramPostings = trigramPostings
    }

    func candidates(for query: String, cap: Int = 2_000) -> [Candidate] {
        let queryCharacters = Self.normalize(query).characters
        guard !queryCharacters.isEmpty, cap > 0 else { return [] }
        let queryText = String(queryCharacters)

        var recalled: Set<Int> = []
        var lower = lowerBound(for: queryText)
        while lower < entriesSortedByNormalized.count,
              entriesSortedByNormalized[lower].normalized.text.hasPrefix(queryText)
        {
            recalled.insert(lower)
            lower += 1
        }

        for (acronym, indexes) in acronymBuckets where acronym.hasPrefix(queryText) {
            recalled.formUnion(indexes)
        }

        var trigramVotes: [Int: Int] = [:]
        for trigram in Set(Self.trigrams(queryCharacters)) {
            for index in trigramPostings[trigram] ?? [] {
                trigramVotes[index, default: 0] += 1
            }
        }
        let trigramIndexes = trigramVotes.keys.sorted {
            let lhs = trigramVotes[$0] ?? 0
            let rhs = trigramVotes[$1] ?? 0
            if lhs != rhs { return lhs > rhs }
            return $0 < $1
        }
        for index in trigramIndexes where recalled.count < cap {
            recalled.insert(index)
        }

        return recalled.sorted().prefix(cap).compactMap { index in
            let entry = entriesSortedByNormalized[index]
            guard let match = Self.subsequence(
                queryCharacters,
                in: entry.normalized
            ) else { return nil }
            return Candidate(
                nameID: entry.nameID,
                score: match.score,
                matchRanges: match.ranges
            )
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.nameID.rawValue < $1.nameID.rawValue
        }
    }

    static func normalize(_ source: String) -> NormalizedName {
        let sourceCharacters = Array(source)
        var characters: [Character] = []
        var wordStarts: Set<Int> = []
        var ranges: [Range<Int>] = []
        var acronym: [Character] = []
        var utf16Offset = 0

        for (sourceIndex, character) in sourceCharacters.enumerated() {
            let length = String(character).utf16.count
            defer { utf16Offset += length }
            guard character.isLetter || character.isNumber else { continue }

            let previous = sourceIndex > 0 ? sourceCharacters[sourceIndex - 1] : nil
            let next = sourceIndex + 1 < sourceCharacters.count
                ? sourceCharacters[sourceIndex + 1] : nil
            let startsWord = previous == nil
                || !(previous!.isLetter || previous!.isNumber)
                || (previous!.isLowercase && character.isUppercase)
                || (previous!.isNumber != character.isNumber)
                || (previous!.isUppercase && character.isUppercase && next?.isLowercase == true)

            let lowered = Array(String(character).lowercased())
            if startsWord, let first = lowered.first {
                wordStarts.insert(characters.count)
                acronym.append(first)
            }
            for loweredCharacter in lowered {
                characters.append(loweredCharacter)
                ranges.append(utf16Offset..<(utf16Offset + length))
            }
        }
        return NormalizedName(
            text: String(characters),
            characters: characters,
            wordStarts: wordStarts,
            originalUTF16Ranges: ranges,
            acronym: String(acronym)
        )
    }

    private func lowerBound(for query: String) -> Int {
        var lower = 0
        var upper = entriesSortedByNormalized.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if entriesSortedByNormalized[middle].normalized.text < query {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    private static func trigrams(_ characters: [Character]) -> [String] {
        guard characters.count >= 3 else { return [] }
        return (0...(characters.count - 3)).map {
            String(characters[$0...($0 + 2)])
        }
    }

    private static func subsequence(
        _ query: [Character],
        in target: NormalizedName
    ) -> (score: Double, ranges: [Range<Int>])? {
        var positions: [Int] = []
        positions.reserveCapacity(query.count)
        var targetIndex = 0
        for character in query {
            guard let match = target.characters[targetIndex...].firstIndex(of: character) else {
                return nil
            }
            positions.append(match)
            targetIndex = match + 1
        }

        var score = Double(query.count * 10)
        if positions.first == 0 { score += 24 }
        for (offset, position) in positions.enumerated() {
            if target.wordStarts.contains(position) { score += 18 }
            if offset > 0, position == positions[offset - 1] + 1 { score += 12 }
        }
        let span = positions.last! - positions.first! + 1
        score += 40 * Double(query.count) / Double(span)
        score -= Double(target.characters.count - query.count) * 0.5

        var ranges: [Range<Int>] = []
        for position in positions {
            let range = target.originalUTF16Ranges[position]
            if let last = ranges.last, last.upperBound == range.lowerBound {
                ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
            } else if ranges.last != range {
                ranges.append(range)
            }
        }
        return (score, ranges)
    }
}
