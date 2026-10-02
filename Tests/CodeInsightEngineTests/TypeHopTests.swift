@testable import CodeInsightCLI
import CodeInsightCore
import CodeInsightEngine
import CodeInsightRustExtractor
import Foundation
import Testing

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

private func makeSession(
    _ files: [String: String],
    language: LanguageID = .rust
) throws -> EngineSession {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TypeHopTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (path, contents) in files {
        let fileURL = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    return try ProjectIndexer().index(root: root, language: language)
}

private func pathID(
    _ relative: String, in session: EngineSession
) throws -> PathID {
    try #require(session.manifest.files.first {
        session.paths.resolve($0.pathID) == relative
    }?.pathID)
}

private func offset(
    line: UInt32, column: UInt32, in session: EngineSession, path relative: String
) throws -> UInt32 {
    let id = try pathID(relative, in: session)
    return try #require(session.content(at: id)?.1.lineTable.byteOffset(
        line: line, column: column
    ))
}

private func queryContext(for session: EngineSession) -> QueryContext {
    QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
}

private func binding(
    named name: String, in session: EngineSession, path relative: String
) -> BindingRecord? {
    guard let id = session.manifest.files.first(where: {
        session.paths.resolve($0.pathID) == relative
    })?.pathID,
       let index = session.content(at: id)?.1
    else { return nil }
    return index.bindings.first {
        session.names.resolve($0.localNameID) == name
    }
}

private func facet(
    named name: String, at candidate: ResolutionCandidate, in session: EngineSession
) -> DeclarationFacet? {
    guard candidate.target.localKind == .declarationFacet,
          let index = session.content(at: candidate.target.pathID)?.1,
          index.symbols.indices.contains(Int(candidate.target.localIndex))
    else { return nil }
    let facet = index.symbols[Int(candidate.target.localIndex)]
    return session.names.resolve(facet.nameID) == name ? facet : nil
}

// MARK: P1 — typeRef survives indexing and the draft codec

@Test
func projectIndexerPreservesBindingTypeRef() throws {
    let session = try makeSession([
        "src/main.rs": """
        struct S;
        fn f(ps: &S) {}
        """,
    ])
    let ps = try #require(binding(named: "ps", in: session, path: "src/main.rs"))
    let head = try #require(ps.typeRef?.ranges.first)
    let bytes = Array("struct S;\nfn f(ps: &S) {}\n".utf8)
    #expect(String(decoding: bytes[Int(head.lowerBound)..<Int(head.upperBound)], as: UTF8.self) == "S")
}

@Test
func draftCodecRejectsOutOfRangeTypeRef() throws {
    let source = "struct S;\nfn f(ps: &S) {}\n"
    let bytes = Array(source.utf8)
    let names = Interner<NameID>()
    let strings = Interner<StringID>()
    let key = ContentIndexKey(
        contentID: ContentID.sha256(of: bytes),
        languageMode: LanguageMode(language: .rust),
        grammarVersion: RustExtractorInfo.grammarVersion,
        extractorVersion: RustExtractorInfo.extractorVersion
    )
    let index = try RustExtractor().extract(
        bytes: bytes, key: key, interner: ExtractionInterners(names: names, strings: strings)
    )
    let draft = ExtractionDraft(
        order: 0,
        bytes: bytes,
        index: index,
        names: names,
        strings: strings,
        containsErrorNodes: false
    )
    let encoded = try ContentIndexDraftCodec.encode(draft)

    // Tamper: give a binding a typeRef whose range lies past the byte count.
    let decompressed = try (Data(encoded.dropFirst(5)) as NSData)
        .decompressed(using: .lzfse) as Data
    struct Payload: Codable {
        let formatVersion: UInt32
        let index: ContentIndex
        let names: [String]
        let strings: [String]
        let containsErrorNodes: Bool
    }
    let original = try JSONDecoder().decode(Payload.self, from: decompressed)
    var bindings = original.index.bindings
    let psIndex = try #require(bindings.firstIndex {
        names.resolve($0.localNameID) == "ps"
    })
    bindings[psIndex] = BindingRecord(
        scopeID: bindings[psIndex].scopeID,
        localNameID: bindings[psIndex].localNameID,
        space: bindings[psIndex].space,
        kind: bindings[psIndex].kind,
        declarationRange: bindings[psIndex].declarationRange,
        targetHint: bindings[psIndex].targetHint,
        typeRef: .named(ByteRange(lowerBound: 1, upperBound: UInt32(bytes.count) + 5))
    )
    let tampered = Payload(
        formatVersion: original.formatVersion,
        index: ContentIndex(
            key: original.index.key,
            scopes: original.index.scopes,
            bindings: bindings,
            executableRegions: original.index.executableRegions,
            symbols: original.index.symbols,
            implRelations: original.index.implRelations,
            calls: original.index.calls,
            imports: original.index.imports,
            exports: original.index.exports,
            lineTable: original.index.lineTable
        ),
        names: original.names,
        strings: original.strings,
        containsErrorNodes: original.containsErrorNodes
    )
    let tamperedJSON = try JSONEncoder().encode(tampered)
    var data = Data([0x43, 0x49, 0x44, 0x58, 0x03])
    data.append(try (tamperedJSON as NSData).compressed(using: .lzfse) as Data)

    #expect(throws: DraftCodecError.self) {
        _ = try ContentIndexDraftCodec.decode(
            data, order: 0, bytes: bytes, expectedKey: key
        )
    }
}

// MARK: P1 — engine type hop

@Test
func typeHopResolvesAnnotatedParameterToStruct() throws {
    let session = try makeSession([
        "src/main.rs": """
        pub struct S { pub n: u32 }

        fn use_it(ps: &S) -> u32 {
            let local: Box<S> = Box::new(S { n: 1 });
            ps.n + local.n
        }
        """,
    ])
    let context = queryContext(for: session)
    let file = try pathID("src/main.rs", in: session)
    // The §2.1 probe: `ps` in `ps.n + local.n` lands on the struct `S`.
    let psOffset = try offset(line: 5, column: 5, in: session, path: "src/main.rs")
    guard case let .targets(psTargets, psCertainty) = try session.typeHop(
        file: file, offset: psOffset, context: context
    ) else {
        Issue.record("ps hop returned no targets")
        return
    }
    #expect(!psTargets.isEmpty)
    #expect(psCertainty == .probable)
    #expect(psTargets.contains { candidate in
        guard let facet = facet(named: "S", at: candidate, in: session) else { return false }
        return facet.kind == .rustStruct
            && session.names.resolve(facet.nameID) == "S"
    })

    // `local` follows `Box<S>` through the strip list to the same struct.
    let localOffset = try offset(line: 5, column: 12, in: session, path: "src/main.rs")
    guard case let .targets(localTargets, _) = try session.typeHop(
        file: file, offset: localOffset, context: context
    ) else {
        Issue.record("local hop returned no targets")
        return
    }
    #expect(localTargets.contains { candidate in
        guard let facet = facet(named: "S", at: candidate, in: session) else { return false }
        return facet.kind == .rustStruct
    })
}

@Test
func typeHopFollowsFieldAccessToFieldType() throws {
    let session = try makeSession([
        "src/main.rs": """
        struct Inner { x: u32 }
        struct Outer { inner: Inner }
        fn f(o: &Outer) -> u32 {
            o.inner.x
        }
        """,
    ])
    let context = queryContext(for: session)
    // The field access `inner` resolves through the field's typeRef.
    let innerOffset = try offset(line: 4, column: 7, in: session, path: "src/main.rs")
    guard case let .targets(targets, _) = try session.typeHop(
        file: pathID("src/main.rs", in: session), offset: innerOffset, context: context
    ) else {
        Issue.record("field hop returned no targets")
        return
    }
    #expect(targets.contains { candidate in
        guard let facet = facet(named: "Inner", at: candidate, in: session) else { return false }
        return facet.kind == .rustStruct
    })
}

@Test
func typeHopStopsAtTypeAlias() throws {
    let session = try makeSession([
        "src/main.rs": """
        struct Inner;
        type Handle = Inner;
        fn f(h: Handle) {}
        """,
    ])
    let context = queryContext(for: session)
    // The parameter `h` in `fn f(h: Handle)`.
    let hOffset = try offset(line: 3, column: 6, in: session, path: "src/main.rs")
    guard case let .targets(targets, _) = try session.typeHop(
        file: pathID("src/main.rs", in: session), offset: hOffset, context: context
    ) else {
        Issue.record("alias hop returned no targets")
        return
    }
    #expect(targets.contains { candidate in
        guard let facet = facet(named: "Handle", at: candidate, in: session) else { return false }
        return facet.kind == .rustTypeAlias
    })
    // The alias is not pierced (Q10).
    #expect(!targets.contains { candidate in
        facet(named: "Inner", at: candidate, in: session) != nil
    })
}

@Test
func typeHopCertaintyIsTheWeakerHop() throws {
    let session = try makeSession([
        "src/main.rs": """
        pub struct S { pub n: u32 }

        fn use_it(ps: &S) -> u32 {
            let made = S { n: 1 };
            ps.n + made.n
        }
        """,
    ])
    let context = queryContext(for: session)
    let file = try pathID("src/main.rs", in: session)
    // `ps` resolves strongly to its declaration; the second hop to `S` is
    // name-only (probable) — the combined certainty is the weaker hop.
    let psOffset = try offset(line: 5, column: 5, in: session, path: "src/main.rs")
    guard case let .targets(_, psCertainty) = try session.typeHop(
        file: file, offset: psOffset, context: context
    ) else {
        Issue.record("ps hop returned no targets")
        return
    }
    #expect(psCertainty == .probable)

    // A constructed head (`S { .. }`) caps at `.probable` (R1.2).
    let madeOffset = try offset(line: 5, column: 12, in: session, path: "src/main.rs")
    guard case let .targets(_, madeCertainty) = try session.typeHop(
        file: file, offset: madeOffset, context: context
    ) else {
        Issue.record("made hop returned no targets")
        return
    }
    #expect(madeCertainty <= .probable)
}

@Test
func resolveTypeHopCLIPrintsTypeLine() throws {
    let session = try makeSession([
        "src/main.rs": """
        pub struct S { pub n: u32 }

        fn use_it(ps: &S) -> u32 {
            let local: Box<S> = Box::new(S { n: 1 });
            ps.n + local.n
        }
        """,
    ])
    let psOffset = try offset(line: 5, column: 5, in: session, path: "src/main.rs")
    let hop = try session.typeHop(
        file: pathID("src/main.rs", in: session),
        offset: psOffset,
        context: queryContext(for: session)
    )
    let line = CodeInsight.codeinsightTypeHopLine(hop, session: session)
    #expect(line.contains("type -> src/main.rs:1:12"))
}


/// R8.1: the §2.1 probe set as a goldset run — ps, local, self, n, inner,
/// h, and the singly-bounded generic `r: T`.
@Test
func typeHopProbesResolveThroughGoldSet() throws {
    let fixture = repositoryRoot.appendingPathComponent("goldset/fixtures/type-hop")
    let report = try evaluateGoldSet(
        at: fixture.appendingPathComponent("type-hop.gold"),
        corpus: fixture
    )
    #expect(report.total == 7)
    #expect(report.failures.isEmpty)
}

@Test
func typeHopReadsFieldTypeFromTheFieldsOwnFile() throws {
    let session = try makeSession([
        "src/types.rs": """
        pub struct Inner { pub id: u64 }

        pub struct Outer {
            pub count: u32,
            pub inner: Inner,
        }
        """,
        "src/main.rs": """
        mod types;
        use types::{Inner, Outer};

        fn f(o: Outer) -> u64 {
            o.inner.id + o.count as u64
        }
        """,
    ])
    let context = queryContext(for: session)
    let main = try pathID("src/main.rs", in: session)
    // `o.inner` — the field lives in types.rs; its type must come from there.
    let innerOffset = try offset(line: 5, column: 7, in: session, path: "src/main.rs")
    guard case let .targets(targets, _) = try session.typeHop(
        file: main, offset: innerOffset, context: context
    ) else {
        Issue.record("cross-file field hop returned no targets")
        return
    }
    #expect(targets.contains { facet(named: "Inner", at: $0, in: session) != nil })
    // `o.count` — a primitive spelled in types.rs, named from types.rs bytes.
    let countOffset = try offset(line: 5, column: 20, in: session, path: "src/main.rs")
    guard case let .primitive(name) = try session.typeHop(
        file: main, offset: countOffset, context: context
    ) else {
        Issue.record("cross-file primitive field did not report a primitive")
        return
    }
    #expect(name == "u32")
}

// MARK: P4 — Python / TypeScript type hops

@Test
func pythonTypeHopResolvesAnnotatedParameterToClass() throws {
    let session = try makeSession([
        "src/lib.py": """
        class Repository:
            pass

        def f(repo: Optional["Repository"]):
            return repo
        """,
    ], language: .python)
    // The `repo` usage on line 5, column 12.
    let hop = try session.typeHop(
        file: try pathID("src/lib.py", in: session),
        offset: try offset(line: 5, column: 12, in: session, path: "src/lib.py"),
        context: queryContext(for: session)
    )
    guard case let .targets(targets, _) = hop else {
        Issue.record("python hop returned \\(hop)")
        return
    }
    #expect(targets.contains { candidate in
        facet(named: "Repository", at: candidate, in: session)?.kind == .pythonClass
    })
}

@Test
func typescriptTypeHopResolvesAnnotatedParameterToClass() throws {
    let session = try makeSession([
        "src/index.ts": """
        class Snapshot {}

        export function f(s: Snapshot): void {
            const _ = s;
        }
        """,
    ], language: .typescript)
    let hop = try session.typeHop(
        file: try pathID("src/index.ts", in: session),
        offset: try offset(line: 4, column: 15, in: session, path: "src/index.ts"),
        context: queryContext(for: session)
    )
    guard case let .targets(targets, _) = hop else {
        Issue.record("typescript hop returned \(hop)")
        return
    }
    #expect(targets.contains { candidate in
        facet(named: "Snapshot", at: candidate, in: session)?.kind == .typescriptClass
    })
}

@Test
func typeHopPythonProbesResolveThroughGoldSet() throws {
    let fixture = repositoryRoot.appendingPathComponent("goldset/fixtures/type-hop-py")
    let report = try evaluateGoldSet(
        at: fixture.appendingPathComponent("type-hop-py.gold"),
        corpus: fixture,
        language: .python
    )
    #expect(report.total == 3)
    #expect(report.failures.isEmpty)
}

@Test
func typeHopTypeScriptProbesResolveThroughGoldSet() throws {
    let fixture = repositoryRoot.appendingPathComponent("goldset/fixtures/type-hop-ts")
    let report = try evaluateGoldSet(
        at: fixture.appendingPathComponent("type-hop-ts.gold"),
        corpus: fixture,
        language: .typescript
    )
    #expect(report.total == 3)
    #expect(report.failures.isEmpty)
}
