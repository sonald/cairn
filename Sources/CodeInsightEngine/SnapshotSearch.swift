import CodeInsightCore
import CodeInsightRustExtractor
import Foundation

public protocol SnapshotContentSource: Sendable {
    var manifest: SnapshotManifest { get }
    func bytes(for contentID: ContentID) -> [UInt8]?
}

public struct ContentSearchQuery: Sendable {
    public let pattern: String
    public let isRegex: Bool
    public let caseSensitive: Bool

    public init(
        pattern: String,
        isRegex: Bool = false,
        caseSensitive: Bool = false
    ) {
        self.pattern = pattern
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
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

    public init(
        matchesByPath: [PathID: [SearchMatch]],
        isFinal: Bool,
        completeness: Completeness,
        truncatedPathIDs: Set<PathID> = []
    ) {
        self.matchesByPath = matchesByPath
        self.isFinal = isFinal
        self.completeness = completeness
        self.truncatedPathIDs = truncatedPathIDs
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
    private let wallClockLimit: Duration

    public init(source: any SnapshotContentSource) {
        self.source = source
        wallClockLimit = .seconds(5)
    }

    init(
        source: any SnapshotContentSource,
        wallClockLimit: Duration
    ) {
        self.source = source
        self.wallClockLimit = wallClockLimit
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
        let wallClockLimit = wallClockLimit
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let startedAt = ContinuousClock.now
                let files = source.manifest.files
                let filesByContent = Dictionary(grouping: files, by: \.contentID)
                var seenContentIDs: Set<ContentID> = []
                let contentIDs = files.compactMap {
                    seenContentIDs.insert($0.contentID).inserted
                        ? $0.contentID : nil
                }
                let allPathIDs = Set(files.map(\.pathID))
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

                contentLoop: for contentID in contentIDs {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    if Self.expired(startedAt, limit: wallClockLimit) {
                        completeness = .truncated
                        truncatedPathIDs.formUnion(allPathIDs.subtracting(processedPathIDs))
                        break
                    }

                    let occurrences = filesByContent[contentID] ?? []
                    guard let bytes = source.bytes(for: contentID) else {
                        completeness = .truncated
                        truncatedPathIDs.formUnion(occurrences.map(\.pathID))
                        processedPathIDs.formUnion(occurrences.map(\.pathID))
                        continue
                    }
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    if Self.expired(startedAt, limit: wallClockLimit) {
                        completeness = .truncated
                        truncatedPathIDs.formUnion(allPathIDs.subtracting(processedPathIDs))
                        break
                    }

                    let ranges: [ByteRange]
                    if let regularExpression {
                        guard bytes.count <= Self.regexContentBytes,
                              let string = String(bytes: bytes, encoding: .utf8)
                        else {
                            completeness = .truncated
                            truncatedPathIDs.formUnion(occurrences.map(\.pathID))
                            processedPathIDs.formUnion(occurrences.map(\.pathID))
                            continue
                        }
                        ranges = Self.regexRanges(
                            regularExpression,
                            string: string,
                            startedAt: startedAt,
                            wallClockLimit: wallClockLimit
                        )
                    } else {
                        ranges = Self.literalRanges(
                            literalPattern,
                            bytes: bytes,
                            caseSensitive: query.caseSensitive,
                            startedAt: startedAt,
                            wallClockLimit: wallClockLimit
                        )
                    }

                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    if Self.expired(startedAt, limit: wallClockLimit) {
                        completeness = .truncated
                        truncatedPathIDs.formUnion(allPathIDs.subtracting(processedPathIDs))
                        break
                    }

                    let fileWasTruncated = ranges.count > Self.matchesPerFile
                    let visibleRanges = ranges.prefix(Self.matchesPerFile)
                    let lineTable = LineTable(bytes: bytes)
                    for occurrence in occurrences {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        if Self.expired(startedAt, limit: wallClockLimit) {
                            completeness = .truncated
                            truncatedPathIDs.formUnion(
                                allPathIDs.subtracting(processedPathIDs)
                            )
                            break contentLoop
                        }

                        let remaining = Self.totalMatches - totalMatchCount
                        let projectedRanges = visibleRanges.prefix(max(0, remaining))
                        let matches = projectedRanges.compactMap { range -> SearchMatch? in
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
                            let unprocessed = allPathIDs.subtracting(processedPathIDs)
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
        let wallClockLimit = wallClockLimit
        #if DEBUG
        let parseObserver = RustExtractor.parseObserver
        #endif
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let startedAt = ContinuousClock.now
                    let files = source.manifest.files.filter {
                        $0.detectedLanguage == .rust
                    }
                    let filesByContent = Dictionary(grouping: files, by: \.contentID)
                    var seenContentIDs: Set<ContentID> = []
                    let contentIDs = files.compactMap {
                        seenContentIDs.insert($0.contentID).inserted
                            ? $0.contentID : nil
                    }
                    let allPathIDs = Set(files.map(\.pathID))
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

                    contentLoop: for contentID in contentIDs {
                        try Task.checkCancellation()
                        if Self.expired(startedAt, limit: wallClockLimit) {
                            completeness = .truncated
                            truncatedPathIDs.formUnion(
                                allPathIDs.subtracting(processedPathIDs)
                            )
                            break
                        }

                        let occurrences = filesByContent[contentID] ?? []
                        guard let bytes = source.bytes(for: contentID) else {
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

                        let rawRanges = Self.literalRanges(
                            pattern,
                            bytes: bytes,
                            caseSensitive: query.caseSensitive,
                            maximumMatches: nil,
                            startedAt: startedAt,
                            wallClockLimit: wallClockLimit
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
                            try RustExtractor().identifierRanges(
                                named: query.pattern,
                                in: bytes
                            )
                        }
                        #else
                        let identifiers = try RustExtractor().identifierRanges(
                            named: query.pattern,
                            in: bytes
                        )
                        #endif
                        let identifierOffsets = Set(identifiers.map(\.lowerBound))
                        let verifiedRanges = rawRanges.filter {
                            identifierOffsets.contains($0.lowerBound)
                        }
                        let lineTable = LineTable(bytes: bytes)

                        for occurrence in occurrences {
                            try Task.checkCancellation()
                            if Self.expired(startedAt, limit: wallClockLimit) {
                                completeness = .truncated
                                truncatedPathIDs.formUnion(
                                    allPathIDs.subtracting(processedPathIDs)
                                )
                                break contentLoop
                            }

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

    private static func literalRanges(
        _ pattern: [UInt8],
        bytes: [UInt8],
        caseSensitive: Bool,
        maximumMatches: Int? = matchesPerFile,
        startedAt: ContinuousClock.Instant,
        wallClockLimit: Duration
    ) -> [ByteRange] {
        guard pattern.count <= bytes.count else { return [] }
        var ranges: [ByteRange] = []
        var offset = 0
        return bytes.withUnsafeBufferPointer { haystack in
            pattern.withUnsafeBufferPointer { needle in
                while offset <= haystack.count - needle.count {
                    if offset & 0xFFF == 0,
                       Task.isCancelled || expired(startedAt, limit: wallClockLimit)
                    {
                        break
                    }
                    var matches = true
                    for patternOffset in needle.indices {
                        let lhs = haystack[offset + patternOffset]
                        let rhs = needle[patternOffset]
                        if caseSensitive ? lhs != rhs : asciiFold(lhs) != asciiFold(rhs) {
                            matches = false
                            break
                        }
                    }
                    if matches {
                        ranges.append(ByteRange(
                            lowerBound: UInt32(offset),
                            upperBound: UInt32(offset + needle.count)
                        ))
                        if let maximumMatches,
                           ranges.count > maximumMatches
                        {
                            break
                        }
                        offset += needle.count
                    } else {
                        offset += 1
                    }
                }
                return ranges
            }
        }
    }

    private static func regexRanges(
        _ regex: NSRegularExpression,
        string: String,
        startedAt: ContinuousClock.Instant,
        wallClockLimit: Duration
    ) -> [ByteRange] {
        var ranges: [ByteRange] = []
        regex.enumerateMatches(
            in: string,
            range: NSRange(string.startIndex..., in: string)
        ) { result, _, stop in
            guard !Task.isCancelled,
                  !expired(startedAt, limit: wallClockLimit),
                  let result,
                  let range = Range(result.range, in: string),
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
            ranges.append(ByteRange(
                lowerBound: lowerBound,
                upperBound: upperBound
            ))
            if ranges.count > matchesPerFile { stop.pointee = true }
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

    private static func asciiFold(_ byte: UInt8) -> UInt8 {
        (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
    }

    private static func expired(
        _ startedAt: ContinuousClock.Instant,
        limit: Duration
    ) -> Bool {
        startedAt.duration(to: .now) >= limit
    }
}

extension EngineSession: SnapshotContentSource {
    public func bytes(for contentID: ContentID) -> [UInt8]? {
        sourceBytesByContent[contentID]
    }

    public func search(
        _ query: ContentSearchQuery,
        context: QueryContext
    ) throws -> AsyncThrowingStream<SearchBatch, Error> {
        try validate(context)
        return try SnapshotSearchService(source: self).search(query, context: context)
    }

    public func searchReferences(
        _ query: ContentSearchQuery,
        excludingPathID: PathID,
        excludingRange: ByteRange,
        context: QueryContext
    ) throws -> AsyncThrowingStream<SearchBatch, Error> {
        try validate(context)
        return try SnapshotSearchService(source: self).searchReferences(
            query,
            excludingPathID: excludingPathID,
            excludingRange: excludingRange,
            context: context
        )
    }
}
