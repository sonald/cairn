import CodeInsightCore
import Foundation

extension SnapshotSearchService {
    public func search(
        _ query: ProjectSearchQuery,
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        isRegex: Bool = false,
        context: QueryContext
    ) throws -> AsyncThrowingStream<SearchBatch, Error> {
        guard !query.includes.isEmpty else { throw SnapshotSearchError.emptyPattern }
        guard context.snapshotID == source.manifest.snapshotID else {
            throw EngineError.snapshotMismatch(expected: source.manifest.snapshotID, actual: context.snapshotID)
        }
        let nonSourceCount = source.manifest.nonSourcePathCount ?? source.manifest.files.filter { file in
            guard let path = source.path(for: file.pathID) else { return false }
            return ![LanguageID.rust, .python, .typescript].contains {
                LanguageMode.classify(path: path, language: $0) != nil
            }
        }.count
        // Keep the parallel scanner and its immediate first batch for simple searches.
        if !query.groupsMatchesByLine {
            let term = query.includes[0][0]
            let stream = try search(ContentSearchQuery(pattern: term.text,
                isRegex: term.kind == .regex || (term.kind == .word && isRegex),
                caseSensitive: caseSensitive, wholeWord: term.kind == .word && wholeWord,
                includeGlobs: query.includeGlobs, excludeGlobs: query.excludeGlobs),
                filters: query, regexForWords: isRegex, wholeWordForWords: wholeWord, context: context)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        for try await batch in stream {
                            var matches: [PathID: [SearchMatch]] = [:]
                            for (path, hits) in batch.matchesByPath {
                                let index = source.searchIndex(for: path)
                                let facets = symbolFacets(index: index)
                                matches[path] = hits.map { hit in
                                    SearchMatch(pathID: path, byteRange: hit.byteRange, line: hit.line,
                                        column: hit.column, lineText: hit.lineText, lineTextRange: hit.lineTextRange,
                                        conditionIndices: [0], conditionRanges: [0: [hit.byteRange]], symbolName: symbolName(at: hit.byteRange.lowerBound, index: index, facets: facets))
                                }
                            }
                            continuation.yield(SearchBatch(matchesByPath: matches, isFinal: batch.isFinal,
                                completeness: batch.completeness, truncatedPathIDs: batch.truncatedPathIDs,
                                searchedPathCount: batch.searchedPathCount, excludedPathCount: batch.excludedPathCount,
                                searchedLanguages: [language], nonSourcePathCount: nonSourceCount,
                                projectExcludedPathCount: source.searchProjectExcludedPathCount,
                                regexSkippedPathCount: batch.regexSkippedPathCount,
                                truncatedConditionIndices: batch.truncatedConditionIndices))
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        let conditions = query.includes + query.excludes.map { [$0] }
        let regexes = try conditions.map { terms in
            try terms.map { term -> NSRegularExpression? in
                guard term.kind == .regex || (term.kind == .word && isRegex) else { return nil }
                return try NSRegularExpression(pattern: term.text, options: caseSensitive ? [] : [.caseInsensitive])
            }
        }
        let includes = query.includeGlobs.compactMap(PathGlob.init)
        let excludes = query.excludeGlobs.compactMap(PathGlob.init)
        let candidates = activeFiles().map(\.file)
        let files = candidates.filter {
            guard let path = source.path(for: $0.pathID) else { return false }
            return (includes.isEmpty || includes.contains { $0.matches(path) }) && !excludes.contains { $0.matches(path) }
        }
        let stream = AsyncThrowingStream<SearchBatch, Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    var totals = Array(repeating: 0, count: conditions.count)
                    var elapsed = Array(repeating: Duration.zero, count: conditions.count)
                    var truncatedConditions: Set<Int> = []
                    var truncatedPaths: Set<PathID> = []
                    var regexSkippedPaths: Set<PathID> = []
                    var batch: [PathID: [SearchMatch]] = [:]
                    var evaluationElapsed = Duration.zero
                    func flush(final: Bool) {
                        continuation.yield(SearchBatch(matchesByPath: batch, isFinal: final,
                            completeness: truncatedConditions.isEmpty ? .complete : .truncated,
                            truncatedPathIDs: truncatedPaths, searchedPathCount: files.count,
                            excludedPathCount: candidates.count - files.count, searchedLanguages: [language],
                            nonSourcePathCount: nonSourceCount, projectExcludedPathCount: source.searchProjectExcludedPathCount,
                            regexSkippedPathCount: regexSkippedPaths.count, truncatedConditionIndices: truncatedConditions))
                        batch.removeAll(keepingCapacity: true)
                    }
                    for file in files {
                        try Task.checkCancellation()
                        guard evaluationElapsed < wallClockLimit else {
                            truncatedPaths.insert(file.pathID)
                            truncatedConditions.formUnion(query.includes.indices)
                            continue
                        }
                        guard let bytes = source.bytes(for: file.contentID) else {
                            truncatedPaths.insert(file.pathID)
                            truncatedConditions.formUnion(conditions.indices)
                            continue
                        }
                        let index = source.searchIndex(for: file.pathID)
                        if index == nil && (query.sameFunction || !query.includedAreas.isEmpty || !query.excludedAreas.isEmpty) {
                            truncatedPaths.insert(file.pathID)
                            truncatedConditions.formUnion(conditions.indices)
                            continue
                        }
                        let lineTable = index?.lineTable ?? LineTable(bytes: bytes)
                        let scopes = query.sameFunction ? Self.functionScopes(index: index) : []
                        var excludedLines: [ScopeID?: Set<Int>] = [:]
                        var excludesWholeFile = false
                        var hits: [[ByteRange]] = []
                        var exclusionsConfirmed = true
                        for condition in conditions.indices {
                            try Task.checkCancellation()
                            let isExclusion = condition >= query.includes.count
                            guard (isExclusion || totals[condition] < searchTotalMatches), elapsed[condition] < wallClockLimit else {
                                if isExclusion { exclusionsConfirmed = false }
                                truncatedConditions.insert(condition)
                                truncatedPaths.insert(file.pathID)
                                hits.append([])
                                continue
                            }
                            let start = ContinuousClock.now
                            let remainingTime = wallClockLimit - elapsed[condition]
                            var ranges: Set<ByteRange> = []
                            let accepts: (ByteRange) -> Bool = { range in
                                let area = Self.area(at: range.lowerBound, index: index)
                                guard (query.includedAreas.isEmpty || query.includedAreas.contains(area)),
                                      !query.excludedAreas.contains(area) else { return false }
                                if isExclusion && (query.near != nil || query.sameFunction) {
                                    let unit = query.sameFunction ? Self.functionUnit(at: range.lowerBound, scopes: scopes) : nil
                                    guard !query.sameFunction || unit != nil else { return false }
                                    // One presence per line/unit suffices; never materialize every
                                    // exclusion occurrence or spend the positive match budget on it.
                                    let line = query.near == nil ? 0 : Int(lineTable.lineColumn(at: range.lowerBound)?.line ?? 0)
                                    excludedLines[unit, default: []].insert(line)
                                    return false
                                }
                                return true
                            }
                            for (alternative, term) in conditions[condition].enumerated() {
                                let boundary = wholeWord && term.kind == .word ? WordBoundary(allowsDollar: language == .typescript) : nil
                                let found: [ByteRange]
                                if let regex = regexes[condition][alternative] {
                                    guard bytes.count <= Self.regexContentBytes, let string = String(bytes: bytes, encoding: .utf8) else {
                                        if isExclusion { exclusionsConfirmed = false }
                                        regexSkippedPaths.insert(file.pathID)
                                        truncatedConditions.insert(condition)
                                        truncatedPaths.insert(file.pathID)
                                        continue
                                    }
                                    found = Self.regexRanges(regex, string: string,
                                        accepting: { (boundary?.isWholeWord($0, in: bytes) ?? true) && accepts($0) },
                                        startedAt: start, wallClockLimit: remainingTime,
                                        maximumMatches: isExclusion ? (query.near == nil && !query.sameFunction ? 0 : Int.max) : searchMatchesPerFile)
                                } else {
                                    found = try literalRanges(Array(term.text.utf8), in: bytes,
                                        caseSensitive: caseSensitive, wordBoundary: boundary,
                                        maximumMatches: isExclusion ? (query.near == nil && !query.sameFunction ? 0 : nil) : searchMatchesPerFile, accepting: accepts,
                                        wallClockExpired: { Self.expired(start, limit: remainingTime) })
                                }
                                ranges.formUnion(found)
                            }
                            elapsed[condition] += start.duration(to: .now)
                            if isExclusion && elapsed[condition] >= wallClockLimit { exclusionsConfirmed = false }
                            let limit = isExclusion ? ranges.count : min(searchMatchesPerFile, searchTotalMatches - totals[condition])
                            if ranges.count > limit || elapsed[condition] >= wallClockLimit {
                                truncatedConditions.insert(condition)
                                truncatedPaths.insert(file.pathID)
                            }
                            let kept = Array(ranges.sorted { $0.lowerBound == $1.lowerBound ? $0.upperBound < $1.upperBound : $0.lowerBound < $1.lowerBound }.prefix(limit))
                            if isExclusion && !kept.isEmpty { excludesWholeFile = true }
                            if !isExclusion { totals[condition] += kept.count }
                            hits.append(kept)
                        }
                        // An unfinished negative predicate is unknown, not false.
                        guard exclusionsConfirmed, !excludesWholeFile else { continue }
                        let evaluationStart = ContinuousClock.now
                        let evaluationLimit = wallClockLimit - evaluationElapsed
                        let excludedPositions = excludedLines.mapValues { $0.sorted() }
                        let lines = hits.map { $0.map { Int(lineTable.lineColumn(at: $0.lowerBound)?.line ?? 0) } }
                        let units = query.sameFunction ? hits.map { $0.map { Self.functionUnit(at: $0.lowerBound, scopes: scopes) } } : []
                        var rows: [UInt32: (range: ByteRange, ranges: [Int: [ByteRange]])] = [:]
                        var evaluationExpired = false
                        evaluating: for condition in query.includes.indices {
                            for (position, range) in hits[condition].enumerated() {
                                try Task.checkCancellation()
                                if Self.expired(evaluationStart, limit: evaluationLimit) {
                                    evaluationExpired = true
                                    break evaluating
                                }
                                let unit = query.sameFunction ? units[condition][position] : nil
                                if query.sameFunction && unit == nil { continue }
                                func inUnit(_ otherCondition: Int, _ otherPosition: Int) -> Bool {
                                    if query.sameFunction && units[otherCondition][otherPosition] != unit { return false }
                                    if let near = query.near, abs(lines[otherCondition][otherPosition] - lines[condition][position]) > near { return false }
                                    return true
                                }
                                if let excluded = excludedPositions[unit] {
                                    if let near = query.near {
                                        let center = lines[condition][position]
                                        var low = 0, high = excluded.count
                                        while low < high {
                                            let middle = (low + high) / 2
                                            if excluded[middle] < center - near { low = middle + 1 } else { high = middle }
                                        }
                                        if low < excluded.count && excluded[low] - center <= near { continue }
                                    } else { continue }
                                }
                                guard query.includes.indices.allSatisfy({ c in hits[c].indices.contains { inUnit(c, $0) } }) else { continue }
                                let line = UInt32(lines[condition][position])
                                if var row = rows[line] {
                                    row.ranges[condition, default: []].append(range)
                                    if range.lowerBound < row.range.lowerBound { row.range = range }
                                    rows[line] = row
                                } else { rows[line] = (range, [condition: [range]]) }
                            }
                        }
                        evaluationElapsed += evaluationStart.duration(to: .now)
                        if evaluationExpired {
                            truncatedPaths.insert(file.pathID)
                            truncatedConditions.formUnion(query.includes.indices)
                            continue
                        }
                        if !rows.isEmpty {
                            let facets = symbolFacets(index: index)
                            batch[file.pathID] = rows.sorted { $0.key < $1.key }.map { line, row in
                                let excerpt = Self.lineExcerpt(in: bytes, range: row.range, lineTable: lineTable)
                                return SearchMatch(pathID: file.pathID, byteRange: row.range, line: line,
                                    column: lineTable.lineColumn(at: row.range.lowerBound)?.column ?? 1,
                                    lineText: excerpt.text, lineTextRange: excerpt.range,
                                    conditionIndices: row.ranges.keys.sorted(), conditionRanges: row.ranges, symbolName: symbolName(at: row.range.lowerBound, index: index, facets: facets))
                            }
                            flush(final: false)
                        }
                    }
                    flush(final: true)
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return coalescing(stream)
    }

    private enum Delivery: Sendable {
        case batch(SearchBatch)
        case flush
    }

    /// Keep delivery responsive even while a later file's regex scan is still running.
    private func coalescing(_ source: AsyncThrowingStream<SearchBatch, Error>) -> AsyncThrowingStream<SearchBatch, Error> {
        let interval = batchInterval
        return AsyncThrowingStream { output in
            let task = Task.detached {
                let events = AsyncThrowingStream<Delivery, Error>.makeStream()
                let producer = Task {
                    do {
                        for try await batch in source {
                            try Task.checkCancellation()
                            events.continuation.yield(.batch(batch))
                        }
                        events.continuation.finish()
                    } catch { events.continuation.finish(throwing: error) }
                }
                var timer: Task<Void, Never>?
                defer { producer.cancel(); timer?.cancel(); events.continuation.finish() }
                var pending: [PathID: [SearchMatch]] = [:]
                var latest: SearchBatch?
                var sent = false
                var lastSent = ContinuousClock.now
                func flush(final: Bool) {
                    guard !Task.isCancelled, let batch = latest else { return }
                    timer?.cancel(); timer = nil
                    output.yield(SearchBatch(matchesByPath: pending, isFinal: final,
                        completeness: batch.completeness, truncatedPathIDs: batch.truncatedPathIDs,
                        searchedPathCount: batch.searchedPathCount, excludedPathCount: batch.excludedPathCount,
                        searchedLanguages: batch.searchedLanguages, nonSourcePathCount: batch.nonSourcePathCount,
                        projectExcludedPathCount: batch.projectExcludedPathCount,
                        regexSkippedPathCount: batch.regexSkippedPathCount,
                        truncatedConditionIndices: batch.truncatedConditionIndices))
                    sent = sent || !pending.isEmpty
                    pending.removeAll(keepingCapacity: true)
                    lastSent = .now
                }
                do {
                    for try await event in events.stream {
                        try Task.checkCancellation()
                        switch event {
                        case .flush:
                            if !pending.isEmpty { flush(final: false) }
                        case .batch(let batch):
                            latest = batch
                            for (path, hits) in batch.matchesByPath { pending[path, default: []] += hits }
                            if batch.isFinal || (!sent && !pending.isEmpty) || pending.count >= 16
                                || pending.values.reduce(0, { $0 + $1.count }) >= 200 {
                                flush(final: batch.isFinal)
                            } else if !pending.isEmpty && timer == nil {
                                let deadline = lastSent.advanced(by: interval)
                                timer = Task {
                                    do {
                                        try await ContinuousClock().sleep(until: deadline)
                                        try Task.checkCancellation()
                                        events.continuation.yield(.flush)
                                    } catch {}
                                }
                            }
                        }
                    }
                    output.finish()
                } catch is CancellationError { output.finish() }
                catch { output.finish(throwing: error) }
            }
            output.onTermination = { _ in task.cancel() }
        }
    }

    static func area(at offset: UInt32, index: ContentIndex?) -> ProjectSearchQuery.Area {
        guard let regions = index?.regions else { return .code }
        var low = 0, high = regions.count
        while low < high {
            let middle = (low + high) / 2
            if regions[middle].range.lowerBound <= offset { low = middle + 1 } else { high = middle }
        }
        guard low > 0, regions[low - 1].range.contains(offset) else { return .code }
        return regions[low - 1].kind == .comment ? .comment : .string
    }

    private static func functionScopes(index: ContentIndex?) -> [ScopeRecord] {
        guard let index else { return [] }
        let regions = Dictionary(grouping: index.executableRegions.filter {
            $0.kind == .function || $0.kind == .method
        }, by: \.enclosingScopeID)
        return index.scopes.filter { $0.kind == .function || $0.kind == .closure }.map { scope in
            guard scope.kind == .function, let region = regions[scope.id]?.first else { return scope }
            let range = region.associatedFacetIndex.flatMap { i in
                index.symbols.indices.contains(Int(i)) ? index.symbols[Int(i)].range : nil
            } ?? region.range
            return ScopeRecord(id: scope.id, parent: scope.parent, kind: scope.kind, range: range)
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func functionUnit(at offset: UInt32, scopes: [ScopeRecord]) -> ScopeID? {
        var low = 0, high = scopes.count
        while low < high {
            let middle = (low + high) / 2
            if scopes[middle].range.lowerBound <= offset { low = middle + 1 } else { high = middle }
        }
        var closure: ScopeID?
        for i in (0..<low).reversed() where scopes[i].range.contains(offset) {
            if scopes[i].kind == .function { return scopes[i].id }
            // Without a named function, the outermost enclosing closure is the
            // top-level function unit; closures nested inside it belong to it.
            closure = scopes[i].id
        }
        return closure
    }

    private func symbolFacets(index: ContentIndex?) -> [Int] {
        guard let index else { return [] }
        return index.symbols.indices.filter { i in
            [.rustFn, .rustMethod, .pythonFunction, .typescriptFunction,
             .rustStruct, .rustEnum, .rustTrait, .rustImpl, .rustMod, .pythonClass, .typescriptClass]
                .contains(index.symbols[i].kind)
        }.sorted { index.symbols[$0].range.lowerBound < index.symbols[$1].range.lowerBound }
    }

    private func symbolName(at offset: UInt32, index: ContentIndex?, facets: [Int]) -> String? {
        guard let index else { return nil }
        var low = 0, high = facets.count
        while low < high {
            let middle = (low + high) / 2
            if index.symbols[facets[middle]].range.lowerBound <= offset { low = middle + 1 } else { high = middle }
        }
        guard let closest = facets[..<low].reversed().first(where: { index.symbols[$0].range.contains(offset) }) else { return nil }
        let facet = index.symbols[closest]
        func name(of i: Int) -> String? {
            let symbol = index.symbols[i]
            if symbol.kind == .rustImpl,
               let relation = index.implRelations.first(where: { $0.implFacetIndex == UInt32(i) }) {
                return source.searchName(for: relation.typeNameID)
            }
            return source.searchName(for: symbol.nameID)
        }
        guard let ownName = name(of: closest), !ownName.isEmpty else { return nil }
        // Functions display their name; methods add only their immediate owning
        // type. Module and outer-function chains are not method ownership.
        guard [.rustFn, .rustMethod, .pythonFunction, .typescriptFunction].contains(facet.kind),
              let parent = facet.parentFacetIndex.map(Int.init), index.symbols.indices.contains(parent),
              [.rustImpl, .rustStruct, .rustEnum, .rustTrait, .pythonClass, .typescriptClass].contains(index.symbols[parent].kind),
              let owner = name(of: parent), !owner.isEmpty else { return ownName }
        return owner + (language == .rust ? "::" : ".") + ownName

    }
}

extension EngineSession {
    public func search(
        _ query: ProjectSearchQuery,
        caseSensitive: Bool = false,
        wholeWord: Bool = false,
        isRegex: Bool = false,
        context: QueryContext
    ) throws -> AsyncThrowingStream<SearchBatch, Error> {
        try validate(context)
        return try SnapshotSearchService(source: self, language: analysisProfile.language, extractor: extractor)
            .search(query, caseSensitive: caseSensitive, wholeWord: wholeWord, isRegex: isRegex, context: context)
    }
}
