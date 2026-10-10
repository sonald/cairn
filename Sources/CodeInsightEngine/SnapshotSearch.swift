import CodeInsightCore
import CodeInsightRustExtractor
import Foundation

public protocol SnapshotContentSource: Sendable {
    var manifest: SnapshotManifest { get }
    func path(for pathID: PathID) -> String?
    func bytes(for contentID: ContentID) -> [UInt8]?
    func searchIndex(for pathID: PathID) -> ContentIndex?
    func searchName(for nameID: NameID) -> String?
    var searchProjectExcludedPathCount: Int? { get }
    /// Whether text search covers this manifest file; a unit session
    /// searches only its own sources.
    func searchIncludes(pathID: PathID) -> Bool
}

public extension SnapshotContentSource {
    func searchIndex(for pathID: PathID) -> ContentIndex? { nil }
    func searchName(for nameID: NameID) -> String? { nil }
    var searchProjectExcludedPathCount: Int? { nil }
    func searchIncludes(pathID: PathID) -> Bool { true }
}

public struct ContentSearchQuery: Sendable {
    public let pattern: String
    public let isRegex: Bool
    public let caseSensitive: Bool
    /// Hits may not touch an identifier character on either side.
    public let wholeWord: Bool
    /// Project-relative path globs; empty means every path.
    public let includeGlobs: [String]
    public let excludeGlobs: [String]

    public init(
        pattern: String,
        isRegex: Bool = false,
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = []
    ) {
        self.pattern = pattern
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
    }
}

public struct SearchMatch: Sendable {
    public let pathID: PathID
    public let byteRange: ByteRange
    public let line: UInt32
    public let column: UInt32
    public let lineText: String
    public let lineTextRange: ByteRange
    public let conditionIndices: [Int]
    public let conditionRanges: [Int: [ByteRange]]
    public let symbolName: String?

    public init(
        pathID: PathID,
        byteRange: ByteRange,
        line: UInt32,
        column: UInt32,
        lineText: String,
        lineTextRange: ByteRange,
        conditionIndices: [Int] = [],
        conditionRanges: [Int: [ByteRange]] = [:],
        symbolName: String? = nil
    ) {
        self.pathID = pathID
        self.byteRange = byteRange
        self.line = line
        self.column = column
        self.lineText = lineText
        self.lineTextRange = lineTextRange
        self.conditionIndices = conditionIndices
        self.conditionRanges = conditionRanges
        self.symbolName = symbolName
    }
}

public struct SearchBatch: Sendable {
    public let matchesByPath: [PathID: [SearchMatch]]
    public let isFinal: Bool
    public let completeness: Completeness
    public let truncatedPathIDs: Set<PathID>
    /// Files of the session's language that the query's path filters kept,
    /// and those they removed; the same on every batch of one search.
    public let searchedPathCount: Int
    public let excludedPathCount: Int
    public let searchedLanguages: [LanguageID]
    public let nonSourcePathCount: Int
    public let projectExcludedPathCount: Int?
    public let regexSkippedPathCount: Int
    public let truncatedConditionIndices: Set<Int>

    public init(
        matchesByPath: [PathID: [SearchMatch]],
        isFinal: Bool,
        completeness: Completeness,
        truncatedPathIDs: Set<PathID> = [],
        searchedPathCount: Int = 0,
        excludedPathCount: Int = 0,
        searchedLanguages: [LanguageID] = [],
        nonSourcePathCount: Int = 0,
        projectExcludedPathCount: Int? = nil,
        regexSkippedPathCount: Int = 0,
        truncatedConditionIndices: Set<Int> = []
    ) {
        self.matchesByPath = matchesByPath
        self.isFinal = isFinal
        self.completeness = completeness
        self.truncatedPathIDs = truncatedPathIDs
        self.searchedPathCount = searchedPathCount
        self.excludedPathCount = excludedPathCount
        self.searchedLanguages = searchedLanguages
        self.nonSourcePathCount = nonSourcePathCount
        self.projectExcludedPathCount = projectExcludedPathCount
        self.regexSkippedPathCount = regexSkippedPathCount
        self.truncatedConditionIndices = truncatedConditionIndices
    }
}

public enum SnapshotSearchError: Error {
    case emptyPattern
}

public struct SnapshotSearchService: Sendable {
    private static let matchesPerFile = 200
    private static let totalMatches = 5_000
    static let regexContentBytes = 4 * 1_024 * 1_024
    private static let filesPerBatch = 16
    private static let matchesPerBatch = 200

    let source: any SnapshotContentSource
    let language: LanguageID
    let extractor: any LanguageExtractor
    let wallClockLimit: Duration
    let batchInterval: Duration
    let workerCount: Int
    let searchMatchesPerFile: Int
    let searchTotalMatches: Int

    // Workers report ranges; only the consumer projects and publishes ordered results.
    private enum ScanEvent: Sendable {
        case content(Int, [UInt8]?, [ByteRange]?, regexSkipped: Bool, incompleteConditions: Set<Int>)
        case workerFinished
        case flush
    }

    public init(source: any SnapshotContentSource) {
        self.init(
            source: source,
            language: .rust,
            extractor: RustExtractor()
        )
    }

    init(
        source: any SnapshotContentSource,
        language: LanguageID,
        extractor: any LanguageExtractor,
        wallClockLimit: Duration = .seconds(5),
        batchInterval: Duration = .milliseconds(50),
        workerCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        matchesPerFile: Int = 200,
        totalMatches: Int = 5_000
    ) {
        precondition(extractor.language == language)
        precondition(workerCount > 0 && matchesPerFile > 0 && totalMatches > 0)
        self.source = source
        self.language = language
        self.extractor = extractor
        self.wallClockLimit = wallClockLimit
        self.batchInterval = batchInterval
        self.workerCount = workerCount
        searchMatchesPerFile = matchesPerFile
        searchTotalMatches = totalMatches
    }

    public func search(
        _ query: ContentSearchQuery,
        context: QueryContext
    ) throws -> AsyncThrowingStream<SearchBatch, Error> {
        try search(query, filters: nil, regexForWords: query.isRegex, wholeWordForWords: query.wholeWord, context: context)
    }

    func search(
        _ query: ContentSearchQuery,
        filters: ProjectSearchQuery?,
        regexForWords: Bool,
        wholeWordForWords: Bool,
        context: QueryContext
    ) throws -> AsyncThrowingStream<SearchBatch, Error> {
        guard !query.pattern.isEmpty else {
            throw SnapshotSearchError.emptyPattern
        }
        guard context.snapshotID == source.manifest.snapshotID else {
            throw EngineError.snapshotMismatch(
                expected: source.manifest.snapshotID,
                actual: context.snapshotID
            )
        }
        let wordBoundary = query.wholeWord
            ? WordBoundary(allowsDollar: language == .typescript) : nil
        let regularExpression: NSRegularExpression?
        if query.isRegex {
            regularExpression = try NSRegularExpression(
                pattern: query.pattern,
                options: query.caseSensitive ? [] : [.caseInsensitive]
            )
        } else {
            regularExpression = nil
        }
        let literalPattern = Array(query.pattern.utf8)
        let exclusionTerms = filters?.excludes ?? []
        let exclusionRegexes = try exclusionTerms.map { term -> NSRegularExpression? in
            guard term.kind == .regex || (term.kind == .word && regexForWords) else { return nil }
            return try NSRegularExpression(pattern: term.text, options: query.caseSensitive ? [] : [.caseInsensitive])
        }


        let source = source
        let candidates = activeFiles().map(\.file)
        let includes = query.includeGlobs.compactMap(PathGlob.init)
        let excludes = query.excludeGlobs.compactMap(PathGlob.init)
        let files = candidates.filter { file in
            guard let path = source.path(for: file.pathID) else { return false }
            return (includes.isEmpty || includes.contains { $0.matches(path) })
                && !excludes.contains { $0.matches(path) }
        }
        let searchedPathCount = files.count
        let excludedPathCount = candidates.count - files.count
        let wallClockLimit = wallClockLimit
        let matchesPerFile = searchMatchesPerFile
        let totalMatches = searchTotalMatches
        let batchInterval = batchInterval
        let workerCount = workerCount
        let needsRegions = !(filters?.includedAreas.isEmpty ?? true) || !(filters?.excludedAreas.isEmpty ?? true)
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let startedAt = ContinuousClock.now
                let filesByContent = Dictionary(grouping: files, by: \.contentID)
                var seenContentIDs: Set<ContentID> = []
                // Equal bytes can have different syntax in .ts and .tsx. Region
                // filters must use each path's actual index; plain text can deduplicate.
                let scanGroups = needsRegions ? files.map { [$0] } : files.compactMap {
                    seenContentIDs.insert($0.contentID).inserted ? filesByContent[$0.contentID] : nil
                }
                let allPathIDs = Set(files.map(\.pathID))
                var processedPathIDs: Set<PathID> = []
                var truncatedPathIDs: Set<PathID> = []
                var regexSkippedPathIDs: Set<PathID> = []
                var truncatedConditionIndices: Set<Int> = []
                var completeness = Completeness.complete
                var totalMatchCount = 0
                var batchMatches: [PathID: [SearchMatch]] = [:]
                var batchMatchCount = 0
                var hasSentResults = false
                var lastSentAt = startedAt
                var flushTask: Task<Void, Never>?
                defer { flushTask?.cancel() }

                func flush(isFinal: Bool) {
                    guard !Task.isCancelled else { return }
                    flushTask?.cancel()
                    flushTask = nil
                    continuation.yield(SearchBatch(
                        matchesByPath: batchMatches,
                        isFinal: isFinal,
                        completeness: completeness,
                        truncatedPathIDs: truncatedPathIDs,
                        searchedPathCount: searchedPathCount,
                        excludedPathCount: excludedPathCount,
                        regexSkippedPathCount: regexSkippedPathIDs.count,
                        truncatedConditionIndices: truncatedConditionIndices
                    ))
                    hasSentResults = hasSentResults || !batchMatches.isEmpty
                    lastSentAt = .now
                    batchMatches.removeAll(keepingCapacity: true)
                    batchMatchCount = 0
                }

                let events = AsyncThrowingStream<ScanEvent, Error>.makeStream()
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        defer {
                            group.cancelAll()
                            events.continuation.finish()
                        }
                        let count = min(workerCount, scanGroups.count)
                        for worker in 0..<count {
                            let lower = worker * scanGroups.count / count
                            let upper = (worker + 1) * scanGroups.count / count
                            group.addTask {
                                defer { events.continuation.yield(.workerFinished) }
                                for offset in lower..<upper {
                                    try Task.checkCancellation()
                                    if Self.expired(startedAt, limit: wallClockLimit) { return }
                                    let bytes = source.bytes(for: scanGroups[offset][0].contentID)
                                    try Task.checkCancellation()
                                    if Self.expired(startedAt, limit: wallClockLimit) { return }
                                    var ranges: [ByteRange]?
                                    var skippedRegex = false
                                    var incompleteConditions: Set<Int> = []
                                    if let bytes {
                                        let index = needsRegions ? source.searchIndex(for: scanGroups[offset][0].pathID) : nil
                                        let accepts: (ByteRange) -> Bool = { range in
                                            guard needsRegions, let filters else { return true }
                                            let area = Self.area(at: range.lowerBound, index: index)
                                            return (filters.includedAreas.isEmpty || filters.includedAreas.contains(area))
                                                && !filters.excludedAreas.contains(area)
                                        }
                                        var mayInclude = !needsRegions || index != nil
                                        if !mayInclude { incompleteConditions.formUnion(0...exclusionTerms.count) }
                                        // Negative predicates only ask whether a match exists in this file.
                                        // They never consume the positive match budget.
                                        for (number, term) in exclusionTerms.enumerated() where mayInclude {
                                            let boundary = wholeWordForWords && term.kind == .word ? WordBoundary(allowsDollar: language == .typescript) : nil
                                            let excluded: [ByteRange]
                                            if let regex = exclusionRegexes[number] {
                                                guard bytes.count <= Self.regexContentBytes,
                                                      let string = String(bytes: bytes, encoding: .utf8) else {
                                                    mayInclude = false
                                                    skippedRegex = true
                                                    incompleteConditions.insert(number + 1)
                                                    break
                                                }
                                                excluded = Self.regexRanges(regex, string: string,
                                                    accepting: { accepts($0) && (boundary?.isWholeWord($0, in: bytes) ?? true) },
                                                    startedAt: startedAt, wallClockLimit: wallClockLimit, maximumMatches: 0)
                                            } else {
                                                excluded = try literalRanges(Array(term.text.utf8), in: bytes,
                                                    caseSensitive: query.caseSensitive, wordBoundary: boundary,
                                                    maximumMatches: 0, accepting: accepts,
                                                    wallClockExpired: { Self.expired(startedAt, limit: wallClockLimit) })
                                            }
                                            try Task.checkCancellation()
                                            if Self.expired(startedAt, limit: wallClockLimit) { return }
                                            if !excluded.isEmpty { mayInclude = false; ranges = [] }
                                        }
                                        if mayInclude {
                                            if let regularExpression {
                                                if bytes.count <= Self.regexContentBytes,
                                                   let string = String(bytes: bytes, encoding: .utf8) {
                                                    ranges = Self.regexRanges(regularExpression, string: string,
                                                        accepting: { accepts($0) && (wordBoundary?.isWholeWord($0, in: bytes) ?? true) },
                                                        startedAt: startedAt, wallClockLimit: wallClockLimit, maximumMatches: matchesPerFile)
                                                } else { skippedRegex = true; incompleteConditions.insert(0) }
                                            } else {
                                                ranges = try literalRanges(literalPattern, in: bytes,
                                                    caseSensitive: query.caseSensitive, wordBoundary: wordBoundary,
                                                    maximumMatches: matchesPerFile,
                                                    accepting: needsRegions ? accepts : nil,
                                                    wallClockExpired: { Self.expired(startedAt, limit: wallClockLimit) })
                                            }
                                        }
                                    } else { incompleteConditions.formUnion(0...exclusionTerms.count) }
                                    try Task.checkCancellation()
                                    if Self.expired(startedAt, limit: wallClockLimit) { return }
                                    events.continuation.yield(.content(offset, bytes, ranges, regexSkipped: skippedRegex, incompleteConditions: incompleteConditions))
                                }
                            }
                        }
                        var finishedWorkers = 0
                        var nextContent = 0
                        var pending: [Int: (bytes: [UInt8]?, ranges: [ByteRange]?, regexSkipped: Bool, incompleteConditions: Set<Int>)] = [:]
                        if count == 0 { return }
                        eventLoop: for try await event in events.stream {
                            try Task.checkCancellation()
                            if Self.expired(startedAt, limit: wallClockLimit) { break }
                            switch event {
                            case .flush:
                                if !batchMatches.isEmpty { flush(isFinal: false) }
                            case .workerFinished:
                                finishedWorkers += 1
                                if finishedWorkers == count { break eventLoop }
                            case let .content(offset, bytes, ranges, regexSkipped, incompleteConditions):
                                pending[offset] = (bytes, ranges, regexSkipped, incompleteConditions)
                                while let scanned = pending.removeValue(forKey: nextContent) {
                                    try Task.checkCancellation()
                                    if Self.expired(startedAt, limit: wallClockLimit) { break eventLoop }
                                    let occurrences = scanGroups[nextContent]
                                    nextContent += 1
                                    guard let bytes = scanned.bytes, let ranges = scanned.ranges else {
                                        if scanned.regexSkipped {
                                            regexSkippedPathIDs.formUnion(occurrences.map(\.pathID))
                                        }
                                        completeness = .truncated
                                        truncatedConditionIndices.formUnion(scanned.incompleteConditions)
                                        truncatedPathIDs.formUnion(occurrences.map(\.pathID))
                                        processedPathIDs.formUnion(occurrences.map(\.pathID))
                                        continue
                                    }
                                    guard !ranges.isEmpty else {
                                        processedPathIDs.formUnion(occurrences.map(\.pathID))
                                        continue
                                    }
                                    let fileWasTruncated = ranges.count > matchesPerFile
                                    let visibleRanges = ranges.prefix(matchesPerFile)
                                    let lineTable = LineTable(bytes: bytes)
                                    for occurrence in occurrences {
                                        try Task.checkCancellation()
                                        if Self.expired(startedAt, limit: wallClockLimit) { break eventLoop }
                                        let remaining = totalMatches - totalMatchCount
                                        let projectedRanges = visibleRanges.prefix(max(0, remaining))
                                        let matches = projectedRanges.compactMap { range -> SearchMatch? in
                                            guard let coordinate = lineTable.lineColumn(at: range.lowerBound)
                                            else { return nil }
                                            let excerpt = Self.lineExcerpt(in: bytes, range: range, lineTable: lineTable)
                                            return SearchMatch(
                                                pathID: occurrence.pathID,
                                                byteRange: range,
                                                line: coordinate.line,
                                                column: coordinate.column,
                                                lineText: excerpt.text,
                                                lineTextRange: excerpt.range
                                            )
                                        }
                                        processedPathIDs.insert(occurrence.pathID)
                                        batchMatches[occurrence.pathID] = matches
                                        batchMatchCount += matches.count
                                        totalMatchCount += matches.count
                                        if fileWasTruncated || matches.count < visibleRanges.count {
                                            truncatedConditionIndices.insert(0)
                                            completeness = .truncated
                                            truncatedPathIDs.insert(occurrence.pathID)
                                        }
                                        if !hasSentResults || batchMatches.count >= Self.filesPerBatch
                                            || batchMatchCount >= Self.matchesPerBatch
                                            || lastSentAt.duration(to: .now) >= batchInterval {
                                            flush(isFinal: false)
                                        } else if flushTask == nil {
                                            let deadline = lastSentAt.advanced(by: batchInterval)
                                            flushTask = Task {
                                                do {
                                                    try await ContinuousClock().sleep(until: deadline)
                                                    try Task.checkCancellation()
                                                    events.continuation.yield(.flush)
                                                } catch {}
                                            }
                                        }
                                        if totalMatchCount == totalMatches {
                                            break eventLoop
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !Task.isCancelled {
                        let unprocessed = allPathIDs.subtracting(processedPathIDs)
                        if !unprocessed.isEmpty {
                            truncatedConditionIndices.insert(0)
                            if Self.expired(startedAt, limit: wallClockLimit) {
                                truncatedConditionIndices.formUnion(1..<(exclusionTerms.count + 1))
                            }
                            completeness = .truncated
                            truncatedPathIDs.formUnion(unprocessed)
                        }
                        flush(isFinal: true)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func searchReferences(
        _ query: ContentSearchQuery,
        excludingPathID: PathID,
        excludingRange: ByteRange,
        context: QueryContext
    ) throws -> AsyncThrowingStream<SearchBatch, Error> {
        guard !query.pattern.isEmpty else {
            throw SnapshotSearchError.emptyPattern
        }
        guard context.snapshotID == source.manifest.snapshotID else {
            throw EngineError.snapshotMismatch(
                expected: source.manifest.snapshotID,
                actual: context.snapshotID
            )
        }
        let pattern = Array(query.pattern.utf8)
        let source = source
        let extractor = extractor
        let keyedFiles = activeFiles().map { item in
            (
                file: item.file,
                key: ContentIndexKey(
                    contentID: item.file.contentID,
                    languageMode: item.mode,
                    grammarVersion: extractor.grammarVersion,
                    extractorVersion: extractor.extractorVersion
                )
            )
        }
        let wallClockLimit = wallClockLimit
        #if DEBUG
        let parseObserver = RustExtractor.parseObserver
        #endif
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let startedAt = ContinuousClock.now
                    let filesByKey = Dictionary(grouping: keyedFiles, by: \.key)
                    var seenKeys: Set<ContentIndexKey> = []
                    let keys = keyedFiles.compactMap {
                        seenKeys.insert($0.key).inserted ? $0.key : nil
                    }
                    let allPathIDs = Set(keyedFiles.map(\.file.pathID))
                    var processedPathIDs: Set<PathID> = []
                    var truncatedPathIDs: Set<PathID> = []
                    var completeness = Completeness.complete
                    var totalMatchCount = 0
                    var batchMatches: [PathID: [SearchMatch]] = [:]
                    var batchMatchCount = 0

                    func flush(isFinal: Bool) {
                        continuation.yield(SearchBatch(
                            matchesByPath: batchMatches,
                            isFinal: isFinal,
                            completeness: completeness,
                            truncatedPathIDs: truncatedPathIDs
                        ))
                        batchMatches.removeAll(keepingCapacity: true)
                        batchMatchCount = 0
                    }

                    contentLoop: for key in keys {
                        try Task.checkCancellation()
                        if Self.expired(startedAt, limit: wallClockLimit) {
                            completeness = .truncated
                            truncatedPathIDs.formUnion(
                                allPathIDs.subtracting(processedPathIDs)
                            )
                            break
                        }

                        let occurrences = (filesByKey[key] ?? []).map(\.file)
                        guard let bytes = source.bytes(for: key.contentID) else {
                            completeness = .truncated
                            truncatedPathIDs.formUnion(occurrences.map(\.pathID))
                            processedPathIDs.formUnion(occurrences.map(\.pathID))
                            continue
                        }
                        try Task.checkCancellation()
                        if Self.expired(startedAt, limit: wallClockLimit) {
                            completeness = .truncated
                            truncatedPathIDs.formUnion(
                                allPathIDs.subtracting(processedPathIDs)
                            )
                            break
                        }

                        let rawRanges = try literalRanges(
                            pattern,
                            in: bytes,
                            caseSensitive: query.caseSensitive,
                            maximumMatches: nil,
                            wallClockExpired: {
                                Self.expired(startedAt, limit: wallClockLimit)
                            }
                        )
                        try Task.checkCancellation()
                        if Self.expired(startedAt, limit: wallClockLimit) {
                            completeness = .truncated
                            truncatedPathIDs.formUnion(
                                allPathIDs.subtracting(processedPathIDs)
                            )
                            break
                        }
                        if rawRanges.isEmpty {
                            processedPathIDs.formUnion(occurrences.map(\.pathID))
                            continue
                        }

                        #if DEBUG
                        let identifiers = try RustExtractor.$parseObserver.withValue(
                            parseObserver
                        ) {
                            try extractor.identifierRanges(
                                named: query.pattern,
                                in: bytes,
                                mode: key.languageMode
                            )
                        }
                        #else
                        let identifiers = try extractor.identifierRanges(
                            named: query.pattern,
                            in: bytes,
                            mode: key.languageMode
                        )
                        #endif
                        let identifierOffsets = Set(identifiers.map(\.lowerBound))
                        let verifiedRanges = rawRanges.filter {
                            identifierOffsets.contains($0.lowerBound)
                        }
                        let lineTable = LineTable(bytes: bytes)

                        for occurrence in occurrences {
                            try Task.checkCancellation()

                            let references = verifiedRanges.filter {
                                occurrence.pathID != excludingPathID
                                    || $0 != excludingRange
                            }
                            let fileWasTruncated = references.count
                                > Self.matchesPerFile
                            let visibleRanges = references.prefix(Self.matchesPerFile)
                            let remaining = Self.totalMatches - totalMatchCount
                            let projectedRanges = visibleRanges.prefix(max(0, remaining))
                            let matches = projectedRanges.compactMap {
                                range -> SearchMatch? in
                                guard let coordinate = lineTable.lineColumn(
                                    at: range.lowerBound
                                ) else { return nil }
                                let excerpt = Self.lineExcerpt(
                                    in: bytes,
                                    range: range,
                                    lineTable: lineTable
                                )
                                return SearchMatch(
                                    pathID: occurrence.pathID,
                                    byteRange: range,
                                    line: coordinate.line,
                                    column: coordinate.column,
                                    lineText: excerpt.text,
                                    lineTextRange: excerpt.range
                                )
                            }
                            processedPathIDs.insert(occurrence.pathID)
                            if !matches.isEmpty {
                                batchMatches[occurrence.pathID] = matches
                                batchMatchCount += matches.count
                                totalMatchCount += matches.count
                            }
                            if fileWasTruncated || matches.count < visibleRanges.count {
                                completeness = .truncated
                                truncatedPathIDs.insert(occurrence.pathID)
                            }

                            if batchMatches.count >= Self.filesPerBatch
                                || batchMatchCount >= Self.matchesPerBatch
                            {
                                flush(isFinal: false)
                            }

                            if totalMatchCount == Self.totalMatches {
                                let unprocessed = allPathIDs.subtracting(
                                    processedPathIDs
                                )
                                if !unprocessed.isEmpty {
                                    completeness = .truncated
                                    truncatedPathIDs.formUnion(unprocessed)
                                    break contentLoop
                                }
                            }
                        }
                    }

                    flush(isFinal: true)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func activeFiles() -> [(
        file: FileOccurrence,
        mode: LanguageMode
    )] {
        source.manifest.files.compactMap { file in
            guard source.searchIncludes(pathID: file.pathID),
                  let path = source.path(for: file.pathID),
                  let mode = LanguageMode.classify(path: path, language: language)
            else { return nil }
            return (file, mode)
        }
    }

    static func regexRanges(
        _ regex: NSRegularExpression,
        string: String,
        accepting accepts: (ByteRange) -> Bool,
        startedAt: ContinuousClock.Instant,
        wallClockLimit: Duration,
        maximumMatches: Int = Self.matchesPerFile
    ) -> [ByteRange] {
        var ranges: [ByteRange] = []
        var progressCallbacks = 0
        regex.enumerateMatches(
            in: string,
            options: .reportProgress,
            range: NSRange(string.startIndex..., in: string)
        ) { result, _, stop in
            if result == nil {
                // Foundation can report progress at every candidate position.
                // Sample these callbacks; always check when a match is delivered.
                progressCallbacks += 1
                guard progressCallbacks & 63 == 0 else { return }
            }
            guard !Task.isCancelled, !expired(startedAt, limit: wallClockLimit) else {
                stop.pointee = true
                return
            }
            guard let result else { return }
            guard let range = Range(result.range, in: string),
                  let lower = range.lowerBound.samePosition(in: string.utf8),
                  let upper = range.upperBound.samePosition(in: string.utf8),
                  let lowerBound = UInt32(exactly: string.utf8.distance(
                    from: string.utf8.startIndex,
                    to: lower
                  )),
                  let upperBound = UInt32(exactly: string.utf8.distance(
                    from: string.utf8.startIndex,
                    to: upper
                  ))
            else {
                stop.pointee = true
                return
            }
            let hit = ByteRange(lowerBound: lowerBound, upperBound: upperBound)
            guard accepts(hit) else { return }
            ranges.append(hit)
            if ranges.count > maximumMatches { stop.pointee = true }
        }
        return ranges
    }

    static func lineExcerpt(
        in bytes: [UInt8],
        range: ByteRange,
        lineTable: LineTable
    ) -> (text: String, range: ByteRange) {
        guard let coordinate = lineTable.lineColumn(at: range.lowerBound) else {
            return ("", range)
        }
        let lineIndex = Int(coordinate.line - 1)
        let lineStart = Int(lineTable.lineStarts[lineIndex])
        var lineEnd = lineIndex + 1 < lineTable.lineStarts.count
            ? Int(lineTable.lineStarts[lineIndex + 1]) - 1
            : bytes.count
        if lineEnd > lineStart && bytes[lineEnd - 1] == 0x0D {
            lineEnd -= 1
        }

        let maximumBytes = 240
        var excerptStart = lineStart
        var excerptEnd = lineEnd
        if lineEnd - lineStart > maximumBytes {
            let hitStart = Int(range.lowerBound)
            let hitEnd = min(Int(range.upperBound), lineEnd)
            let center = hitStart + max(0, hitEnd - hitStart) / 2
            excerptStart = min(
                max(lineStart, center - maximumBytes / 2),
                lineEnd - maximumBytes
            )
            excerptEnd = excerptStart + maximumBytes
        }
        return (
            String(decoding: bytes[excerptStart..<excerptEnd], as: UTF8.self),
            ByteRange(
                lowerBound: UInt32(excerptStart),
                upperBound: UInt32(excerptEnd)
            )
        )
    }

    static func expired(
        _ startedAt: ContinuousClock.Instant,
        limit: Duration
    ) -> Bool {
        startedAt.duration(to: .now) >= limit
    }
}

extension EngineSession: SnapshotContentSource {
    public func searchIndex(for pathID: PathID) -> ContentIndex? { content(at: pathID)?.1 }
    public func searchName(for nameID: NameID) -> String? { names.resolve(nameID) }
    public var searchProjectExcludedPathCount: Int? { manifest.ruleExcludedPathCount }
    public func searchIncludes(pathID: PathID) -> Bool { activePathIDs.contains(pathID) }

    public func path(for pathID: PathID) -> String? {
        paths.resolve(pathID)
    }

    public func bytes(for contentID: ContentID) -> [UInt8]? {
        sourceBytesByContent[contentID]
    }

    public func search(
        _ query: ContentSearchQuery,
        context: QueryContext
    ) throws -> AsyncThrowingStream<SearchBatch, Error> {
        try validate(context)
        return try SnapshotSearchService(
            source: self,
            language: analysisProfile.language,
            extractor: extractor
        ).search(query, context: context)
    }

    public func searchReferences(
        _ query: ContentSearchQuery,
        excludingPathID: PathID,
        excludingRange: ByteRange,
        context: QueryContext
    ) throws -> AsyncThrowingStream<SearchBatch, Error> {
        try validate(context)
        return try SnapshotSearchService(
            source: self,
            language: analysisProfile.language,
            extractor: extractor
        ).searchReferences(
            query,
            excludingPathID: excludingPathID,
            excludingRange: excludingRange,
            context: context
        )
    }
}
