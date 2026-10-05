import CodeInsightCore
import CodeInsightRustExtractor
import Foundation

public protocol SnapshotContentSource: Sendable {
    var manifest: SnapshotManifest { get }
    func path(for pathID: PathID) -> String?
    func bytes(for contentID: ContentID) -> [UInt8]?
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

    public init(
        pathID: PathID,
        byteRange: ByteRange,
        line: UInt32,
        column: UInt32,
        lineText: String,
        lineTextRange: ByteRange
    ) {
        self.pathID = pathID
        self.byteRange = byteRange
        self.line = line
        self.column = column
        self.lineText = lineText
        self.lineTextRange = lineTextRange
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

    public init(
        matchesByPath: [PathID: [SearchMatch]],
        isFinal: Bool,
        completeness: Completeness,
        truncatedPathIDs: Set<PathID> = [],
        searchedPathCount: Int = 0,
        excludedPathCount: Int = 0
    ) {
        self.matchesByPath = matchesByPath
        self.isFinal = isFinal
        self.completeness = completeness
        self.truncatedPathIDs = truncatedPathIDs
        self.searchedPathCount = searchedPathCount
        self.excludedPathCount = excludedPathCount
    }
}

public enum SnapshotSearchError: Error {
    case emptyPattern
}

public struct SnapshotSearchService: Sendable {
    private static let matchesPerFile = 200
    private static let totalMatches = 5_000
    private static let regexContentBytes = 4 * 1_024 * 1_024
    private static let filesPerBatch = 16
    private static let matchesPerBatch = 200

    private let source: any SnapshotContentSource
    private let language: LanguageID
    private let extractor: any LanguageExtractor
    private let wallClockLimit: Duration
    private let workerCount: Int
    private let searchMatchesPerFile: Int
    private let searchTotalMatches: Int

    // Workers report ranges; only the consumer projects and publishes ordered results.
    private enum ScanEvent: Sendable {
        case content(Int, [UInt8]?, [ByteRange]?)
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
        self.workerCount = workerCount
        searchMatchesPerFile = matchesPerFile
        searchTotalMatches = totalMatches
    }

    public func search(
        _ query: ContentSearchQuery,
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
        let workerCount = workerCount
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let startedAt = ContinuousClock.now
                let filesByContent = Dictionary(grouping: files, by: \.contentID)
                var seenContentIDs: Set<ContentID> = []
                let contentIDs = files.compactMap {
                    seenContentIDs.insert($0.contentID).inserted ? $0.contentID : nil
                }
                let allPathIDs = Set(files.map(\.pathID))
                var processedPathIDs: Set<PathID> = []
                var truncatedPathIDs: Set<PathID> = []
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
                        excludedPathCount: excludedPathCount
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
                        let count = min(workerCount, contentIDs.count)
                        for worker in 0..<count {
                            let lower = worker * contentIDs.count / count
                            let upper = (worker + 1) * contentIDs.count / count
                            group.addTask {
                                defer { events.continuation.yield(.workerFinished) }
                                for offset in lower..<upper {
                                    try Task.checkCancellation()
                                    if Self.expired(startedAt, limit: wallClockLimit) { return }
                                    let bytes = source.bytes(for: contentIDs[offset])
                                    try Task.checkCancellation()
                                    if Self.expired(startedAt, limit: wallClockLimit) { return }
                                    var ranges: [ByteRange]?
                                    if let bytes {
                                        if let regularExpression {
                                            if bytes.count <= Self.regexContentBytes,
                                               let string = String(bytes: bytes, encoding: .utf8) {
                                                ranges = Self.regexRanges(
                                                    regularExpression,
                                                    string: string,
                                                    accepting: { range in
                                                        wordBoundary?.isWholeWord(range, in: bytes) ?? true
                                                    },
                                                    startedAt: startedAt,
                                                    wallClockLimit: wallClockLimit,
                                                    maximumMatches: matchesPerFile
                                                )
                                            }
                                        } else {
                                            ranges = try literalRanges(
                                                literalPattern,
                                                in: bytes,
                                                caseSensitive: query.caseSensitive,
                                                wordBoundary: wordBoundary,
                                                maximumMatches: matchesPerFile,
                                                wallClockExpired: {
                                                    Self.expired(startedAt, limit: wallClockLimit)
                                                }
                                            )
                                        }
                                    }
                                    try Task.checkCancellation()
                                    if Self.expired(startedAt, limit: wallClockLimit) { return }
                                    events.continuation.yield(.content(offset, bytes, ranges))
                                }
                            }
                        }
                        var finishedWorkers = 0
                        var nextContent = 0
                        var pending: [Int: (bytes: [UInt8]?, ranges: [ByteRange]?)] = [:]
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
                            case let .content(offset, bytes, ranges):
                                pending[offset] = (bytes, ranges)
                                while let scanned = pending.removeValue(forKey: nextContent) {
                                    try Task.checkCancellation()
                                    if Self.expired(startedAt, limit: wallClockLimit) { break eventLoop }
                                    let occurrences = filesByContent[contentIDs[nextContent]] ?? []
                                    nextContent += 1
                                    guard let bytes = scanned.bytes, let ranges = scanned.ranges else {
                                        completeness = .truncated
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
                                            completeness = .truncated
                                            truncatedPathIDs.insert(occurrence.pathID)
                                        }
                                        if !hasSentResults || batchMatches.count >= Self.filesPerBatch
                                            || batchMatchCount >= Self.matchesPerBatch
                                            || lastSentAt.duration(to: .now) >= .milliseconds(50) {
                                            flush(isFinal: false)
                                        } else if flushTask == nil {
                                            let deadline = lastSentAt.advanced(by: .milliseconds(50))
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

    private func activeFiles() -> [(
        file: FileOccurrence,
        mode: LanguageMode
    )] {
        source.manifest.files.compactMap { file in
            guard let path = source.path(for: file.pathID),
                  let mode = LanguageMode.classify(path: path, language: language)
            else { return nil }
            return (file, mode)
        }
    }

    private static func regexRanges(
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

    private static func lineExcerpt(
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

    private static func expired(
        _ startedAt: ContinuousClock.Instant,
        limit: Duration
    ) -> Bool {
        startedAt.duration(to: .now) >= limit
    }
}

extension EngineSession: SnapshotContentSource {
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
