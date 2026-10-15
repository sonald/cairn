import CodeInsightCore
@testable import CodeInsightEngine
import CodeInsightGit
import CodeInsightPythonExtractor
import CodeInsightRustExtractor
import CodeInsightTypeScriptExtractor
import Foundation
import Testing

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

// MARK: - Round trip

@Test
func binaryDraftCodecRoundTripsRealExtractionsInEveryLanguage() throws {
    let drafts = try fixtureDrafts()
    #expect(Set(drafts.map { "\($0.index.key.languageMode.language)/\($0.index.key.languageMode.variant ?? "")" })
        == ["rust/", "python/", "typescript/", "typescript/tsx"])
    for (offset, draft) in drafts.enumerated() {
        try expectRoundTrip(draft, order: offset)
    }
}

@Test
func binaryDraftCodecRoundTripsGeneratedDrafts() throws {
    var random = SplitMix64(seed: 0xC0DEC_0006)
    for order in 0..<300 {
        try expectRoundTrip(generatedDraft(&random), order: order)
    }
    try expectRoundTrip(generatedDraft(&random, empty: true), order: 0)
}

// MARK: - Damaged rows

@Test
func truncatedDraftPayloadsAreRejectedAtEveryCut() throws {
    for draft in try smallDrafts() {
        let data = ContentIndexDraftCodec.encode(draft)
        for cut in 0..<data.count {
            expectRejected(data.prefix(cut), draft)
        }
        // A consistent digest over a cut body still has to fail in the reader.
        let body = body(of: data)
        for cut in 5..<body.count {
            expectRejected(resealed(Array(body.prefix(cut))), draft)
        }
    }
}

@Test
func oversizedLengthFieldsAreRejectedBeforeAllocating() throws {
    let (draft, body, name) = try located("xyz", "ayz")
    // `name` is the first byte of the only name: its length byte precedes
    // it, the names count precedes that, and the content ID length is
    // right after the header and the algorithm byte.
    let huge = varint(1 << 40)
    for at in [name - 2, name - 1, 6] {
        var damaged = body
        damaged.replaceSubrange(at...at, with: huge)
        expectRejected(resealed(damaged), draft)
    }
    // A count of 1 spelled in more than ten bytes, or with a tenth byte
    // that only adds bits past 64: read without the cap, both would be 1.
    for bad: [UInt8] in [[0x81] + Array(repeating: 0x80, count: 9) + [0x00], [0x81] + Array(repeating: 0x80, count: 8) + [0x02]] {
        var damaged = body
        damaged.replaceSubrange((name - 2)...(name - 2), with: bad)
        expectRejected(resealed(damaged), draft)
    }
}

@Test
func unknownEnumAndFlagValuesAreRejected() throws {
    var fields: [(String, Int)] = []
    func locate(_ label: String, _ change: (inout Knobs) -> Void) throws {
        var changed = Knobs()
        change(&changed)
        let a = body(of: ContentIndexDraftCodec.encode(oneOfEach(Knobs())))
        let b = body(of: ContentIndexDraftCodec.encode(oneOfEach(changed)))
        let differing = a.indices.filter { a[$0] != b[$0] }
        try #require(a.count == b.count && differing.count == 1, "\(label)")
        fields.append((label, differing[0]))
    }
    try locate("containsErrorNodes") { $0.containsErrorNodes = true }
    try locate("scope kind") { $0.scopeKind = .function }
    try locate("binding space") { $0.space = .type }
    try locate("binding kind") { $0.bindingKind = .letBinding }
    try locate("hint kind") { $0.hintKind = .member }
    try locate("type ref tag") { $0.typeRefTag = 2 }
    try locate("executable region kind") { $0.regionKind = .closure }
    try locate("declaration kind") { $0.declarationKind = .typescriptEnum }
    try locate("visibility") { $0.visibility = .private }
    try locate("call kind") { $0.callKind = .methodCall }
    try locate("import kind") { $0.importKind = .named }
    try locate("import flags") { $0.importFlags = .typeOnly }
    try locate("content region kind") { $0.contentRegionKind = .string }

    let draft = oneOfEach(Knobs())
    let base = body(of: ContentIndexDraftCodec.encode(draft))
    expectAccepted(resealed(base), draft)
    for (label, at) in fields {
        let values: [UInt8] = switch label {
        case "import flags": [0x20, 0x80]
        case "containsErrorNodes": [2, 0xFF]
        default: [0xEE]
        }
        for bad in values {
            var damaged = base
            damaged[at] = bad
            #expect(throws: DraftCodecError.self, "\(label)=\(bad)") {
                try ContentIndexDraftCodec.decode(resealed(damaged), order: 0, bytes: draft.bytes, expectedKey: draft.index.key)
            }
        }
    }
}

@Test
func invalidUTF8InStoredStringsIsRejected() throws {
    let (draft, body, name) = try located("xyz", "ayz")
    expectAccepted(resealed(body), draft)
    // Lone byte, bad continuation, truncated four-byte sequence (which
    // decodes to a U+FFFD of the same length), surrogate, overlong.
    for bad: [UInt8] in [[0xFF, 0x79, 0x7A], [0xC3, 0x28, 0x7A], [0xF0, 0x90, 0x80], [0xED, 0xA0, 0x80], [0xC0, 0xAF, 0x7A]] {
        var damaged = body
        damaged.replaceSubrange(name..<(name + 3), with: bad)
        expectRejected(resealed(damaged), draft)
    }
}

@Test
func trailingBytesAfterADraftAreRejected() throws {
    for draft in try smallDrafts().prefix(4) {
        let data = ContentIndexDraftCodec.encode(draft)
        expectRejected(data + [0], draft)
        let body = body(of: data)
        for extra: [UInt8] in [[0], [0, 0, 0], [0x01]] {
            expectRejected(resealed(body + extra), draft)
        }
    }
}

@Test
func mismatchedFormatKeyOrSourceIsRejected() throws {
    let draft = try #require(try smallDrafts().first)
    let key = draft.index.key
    let data = ContentIndexDraftCodec.encode(draft)
    let body = body(of: data)
    expectAccepted(data, draft)
    var olderFormat = body
    olderFormat[4] = 5
    expectRejected(resealed(olderFormat), draft)
    var otherMagic = body
    otherMagic[3] = 0x58
    expectRejected(resealed(otherMagic), draft)

    // The JSON rows of format 5 (`CIDX` 5, LZFSE) are never decoded.
    expectRejected(try formatFiveRow(draft), draft)

    let otherKeys = [
        ContentIndexKey(contentID: key.contentID, languageMode: key.languageMode,
                        grammarVersion: key.grammarVersion, extractorVersion: key.extractorVersion &+ 1),
        ContentIndexKey(contentID: key.contentID, languageMode: key.languageMode,
                        grammarVersion: key.grammarVersion &+ 1, extractorVersion: key.extractorVersion),
        ContentIndexKey(contentID: key.contentID, languageMode: LanguageMode(language: key.languageMode.language, variant: "tsx"),
                        grammarVersion: key.grammarVersion, extractorVersion: key.extractorVersion),
    ]
    for other in otherKeys {
        #expect(throws: DraftCodecError.self) {
            try ContentIndexDraftCodec.decode(data, order: 0, bytes: draft.bytes, expectedKey: other)
        }
    }
    // Bytes that no longer hash to the key's content ID.
    #expect(throws: DraftCodecError.self) {
        try ContentIndexDraftCodec.decode(data, order: 0, bytes: draft.bytes + [0x0A], expectedKey: key)
    }
}

@Test
func randomByteFlipsNeverCrashTheDecoder() throws {
    var random = SplitMix64(seed: 0xF11F_0006)
    let drafts = try smallDrafts()
    var sealedAccepted = 0
    var resealedAccepted = 0
    var trials = 0
    for draft in drafts {
        let data = ContentIndexDraftCodec.encode(draft)
        let body = body(of: data)
        for _ in 0..<60 {
            trials += 1
            var flipped = data
            let at = Int(random.next() % UInt64(flipped.count))
            flipped[flipped.startIndex + at] ^= UInt8(random.next() % 255 + 1)
            if (try? ContentIndexDraftCodec.decode(flipped, order: 0, bytes: draft.bytes, expectedKey: draft.index.key)) != nil {
                sealedAccepted += 1
            }
            // With the digest recomputed, the reader alone has to cope; a
            // flip that lands on a value still in range decodes, which is
            // what the digest is there to catch.
            var damaged = body
            let bodyAt = 5 + Int(random.next() % UInt64(body.count - 5))
            damaged[bodyAt] ^= UInt8(random.next() % 255 + 1)
            if (try? ContentIndexDraftCodec.decode(resealed(damaged), order: 0, bytes: draft.bytes, expectedKey: draft.index.key)) != nil {
                resealedAccepted += 1
            }
        }
    }
    print("FLIPS trials=\(trials) acceptedWithDigest=\(sealedAccepted) acceptedResealed=\(resealedAccepted)")
    #expect(sealedAccepted == 0)
}

// MARK: - Opt-in corpus round trip

// Skipped unless CAIRN_DRAFT_CODEC_CORPORA lists repositories, separated by
// `:`. Indexes HEAD of each into a scratch cache, then checks every cached
// row against a fresh extraction of the same content: the decoded draft
// equals it, and encoding it again gives the stored bytes.
//   CAIRN_DRAFT_CODEC_CORPORA=/path/a:/path/b swift test --filter cachedDraftsOfWholeCorporaRoundTrip
private let corpora = ProcessInfo.processInfo.environment["CAIRN_DRAFT_CODEC_CORPORA"]

@Test(.enabled(if: corpora != nil))
func cachedDraftsOfWholeCorporaRoundTrip() throws {
    for path in corpora!.split(separator: ":") {
        let root = URL(fileURLWithPath: String(path), isDirectory: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("cairn-draft-codec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let cache = try IndexCache(fileURL: scratch.appendingPathComponent("cache.sqlite3"))
        let indexer = ProjectIndexer(parallelism: ProcessInfo.processInfo.activeProcessorCount, cache: cache)
        let snapshot = try CommitSnapshot(repositoryURL: root, revision: "HEAD")
        let store = ProjectIndexStore()
        for item in try indexer.prepareSnapshots(snapshot, into: store, languages: snapshot.languages) {
            _ = try indexer.completeSnapshot(item)
        }
        indexer.flushPersistentWrites()
        cache.flush()
        let state = store.snapshot()
        let keys = Array(state.contentIndexes.keys)
        let payloads = cache.payloads(for: keys.map(cacheKey(for:)))
        cache.flush()
        try #require(payloads.count == keys.count)

        final class Tally: @unchecked Sendable {
            let lock = NSLock()
            var mismatches: [String] = []
            var byLanguage: [String: Int] = [:]
            var rowBytes = 0
            var next = 0
        }
        let tally = Tally()
        // Extraction recurses deeply on some files; give workers the stack
        // the indexer's own workers get.
        let group = DispatchGroup()
        for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
            group.enter()
            let worker = Thread {
                defer { group.leave() }
                while let offset = tally.lock.withLock({ () -> Int? in
                    defer { tally.next += 1 }
                    return tally.next < keys.count ? tally.next : nil
                }) {
                    check(offset)
                }
            }
            worker.stackSize = 64 << 20
            worker.start()
        }
        @Sendable func check(_ offset: Int) {
            let key = keys[offset]
            let bytes = state.sourceBytesByContent[key.contentID]!
            let payload = payloads[cacheKey(for: key)]!
            let problem: String? = {
                do {
                    let fresh = try extract(bytes, key: key)
                    let decoded = try ContentIndexDraftCodec.decode(payload, order: offset, bytes: bytes, expectedKey: key)
                    if canonical(decoded) != canonical(fresh) { return "decoded differs" }
                    if ContentIndexDraftCodec.encode(decoded) != payload { return "re-encoding differs" }
                    return nil
                } catch {
                    return "\(error)"
                }
            }()
            tally.lock.withLock {
                tally.byLanguage["\(key.languageMode.language)\(key.languageMode.variant.map { "/" + $0 } ?? "")", default: 0] += 1
                tally.rowBytes += payload.count
                if let problem { tally.mismatches.append("\(cacheKey(for: key)): \(problem)") }
            }
        }
        group.wait()
        print("CODEC corpus=\(root.lastPathComponent) drafts=\(keys.count) byLanguage=\(tally.byLanguage.sorted { $0.key < $1.key }) rowBytes=\(tally.rowBytes) mismatches=\(tally.mismatches.count)")
        #expect(tally.mismatches.isEmpty, "\(tally.mismatches.prefix(5))")
    }
}

// MARK: - Helpers

/// Every field of a draft in one comparable form: none of the records are
/// Equatable, and sorted-key JSON spells each one out.
private struct Canonical: Encodable {
    let index: ContentIndex
    let names: [String]
    let strings: [String]
    let containsErrorNodes: Bool
}

private func canonical(_ draft: ExtractionDraft) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try! encoder.encode(Canonical(
        index: draft.index,
        names: draft.names.values,
        strings: draft.strings.values,
        containsErrorNodes: draft.containsErrorNodes
    ))
}

private func expectRoundTrip(_ draft: ExtractionDraft, order: Int, sourceLocation: Testing.SourceLocation = #_sourceLocation) throws {
    let data = ContentIndexDraftCodec.encode(draft)
    let decoded = try ContentIndexDraftCodec.decode(data, order: order, bytes: draft.bytes, expectedKey: draft.index.key)
    #expect(canonical(decoded) == canonical(draft), sourceLocation: sourceLocation)
    #expect(decoded.bytes == draft.bytes, sourceLocation: sourceLocation)
    #expect(decoded.order == order, sourceLocation: sourceLocation)
}

private func expectRejected(_ data: Data, _ draft: ExtractionDraft, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
    #expect(throws: DraftCodecError.self, sourceLocation: sourceLocation) {
        try ContentIndexDraftCodec.decode(data, order: 0, bytes: draft.bytes, expectedKey: draft.index.key)
    }
}

private func expectAccepted(_ data: Data, _ draft: ExtractionDraft, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
    let decoded = try? ContentIndexDraftCodec.decode(data, order: 0, bytes: draft.bytes, expectedKey: draft.index.key)
    #expect(decoded.map(canonical) == canonical(draft), sourceLocation: sourceLocation)
}

private func body(of data: Data) -> [UInt8] {
    Array(data.dropLast(32))
}

private func resealed(_ body: [UInt8]) -> Data {
    Data(ContentIndexDraftCodec.sealed(body))
}

private func varint(_ value: UInt64) -> [UInt8] {
    var value = value
    var out: [UInt8] = []
    while value >= 0x80 {
        out.append(UInt8(truncatingIfNeeded: value) | 0x80)
        value >>= 7
    }
    return out + [UInt8(value)]
}

/// Two drafts whose one name differs only in its first byte; returns the
/// first, its body and the body offset of that byte.
private func located(_ first: String, _ second: String) throws -> (ExtractionDraft, [UInt8], Int) {
    func draft(_ name: String) -> ExtractionDraft {
        let bytes = Array("fn x() {}\n".utf8)
        let names = Interner<NameID>()
        _ = names.intern(name)
        return ExtractionDraft(
            order: 0, bytes: bytes,
            index: ContentIndex(
                key: key(for: bytes, language: .rust), scopes: [], bindings: [], executableRegions: [],
                symbols: [], calls: [], imports: [], exports: [], lineTable: LineTable(bytes: bytes)
            ),
            names: names, strings: Interner<StringID>(), containsErrorNodes: false
        )
    }
    let a = body(of: ContentIndexDraftCodec.encode(draft(first)))
    let b = body(of: ContentIndexDraftCodec.encode(draft(second)))
    let differing = a.indices.filter { a[$0] != b[$0] }
    try #require(a.count == b.count && differing.count == 1)
    return (draft(first), a, differing[0])
}

private func key(for bytes: [UInt8], language: LanguageID, variant: String? = nil) -> ContentIndexKey {
    ContentIndexKey(
        contentID: ContentID.sha256(of: bytes),
        languageMode: LanguageMode(language: language, variant: variant),
        grammarVersion: 1,
        extractorVersion: 1
    )
}

private func extractor(for language: LanguageID) -> any LanguageExtractor {
    switch language {
    case .rust: RustExtractor()
    case .python: PythonExtractor()
    case .typescript, .javascript: TypeScriptExtractor()
    }
}

private func extract(_ bytes: [UInt8], key: ContentIndexKey) throws -> ExtractionDraft {
    let names = Interner<NameID>()
    let strings = Interner<StringID>()
    let result = try extractor(for: key.languageMode.language).extractWithDiagnostics(
        bytes: bytes, key: key, interner: ExtractionInterners(names: names, strings: strings)
    )
    return ExtractionDraft(
        order: 0, bytes: bytes, index: result.index, names: names, strings: strings,
        containsErrorNodes: result.containsErrorNodes
    )
}

/// Every Rust, Python, TypeScript and TSX file in the repository's
/// fixtures, extracted once per test process. The multi-megabyte layout
/// stress files are left out; the opt-in corpus test covers scale.
private func fixtureDrafts() throws -> [ExtractionDraft] {
    try fixtureExtractions.get()
}

private let fixtureExtractions = Result { try extractFixtures() }

private func extractFixtures() throws -> [ExtractionDraft] {
    let directories = ["fixtures", "goldset/fixtures"].map { repositoryRoot.appendingPathComponent($0) }
    var drafts: [ExtractionDraft] = []
    for directory in directories {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .sorted { $0.path < $1.path }
        for file in files {
            guard let mode = LanguageMode.classify(path: file.lastPathComponent) else { continue }
            let bytes = try [UInt8](Data(contentsOf: file))
            guard bytes.count <= 512 * 1024 else { continue }
            let probe = extractor(for: mode.language)
            drafts.append(try extract(bytes, key: ContentIndexKey(
                contentID: ContentID.sha256(of: bytes), languageMode: mode,
                grammarVersion: probe.grammarVersion, extractorVersion: probe.extractorVersion
            )))
        }
    }
    return drafts
}

/// Real extractions small enough to cut at every byte, plus generated ones.
private func smallDrafts() throws -> [ExtractionDraft] {
    var random = SplitMix64(seed: 0x5A11_0006)
    let real = try fixtureDrafts().filter { ContentIndexDraftCodec.encode($0).count < 3_000 }
    return Array(real.prefix(6)) + (0..<10).map { _ in generatedDraft(&random) }
}

/// The JSON row the previous codec wrote for `draft`.
private func formatFiveRow(_ draft: ExtractionDraft) throws -> Data {
    struct Payload: Encodable {
        let formatVersion: UInt32
        let index: ContentIndex
        let names: [String]
        let strings: [String]
        let containsErrorNodes: Bool
    }
    let json = try JSONEncoder().encode(Payload(
        formatVersion: 5, index: draft.index, names: draft.names.values,
        strings: draft.strings.values, containsErrorNodes: draft.containsErrorNodes
    ))
    return Data([0x43, 0x49, 0x44, 0x58, 0x05]) + (try (json as NSData).compressed(using: .lzfse) as Data)
}

/// Fixed-seed generator (SplitMix64), so a failing case reproduces.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func cases<T: RawRepresentable>(_: T.Type) -> [T] where T.RawValue == UInt8 {
    (0...255).compactMap { T(rawValue: UInt8($0)) }
}

private let samples = [
    "", "a", "fn", "名字", "変数_値", "é", "e\u{301}", "Å", "A\u{30A}", "👨‍👩‍👧", "🦀", "x\u{0}y",
    String(repeating: "long_identifier_", count: 40), "\u{FFFD}", "tab\tnew\nline",
]

/// A draft that passes the decoder's validity checks: every reference
/// points into its table, ranges lie inside the bytes, ids are unique and
/// regions are ordered and disjoint. Values reach the extremes the format
/// allows (UInt32.max ids and versions, UInt16.max argument counts, ranges
/// ending at the last byte).
private func generatedDraft(_ random: inout SplitMix64, empty: Bool = false) -> ExtractionDraft {
    func chance(_ percent: UInt64) -> Bool { random.next() % 100 < percent }
    func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &random) }
    func u32() -> UInt32 {
        [0, 1, 127, 128, 16_383, 16_384, UInt32.max - 1, UInt32.max, UInt32.random(in: 0...UInt32.max, using: &random)]
            .randomElement(using: &random)!
    }
    func text() -> String {
        chance(70)
            ? samples.randomElement(using: &random)!
            : String((0..<int(0...6)).map { _ in
                Character(Unicode.Scalar([0x41, 0x3B1, 0x4E2D, 0x1F600, 0x301].randomElement(using: &random)! + UInt32(int(0...20)))!)
            })
    }
    let bytes: [UInt8] = empty ? [] : (0..<int(0...400)).map { _ in UInt8.random(in: 0...255, using: &random) }
    let n = UInt32(bytes.count)
    func range() -> ByteRange {
        let lower = chance(10) ? n : UInt32.random(in: 0...n, using: &random)
        let upper = chance(20) ? n : UInt32.random(in: lower...n, using: &random)
        return ByteRange(lowerBound: lower, upperBound: upper)
    }
    func optRange() -> ByteRange? { chance(50) ? range() : nil }
    func pick<T: RawRepresentable>(_ type: T.Type) -> T where T.RawValue == UInt8 {
        cases(type).randomElement(using: &random)!
    }
    func count(_ limit: Int) -> Int { empty ? 0 : int(0...limit) }

    let languageMode = chance(25)
        ? LanguageMode(language: .typescript, variant: chance(50) ? "tsx" : text())
        : LanguageMode(language: pick(LanguageID.self))
    let key = ContentIndexKey(
        contentID: ContentID.sha256(of: bytes), languageMode: languageMode,
        grammarVersion: u32(), extractorVersion: u32()
    )
    let names = Interner<NameID>()
    let strings = Interner<StringID>()
    for _ in 0..<count(8) { _ = names.intern(text()) }
    for _ in 0..<count(4) { _ = strings.intern(text()) }
    let nameCount = names.values.count
    let stringCount = strings.values.count
    func name() -> NameID { NameID(rawValue: UInt32(int(0...(nameCount - 1)))) }
    func fingerprint() -> ContentID? {
        chance(50) ? ContentID(algorithm: UInt8.random(in: 0...255, using: &random),
                               bytes: (0..<int(0...40)).map { _ in UInt8.random(in: 0...255, using: &random) }) : nil
    }
    func typeRef() -> TypeRef? {
        switch int(0...6) {
        case 0: nil
        case 1: .named(range())
        case 2: .primitive(range())
        case 3: .selfType(range())
        case 4: .constructed(range())
        case 5: .genericBound(parameter: range(), bound: range())
        default: .genericUnbounded(parameter: range())
        }
    }

    var scopeIDs: [ScopeID] = []
    let scopeCount = count(5)
    while scopeIDs.count < scopeCount {
        let id = ScopeID(rawValue: u32())
        if !scopeIDs.contains(id) { scopeIDs.append(id) }
    }
    let scopes = scopeIDs.map {
        ScopeRecord(id: $0, parent: chance(50) ? scopeIDs.randomElement(using: &random) : nil,
                    kind: pick(ScopeKind.self), range: range())
    }
    let symbolCount = nameCount == 0 ? 0 : count(6)
    let symbols = (0..<symbolCount).map { _ in
        DeclarationFacet(
            symbolGroupID: SymbolGroupID(rawValue: u32()), space: pick(SymbolSpace.self),
            kind: pick(DeclarationKind.self), nameID: name(), range: range(), nameRange: range(),
            parentFacetIndex: chance(50) ? UInt32(int(0...(symbolCount - 1))) : nil,
            signatureFingerprint: fingerprint(), bodyFingerprint: fingerprint(), typeRef: typeRef(),
            visibility: chance(70) ? pick(DeclarationVisibility.self) : nil
        )
    }
    let bindings = scopeIDs.isEmpty || nameCount == 0 ? [] : (0..<count(6)).map { _ in
        BindingRecord(
            scopeID: scopeIDs.randomElement(using: &random)!, localNameID: name(),
            space: pick(SymbolSpace.self), kind: pick(BindingKind.self), declarationRange: range(),
            targetHint: chance(50) ? UnresolvedSymbolRef(nameID: name(), hintKind: pick(UnresolvedSymbolHintKind.self)) : nil,
            typeRef: typeRef()
        )
    }
    var regionIDs: [ExecutableRegionID] = []
    let regionCount = scopeIDs.isEmpty ? 0 : count(4)
    do {
        while regionIDs.count < regionCount {
            let id = ExecutableRegionID(rawValue: u32())
            if !regionIDs.contains(id) { regionIDs.append(id) }
        }
    }
    let executableRegions = regionIDs.map {
        ExecutableRegionRecord(
            id: $0, kind: pick(ExecutableRegionKind.self), range: range(),
            enclosingScopeID: scopeIDs.randomElement(using: &random)!,
            associatedFacetIndex: symbolCount > 0 && chance(50) ? UInt32(int(0...(symbolCount - 1))) : nil
        )
    }
    let implRelations = symbolCount == 0 ? [] : (0..<count(3)).map { _ in
        ImplRelation(
            implFacetIndex: UInt32(int(0...(symbolCount - 1))), traitNameID: chance(50) ? name() : nil,
            traitNameRange: optRange(), typeNameID: name()
        )
    }
    let calls: [UnresolvedCall] = regionIDs.isEmpty || nameCount == 0 ? [] : (0..<count(6)).map { _ in
        let outer = range()
        let lower = UInt32.random(in: outer.lowerBound...outer.upperBound, using: &random)
        let inner = ByteRange(lowerBound: lower, upperBound: UInt32.random(in: lower...outer.upperBound, using: &random))
        return UnresolvedCall(
            regionID: regionIDs.randomElement(using: &random)!, nameID: name(), range: outer, nameRange: inner,
            syntacticKind: pick(CallKind.self), qualifierRange: optRange(), receiverRange: optRange(),
            argumentCount: chance(30) ? nil : [0, 1, UInt16.max, UInt16.random(in: 0...UInt16.max, using: &random)]
                .randomElement(using: &random)!
        )
    }
    let imports = scopeIDs.isEmpty || stringCount == 0 || nameCount == 0 ? [] : (0..<count(4)).map { _ in
        ImportBinding(
            moduleSpecifier: StringID(rawValue: UInt32(int(0...(stringCount - 1)))),
            importedName: chance(50) ? name() : nil, localName: chance(50) ? name() : nil,
            kind: pick(ImportKind.self), flags: ImportFlags(rawValue: UInt8(int(0...31))),
            scopeID: scopeIDs.randomElement(using: &random)!, range: range()
        )
    }
    let exports = nameCount == 0 ? [] : (0..<count(3)).map { _ in
        ExportRecord(
            exportedName: name(),
            sourceBindingIndex: !imports.isEmpty && chance(50) ? UInt32(int(0...(imports.count - 1))) : nil,
            range: range()
        )
    }
    var regions: [ContentRegion] = []
    var cursor: UInt32 = 0
    while !empty, cursor < n, regions.count < 8 {
        let lower = UInt32.random(in: cursor...(n - 1), using: &random)
        let upper = UInt32.random(in: (lower + 1)...n, using: &random)
        regions.append(ContentRegion(range: ByteRange(lowerBound: lower, upperBound: upper), kind: pick(ContentRegionKind.self)))
        cursor = upper
    }
    return ExtractionDraft(
        order: 0,
        bytes: bytes,
        index: ContentIndex(
            key: key, scopes: scopes, bindings: bindings, executableRegions: executableRegions,
            symbols: symbols, implRelations: implRelations, calls: calls, imports: imports,
            exports: exports, lineTable: LineTable(bytes: bytes), regions: regions
        ),
        names: names,
        strings: strings,
        containsErrorNodes: chance(50)
    )
}

/// One record of every kind, each enum or flag set by a knob, so two
/// drafts differ in exactly one stored byte.
private struct Knobs {
    var containsErrorNodes = false
    var scopeKind = ScopeKind.block
    var space = SymbolSpace.value
    var bindingKind = BindingKind.param
    var hintKind = UnresolvedSymbolHintKind.unqualified
    var typeRefTag = 1
    var regionKind = ExecutableRegionKind.function
    var declarationKind = DeclarationKind.rustFn
    var visibility = DeclarationVisibility.public
    var callKind = CallKind.directCall
    var importKind = ImportKind.module
    var importFlags: ImportFlags = .wildcard
    var contentRegionKind = ContentRegionKind.comment
}

private func oneOfEach(_ knobs: Knobs) -> ExtractionDraft {
    let bytes = Array("fn f(x: S) { g(1) } // c\n".utf8)
    let r = ByteRange(lowerBound: 1, upperBound: 4)
    let names = Interner<NameID>()
    let strings = Interner<StringID>()
    let name = names.intern("f")
    let module = strings.intern("m")
    let scope = ScopeID(rawValue: 1)
    let region = ExecutableRegionID(rawValue: 2)
    return ExtractionDraft(
        order: 0,
        bytes: bytes,
        index: ContentIndex(
            key: key(for: bytes, language: .rust),
            scopes: [ScopeRecord(id: scope, parent: nil, kind: knobs.scopeKind, range: r)],
            bindings: [BindingRecord(
                scopeID: scope, localNameID: name, space: knobs.space, kind: knobs.bindingKind,
                declarationRange: r, targetHint: UnresolvedSymbolRef(nameID: name, hintKind: knobs.hintKind),
                typeRef: knobs.typeRefTag == 1 ? .named(r) : .primitive(r)
            )],
            executableRegions: [ExecutableRegionRecord(
                id: region, kind: knobs.regionKind, range: r, enclosingScopeID: scope, associatedFacetIndex: 0
            )],
            symbols: [DeclarationFacet(
                symbolGroupID: SymbolGroupID(rawValue: 3), space: .value, kind: knobs.declarationKind,
                nameID: name, range: r, nameRange: r, parentFacetIndex: nil,
                signatureFingerprint: nil, bodyFingerprint: nil, visibility: knobs.visibility
            )],
            calls: [UnresolvedCall(
                regionID: region, nameID: name, range: r, nameRange: r, syntacticKind: knobs.callKind,
                qualifierRange: nil, receiverRange: nil, argumentCount: 1
            )],
            imports: [ImportBinding(
                moduleSpecifier: module, importedName: nil, localName: nil, kind: knobs.importKind,
                flags: knobs.importFlags, scopeID: scope, range: r
            )],
            exports: [],
            lineTable: LineTable(bytes: bytes),
            regions: [ContentRegion(range: ByteRange(lowerBound: 20, upperBound: 24), kind: knobs.contentRegionKind)]
        ),
        names: names,
        strings: strings,
        containsErrorNodes: knobs.containsErrorNodes
    )
}
