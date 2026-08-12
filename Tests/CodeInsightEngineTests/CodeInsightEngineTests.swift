import CodeInsightCore
@testable import CodeInsightEngine
import Foundation
import Testing

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@Test
func resolvesUniqueRustImportAndFindsCaller() throws {
    let main = """
        mod db;
        mod util;
        use db::connect as open_db;
        fn main() { open_db(); }
        """
    try withProject([
        "main.rs": main,
        "db.rs": "pub fn connect() {}",
        "util.rs": "pub fn connect() {}",
    ]) { session in
        let context = queryContext(for: session)
        let mainPath = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: mainPath,
            offset: offset(of: "open_db();", in: main),
            context: context
        )
        let top = try #require(resolved.first)

        #expect(session.paths.resolve(top.target.pathID) == "db.rs")
        #expect(top.certainty == .strong)
        #expect(hasUniqueImport(top.evidence))
        #expect(session.paths.resolve(top.target.pathID) != "util.rs")

        let callers = try session.callers(of: "connect", context: context)
        let caller = try #require(callers.first {
            session.paths.resolve($0.callSite.pathID) == "main.rs"
        })
        #expect(caller.callSite.localKind == .callSite)
        #expect(caller.certainty == .strong)
        #expect(hasUniqueImport(caller.evidence))

        let definitions = try session.definitions(of: "connect", context: context)
        #expect(definitions.allSatisfy { $0.0.localKind == .declarationFacet })
        #expect(definitions.map { session.paths.resolve($0.2) } == ["db.rs", "util.rs"])
    }
}

@Test
func resolvesNearestShadowedBinding() throws {
    let source = "fn f() { let g = 1; { let g = 2; g; } }"
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let offset = offset(of: "g;", in: source, options: .backwards)
        let resolved = try session.resolve(
            file: path,
            offset: offset,
            context: queryContext(for: session)
        )
        let top = try #require(resolved.first)

        #expect(top.certainty == .strong)
        #expect(top.target.localIndex == 1)
        #expect(hasLexicalBinding(top.evidence, index: 1))
    }
}

@Test
func tokenRangeLocatesNameWithoutResolvingCandidates() throws {
    let source = "fn target() {}\nfn main() { target(); }"
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let start = offset(of: "target();", in: source)

        #expect(try session.tokenRange(
            file: path,
            offset: start + 2,
            context: queryContext(for: session)
        ) == ByteRange(lowerBound: start, upperBound: start + 6))
        #expect(try session.tokenRange(
            file: path,
            offset: offset(of: " { target", in: source),
            context: queryContext(for: session)
        ) == nil)
    }
}

@Test
func qualifiedCallQualifierResolvesItsOwnSymbol() throws {
    let source = """
        struct Config;
        impl Config { fn set() {} }
        enum ConfigKey { Backend }
        fn f() { Config::set(ConfigKey::Backend, 1); }
        """
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let index = try #require(session.content(at: path)?.1)
        #expect(index.imports.isEmpty)
        #expect(index.symbols.contains {
            session.names.resolve($0.nameID) == "Config"
        })

        let resolved = try session.resolve(
            file: path,
            offset: offset(of: "Config::set", in: source),
            context: queryContext(for: session)
        )
        let top = try #require(resolved.first)
        #expect(top.target.localKind == .declarationFacet)
        let target = try #require(session.content(at: top.target.pathID)?.1)
        let targetIndex = Int(top.target.localIndex)
        let facet = try #require(
            target.symbols.indices.contains(targetIndex)
                ? target.symbols[targetIndex] : nil
        )

        #expect(session.names.resolve(facet.nameID) == "Config")
        #expect(session.names.resolve(facet.nameID) != "set")
    }
}

@Test
func methodCallReceiverResolvesMethodsWithoutClaimingStrong() throws {
    let source = """
        struct A; impl A { fn tick(&self) {} }
        struct B; impl B { fn tick(&self) {} }
        fn probe<T>(a: T) { a.tick(); }
        """
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let index = try #require(session.content(at: path)?.1)
        let receiverOffset = offset(of: "a.tick", in: source)
        let call = try #require(index.calls.first)
        let parameter = try #require(index.bindings.first {
            session.names.resolve($0.localNameID) == "a"
        })
        let receiverRange = try #require(call.receiverRange)

        #expect(receiverRange == ByteRange(
            lowerBound: receiverOffset,
            upperBound: receiverOffset + 1
        ))
        #expect(parameter.declarationRange.length == receiverRange.length)
        #expect(!parameter.declarationRange.contains(receiverOffset))
        #expect(try session.tokenRange(
            file: path,
            offset: receiverOffset,
            context: queryContext(for: session)
        ) == receiverRange)

        let resolved = try session.resolve(
            file: path,
            offset: receiverOffset,
            context: queryContext(for: session)
        )
        let firstTickOffset = offset(of: "tick(&self)", in: source)

        #expect(resolved.contains {
            guard $0.target.localKind == .declarationFacet,
                  let target = session.content(at: $0.target.pathID)?.1,
                  target.symbols.indices.contains(Int($0.target.localIndex))
            else { return false }
            return target.symbols[Int($0.target.localIndex)].nameRange.lowerBound
                == firstTickOffset
        })
        #expect(resolved.allSatisfy { $0.certainty <= .possible })
    }
}

@Test
func qualifiedCallQualifierUsesItsOwnRangeWhenNoSymbolMatches() throws {
    let source = "fn target() {}\nfn f() { unknown::target(); }"
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let index = try #require(session.content(at: path)?.1)
        let qualifierOffset = offset(of: "unknown::", in: source)
        let call = try #require(index.calls.first)
        let qualifierRange = try #require(call.qualifierRange)

        #expect(qualifierRange == ByteRange(
            lowerBound: qualifierOffset,
            upperBound: qualifierOffset + UInt32("unknown".utf8.count)
        ))
        #expect(try session.tokenRange(
            file: path,
            offset: qualifierOffset,
            context: queryContext(for: session)
        ) == qualifierRange)

        let resolved = try session.resolve(
            file: path,
            offset: qualifierOffset,
            context: queryContext(for: session)
        )
        let top = try #require(resolved.first)
        let target = try #require(session.content(at: top.target.pathID)?.1)
        let facet = try #require(
            target.symbols.indices.contains(Int(top.target.localIndex))
                ? target.symbols[Int(top.target.localIndex)] : nil
        )

        #expect(session.names.resolve(facet.nameID) == "target")
    }
}

@Test
func marksFunctionValueCallAsCallback() throws {
    let source = "fn f() { let h = |x: u32| x; h(1); }"
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: offset(of: "h(1)", in: source),
            context: queryContext(for: session)
        )
        let top = try #require(resolved.first)

        #expect(top.certainty == .strong)
        #expect(top.dispatch == .callback)
        #expect(hasLexicalBinding(top.evidence, index: 0))
    }
}

@Test
func methodCallsStayPossibleAcrossImpls() throws {
    let source = """
        struct A; impl A { fn close(&self) {} }
        struct B; impl B { fn close(&self) {} }
        fn f<T>(c: T) { c.close(); }
        """
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: offset(of: "close();", in: source),
            context: queryContext(for: session)
        )

        #expect(resolved.count == 2)
        #expect(resolved.allSatisfy { $0.certainty == .possible })
        #expect(resolved.allSatisfy { $0.dispatch == .dynamicDispatch })
        #expect(resolved.allSatisfy { hasMethodNameOnly($0.evidence) })
    }
}

@Test
func annotatedReceiverResolvesOnlyItsImplStrongly() throws {
    let source = """
        struct A; impl A { fn close(&self) {} }
        struct B; impl B { fn close(&self) {} }
        fn f(receiver: A) { receiver.close(); }
        """
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: offset(of: "close();", in: source),
            context: queryContext(for: session)
        )

        #expect(resolved.count == 1)
        #expect(resolved.first?.certainty == .strong)
        #expect(resolved.first?.dispatch == .direct)
        #expect(resolved.first.map { resolvedImplType(of: $0, in: session) } == "A")
        #expect(resolved.allSatisfy {
            hasReceiverType($0.evidence, named: "A", in: session)
        })
    }
}

@Test
func selfReceiverUsesItsEnclosingImplType() throws {
    let source = """
        struct A;
        impl A {
            fn close(&self) {}
            fn f(&self) { self.close(); }
        }
        """
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: offset(of: "close();", in: source, options: .backwards),
            context: queryContext(for: session)
        )

        #expect(resolved.count == 1)
        #expect(resolved.first?.certainty == .strong)
        #expect(resolved.first.map { resolvedImplType(of: $0, in: session) } == "A")
        #expect(resolved.allSatisfy {
            hasReceiverType($0.evidence, named: "A", in: session)
        })
    }
}

@Test
func constructedReceiverResolvesItsImplProbably() throws {
    let source = """
        struct A;
        impl A {
            fn new() -> Self { A }
            fn close(&self) {}
        }
        fn f() { let receiver = A::new(); receiver.close(); }
        """
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: offset(of: "close();", in: source, options: .backwards),
            context: queryContext(for: session)
        )

        #expect(resolved.count == 1)
        #expect(resolved.first?.certainty == .probable)
        #expect(resolved.first.map { resolvedImplType(of: $0, in: session) } == "A")
        #expect(resolved.allSatisfy {
            hasReceiverType($0.evidence, named: "A", in: session)
        })
    }
}

@Test
func shadowedReceiverUsesTheNearestTypedBinding() throws {
    let source = """
        struct A; impl A { fn close(&self) {} }
        struct B; impl B { fn close(&self) {} }
        fn f(receiver: A) {
            {
                let receiver: B = B;
                receiver.close();
            }
        }
        """
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: offset(of: "close();", in: source, options: .backwards),
            context: queryContext(for: session)
        )

        #expect(resolved.count == 1)
        #expect(resolved.first?.certainty == .strong)
        #expect(resolved.first.map { resolvedImplType(of: $0, in: session) } == "B")
        #expect(resolved.allSatisfy {
            hasReceiverType($0.evidence, named: "B", in: session)
        })
    }
}

@Test
func traitObjectReceiverStaysPossibleByMethodName() throws {
    let source = """
        trait Close { fn close(&self); }
        fn f(receiver: &dyn Close) { receiver.close(); }
        """
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: offset(of: "close();", in: source),
            context: queryContext(for: session)
        )

        #expect(!resolved.isEmpty)
        #expect(resolved.allSatisfy { $0.certainty == .possible })
        #expect(resolved.allSatisfy { $0.dispatch == .dynamicDispatch })
        #expect(resolved.allSatisfy { hasMethodNameOnly($0.evidence) })
    }
}

@Test
func annotatedTraitImplReceiverUsesTraitDispatch() throws {
    let source = """
        trait Close { fn close(&self); }
        struct A;
        impl Close for A { fn close(&self) {} }
        fn f(receiver: A) { receiver.close(); }
        """
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: offset(of: "close();", in: source, options: .backwards),
            context: queryContext(for: session)
        )

        #expect(resolved.count == 1)
        #expect(resolved.first?.certainty == .strong)
        #expect(resolved.first?.dispatch == .traitDispatch)
        #expect(resolved.first.map { resolvedImplType(of: $0, in: session) } == "A")
    }
}

@Test
func receiverTypedCallersPreserveStrongAndProbableCertainty() throws {
    let source = """
        struct A;
        impl A {
            fn new() -> Self { A }
            fn close(&self) {}
        }
        fn annotated(receiver: A) { receiver.close(); }
        fn inferred() { let receiver = A::new(); receiver.close(); }
        """
    try withProject(["main.rs": source]) { session in
        let callers = try session.callers(
            of: "close",
            context: queryContext(for: session)
        )

        #expect(callers.map(\.certainty) == [.strong, .probable])
        #expect(callers.allSatisfy {
            hasReceiverType($0.evidence, named: "A", in: session)
        })
    }
}

@Test
func outgoingCallsResolveEveryRustCallKind() throws {
    let source = """
        fn direct_target() {}
        fn qualified_target() {}
        struct Receiver;
        impl Receiver { fn method_target(&self) {} }
        fn caller(receiver: Receiver) {
            direct_target();
            crate::qualified_target();
            receiver.method_target();
            unknown_macro!();
        }
        """
    try withProject(["main.rs": source]) { session in
        let context = queryContext(for: session)
        let caller = try #require(
            session.definitions(of: "caller", context: context).first?.0
        )
        let result = try session.outgoingCalls(from: caller, context: context)

        #expect(result.completeness == .complete)
        #expect(result.calls.map(\.calleeName) == [
            "direct_target", "qualified_target", "method_target", "unknown_macro",
        ])
        #expect(result.calls.map(\.call.syntacticKind) == [
            .directCall, .qualifiedCall, .methodCall, .macroInvocation,
        ])

        let direct = try #require(result.calls[0].candidates.first)
        #expect(direct.certainty == .strong)
        #expect(direct.dispatch == .direct)
        #expect(direct.provenance == .fuzzyResolver)
        #expect(direct.completeness == .complete)

        let qualified = try #require(result.calls[1].candidates.first)
        #expect(qualified.certainty == .strong)
        #expect(qualified.dispatch == .direct)
        #expect(qualified.provenance == .fuzzyResolver)
        #expect(qualified.completeness == .complete)

        let method = try #require(result.calls[2].candidates.first)
        #expect(method.certainty == .strong)
        #expect(method.dispatch == .direct)
        #expect(method.provenance == .fuzzyResolver)
        #expect(method.completeness == .complete)
        #expect(hasReceiverType(method.evidence, named: "Receiver", in: session))
        #expect(result.calls[3].candidates.isEmpty)
    }
}

@Test
func outgoingCallsIncludeClosuresButExcludeNestedNamedFunctions() throws {
    let source = """
        fn direct() {}
        fn in_closure() {}
        fn in_nested() {}
        fn outer() {
            direct();
            let closure = || in_closure();
            fn nested() { in_nested(); }
            nested();
        }
        """
    try withProject(["main.rs": source]) { session in
        let context = queryContext(for: session)
        let outer = try #require(
            session.definitions(of: "outer", context: context).first?.0
        )
        let nested = try #require(
            session.definitions(of: "nested", context: context).first?.0
        )

        #expect(try session.outgoingCalls(
            from: outer,
            context: context
        ).calls.map(\.calleeName) == ["direct", "in_closure", "nested"])
        #expect(try session.outgoingCalls(
            from: nested,
            context: context
        ).calls.map(\.calleeName) == ["in_nested"])
    }
}

@Test
func outgoingCallsFollowConstantInitializerRegionOwnership() throws {
    let source = "fn initialize() {}\nconst VALUE: () = initialize();"
    try withProject(["main.rs": source]) { session in
        let context = queryContext(for: session)
        let constant = try #require(
            session.definitions(of: "VALUE", context: context).first?.0
        )
        let result = try session.outgoingCalls(from: constant, context: context)

        #expect(result.completeness == .complete)
        #expect(result.calls.map(\.calleeName) == ["initialize"])
    }
}

@Test
func outgoingCallsTruncateAfterFirst512CallSites() throws {
    let body = Array(repeating: "target();", count: 513).joined(separator: "\n")
    let source = "fn target() {}\nfn caller() {\n\(body)\n}"
    try withProject(["main.rs": source]) { session in
        let context = queryContext(for: session)
        let caller = try #require(
            session.definitions(of: "caller", context: context).first?.0
        )
        let result = try session.outgoingCalls(from: caller, context: context)

        #expect(result.completeness == .truncated)
        #expect(result.calls.count == 512)
        #expect(result.calls.map(\.call.range.lowerBound) == result.calls
            .map(\.call.range.lowerBound).sorted())
        #expect(result.calls.last?.callSite.localIndex == 511)
    }
}

@Test
func findsTraitImplementationsAndMethodOverrides() throws {
    try withProject([
        "main.rs": """
            trait Render { fn render(&self); }
            struct Simple;
            impl Render for Simple { fn render(&self) {} }
            struct Boxed<T>(T);
            impl<T> Render for Boxed<T> { fn render(&self) {} }
            struct Inherent;
            impl Inherent { fn render(&self) {} }
            """,
        "a.rs": """
            trait Duplicate { fn act(&self); }
            struct A;
            impl Duplicate for A { fn act(&self) {} }
            """,
        "b.rs": """
            trait Duplicate { fn act(&self); }
            struct B;
            impl Duplicate for B { fn act(&self) {} }
            """,
    ]) { session in
        let context = queryContext(for: session)
        let implementations = try session.implementations(
            ofTrait: "Render",
            context: context
        )
        #expect(implementations.map(\.typeName) == ["Simple", "Boxed"])
        #expect(implementations.allSatisfy { $0.certainty == .strong })
        #expect(implementations.allSatisfy {
            $0.traitDefinitions.count == 1
                && $0.traitDefinitions[0].certainty == .strong
                && $0.traitDefinitions[0].dispatch == .traitDispatch
        })

        let renderTrait = try #require(session.definitions(
            of: "Render",
            context: context
        ).first)
        let renderIndex = try #require(session.contentIndexes.first(where: {
            key, _ in key.contentID == session.manifest.files.first(where: {
                $0.pathID == renderTrait.2
            })?.contentID
        })?.value)
        let renderMethodIndex = try #require(renderIndex.symbols.firstIndex {
            $0.kind == .rustMethod
                && $0.parentFacetIndex == renderTrait.0.localIndex
                && session.names.resolve($0.nameID) == "render"
        })
        let overrides = try session.overrides(
            ofTraitMethod: SymbolOccurrenceID(
                snapshotID: session.snapshotID,
                pathID: renderTrait.2,
                localKind: .declarationFacet,
                localIndex: UInt32(renderMethodIndex)
            ),
            context: context
        )
        #expect(overrides.count == 2)
        #expect(overrides.allSatisfy {
            $0.certainty == .strong && $0.dispatch == .traitDispatch
        })

        let ambiguous = try session.implementations(
            ofTrait: "Duplicate",
            context: context
        )
        #expect(ambiguous.map(\.typeName) == ["A", "B"])
        #expect(ambiguous.allSatisfy {
            $0.certainty == .possible
                && $0.traitDefinitions.count == 2
                && $0.traitDefinitions.allSatisfy { $0.certainty == .possible }
        })
    }
}

@Test
func deduplicatesContentButKeepsEveryManifestPath() throws {
    let source = "pub fn same() {}"
    try withProject(["a.rs": source, "nested/b.rs": source]) { session in
        #expect(session.stats.fileCount == 2)
        #expect(session.stats.uniqueContentCount == 1)
        #expect(session.manifest.files.count == 2)
        #expect(Set(session.manifest.files.map {
            session.paths.resolve($0.pathID)
        }) == ["a.rs", "nested/b.rs"])
    }
}

@Test
func indexingIsDeterministicAcrossRuns() throws {
    try withProjectRoot(determinismFixture) { root in
        let first = try ProjectIndexer().index(root: root)
        let second = try ProjectIndexer().index(root: root)

        #expect(canonicalSessionDump(first) == canonicalSessionDump(second))
        #expect(aggregateStatsDump(first.stats) == aggregateStatsDump(second.stats))
    }
}

@Test
func analysisProfileIDIsDeterministicAcrossIndexes() throws {
    try withProjectRoot(determinismFixture) { root in
        let first = try ProjectIndexer().index(root: root)
        let second = try ProjectIndexer().index(root: root)

        #expect(first.analysisProfile.id == second.analysisProfile.id)
    }
}

@Test
func parallelIndexMatchesSerialIndex() throws {
    try withProjectRoot(determinismFixture) { root in
        let serial = try ProjectIndexer(parallelism: 1).index(root: root)
        let parallel = try ProjectIndexer(parallelism: 4).index(root: root)

        #expect(canonicalSessionDump(serial) == canonicalSessionDump(parallel))
        #expect(aggregateStatsDump(serial.stats) == aggregateStatsDump(parallel.stats))
    }
}

@Test
func storeAndSnapshotViewPreserveFixtureFieldsAndQueries() throws {
    let root = repositoryRoot.appendingPathComponent(
        "Tests/RustExtractorTests/Fixtures/use_alias"
    )
    let session = try ProjectIndexer().index(root: root)
    let store = session.store
    let view = session.snapshotView

    #expect(view.store === store)
    #expect(session.names === store.names)
    #expect(session.paths === store.paths)
    #expect(session.strings === store.strings)
    #expect(session.manifest.snapshotID == view.manifest.snapshotID)
    #expect(session.manifest.files.map(\.pathID) == view.manifest.files.map(\.pathID))
    #expect(Set(session.contentIndexes.keys) == Set(store.contentIndexes.keys))
    #expect(session.sourceBytesByContent == store.sourceBytesByContent)
    #expect(session.moduleChildren == view.moduleMap.moduleChildren)
    #expect(aggregateStatsDump(session.stats) == aggregateStatsDump(view.stats))
    #expect(session.stats.elapsedMilliseconds == view.stats.elapsedMilliseconds)
    #expect(session.analysisProfile.id == view.analysisProfile.id)
    #expect(session.analysisProfile.projectRoot == view.analysisProfile.projectRoot)

    let rebuiltPosting = NamePosting(indexes: store.contentIndexes)
    #expect(store.namePosting.definitions.mapValues(\.count)
        == rebuiltPosting.definitions.mapValues(\.count))
    #expect(store.namePosting.calls.mapValues(\.count)
        == rebuiltPosting.calls.mapValues(\.count))

    let context = queryContext(for: session)
    let mainPath = try #require(pathID("main.rs", in: session))
    let source = try String(
        contentsOf: root.appendingPathComponent("main.rs"),
        encoding: .utf8
    )
    let resolved = try session.resolve(
        file: mainPath,
        offset: offset(of: "open_db();", in: source),
        context: context
    )
    let callers = try session.callers(of: "connect", context: context)

    #expect(resolved.map {
        "\(session.paths.resolve($0.target.pathID)):\($0.target.localKind):\($0.target.localIndex):\($0.certainty)"
    } == ["db.rs:declarationFacet:0:strong"])
    #expect(callers.map {
        "\(session.paths.resolve($0.callSite.pathID)):\($0.callSite.localKind):\($0.callSite.localIndex):\($0.certainty)"
    } == ["main.rs:callSite:0:strong"])
}

@Test
func engineSessionExposesOnlyTheClassifierSelectedLanguageMode() throws {
    try withProject([
        "main.rs": "fn active() {}\nfn caller() { active(); }\n",
    ]) { session in
        let active = try #require(session.contentIndexes.first)
        let bytes = try #require(session.sourceBytesByContent[active.key.contentID])

        func rekey(_ mode: LanguageMode) -> ContentIndex {
            ContentIndex(
                key: ContentIndexKey(
                    contentID: active.key.contentID,
                    languageMode: mode,
                    grammarVersion: active.key.grammarVersion,
                    extractorVersion: active.key.extractorVersion
                ),
                scopes: active.value.scopes,
                bindings: active.value.bindings,
                executableRegions: active.value.executableRegions,
                symbols: active.value.symbols,
                implRelations: active.value.implRelations,
                calls: active.value.calls,
                imports: active.value.imports,
                exports: active.value.exports,
                lineTable: active.value.lineTable
            )
        }

        let foreignLanguage = rekey(LanguageMode(language: .python))
        let foreignVariant = rekey(LanguageMode(
            language: .rust,
            variant: "alternate"
        ))
        session.store.insert(
            foreignLanguage,
            bytes: bytes,
            containsErrorNodes: false
        )
        session.store.insert(
            foreignVariant,
            bytes: bytes,
            containsErrorNodes: false
        )

        let rebuilt = EngineSession(
            store: session.store,
            snapshotView: SnapshotView(
                store: session.store,
                manifest: session.manifest,
                stats: session.stats,
                analysisProfile: session.analysisProfile,
                extractor: session.extractor
            )
        )
        let activeKeys = Set(rebuilt.contentIndexes.keys)
        #expect(activeKeys == Set([active.key]))
        let path = try #require(pathID("main.rs", in: rebuilt))
        #expect(rebuilt.content(at: path)?.0 == active.key)
        #expect(rebuilt.namePosting.definitions.values.flatMap { $0 }.allSatisfy {
            activeKeys.contains($0.key)
        })
        #expect(rebuilt.namePosting.calls.values.flatMap { $0 }.allSatisfy {
            activeKeys.contains($0.key)
        })
        #expect(try rebuilt.definitions(
            of: "active",
            context: queryContext(for: rebuilt)
        ).count == 1)
    }
}

@Test
func rejectsWrongSnapshotAcrossEveryQueryAPI() throws {
    try withProject(["main.rs": "fn main() {}"] ) { session in
        let definition = try #require(session.definitions(
            of: "main",
            context: queryContext(for: session)
        ).first?.0)
        let wrong = QueryContext(
            snapshotID: SnapshotID(rawValue: UUID()),
            analysisProfileID: session.analysisProfile.id,
            generation: 1
        )
        let path = try #require(pathID("main.rs", in: session))
        var failures = 0
        do { _ = try session.definitions(of: "main", context: wrong) }
        catch { failures += 1 }
        do { _ = try session.callers(of: "main", context: wrong) }
        catch { failures += 1 }
        do { _ = try session.resolve(file: path, offset: 3, context: wrong) }
        catch { failures += 1 }
        do { _ = try session.tokenRange(file: path, offset: 3, context: wrong) }
        catch { failures += 1 }
        do { _ = try session.outgoingCalls(from: definition, context: wrong) }
        catch { failures += 1 }
        do { _ = try session.implementations(ofTrait: "main", context: wrong) }
        catch { failures += 1 }
        do { _ = try session.overrides(ofTraitMethod: definition, context: wrong) }
        catch { failures += 1 }
        do {
            _ = try session.searchSymbols(
                query: "main",
                limit: 10,
                boost: SearchBoost(),
                context: wrong
            )
        } catch { failures += 1 }
        do {
            _ = try session.search(
                ContentSearchQuery(pattern: "main"),
                context: wrong
            )
        } catch { failures += 1 }
        #expect(failures == 9)
    }
}

@Test
func rejectsWrongProfileAcrossEveryQueryAPI() throws {
    try withProject(["main.rs": "fn main() {}"] ) { session in
        let definition = try #require(session.definitions(
            of: "main",
            context: queryContext(for: session)
        ).first?.0)
        let wrong = QueryContext(
            snapshotID: session.snapshotID,
            analysisProfileID: AnalysisProfileID(rawValue: UUID()),
            generation: 1
        )
        let path = try #require(pathID("main.rs", in: session))
        var failures = 0
        do { _ = try session.definitions(of: "main", context: wrong) }
        catch { failures += 1 }
        do { _ = try session.callers(of: "main", context: wrong) }
        catch { failures += 1 }
        do { _ = try session.resolve(file: path, offset: 3, context: wrong) }
        catch { failures += 1 }
        do { _ = try session.tokenRange(file: path, offset: 3, context: wrong) }
        catch { failures += 1 }
        do { _ = try session.outgoingCalls(from: definition, context: wrong) }
        catch { failures += 1 }
        do { _ = try session.implementations(ofTrait: "main", context: wrong) }
        catch { failures += 1 }
        do { _ = try session.overrides(ofTraitMethod: definition, context: wrong) }
        catch { failures += 1 }
        do {
            _ = try session.searchSymbols(
                query: "main",
                limit: 10,
                boost: SearchBoost(),
                context: wrong
            )
        } catch { failures += 1 }
        do {
            _ = try session.search(
                ContentSearchQuery(pattern: "main"),
                context: wrong
            )
        } catch { failures += 1 }
        #expect(failures == 9)
    }
}

@Test
func externalRustImportDoesNotCrash() throws {
    let source = "use std::io::Read; fn f() { Read(); }"
    try withProject(["main.rs": source]) { session in
        let path = try #require(pathID("main.rs", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: offset(of: "Read();", in: source),
            context: queryContext(for: session)
        )

        let top = try #require(resolved.first)
        #expect(top.certainty == .unresolved)
        #expect(top.target.localKind == .importBinding)
    }
}

@Test
func indexesProgrammaticallyGeneratedProject() throws {
    let files = Dictionary(uniqueKeysWithValues: (0..<200).map { fileIndex in
        let source = (0..<20).map {
            "fn file_\(fileIndex)_function_\($0)() {}"
        }.joined(separator: "\n")
        return ("file_\(fileIndex).rs", source)
    })

    try withProject(files) { session in
        #expect(session.stats.fileCount == 200)
        #expect(session.stats.uniqueContentCount == 200)
        #expect(session.stats.symbolCount == 4_000)
        #expect(session.stats.bindingCount == 0)
        #expect(session.stats.callCount == 0)
        #expect(session.stats.importCount == 0)
        #expect(session.stats.filesWithErrorNodes == 0)
    }
}

@Test
func evaluatesGoldSetMetricsAndKnownFailures() throws {
    let fixture = repositoryRoot.appendingPathComponent("goldset/fixtures/runner")
    let report = try evaluateGoldSet(
        at: fixture.appendingPathComponent("sample.gold"),
        corpus: fixture
    )

    #expect(report.total == 9)
    #expect(report.defTop1Passed == 1)
    #expect(report.defTop1Total == 2)
    #expect(report.def5Top5Passed == 1)
    #expect(report.def5Top5Total == 1)
    #expect(report.noStrongViolations == 1)
    #expect(report.unresolvedPassed == 1)
    #expect(report.unresolvedTotal == 1)
    #expect(report.noResults == 1)
    #expect(report.knownFailures == 2)
    #expect(report.unexpectedFailures == 0)

    let failing = try evaluateGoldSet(
        at: fixture.appendingPathComponent("unexpected.gold"),
        corpus: fixture
    )
    #expect(failing.total == 1)
    #expect(failing.unexpectedFailures == 1)
}

@Test
func symbolSearchNormalizesAndUsesEveryRecallRoute() throws {
    let normalized = SymbolSearchIndex.normalize("HTTPServer_value")
    #expect(normalized.text == "httpservervalue")
    #expect(normalized.wordStarts == [0, 4, 10])
    #expect(normalized.acronym == "hsv")

    try withProject([
        "main.rs": "fn handle_connection() {} fn hyper_client() {} fn middle() {}",
    ]) { session in
        let context = queryContext(for: session)
        let prefix = try searchedNames("hand", session: session, context: context)
        let acronym = try searchedNames("hc", session: session, context: context)
        let trigram = try searchedNames("ddl", session: session, context: context)
        #expect(prefix.contains("handle_connection"))
        #expect(acronym.contains("hyper_client"))
        #expect(trigram.contains("middle"))
    }
}

@Test
func symbolSearchRanksSubsequenceAndWordBoundaries() throws {
    try withProject([
        "main.rs": """
            fn handle_connection() {}
            fn handleconnection() {}
            fn handle_disconnected_connection() {}
            """,
    ]) { session in
        let context = queryContext(for: session)
        let fuzzy = try searchedNames("hndlconn", session: session, context: context)
        #expect(fuzzy.first == "handle_connection")

        let boundary = try searchedNames("handlecon", session: session, context: context)
        #expect(boundary.first == "handle_connection")
    }
}

@Test
func symbolSearchBoostsCurrentFileAndIsDeterministic() throws {
    try withProject([
        "a.rs": "fn target_name() {}",
        "nested/b.rs": "fn target_name() {}",
    ]) { session in
        let context = queryContext(for: session)
        let current = try #require(pathID("nested/b.rs", in: session))
        let boost = SearchBoost(currentFile: current, recentFiles: [])
        let first = try session.searchSymbols(
            query: "target",
            limit: 10,
            boost: boost,
            context: context
        )
        let second = try session.searchSymbols(
            query: "target",
            limit: 10,
            boost: boost,
            context: context
        )

        #expect(first.first?.path == "nested/b.rs")
        #expect(first.count == second.count)
        #expect(zip(first, second).allSatisfy { lhs, rhs in
            lhs.path == rhs.path
                && lhs.occurrence.localIndex == rhs.occurrence.localIndex
                && lhs.score == rhs.score
                && lhs.matchRanges == rhs.matchRanges
        })
    }
}

@Test
func pythonResolverResolvesAbsoluteAndRelativeNamedAliasesStrongly() throws {
    let modelsSource = "def fetch():\n    pass\n"
    let otherSource = "def make():\n    pass\n"
    let mainSource = """
        from .models import fetch as go
        from pkg.other import make as build

        go()
        build()
        """
    let goCall = byteRange(of: "go()", in: mainSource)
    let buildCall = byteRange(of: "build()", in: mainSource)
    try withManualPythonProject([
        PythonFileSpec(path: "pkg/__init__.py", source: ""),
        PythonFileSpec(
            path: "pkg/models.py",
            source: modelsSource,
            symbols: [
                PythonTestSymbol(
                    name: "fetch",
                    kind: .pythonFunction,
                    parent: nil,
                    range: byteRange(of: "fetch", in: modelsSource)
                )
            ]
        ),
        PythonFileSpec(
            path: "pkg/other.py",
            source: otherSource,
            symbols: [
                PythonTestSymbol(
                    name: "make",
                    kind: .pythonFunction,
                    parent: nil,
                    range: byteRange(of: "make", in: otherSource)
                )
            ]
        ),
        PythonFileSpec(
            path: "pkg/main.py",
            source: mainSource,
            imports: [
                PythonTestImport(
                    specifier: ".models",
                    imported: "fetch",
                    local: "go",
                    kind: .named,
                    range: byteRange(of: ".models import fetch", in: mainSource)
                ),
                PythonTestImport(
                    specifier: "pkg.other",
                    imported: "make",
                    local: "build",
                    kind: .named,
                    range: byteRange(of: "pkg.other import make", in: mainSource)
                )
            ],
            calls: [
                PythonTestCall(
                    name: "go",
                    kind: .directCall,
                    range: ByteRange(
            lowerBound: goCall.lowerBound,
            upperBound: goCall.upperBound
        ),
                    nameRange: ByteRange(
                        lowerBound: goCall.lowerBound,
                        upperBound: goCall.lowerBound + 2
                    ),
                    receiverRange: nil
                ),
                PythonTestCall(
                    name: "build",
                    kind: .directCall,
                    range: ByteRange(
            lowerBound: buildCall.lowerBound,
            upperBound: buildCall.upperBound
        ),
                    nameRange: ByteRange(
                        lowerBound: buildCall.lowerBound,
                        upperBound: buildCall.lowerBound + 5
                    ),
                    receiverRange: nil
                )
            ]
        )
    ]) { session in
        let context = queryContext(for: session)
        let mainPath = try #require(pathID("pkg/main.py", in: session))
        let relative = try session.resolve(
            file: mainPath,
            offset: goCall.lowerBound,
            context: context
        )
        let absolute = try session.resolve(
            file: mainPath,
            offset: buildCall.lowerBound,
            context: context
        )

        #expect(session.paths.resolve(relative.first?.target.pathID ?? .init(rawValue: .max))
            == "pkg/models.py")
        #expect(relative.first?.certainty == .strong)
        #expect(hasUniqueImport(relative.first?.evidence ?? []))
        #expect(session.paths.resolve(absolute.first?.target.pathID ?? .init(rawValue: .max))
            == "pkg/other.py")
        #expect(absolute.first?.certainty == .strong)
        #expect(hasUniqueImport(absolute.first?.evidence ?? []))
    }
}

@Test
func pythonResolverUsesSrcOnlyModuleIdentity() throws {
    let modelsSource = "def fetch():\n    pass\n"
    let mainSource = "from .models import fetch as go\ngo()\n"
    let goCall = byteRange(of: "go()", in: mainSource)
    try withManualPythonProject([
        PythonFileSpec(path: "src/pkg/__init__.py", source: ""),
        PythonFileSpec(
            path: "src/pkg/models.py",
            source: modelsSource,
            symbols: [
                PythonTestSymbol(
                    name: "fetch",
                    kind: .pythonFunction,
                    parent: nil,
                    range: byteRange(of: "fetch", in: modelsSource)
                )
            ]
        ),
        PythonFileSpec(
            path: "src/pkg/main.py",
            source: mainSource,
            imports: [
                PythonTestImport(
                    specifier: ".models",
                    imported: "fetch",
                    local: "go",
                    kind: .named,
                    range: byteRange(of: ".models import", in: mainSource)
                )
            ],
            calls: [
                PythonTestCall(
                    name: "go",
                    kind: .directCall,
                    range: ByteRange(
                        lowerBound: goCall.lowerBound,
                        upperBound: goCall.lowerBound + 2
                    ),
                    nameRange: ByteRange(
                        lowerBound: goCall.lowerBound,
                        upperBound: goCall.lowerBound + 2
                    ),
                    receiverRange: nil
                )
            ]
        )
    ]) { session in
        let mainPath = try #require(pathID("src/pkg/main.py", in: session))
        let resolved = try session.resolve(
            file: mainPath,
            offset: goCall.lowerBound,
            context: queryContext(for: session)
        )

        #expect(session.paths.resolve(resolved.first?.target.pathID ?? .init(rawValue: .max))
            == "src/pkg/models.py")
        #expect(resolved.first?.certainty == .strong)
    }
}

@Test
func pythonRelativeImportFromPackageInitKeepsCurrentPackage() throws {
    let modelsSource = "def fetch():\n    pass\n"
    let initSource = "from .models import fetch as go\ngo()\n"
    let goCall = byteRange(of: "go()", in: initSource)
    try withManualPythonProject([
        PythonFileSpec(
            path: "pkg/__init__.py",
            source: initSource,
            imports: [
                PythonTestImport(
                    specifier: ".models",
                    imported: "fetch",
                    local: "go",
                    kind: .named,
                    range: byteRange(of: ".models import", in: initSource)
                )
            ],
            calls: [
                PythonTestCall(
                    name: "go",
                    kind: .directCall,
                    range: ByteRange(
                        lowerBound: goCall.lowerBound,
                        upperBound: goCall.lowerBound + 2
                    ),
                    nameRange: ByteRange(
                        lowerBound: goCall.lowerBound,
                        upperBound: goCall.lowerBound + 2
                    ),
                    receiverRange: nil
                )
            ]
        ),
        PythonFileSpec(
            path: "pkg/models.py",
            source: modelsSource,
            symbols: [
                PythonTestSymbol(
                    name: "fetch",
                    kind: .pythonFunction,
                    parent: nil,
                    range: byteRange(of: "fetch", in: modelsSource)
                )
            ]
        )
    ]) { session in
        let path = try #require(pathID("pkg/__init__.py", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: goCall.lowerBound,
            context: queryContext(for: session)
        )

        #expect(session.paths.resolve(resolved.first?.target.pathID ?? .init(rawValue: .max))
            == "pkg/models.py")
        #expect(resolved.first?.certainty == .strong)
    }
}

@Test
func pythonRelativeFromTopLevelModuleStaysUnresolved() throws {
    let modelsSource = "def fetch():\n    pass\n"
    let mainSource = "from .models import fetch as go\ngo()\n"
    let goCall = byteRange(of: "go()", in: mainSource)
    try withManualPythonProject([
        PythonFileSpec(path: "models.py", source: modelsSource),
        PythonFileSpec(
            path: "main.py",
            source: mainSource,
            imports: [
                PythonTestImport(
                    specifier: ".models",
                    imported: "fetch",
                    local: "go",
                    kind: .named,
                    range: byteRange(of: ".models import", in: mainSource)
                )
            ],
            calls: [
                PythonTestCall(
                    name: "go",
                    kind: .directCall,
                    range: ByteRange(
                        lowerBound: goCall.lowerBound,
                        upperBound: goCall.lowerBound + 2
                    ),
                    nameRange: ByteRange(
                        lowerBound: goCall.lowerBound,
                        upperBound: goCall.lowerBound + 2
                    ),
                    receiverRange: nil
                )
            ]
        )
    ]) { session in
        let path = try #require(pathID("main.py", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: goCall.lowerBound,
            context: queryContext(for: session)
        )

        #expect(resolved.first?.certainty == .unresolved)
    }
}

@Test
func pythonResolverRejectsSharedModuleConflictAcrossRootAndSrc() throws {
    let modelsSource = "def fetch():\n    pass\n"
    let mainSource = "from .models import fetch as go\ngo()\n"
    let goCall = byteRange(of: "go()", in: mainSource)
    try withManualPythonProject([
        PythonFileSpec(
            path: "pkg/models.py",
            source: modelsSource,
            symbols: [
                PythonTestSymbol(
                    name: "fetch",
                    kind: .pythonFunction,
                    parent: nil,
                    range: byteRange(of: "fetch", in: modelsSource)
                )
            ]
        ),
        PythonFileSpec(path: "src/pkg/__init__.py", source: ""),
        PythonFileSpec(
            path: "src/pkg/models.py",
            source: modelsSource,
            symbols: [
                PythonTestSymbol(
                    name: "fetch",
                    kind: .pythonFunction,
                    parent: nil,
                    range: byteRange(of: "fetch", in: modelsSource)
                )
            ]
        ),
        PythonFileSpec(
            path: "src/pkg/main.py",
            source: mainSource,
            imports: [
                PythonTestImport(
                    specifier: ".models",
                    imported: "fetch",
                    local: "go",
                    kind: .named,
                    range: byteRange(of: ".models import", in: mainSource)
                )
            ],
            calls: [
                PythonTestCall(
                    name: "go",
                    kind: .directCall,
                    range: ByteRange(
                        lowerBound: goCall.lowerBound,
                        upperBound: goCall.lowerBound + 2
                    ),
                    nameRange: ByteRange(
                        lowerBound: goCall.lowerBound,
                        upperBound: goCall.lowerBound + 2
                    ),
                    receiverRange: nil
                )
            ]
        )
    ]) { session in
        let path = try #require(pathID("src/pkg/main.py", in: session))
        let resolved = try session.resolve(
            file: path,
            offset: goCall.lowerBound,
            context: queryContext(for: session)
        )

        #expect(resolved.first?.certainty == .unresolved)
    }
}

@Test
func pythonResolverLeavesModuleObjectAndNamespaceImportsUnresolved() throws {
    let modelsSource = "class Package:\n    pass\n"
    let mainSource = """
        import pkg.models as m
        from no.init.mod import stable as s

        m.run()
        s()
        """
    let runCall = byteRange(of: "run()", in: mainSource)
    let stableCall = byteRange(of: "s()", in: mainSource)
    try withManualPythonProject([
        PythonFileSpec(path: "pkg/__init__.py", source: ""),
        PythonFileSpec(
            path: "pkg/models.py",
            source: modelsSource,
            symbols: [
                PythonTestSymbol(
                    name: "Package",
                    kind: .pythonClass,
                    parent: nil,
                    range: byteRange(of: "Package", in: modelsSource)
                )
            ]
        ),
        PythonFileSpec(path: "no/mod.py", source: modelsSource),
        PythonFileSpec(
            path: "entry.py",
            source: mainSource,
            imports: [
                PythonTestImport(
                    specifier: "pkg.models",
                    imported: nil,
                    local: "m",
                    kind: .module,
                    range: byteRange(of: "pkg.models", in: mainSource)
                ),
                PythonTestImport(
                    specifier: "no.init.mod",
                    imported: "stable",
                    local: "s",
                    kind: .named,
                    range: byteRange(of: "no.init.mod", in: mainSource)
                )
            ],
            calls: [
                PythonTestCall(
                    name: "run",
                    kind: .methodCall,
                    range: ByteRange(
                        lowerBound: runCall.lowerBound - 2,
                        upperBound: runCall.upperBound
                    ),
                    nameRange: ByteRange(
                        lowerBound: runCall.lowerBound,
                        upperBound: runCall.upperBound - 2
                    ),
                    receiverRange: ByteRange(
                        lowerBound: runCall.lowerBound - 2,
                        upperBound: runCall.lowerBound - 1
                    )
                ),
                PythonTestCall(
                    name: "s",
                    kind: .directCall,
                    range: ByteRange(
                        lowerBound: stableCall.lowerBound,
                        upperBound: stableCall.upperBound
                    ),
                    nameRange: ByteRange(
                        lowerBound: stableCall.lowerBound,
                        upperBound: stableCall.lowerBound + 1
                    ),
                    receiverRange: nil
                )
            ]
        )
    ]) { session in
        let context = queryContext(for: session)
        let path = try #require(pathID("entry.py", in: session))
        let moduleObject = try session.resolve(
            file: path,
            offset: runCall.lowerBound,
            context: context
        )
        let namespace = try session.resolve(
            file: path,
            offset: stableCall.lowerBound,
            context: context
        )

        #expect(moduleObject.count == 1)
        #expect(moduleObject.first?.certainty == .unresolved)
        #expect(namespace.first?.certainty == .unresolved)
    }
}

@Test
func pythonResolverScoresClassConstructorsStrongAndMethodsPossible() throws {
    let source = """
        class Model:
            def run(self):
                pass

        def probe(obj):
            obj.run()

        def call():
            Model()
        """
    let methodCall = byteRange(of: "obj.run()", in: source)
    let constructorCall = byteRange(of: "Model()", in: source)
    let constructorName = ByteRange(
        lowerBound: constructorCall.lowerBound,
        upperBound: constructorCall.upperBound - 2
    )
    try withManualPythonProject([
        PythonFileSpec(
            path: "models.py",
            source: source,
            symbols: [
                PythonTestSymbol(
                    name: "Model",
                    kind: .pythonClass,
                    parent: nil,
                    range: byteRange(of: "class Model", in: source)
                ),
                PythonTestSymbol(
                    name: "run",
                    kind: .pythonFunction,
                    parent: 0,
                    range: byteRange(of: "def run", in: source)
                )
            ],
            calls: [
                PythonTestCall(
                    name: "run",
                    kind: .methodCall,
                    range: ByteRange(
                        lowerBound: methodCall.lowerBound,
                        upperBound: methodCall.upperBound
                    ),
                    nameRange: ByteRange(
                        lowerBound: methodCall.lowerBound + 4,
                        upperBound: methodCall.upperBound - 2
                    ),
                    receiverRange: ByteRange(
                        lowerBound: methodCall.lowerBound,
                        upperBound: methodCall.lowerBound + 3
                    )
                ),
                PythonTestCall(
                    name: "Model",
                    kind: .directCall,
                    range: constructorCall,
                    nameRange: constructorName,
                    receiverRange: nil
                )
            ]
        )
    ]) { session in
        let context = queryContext(for: session)
        let path = try #require(pathID("models.py", in: session))
        let method = try session.resolve(
            file: path,
            offset: methodCall.lowerBound,
            context: context
        )
        let constructor = try session.resolve(
            file: path,
            offset: constructorName.lowerBound,
            context: context
        )

        #expect(method.count == 1)
        #expect(method.first?.certainty == .possible)
        #expect(method.first?.dispatch == .dynamicDispatch)
        #expect(method.first?.target.localKind == .declarationFacet)
        #expect(constructor.first?.certainty == .strong)
        #expect(constructor.first?.target.localIndex == 0)
        #expect(try session.implementations(
            ofTrait: "Model",
            context: context
        ).isEmpty)
    }
}

@Test
func pythonResolverKeepsMethodBoundaryForNestedClassFunctions() throws {
    let source = """
        class C:
            def m(self):
                def inner(self):
                    pass

        def probe(obj):
            obj.m().inner()
        """
    let callChain = byteRange(of: "obj.m().inner()", in: source)
    try withManualPythonProject([
        PythonFileSpec(
            path: "models.py",
            source: source,
            symbols: [
                PythonTestSymbol(
                    name: "C",
                    kind: .pythonClass,
                    parent: nil,
                    range: byteRange(of: "class C", in: source)
                ),
                PythonTestSymbol(
                    name: "m",
                    kind: .pythonFunction,
                    parent: 0,
                    range: byteRange(of: "def m", in: source)
                ),
                PythonTestSymbol(
                    name: "inner",
                    kind: .pythonFunction,
                    parent: 1,
                    range: byteRange(of: "def inner", in: source)
                )
            ],
            calls: [
                PythonTestCall(
                    name: "m",
                    kind: .methodCall,
                    range: ByteRange(
                        lowerBound: callChain.lowerBound,
                        upperBound: callChain.lowerBound + 4
                    ),
                    nameRange: ByteRange(
                        lowerBound: callChain.lowerBound + 4,
                        upperBound: callChain.lowerBound + 5
                    ),
                    receiverRange: ByteRange(
                        lowerBound: callChain.lowerBound,
                        upperBound: callChain.lowerBound + 3
                    )
                ),
                PythonTestCall(
                    name: "inner",
                    kind: .methodCall,
                    range: ByteRange(
                        lowerBound: callChain.lowerBound + 6,
                        upperBound: callChain.upperBound
                    ),
                    nameRange: ByteRange(
                        lowerBound: callChain.lowerBound + 6,
                        upperBound: callChain.lowerBound + 11
                    ),
                    receiverRange: nil
                )
            ]
        )
    ]) { session in
        let path = try #require(pathID("models.py", in: session))
        let resolvedM = try session.resolve(
            file: path,
            offset: callChain.lowerBound + 4,
            context: queryContext(for: session)
        )
        let resolvedInner = try session.resolve(
            file: path,
            offset: callChain.lowerBound + 6,
            context: queryContext(for: session)
        )

        #expect(resolvedM.count == 1)
        #expect(resolvedM.first?.certainty == .possible)
        #expect(resolvedInner.isEmpty)
    }
}

@Test
func rustModuleMapStillSupportsCrateAndSuperAfterPythonBranch() throws {
    try withProject([
        "main.rs": """
            mod db;
            use crate::db::connect;
            fn main() { connect(); }
            """,
        "db.rs": """
            pub mod nested;
            pub fn connect() {}
            """,
        "db/nested.rs": "pub fn inner() {}\npub fn call() { super::connect(); }",
    ]) { session in
        let mainPath = try #require(pathID("main.rs", in: session))
        let dbPath = try #require(pathID("db.rs", in: session))
        let nestedPath = try #require(pathID("db/nested.rs", in: session))
        let context = queryContext(for: session)
        let mainSource = try #require(
            session.sourceBytes(at: mainPath).map { String(decoding: $0, as: UTF8.self) }
        )
        let resolvedViaCrate = try session.resolve(
            file: mainPath,
            offset: offset(of: "connect();", in: mainSource),
            context: context
        )
        #expect(resolvedViaCrate.first?.target.pathID == dbPath)

        let nestedSource = try #require(
            session.sourceBytes(at: nestedPath).map { String(decoding: $0, as: UTF8.self) }
        )
        let resolvedSuper = try session.resolve(
            file: nestedPath,
            offset: offset(of: "connect();", in: nestedSource, options: .backwards),
            context: context
        )
        #expect(resolvedSuper.first?.target.pathID == dbPath)
    }
}

@Test
func typeScriptModuleMapResolvesRelativeManifestSubset() throws {
    let mainSource = "import { load } from './service'\nload()\n"
    let serviceSource = "export function load() {}\n"
    try withManualTypeScriptProject([
        TypeScriptFileSpec(
            path: "main.ts",
            source: mainSource,
            imports: [
                TypeScriptImportSpec(
                    specifier: "./service",
                    imported: "load",
                    local: "load",
                    kind: .named,
                    flags: [],
                    range: byteRange(of: "'./service'", in: mainSource)
                )
            ],
            calls: [
                PythonTestCall(
                    name: "load",
                    kind: .directCall,
                    range: byteRange(of: "load()", in: mainSource),
                    nameRange: byteRange(of: "load", in: mainSource),
                    receiverRange: nil
                )
            ]
        ),
        TypeScriptFileSpec(
            path: "service.ts",
            source: serviceSource,
            symbols: [
                TypeScriptSymbolSpec(
                    name: "load",
                    kind: .typescriptFunction,
                    parent: nil,
                    range: byteRange(of: "load", in: serviceSource)
                )
            ],
            exports: ["load"]
        )
    ]) { session in
        let mainPath = try #require(pathID("main.ts", in: session))
        let index = try #require(session.content(at: mainPath)?.1)
        let importBinding = try #require(index.imports.first)
        let target = try #require(session.moduleMap.targetFile(
            for: importBinding,
            from: mainPath,
            names: session.names,
            strings: session.strings
        ))

        #expect(session.paths.resolve(target) == "service.ts")

        let context = queryContext(for: session)
        let resolved = try session.resolve(
            file: mainPath,
            offset: offset(of: "load()", in: mainSource),
            context: context
        )
        let top = try #require(resolved.first)
        #expect(top.certainty == .probable)
        #expect(top.completeness == .partial)
        #expect(session.paths.resolve(top.target.pathID) == "service.ts")

        let callers = try session.callers(
            of: "load",
            context: context
        )
        let caller = try #require(callers.first)
        #expect(session.paths.resolve(caller.callSite.pathID) == "main.ts")
    }
}

@Test
func typeScriptResolverSupportsExactExtensionlessDirectoryAndTsxTargets() throws {
    let mainSource = "import { run } from '../nested/service'\nrun()\n"
    let componentSource = "export function run() {}\n"
    try withManualTypeScriptProject([
        TypeScriptFileSpec(path: "src/main.ts", source: mainSource, imports: [
            TypeScriptImportSpec(
                specifier: "../nested/service",
                imported: "run",
                local: "run",
                kind: .named,
                flags: [],
                range: byteRange(of: "'../nested/service'", in: mainSource)
            )
        ], calls: [
            PythonTestCall(
                name: "run",
                kind: .directCall,
                range: byteRange(of: "run()", in: mainSource),
                nameRange: byteRange(of: "run", in: mainSource),
                receiverRange: nil
            )
        ]),
        TypeScriptFileSpec(path: "nested/service.tsx", source: componentSource, symbols: [
            TypeScriptSymbolSpec(name: "run", kind: .typescriptFunction, parent: nil, range: byteRange(of: "run", in: componentSource))
        ], exports: ["run"])
    ]) { session in
        let mainPath = try #require(pathID("src/main.ts", in: session))
        let resolved = try session.resolve(
            file: mainPath,
            offset: offset(of: "run()", in: mainSource),
            context: queryContext(for: session)
        )
        let top = try #require(resolved.first)
        #expect(session.paths.resolve(top.target.pathID) == "nested/service.tsx")
        #expect(top.certainty == .probable)
        #expect(top.completeness == .partial)
    }
}

@Test
func typeScriptResolverCoversManifestPathAndUnresolvedMatrix() throws {
    let mainSource = """
        import { good } from './exact'
        import { missing } from './absent'
        import { same } from '../nope'
        import alias from './def'
        import * as ns from './all'
        import type { TypeOnly } from './type'

        good()
        missing()
        same()
        alias()
        ns.run()
        TypeOnly()
        """
    try withManualTypeScriptProject([
        TypeScriptFileSpec(path: "main.ts", source: mainSource, imports: [
            TypeScriptImportSpec(specifier: "./exact", imported: "good", local: "good", kind: .named, flags: [], range: byteRange(of: "'./exact'", in: mainSource)),
            TypeScriptImportSpec(specifier: "./absent", imported: "missing", local: "missing", kind: .named, flags: [], range: byteRange(of: "'./absent'", in: mainSource)),
            TypeScriptImportSpec(specifier: "../nope", imported: "same", local: "same", kind: .named, flags: [], range: byteRange(of: "'../nope'", in: mainSource)),
            TypeScriptImportSpec(specifier: "./def", imported: nil, local: "alias", kind: .default, flags: [], range: byteRange(of: "'./def'", in: mainSource)),
            TypeScriptImportSpec(specifier: "./all", imported: nil, local: "ns", kind: .namespace, flags: [.wildcard], range: byteRange(of: "'./all'", in: mainSource)),
            TypeScriptImportSpec(specifier: "./type", imported: "TypeOnly", local: "TypeOnly", kind: .named, flags: [.typeOnly], range: byteRange(of: "'./type'", in: mainSource))
        ], calls: [
            PythonTestCall(name: "good", kind: .directCall, range: byteRange(of: "good()", in: mainSource), nameRange: byteRange(of: "good", in: mainSource), receiverRange: nil),
            PythonTestCall(name: "missing", kind: .directCall, range: byteRange(of: "missing()", in: mainSource), nameRange: byteRange(of: "missing", in: mainSource, options: .backwards), receiverRange: nil),
            PythonTestCall(name: "same", kind: .directCall, range: byteRange(of: "same()", in: mainSource), nameRange: byteRange(of: "same", in: mainSource, options: .backwards), receiverRange: nil),
            PythonTestCall(name: "alias", kind: .directCall, range: byteRange(of: "alias()", in: mainSource), nameRange: byteRange(of: "alias", in: mainSource, options: .backwards), receiverRange: nil),
            PythonTestCall(name: "run", kind: .methodCall, range: byteRange(of: "ns.run()", in: mainSource), nameRange: byteRange(of: "run", in: mainSource, options: .backwards), receiverRange: byteRange(of: "ns", in: mainSource)),
            PythonTestCall(name: "TypeOnly", kind: .directCall, range: byteRange(of: "TypeOnly()", in: mainSource), nameRange: byteRange(of: "TypeOnly", in: mainSource, options: .backwards), receiverRange: nil)
        ]),
        TypeScriptFileSpec(path: "exact.ts", source: "export function good() {}\n", symbols: [
            TypeScriptSymbolSpec(name: "good", kind: .typescriptFunction, parent: nil, range: byteRange(of: "good", in: "export function good() {}\n"))
        ], exports: ["good"]),
        TypeScriptFileSpec(path: "def.ts", source: "export default function def() {}\n", symbols: [
            TypeScriptSymbolSpec(name: "def", kind: .typescriptFunction, parent: nil, range: byteRange(of: "def", in: "export default function def() {}\n"))
        ]),
        TypeScriptFileSpec(path: "all.ts", source: "export function run() {}\n", symbols: [
            TypeScriptSymbolSpec(name: "run", kind: .typescriptFunction, parent: nil, range: byteRange(of: "run", in: "export function run() {}\n"))
        ], exports: ["run"]),
        TypeScriptFileSpec(path: "type.ts", source: "export type TypeOnly = string\n", symbols: [
            TypeScriptSymbolSpec(name: "TypeOnly", kind: .typescriptFunction, parent: nil, range: byteRange(of: "TypeOnly", in: "export type TypeOnly = string\n"))
        ], exports: ["TypeOnly"])
    ]) { session in
        let mainPath = try #require(pathID("main.ts", in: session))
        let context = queryContext(for: session)
        func resolve(
            _ needle: String,
            options: String.CompareOptions = []
        ) throws -> [ResolutionCandidate] {
            try session.resolve(
                file: mainPath,
                offset: offset(of: needle, in: mainSource, options: options),
                context: context
            )
        }

        let good = try #require((try resolve("good()")).first)
        #expect(session.paths.resolve(good.target.pathID) == "exact.ts")
        #expect(good.certainty == .probable)
        #expect(good.completeness == .partial)
        #expect(try resolve("missing()").first?.certainty == .unresolved)
        #expect(try resolve("same()").first?.certainty == .unresolved)
        #expect(try resolve("alias()").first?.certainty == .unresolved)

        let nsResult = try resolve("run")
        #expect(nsResult.first?.certainty == .unresolved || nsResult.first?.certainty == .possible)
        #expect(nsResult.allSatisfy { $0.dispatch == .dynamicDispatch })
        #expect(try resolve("TypeOnly()").first?.certainty == .unresolved)
    }
}

@Test
func typeScriptResolverSupportsReexportAndExportVisibility() throws {
    let mainSource = "import { run } from './barrel0'\nrun()\n"
    let leafSource = "export function run() {}\n"
    var specs: [TypeScriptFileSpec] = [
        TypeScriptFileSpec(path: "main.ts", source: mainSource, imports: [
            TypeScriptImportSpec(specifier: "./barrel0", imported: "run", local: "run", kind: .named, flags: [], range: byteRange(of: "'./barrel0'", in: mainSource))
        ], calls: [
            PythonTestCall(name: "run", kind: .directCall, range: byteRange(of: "run()", in: mainSource), nameRange: byteRange(of: "run", in: mainSource, options: .backwards), receiverRange: nil)
        ])
    ]
    for hop in 0..<4 {
        let file = "barrel\(hop).ts"
        let source = "export { run } from './barrel\(hop + 1)'\n"
        specs.append(TypeScriptFileSpec(
            path: file,
            source: source,
            imports: [
                TypeScriptImportSpec(
                    specifier: "./barrel\(hop + 1)",
                    imported: "run",
                    local: "run",
                    kind: .named,
                    flags: [.reexport],
                    range: byteRange(of: "'./barrel\(hop + 1)'", in: source)
                )
            ],
            reexports: [
                TypeScriptReexportSpec(imported: "run", exported: "run", importIndex: 0)
            ]
        ))
    }
    specs.append(TypeScriptFileSpec(path: "barrel4.ts", source: leafSource, symbols: [
        TypeScriptSymbolSpec(name: "run", kind: .typescriptFunction, parent: nil, range: byteRange(of: "run", in: leafSource))
    ], exports: ["run"]))
    try withManualTypeScriptProject(specs) { session in
        let mainPath = try #require(pathID("main.ts", in: session))
        let resolved = try session.resolve(
            file: mainPath,
            offset: offset(of: "run()", in: mainSource),
            context: queryContext(for: session)
        )
        let top = try #require(resolved.first)
        #expect(session.paths.resolve(top.target.pathID) == "barrel4.ts")
        #expect(top.certainty == .probable)
        #expect(top.completeness == .partial)
    }
}


@Test
func typeScriptModuleMapRejectsUnsupportedAndAmbiguousTargets() throws {
    let mainSource = "import { run } from './x'\nrun()\n"
    try withManualTypeScriptProject([
        TypeScriptFileSpec(
            path: "main.ts",
            source: mainSource,
            imports: [
                TypeScriptImportSpec(
                    specifier: "./x",
                    imported: "run",
                    local: "run",
                    kind: .named,
                    flags: [],
                    range: byteRange(of: "'./x'", in: mainSource)
                )
            ],
            calls: [
                PythonTestCall(
                    name: "run",
                    kind: .directCall,
                    range: byteRange(of: "run()", in: mainSource),
                    nameRange: byteRange(of: "run", in: mainSource),
                    receiverRange: nil
                )
            ]
        ),
        TypeScriptFileSpec(path: "x.ts", source: "export function run() {}\n", symbols: [
            TypeScriptSymbolSpec(name: "run", kind: .typescriptFunction, parent: nil, range: byteRange(of: "run", in: "export function run() {}\n"))
        ], exports: ["run"]),
        TypeScriptFileSpec(path: "x.tsx", source: "export function run() {}\n", symbols: [
            TypeScriptSymbolSpec(name: "run", kind: .typescriptFunction, parent: nil, range: byteRange(of: "run", in: "export function run() {}\n"))
        ], exports: ["run"]),
        TypeScriptFileSpec(path: "x.json", source: "{}", symbols: [], exports: [])
    ]) { session in
        let mainPath = try #require(pathID("main.ts", in: session))
        let index = try #require(session.content(at: mainPath)?.1)
        let binding = try #require(index.imports.first)
        let target = session.moduleMap.targetFile(
            for: binding,
            from: mainPath,
            names: session.names,
            strings: session.strings
        )

        #expect(target == nil)
        #expect(try session.resolve(
            file: mainPath,
            offset: offset(of: "run()", in: mainSource),
            context: queryContext(for: session)
        ).first?.certainty == .unresolved)
    }
}

@Test
func typeScriptResolverCompositeRemainingContract() throws {
    let mainSource = """
        import { run } from './entry'
        import { hidden } from './hidden'
        import { chain } from './typebarrel'
        import { method } from './wildbarrel'
        import { exact } from './exact.ts'
        import { dir } from './dir'
        import { missing } from './depth5'
        import { obj } from './obj'

        run()
        hidden()
        chain()
        method()
        exact()
        dir()
        missing()
        ghost()
        obj.method()
        """
    try withManualTypeScriptProject([
        TypeScriptFileSpec(path: "main.ts", source: mainSource, imports: [
            TypeScriptImportSpec(specifier: "./entry", imported: "run", local: "run", kind: .named, flags: [], range: byteRange(of: "'./entry'", in: mainSource)),
            TypeScriptImportSpec(specifier: "./hidden", imported: "hidden", local: "hidden", kind: .named, flags: [], range: byteRange(of: "'./hidden'", in: mainSource)),
            TypeScriptImportSpec(specifier: "./typebarrel", imported: "chain", local: "chain", kind: .named, flags: [], range: byteRange(of: "'./typebarrel'", in: mainSource)),
            TypeScriptImportSpec(specifier: "./wildbarrel", imported: "method", local: "method", kind: .named, flags: [], range: byteRange(of: "'./wildbarrel'", in: mainSource)),
            TypeScriptImportSpec(specifier: "./exact.ts", imported: "exact", local: "exact", kind: .named, flags: [], range: byteRange(of: "'./exact.ts'", in: mainSource)),
            TypeScriptImportSpec(specifier: "./dir", imported: "dir", local: "dir", kind: .named, flags: [], range: byteRange(of: "'./dir'", in: mainSource)),
            TypeScriptImportSpec(specifier: "./depth5", imported: "missing", local: "missing", kind: .named, flags: [], range: byteRange(of: "'./depth5'", in: mainSource)),
            TypeScriptImportSpec(specifier: "./obj", imported: "obj", local: "obj", kind: .named, flags: [], range: byteRange(of: "'./obj'", in: mainSource))
        ], calls: [
            PythonTestCall(name: "run", kind: .directCall, range: byteRange(of: "run()", in: mainSource), nameRange: byteRange(of: "run", in: mainSource), receiverRange: nil),
            PythonTestCall(name: "hidden", kind: .directCall, range: byteRange(of: "hidden()", in: mainSource), nameRange: byteRange(of: "hidden", in: mainSource), receiverRange: nil),
            PythonTestCall(name: "chain", kind: .directCall, range: byteRange(of: "chain()", in: mainSource), nameRange: byteRange(of: "chain", in: mainSource), receiverRange: nil),
            PythonTestCall(name: "method", kind: .directCall, range: byteRange(of: "method()", in: mainSource), nameRange: byteRange(of: "method", in: mainSource), receiverRange: nil),
            PythonTestCall(name: "exact", kind: .directCall, range: byteRange(of: "exact()", in: mainSource), nameRange: byteRange(of: "exact", in: mainSource), receiverRange: nil),
            PythonTestCall(name: "dir", kind: .directCall, range: byteRange(of: "dir()", in: mainSource), nameRange: byteRange(of: "dir", in: mainSource), receiverRange: nil),
            PythonTestCall(name: "missing", kind: .directCall, range: byteRange(of: "missing()", in: mainSource), nameRange: byteRange(of: "missing", in: mainSource, options: .backwards), receiverRange: nil),
            PythonTestCall(name: "ghost", kind: .directCall, range: byteRange(of: "ghost()", in: mainSource), nameRange: byteRange(of: "ghost", in: mainSource, options: .backwards), receiverRange: nil),
            PythonTestCall(
                name: "method",
                kind: .methodCall,
                range: ByteRange(
                    lowerBound: offset(of: "obj.method()", in: mainSource),
                    upperBound: offset(of: "obj.method()", in: mainSource)
                        + UInt32("obj.method()".utf8.count)
                ),
                nameRange: ByteRange(
                    lowerBound: offset(of: "obj.method()", in: mainSource)
                        + UInt32("obj.".utf8.count),
                    upperBound: offset(of: "obj.method()", in: mainSource)
                        + UInt32("obj.method".utf8.count)
                ),
                receiverRange: ByteRange(
                    lowerBound: offset(of: "obj.method()", in: mainSource),
                    upperBound: offset(of: "obj.method()", in: mainSource)
                        + UInt32("obj".utf8.count)
                )
            )
        ]),
        TypeScriptFileSpec(path: "entry.ts", source: "export { run } from './a1'\n", imports: [
            TypeScriptImportSpec(specifier: "./a1", imported: "run", local: "run", kind: .named, flags: [.reexport], range: byteRange(of: "'./a1'", in: "export { run } from './a1'\n"))
        ], reexports: [TypeScriptReexportSpec(imported: "run", exported: "run", importIndex: 0)]),
        TypeScriptFileSpec(path: "a1.ts", source: "export { run } from './a2'\n", imports: [
            TypeScriptImportSpec(specifier: "./a2", imported: "run", local: "run", kind: .named, flags: [.reexport], range: byteRange(of: "'./a2'", in: "export { run } from './a2'\n"))
        ], reexports: [TypeScriptReexportSpec(imported: "run", exported: "run", importIndex: 0)]),
        TypeScriptFileSpec(path: "a2.ts", source: "export { run } from './a3'\n", imports: [
            TypeScriptImportSpec(specifier: "./a3", imported: "run", local: "run", kind: .named, flags: [.reexport], range: byteRange(of: "'./a3'", in: "export { run } from './a3'\n"))
        ], reexports: [TypeScriptReexportSpec(imported: "run", exported: "run", importIndex: 0)]),
        TypeScriptFileSpec(path: "a3.ts", source: "export { run } from './a4'\n", imports: [
            TypeScriptImportSpec(specifier: "./a4", imported: "run", local: "run", kind: .named, flags: [.reexport], range: byteRange(of: "'./a4'", in: "export { run } from './a4'\n"))
        ], reexports: [TypeScriptReexportSpec(imported: "run", exported: "run", importIndex: 0)]),
        TypeScriptFileSpec(path: "a4.ts", source: "export function run() {}\n", symbols: [
            TypeScriptSymbolSpec(name: "run", kind: .typescriptFunction, parent: nil, range: byteRange(of: "run", in: "export function run() {}\n"))
        ], exports: ["run"]),
        TypeScriptFileSpec(path: "hidden.ts", source: "export function hidden() {}\n", symbols: [
            TypeScriptSymbolSpec(name: "hidden", kind: .typescriptFunction, parent: nil, range: byteRange(of: "hidden", in: "export function hidden() {}\n"))
        ]),
        TypeScriptFileSpec(path: "typebarrel.ts", source: "export type { chain } from './leaf'\n", imports: [
            TypeScriptImportSpec(specifier: "./leaf", imported: "chain", local: "chain", kind: .named, flags: [.reexport, .typeOnly], range: byteRange(of: "'./leaf'", in: "export type { chain } from './leaf'\n"))
        ], reexports: [TypeScriptReexportSpec(imported: "chain", exported: "chain", importIndex: 0)]),
        TypeScriptFileSpec(path: "leaf.ts", source: "export function chain() {}\n", symbols: [
            TypeScriptSymbolSpec(name: "chain", kind: .typescriptFunction, parent: nil, range: byteRange(of: "chain", in: "export function chain() {}\n"))
        ], exports: ["chain"]),
        TypeScriptFileSpec(path: "wildbarrel.ts", source: "export * from './impl'\n", imports: [
            TypeScriptImportSpec(specifier: "./impl", imported: nil, local: nil, kind: .namespace, flags: [.reexport, .wildcard], range: byteRange(of: "'./impl'", in: "export * from './impl'\n"))
        ]),
        TypeScriptFileSpec(path: "impl.ts", source: "export function method() {}\n", symbols: [
            TypeScriptSymbolSpec(name: "method", kind: .typescriptFunction, parent: nil, range: byteRange(of: "method", in: "export function method() {}\n"))
        ], exports: ["method"]),
        TypeScriptFileSpec(path: "exact.ts", source: "export function exact() {}\n", symbols: [
            TypeScriptSymbolSpec(name: "exact", kind: .typescriptFunction, parent: nil, range: byteRange(of: "exact", in: "export function exact() {}\n"))
        ], exports: ["exact"]),
        TypeScriptFileSpec(path: "dir/index.tsx", source: "export function dir() {}\n", symbols: [
            TypeScriptSymbolSpec(name: "dir", kind: .typescriptFunction, parent: nil, range: byteRange(of: "dir", in: "export function dir() {}\n"))
        ], exports: ["dir"]),
        TypeScriptFileSpec(path: "depth5.ts", source: "export { missing } from './d1'\n", imports: [
            TypeScriptImportSpec(specifier: "./d1", imported: "missing", local: "missing", kind: .named, flags: [.reexport], range: byteRange(of: "'./d1'", in: "export { missing } from './d1'\n"))
        ], reexports: [TypeScriptReexportSpec(imported: "missing", exported: "missing", importIndex: 0)]),
        TypeScriptFileSpec(path: "d1.ts", source: "export { missing } from './d2'\n", imports: [
            TypeScriptImportSpec(specifier: "./d2", imported: "missing", local: "missing", kind: .named, flags: [.reexport], range: byteRange(of: "'./d2'", in: "export { missing } from './d2'\n"))
        ], reexports: [TypeScriptReexportSpec(imported: "missing", exported: "missing", importIndex: 0)]),
        TypeScriptFileSpec(path: "d2.ts", source: "export { missing } from './d3'\n", imports: [
            TypeScriptImportSpec(specifier: "./d3", imported: "missing", local: "missing", kind: .named, flags: [.reexport], range: byteRange(of: "'./d3'", in: "export { missing } from './d3'\n"))
        ], reexports: [TypeScriptReexportSpec(imported: "missing", exported: "missing", importIndex: 0)]),
        TypeScriptFileSpec(path: "d3.ts", source: "export { missing } from './d4'\n", imports: [
            TypeScriptImportSpec(specifier: "./d4", imported: "missing", local: "missing", kind: .named, flags: [.reexport], range: byteRange(of: "'./d4'", in: "export { missing } from './d4'\n"))
        ], reexports: [TypeScriptReexportSpec(imported: "missing", exported: "missing", importIndex: 0)]),
        TypeScriptFileSpec(path: "d4.ts", source: "export { missing } from './leaf99'\n", imports: [
            TypeScriptImportSpec(specifier: "./leaf99", imported: "missing", local: "missing", kind: .named, flags: [.reexport], range: byteRange(of: "'./leaf99'", in: "export { missing } from './leaf99'\n"))
        ], reexports: [TypeScriptReexportSpec(imported: "missing", exported: "missing", importIndex: 0)]),
        TypeScriptFileSpec(path: "ghost.ts", source: "export function ghost() {}\n", symbols: [
            TypeScriptSymbolSpec(name: "ghost", kind: .typescriptFunction, parent: nil, range: byteRange(of: "ghost", in: "export function ghost() {}\n"))
        ], exports: ["ghost"]),
        TypeScriptFileSpec(path: "obj.ts", source: "export class Obj { method() {} }\n", symbols: [
            TypeScriptSymbolSpec(name: "Obj", kind: .typescriptClass, parent: nil, range: byteRange(of: "Obj", in: "export class Obj { method() {} }\n")),
            TypeScriptSymbolSpec(name: "method", kind: .typescriptFunction, parent: 0, range: byteRange(of: "method", in: "export class Obj { method() {} }\n"))
        ], exports: ["Obj"])
    ]) { session in
        let mainPath = try #require(pathID("main.ts", in: session))
        let context = queryContext(for: session)
        func resolve(
            _ needle: String,
            options: String.CompareOptions = []
        ) throws -> [ResolutionCandidate] {
            try session.resolve(
                file: mainPath,
                offset: offset(of: needle, in: mainSource, options: options),
                context: context
            )
        }

        let entry = try #require(try resolve("run()").first)
        #expect(session.paths.resolve(entry.target.pathID) == "a4.ts")
        #expect(entry.certainty == .probable)
        #expect(try resolve("hidden()").first?.certainty == .unresolved)
        #expect(try resolve("chain()").first?.certainty == .unresolved)
        let directMethod = try #require(try resolve("method()").first)
        #expect(session.paths.resolve(directMethod.target.pathID) == "impl.ts")
        #expect(directMethod.certainty == .probable)
        let methodOffset = offset(of: "obj.method()", in: mainSource)
            + UInt32("obj.".utf8.count)
        let method = try #require(try session.resolve(
            file: mainPath,
            offset: methodOffset,
            context: context
        ).first)
        #expect(method.certainty == .possible)
        #expect(method.dispatch == .dynamicDispatch)
        #expect(try resolve("exact()").first.map { session.paths.resolve($0.target.pathID) }
            == "exact.ts")
        #expect(try resolve("dir()").first.map { session.paths.resolve($0.target.pathID) }
            == "dir/index.tsx")
        let missing = try resolve("missing()", options: .backwards)
        #expect(missing.first?.certainty == .unresolved)
        #expect(missing.first?.target.localKind == .importBinding)
        #expect(try resolve("ghost()").isEmpty)
    }
}

private func withProject(
    _ files: [String: String],
    test: (EngineSession) throws -> Void
) throws {
    try withProjectRoot(files) { root in
        try test(ProjectIndexer().index(root: root))
    }
}

private func withProjectRoot(
    _ files: [String: String],
    test: (URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeInsightEngineTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for (path, contents) in files {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
    try test(root)
}

private let determinismFixture = [
    "a.rs": "use crate::z::run as go; fn main() { go(); }",
    "copy.rs": "pub fn run() {}",
    "nested/model.rs": "struct Model { value: u32 } impl Model { fn read(&self) {} }",
    "z.rs": "pub fn run() {}",
]

private func canonicalSessionDump(_ session: EngineSession) -> String {
    var lines: [String] = []
    var seen: Set<ContentIndexKey> = []
    for file in session.manifest.files {
        lines.append("path #\(file.pathID.rawValue) \(session.paths.resolve(file.pathID))")
        let entry = session.contentIndexes.first { key, _ in
            key.contentID == file.contentID && key.languageMode.language == .rust
        }!
        guard seen.insert(entry.key).inserted else { continue }
        let index = entry.value
        lines.append(CanonicalDump.render(
            index,
            names: session.names,
            strings: session.strings
        ))
        lines.append("bindingNames \(index.bindings.map { $0.localNameID.rawValue })")
        lines.append("bindingTargets \(index.bindings.map { $0.targetHint?.nameID.rawValue })")
        lines.append("symbolNames \(index.symbols.map { $0.nameID.rawValue })")
        lines.append("callNames \(index.calls.map { $0.nameID.rawValue })")
        lines.append("importStrings \(index.imports.map { $0.moduleSpecifier.rawValue })")
        lines.append("importNames \(index.imports.map { [$0.importedName?.rawValue, $0.localName?.rawValue] })")
        lines.append("exportNames \(index.exports.map { $0.exportedName.rawValue })")
    }
    return lines.joined(separator: "\n")
}

private func aggregateStatsDump(_ stats: IndexStats) -> String {
    [
        stats.fileCount,
        stats.uniqueContentCount,
        stats.scopeCount,
        stats.bindingCount,
        stats.symbolCount,
        stats.callCount,
        stats.importCount,
        stats.filesWithErrorNodes,
    ].map(String.init).joined(separator: ",")
}

private func queryContext(for session: EngineSession) -> QueryContext {
    QueryContext(
        snapshotID: session.snapshotID,
        analysisProfileID: session.analysisProfile.id,
        generation: 1
    )
}

private func pathID(_ path: String, in session: EngineSession) -> PathID? {
    session.manifest.files.first {
        session.paths.resolve($0.pathID) == path
    }?.pathID
}

private func searchedNames(
    _ query: String,
    session: EngineSession,
    context: QueryContext
) throws -> [String] {
    try session.searchSymbols(
        query: query,
        limit: 20,
        boost: SearchBoost(),
        context: context
    ).map { session.names.resolve($0.nameID) }
}

private func offset(
    of needle: String,
    in source: String,
    options: String.CompareOptions = []
) -> UInt32 {
    let range = source.range(of: needle, options: options)!
    return UInt32(source[..<range.lowerBound].utf8.count)
}

private func hasUniqueImport(_ evidence: [ResolutionEvidence]) -> Bool {
    evidence.contains {
        if case .uniqueImport = $0 { return true }
        return false
    }
}

private func hasLexicalBinding(
    _ evidence: [ResolutionEvidence],
    index: UInt32
) -> Bool {
    evidence.contains {
        if case let .lexicalBinding(bindingIndex) = $0 {
            return bindingIndex == index
        }
        return false
    }
}

private func hasMethodNameOnly(_ evidence: [ResolutionEvidence]) -> Bool {
    evidence.contains {
        if case .methodNameOnly = $0 { return true }
        return false
    }
}

private func hasReceiverType(
    _ evidence: [ResolutionEvidence],
    named name: String,
    in session: EngineSession
) -> Bool {
    evidence.contains {
        if case let .receiverType(nameID) = $0 {
            return session.names.resolve(nameID) == name
        }
        return false
    }
}

private func resolvedImplType(
    of candidate: ResolutionCandidate,
    in session: EngineSession
) -> String? {
    guard candidate.target.localKind == .declarationFacet,
          let (_, index) = session.content(at: candidate.target.pathID),
          index.symbols.indices.contains(Int(candidate.target.localIndex)),
          let implFacetIndex =
            index.symbols[Int(candidate.target.localIndex)].parentFacetIndex,
          let relation = index.implRelations.first(where: {
              $0.implFacetIndex == implFacetIndex
          })
    else { return nil }
    return session.names.resolve(relation.typeNameID)
}

private struct PythonTestSymbol {
    let name: String
    let kind: DeclarationKind
    let parent: UInt32?
    let range: ByteRange
}

private struct PythonTestImport {
    let specifier: String
    let imported: String?
    let local: String?
    let kind: ImportKind
    let range: ByteRange
}

private struct PythonTestCall {
    let name: String
    let kind: CallKind
    let range: ByteRange
    let nameRange: ByteRange
    let receiverRange: ByteRange?
}

private struct PythonFileSpec {
    let path: String
    let source: String
    var symbols: [PythonTestSymbol]
    var imports: [PythonTestImport]
    var calls: [PythonTestCall]

    init(
        path: String,
        source: String,
        symbols: [PythonTestSymbol] = [],
        imports: [PythonTestImport] = [],
        calls: [PythonTestCall] = []
    ) {
        self.path = path
        self.source = source
        self.symbols = symbols
        self.imports = imports
        self.calls = calls
    }
}

private struct TypeScriptSymbolSpec {
    let name: String
    let kind: DeclarationKind
    let parent: UInt32?
    let range: ByteRange
}

private struct TypeScriptImportSpec {
    let specifier: String
    let imported: String?
    let local: String?
    let kind: ImportKind
    let flags: ImportFlags
    let range: ByteRange
}

private struct TypeScriptFileSpec {
    let path: String
    let source: String
    var symbols: [TypeScriptSymbolSpec]
    var imports: [TypeScriptImportSpec]
    var exports: [String]
    var reexports: [TypeScriptReexportSpec]
    var calls: [PythonTestCall]

    init(
        path: String,
        source: String,
        symbols: [TypeScriptSymbolSpec] = [],
        imports: [TypeScriptImportSpec] = [],
        exports: [String] = [],
        reexports: [TypeScriptReexportSpec] = [],
        calls: [PythonTestCall] = []
    ) {
        self.path = path
        self.source = source
        self.symbols = symbols
        self.imports = imports
        self.exports = exports
        self.reexports = reexports
        self.calls = calls
    }
}

private struct TypeScriptReexportSpec {
    let imported: String
    let exported: String
    let importIndex: UInt32
}

private func withManualTypeScriptProject(
    _ files: [TypeScriptFileSpec],
    test: (EngineSession) throws -> Void
) throws {
    let store = ProjectIndexStore()
    var occurrences: [FileOccurrence] = []
    var entries: [(ContentIndex, [UInt8], Bool)] = []
    let moduleScopeID = ScopeID(rawValue: 0)
    let moduleRegionID = ExecutableRegionID(rawValue: 0)
    var symbolCount = 0
    var importCount = 0
    var callCount = 0

    let active = files.filter {
        LanguageMode.classify(path: $0.path, language: .typescript) != nil
    }
    for (index, file) in active.enumerated() {
        let bytes = Array(file.source.utf8)
        let contentID = ContentID.sha256(of: bytes)
        let pathID = store.paths.intern(file.path)
        occurrences.append(FileOccurrence(
            occurrenceID: FileOccurrenceID(rawValue: UInt32(index)),
            pathID: pathID,
            contentID: contentID,
            detectedLanguage: .typescript,
            sourceKind: .untracked,
            fileMode: .regular,
            size: UInt64(bytes.count)
        ))
        let symbols = file.symbols.enumerated().map { offset, symbol in
            DeclarationFacet(
                symbolGroupID: SymbolGroupID(rawValue: UInt32(offset)),
                space: .value,
                kind: symbol.kind,
                nameID: store.names.intern(symbol.name),
                range: symbol.range,
                nameRange: symbol.range,
                parentFacetIndex: symbol.parent,
                signatureFingerprint: nil,
                bodyFingerprint: nil
            )
        }
        let exports = file.exports.map { export in
            ExportRecord(
                exportedName: store.names.intern(export),
                sourceBindingIndex: nil,
                range: byteRange(of: export, in: file.source)
            )
        }
        let reexports = file.reexports.map { reexport in
            ExportRecord(
                exportedName: store.names.intern(reexport.exported),
                sourceBindingIndex: reexport.importIndex,
                range: byteRange(of: reexport.exported, in: file.source)
            )
        }
        let imports = file.imports.map { binding in
            ImportBinding(
                moduleSpecifier: store.strings.intern(binding.specifier),
                importedName: binding.imported.map(store.names.intern),
                localName: binding.local.map(store.names.intern),
                kind: binding.kind,
                flags: binding.flags,
                scopeID: moduleScopeID,
                range: binding.range
            )
        }
        let calls = file.calls.map { call in
            UnresolvedCall(
                regionID: moduleRegionID,
                nameID: store.names.intern(call.name),
                range: call.range,
                nameRange: call.nameRange,
                syntacticKind: call.kind,
                qualifierRange: nil,
                receiverRange: call.receiverRange,
                argumentCount: nil
            )
        }
        let scope = ScopeRecord(
            id: moduleScopeID,
            parent: nil,
            kind: .module,
            range: ByteRange(lowerBound: 0, upperBound: UInt32(bytes.count))
        )
        let region = ExecutableRegionRecord(
            id: moduleRegionID,
            kind: .moduleInitializer,
            range: scope.range,
            enclosingScopeID: moduleScopeID,
            associatedFacetIndex: nil
        )
        guard let mode = LanguageMode.classify(path: file.path, language: .typescript) else {
            continue
        }
        let key = ContentIndexKey(
            contentID: contentID,
            languageMode: mode,
            grammarVersion: 1,
            extractorVersion: 1
        )
        let index = ContentIndex(
            key: key,
            scopes: [scope],
            bindings: [],
            executableRegions: [region],
            symbols: symbols,
            calls: calls,
            imports: imports,
            exports: exports + reexports,
            lineTable: LineTable(bytes: bytes)
        )
        entries.append((index, bytes, false))
        symbolCount += symbols.count
        importCount += imports.count
        callCount += calls.count
    }
    store.insert(entries)
    let stats = IndexStats(
        fileCount: files.count,
        uniqueContentCount: files.count,
        scopeCount: 0,
        bindingCount: 0,
        symbolCount: symbolCount,
        callCount: callCount,
        importCount: importCount,
        elapsedMilliseconds: 0,
        filesWithErrorNodes: 0,
        reusedCount: 0,
        extractedCount: files.count
    )
    let manifest = SnapshotManifest(
        snapshotID: SnapshotID(rawValue: UUID()),
        files: occurrences
    )
    let profile = AnalysisProfile.placeholder(language: .typescript, root: store.paths.intern("."))
    let view = SnapshotView(
        store: store,
        manifest: manifest,
        stats: stats,
        analysisProfile: profile,
        extractor: TypeScriptManualExtractor()
    )
    try test(EngineSession(store: store, snapshotView: view))
}

private struct TypeScriptManualExtractor: LanguageExtractor {
    var language: LanguageID { .typescript }
    var grammarVersion: UInt32 { 1 }
    var extractorVersion: UInt32 { 1 }

    func extractWithDiagnostics(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner _: ExtractionInterners
    ) throws -> (index: ContentIndex, containsErrorNodes: Bool) {
        (ContentIndex(
            key: key,
            scopes: [],
            bindings: [],
            executableRegions: [],
            symbols: [],
            calls: [],
            imports: [],
            exports: [],
            lineTable: LineTable(bytes: bytes)
        ), false)
    }

    func identifierRanges(
        named _: String,
        in bytes: [UInt8],
        mode: LanguageMode
    ) throws -> [ByteRange] {
        []
    }
}

private func withManualPythonProject(
    _ files: [PythonFileSpec],
    test: (EngineSession) throws -> Void
) throws {
    let store = ProjectIndexStore()
    var occurrences: [FileOccurrence] = []
    var entries: [(ContentIndex, [UInt8], Bool)] = []
    var symbolsByPath: [String: [DeclarationFacet]] = [:]
    var importsByPath: [String: [ImportBinding]] = [:]
    var callsByPath: [String: [UnresolvedCall]] = [:]
    let moduleScopeID = ScopeID(rawValue: 0)
    let moduleRegionID = ExecutableRegionID(rawValue: 0)

    for (index, file) in files.enumerated() {
        let bytes = Array(file.source.utf8)
        let contentID = ContentID.sha256(of: bytes)
        let pathID = store.paths.intern(file.path)
        occurrences.append(FileOccurrence(
            occurrenceID: FileOccurrenceID(rawValue: UInt32(index)),
            pathID: pathID,
            contentID: contentID,
            detectedLanguage: .python,
            sourceKind: .untracked,
            fileMode: .regular,
            size: UInt64(bytes.count)
        ))
        symbolsByPath[file.path] = file.symbols.enumerated().map { offset, symbol in
            DeclarationFacet(
                symbolGroupID: SymbolGroupID(rawValue: UInt32(offset)),
                space: .value,
                kind: symbol.kind,
                nameID: store.names.intern(symbol.name),
                range: symbol.range,
                nameRange: symbol.range,
                parentFacetIndex: symbol.parent,
                signatureFingerprint: nil,
                bodyFingerprint: nil
            )
        }
        importsByPath[file.path] = file.imports.map { binding in
            ImportBinding(
                moduleSpecifier: store.strings.intern(binding.specifier),
                importedName: binding.imported.map(store.names.intern),
                localName: binding.local.map(store.names.intern),
                kind: binding.kind,
                flags: [],
                scopeID: moduleScopeID,
                range: binding.range
            )
        }
        callsByPath[file.path] = file.calls.map { call in
            UnresolvedCall(
                regionID: moduleRegionID,
                nameID: store.names.intern(call.name),
                range: call.range,
                nameRange: call.nameRange,
                syntacticKind: call.kind,
                qualifierRange: nil,
                receiverRange: call.receiverRange,
                argumentCount: nil
            )
        }
        let scope = ScopeRecord(
            id: moduleScopeID,
            parent: nil,
            kind: .module,
            range: ByteRange(lowerBound: 0, upperBound: UInt32(bytes.count))
        )
        let region = ExecutableRegionRecord(
            id: moduleRegionID,
            kind: .moduleInitializer,
            range: scope.range,
            enclosingScopeID: moduleScopeID,
            associatedFacetIndex: nil
        )
        let key = ContentIndexKey(
            contentID: contentID,
            languageMode: LanguageMode(language: .python),
            grammarVersion: PythonTestExtractor.grammarVersion,
            extractorVersion: PythonTestExtractor.extractorVersion
        )
        let index = ContentIndex(
            key: key,
            scopes: [scope],
            bindings: [],
            executableRegions: [region],
            symbols: symbolsByPath[file.path] ?? [],
            calls: callsByPath[file.path] ?? [],
            imports: importsByPath[file.path] ?? [],
            exports: [],
            lineTable: LineTable(bytes: bytes)
        )
        entries.append((index, bytes, false))
    }
    store.insert(entries)
    let manifest = SnapshotManifest(
        snapshotID: SnapshotID(rawValue: UUID()),
        files: occurrences
    )
    let profile = AnalysisProfile.placeholder(language: .python, root: store.paths.intern("."))
    let view = SnapshotView(
        store: store,
        manifest: manifest,
        stats: IndexStats(
            fileCount: manifest.files.count,
            uniqueContentCount: store.contentIndexes.count,
            scopeCount: 0,
            bindingCount: 0,
            symbolCount: symbolsByPath.values.reduce(0) { $0 + $1.count },
            callCount: callsByPath.values.reduce(0) { $0 + $1.count },
            importCount: importsByPath.values.reduce(0) { $0 + $1.count },
            elapsedMilliseconds: 0,
            filesWithErrorNodes: 0,
            reusedCount: 0,
            extractedCount: manifest.files.count
        ),
        analysisProfile: profile,
        extractor: PythonTestExtractor()
    )
    try test(EngineSession(store: store, snapshotView: view))
}

private func byteRange(
    of needle: String,
    in source: String,
    options: String.CompareOptions = []
) -> ByteRange {
    let start = offset(of: needle, in: source, options: options)
    return ByteRange(
        lowerBound: start,
        upperBound: start + UInt32(needle.utf8.count)
    )
}

private struct PythonTestExtractor: LanguageExtractor {
    static let grammarVersion: UInt32 = 1
    static let extractorVersion: UInt32 = 1

    var language: LanguageID { .python }
    var grammarVersion: UInt32 { Self.grammarVersion }
    var extractorVersion: UInt32 { Self.extractorVersion }

    func extractWithDiagnostics(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner _: ExtractionInterners
    ) throws -> (index: ContentIndex, containsErrorNodes: Bool) {
        (ContentIndex(
            key: key,
            scopes: [],
            bindings: [],
            executableRegions: [],
            symbols: [],
            calls: [],
            imports: [],
            exports: [],
            lineTable: LineTable(bytes: bytes)
        ), false)
    }

    func identifierRanges(
        named _: String,
        in bytes: [UInt8],
        mode: LanguageMode
    ) throws -> [ByteRange] {
        []
    }
}
