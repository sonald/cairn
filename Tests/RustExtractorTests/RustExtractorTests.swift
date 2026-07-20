import CodeInsightCore
import CodeInsightRustExtractor
import Foundation
import Testing

@Test
func preservesShadowedBindingsInSourceOrder() throws {
    let result = try extract("fn f() { let x = 1; let x = x + 1; }")
    let bindings = result.index.bindings.filter {
        result.names.resolve($0.localNameID) == "x"
    }

    #expect(bindings.count == 2)
    #expect(bindings[0].scopeID == bindings[1].scopeID)
    #expect(bindings[0].declarationRange < bindings[1].declarationRange)
    #expect(bindings.allSatisfy { $0.kind == .letBinding })
}

@Test
func bindsEveryIdentifierInDestructuredPatterns() throws {
    let source = """
        struct Pair { left: i32, right: i32 }
        fn f((a, b): (i32, i32), pair: Pair) {
            let Pair { left: x, right } = pair;
        }
        """
    let result = try extract(source)
    let bindings = result.index.bindings.map {
        (result.names.resolve($0.localNameID), $0.kind)
    }

    #expect(bindings.map(\.0) == ["a", "b", "pair", "x", "right"])
    #expect(bindings.prefix(3).allSatisfy { $0.1 == .param })
    #expect(bindings.suffix(2).allSatisfy { $0.1 == .letBinding })
}

@Test
func extractsClosureParametersAndRegion() throws {
    let result = try extract("fn f() { let add = |a, b| a + b; }")
    let closureScope = try #require(result.index.scopes.first {
        $0.kind == .closure
    })
    let parameters = result.index.bindings.filter {
        $0.scopeID == closureScope.id && $0.kind == .param
    }.map { result.names.resolve($0.localNameID) }

    #expect(parameters == ["a", "b"])
    #expect(result.index.executableRegions.contains {
        $0.kind == .closure && $0.enclosingScopeID == closureScope.id
    })
}

@Test
func nestsInlineModuleScopesAndFacets() throws {
    let result = try extract("mod a { mod b { fn c() {} } }")
    let moduleScopes = result.index.scopes.filter { $0.kind == .module }
    let a = try #require(facetIndex(named: "a", in: result))
    let b = try #require(facetIndex(named: "b", in: result))
    let c = try #require(facetIndex(named: "c", in: result))

    #expect(moduleScopes.count == 3)
    #expect(moduleScopes[0].parent == nil)
    #expect(moduleScopes[1].parent == moduleScopes[0].id)
    #expect(moduleScopes[2].parent == moduleScopes[1].id)
    #expect(result.index.symbols[b].parentFacetIndex == UInt32(a))
    #expect(result.index.symbols[c].parentFacetIndex == UInt32(b))
}

@Test
func associatesImplMethodFacetAndRegion() throws {
    let result = try extract("struct Foo; impl Foo { fn bar(&self) {} }")
    let implIndex = try #require(result.index.symbols.firstIndex {
        $0.kind == .rustImpl
    })
    let methodIndex = try #require(facetIndex(named: "bar", in: result))
    let methodRegion = try #require(result.index.executableRegions.first {
        $0.kind == .method
    })

    #expect(result.index.symbols[methodIndex].kind == .rustMethod)
    #expect(result.index.symbols[methodIndex].parentFacetIndex == UInt32(implIndex))
    #expect(methodRegion.associatedFacetIndex == UInt32(methodIndex))
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "self" && $0.kind == .param
    })
}

@Test
func bindsMatchPatternsInArmScope() throws {
    let result = try extract(
        "fn f(v: Option<i32>) { match v { Some(x) => x, None => 0 } }"
    )
    let binding = try #require(result.index.bindings.first {
        result.names.resolve($0.localNameID) == "x"
    })
    let scope = try #require(result.index.scopes.first {
        $0.id == binding.scopeID
    })

    #expect(binding.kind == .patternBinding)
    #expect(scope.kind == .matchArm)
}

@Test
func associatesStructFieldsWithStructFacet() throws {
    let result = try extract("struct Foo { value: i32 }")
    let structIndex = try #require(facetIndex(named: "Foo", in: result))
    let fieldIndex = try #require(facetIndex(named: "value", in: result))

    #expect(result.index.symbols[fieldIndex].kind == .rustField)
    #expect(result.index.symbols[fieldIndex].parentFacetIndex == UInt32(structIndex))
}

@Test
func syntaxErrorsStillYieldParsedDeclarations() throws {
    let result = try extract("fn good() {} fn broken( {")

    #expect(facetIndex(named: "good", in: result) != nil)
}

@Test
func skipsMacroDefinitionAndInvocationSubtrees() throws {
    let source = """
        macro_rules! make { ($name:ident) => { fn generated() {} }; }
        #[derive(Debug)] struct Visible;
        fn f() {
            println!("{}", { let hidden = 1; hidden });
            let visible = 1;
        }
        """
    let result = try extract(source)
    let names = result.index.bindings.map {
        result.names.resolve($0.localNameID)
    }
    let macroCall = try #require(result.index.calls.first)

    #expect(names == ["visible"])
    #expect(facetIndex(named: "generated", in: result) == nil)
    #expect(result.index.calls.count == 1)
    #expect(macroCall.syntacticKind == .macroInvocation)
    #expect(result.names.resolve(macroCall.nameID) == "println")
}

@Test
func extractsAliasedUseAndExternCrate() throws {
    let result = try extract(
        "use std::io::Read as R; extern crate serde as s;"
    )
    let useBinding = try #require(result.index.imports.first)
    let externBinding = try #require(result.index.imports.last)

    #expect(result.strings.resolve(useBinding.moduleSpecifier) == "std::io::Read")
    #expect(useBinding.importedName.map(result.names.resolve) == "Read")
    #expect(useBinding.localName.map(result.names.resolve) == "R")
    #expect(useBinding.kind == .named)
    #expect(result.strings.resolve(externBinding.moduleSpecifier) == "serde")
    #expect(externBinding.importedName.map(result.names.resolve) == "serde")
    #expect(externBinding.localName.map(result.names.resolve) == "s")
    #expect(externBinding.kind == .module)
}

@Test
func expandsGroupedNestedAndSelfImports() throws {
    let result = try extract(
        "use a::{b, c as d, e::{f, g}, h::{self}};"
    )
    let imports = result.index.imports.map {
        (
            result.strings.resolve($0.moduleSpecifier),
            $0.importedName.map(result.names.resolve),
            $0.localName.map(result.names.resolve)
        )
    }

    #expect(imports.count == 5)
    #expect(imports.map(\.0) == ["a::b", "a::c", "a::e::f", "a::e::g", "a::h"])
    #expect(imports.map(\.1) == ["b", "c", "f", "g", "h"])
    #expect(imports.map(\.2) == ["b", "d", "f", "g", "h"])
}

@Test
func extractsGlobWithoutNames() throws {
    let result = try extract("use a::*;")
    let binding = try #require(result.index.imports.first)

    #expect(result.index.imports.count == 1)
    #expect(result.strings.resolve(binding.moduleSpecifier) == "a")
    #expect(binding.flags.contains(.wildcard))
    #expect(binding.importedName == nil)
    #expect(binding.localName == nil)
}

@Test
func linksPublicUseToExport() throws {
    let result = try extract("pub use a::b as c;")
    let binding = try #require(result.index.imports.first)
    let export = try #require(result.index.exports.first)

    #expect(binding.flags.contains(.reexport))
    #expect(result.names.resolve(export.exportedName) == "c")
    #expect(export.sourceBindingIndex == 0)
}

@Test
func assignsUseInFunctionBodyToFunctionScope() throws {
    let result = try extract("fn f() { use a::b; }")
    let binding = try #require(result.index.imports.first)
    let scope = try #require(result.index.scopes.first { $0.id == binding.scopeID })

    #expect(scope.kind == .function)
}

@Test
func extractsQualifiedAndMethodCalls() throws {
    let source = "fn f(x: X) { a::b::c(); x.foo(1, 2); }"
    let result = try extract(source)
    let qualified = try #require(result.index.calls.first)
    let method = try #require(result.index.calls.last)

    #expect(result.names.resolve(qualified.nameID) == "c")
    #expect(qualified.syntacticKind == .qualifiedCall)
    #expect(text(in: source, range: qualified.qualifierRange) == "a::b")
    #expect(result.names.resolve(method.nameID) == "foo")
    #expect(method.syntacticKind == .methodCall)
    #expect(text(in: source, range: method.receiverRange) == "x")
    #expect(method.argumentCount == 2)
}

@Test
func stripsTurbofishBeforeClassifyingCalls() throws {
    let result = try extract(
        "fn caller() { f::<T>(); Vec::<u8>::new(); }"
    )
    let direct = try #require(result.index.calls.first)
    let qualified = try #require(result.index.calls.last)

    #expect(result.index.calls.count == 2)
    #expect(result.names.resolve(direct.nameID) == "f")
    #expect(direct.syntacticKind == .directCall)
    #expect(result.names.resolve(qualified.nameID) == "new")
    #expect(qualified.syntacticKind == .qualifiedCall)
}

@Test
func assignsCallsToInnermostExecutableRegion() throws {
    let source = """
        fn outer() { direct(); let closure = || nested(); }
        const C: i32 = initialize();
        """
    let result = try extract(source)

    for (name, kind) in [
        ("direct", ExecutableRegionKind.function),
        ("nested", .closure),
        ("initialize", .constantInitializer),
    ] {
        let call = try #require(result.index.calls.first {
            result.names.resolve($0.nameID) == name
        })
        let region = try #require(result.index.executableRegions.first {
            $0.id == call.regionID
        })
        #expect(region.kind == kind)
    }
}

@Test
func syntaxErrorsPreserveEarlierCallsAndImports() throws {
    let result = try extract("use a::b; fn good() { c(); } fn broken( {")

    #expect(result.index.imports.count == 1)
    #expect(result.index.calls.count == 1)
}

@Test
func createsControlFlowPatternScopes() throws {
    let source = """
        fn f(values: Vec<Option<i32>>) {
            if let Some(x) = values.first() { let _ = x; }
            while let Some(y) = values.first() { break; }
            for z in values { let _ = z; }
        }
        """
    let result = try extract(source)

    for name in ["x", "y", "z"] {
        let binding = try #require(result.index.bindings.first {
            result.names.resolve($0.localNameID) == name
        })
        let scope = try #require(result.index.scopes.first {
            $0.id == binding.scopeID
        })
        #expect(binding.kind == .patternBinding)
        #expect(scope.kind == .block)
    }
}

@Test
func coversRequiredDeclarationKindsAndConstantRegions() throws {
    let source = """
        enum E { A }
        trait T { fn required(&self); }
        const C: i32 = 1;
        static S: i32 = 2;
        mod m;
        type Alias = i32;
        fn top(value: i32) {}
        """
    let result = try extract(source)
    let kinds = result.index.symbols.map(\.kind)
    let traitIndex = try #require(facetIndex(named: "T", in: result))
    let requiredIndex = try #require(facetIndex(named: "required", in: result))

    #expect(kinds.contains(.rustEnum))
    #expect(kinds.contains(.rustTrait))
    #expect(kinds.contains(.rustMethod))
    #expect(kinds.contains(.rustConst))
    #expect(kinds.contains(.rustStatic))
    #expect(kinds.contains(.rustMod))
    #expect(kinds.contains(.rustTypeAlias))
    #expect(kinds.contains(.rustFn))
    #expect(result.index.symbols[requiredIndex].parentFacetIndex == UInt32(traitIndex))
    #expect(result.index.executableRegions.filter {
        $0.kind == .constantInitializer
    }.count == 2)
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "value" && $0.kind == .param
    })
}

@Test
func extractsEmptyRustContent() throws {
    let index = try extract("").index

    #expect(index.bindings.isEmpty)
    #expect(index.executableRegions.isEmpty)
    #expect(index.symbols.isEmpty)
    #expect(index.calls.isEmpty)
    #expect(index.imports.isEmpty)
    #expect(index.exports.isEmpty)
}

private struct ExtractionResult {
    let index: ContentIndex
    let names: Interner<NameID>
    let strings: Interner<StringID>
}

private func extract(_ source: String) throws -> ExtractionResult {
    let bytes = Array(source.utf8)
    let names = Interner<NameID>()
    let strings = Interner<StringID>()
    let interner = ExtractionInterners(
        names: names,
        strings: strings
    )
    let key = ContentIndexKey(
        contentID: ContentID.sha256(of: bytes),
        languageMode: LanguageMode(language: .rust),
        grammarVersion: RustExtractorInfo.grammarVersion,
        extractorVersion: RustExtractorInfo.extractorVersion
    )
    return ExtractionResult(
        index: try RustExtractor().extract(
            bytes: bytes,
            key: key,
            interner: interner
        ),
        names: names,
        strings: strings
    )
}

private func text(in source: String, range: ByteRange?) -> String? {
    guard let range else { return nil }
    let bytes = Array(source.utf8)
    return String(
        bytes: bytes[Int(range.lowerBound)..<Int(range.upperBound)],
        encoding: .utf8
    )
}

private func facetIndex(
    named name: String,
    in result: ExtractionResult
) -> Int? {
    result.index.symbols.firstIndex {
        result.names.resolve($0.nameID) == name
    }
}
