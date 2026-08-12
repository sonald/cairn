import CodeInsightCore
import CodeInsightPythonExtractor
import Foundation
import Testing

@Test
func extractsBasicFunctionFacetAndScope() throws {
    let result = try extract(
        """
        def alpha(value):
            return value
        """
    )
    let alpha = try #require(facet(named: "alpha", in: result))

    #expect(alpha.kind == .pythonFunction)
    #expect(alpha.parentFacetIndex == nil)
    #expect(text(in: result.source, range: alpha.nameRange) == "alpha")
    #expect(result.index.symbols.contains {
        $0.kind == .pythonFunction && $0.nameID == alpha.nameID
    })
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "value"
            && $0.kind == .param
    })
}

@Test
func extractsDecoratedAsyncNestedClassAndLambdaFieldwise() throws {
    let source = """
        @app.route("/")
        async def handler(data, limit=1) -> str:
            class Inner:
                def method(self, x):
                    cb = lambda y: y
                    return cb(x)
            return Inner
        """
    let result = try extract(source)
    let handler = try #require(facet(named: "handler", in: result))
    let inner = try #require(facet(named: "Inner", in: result))
    let method = try #require(facet(named: "method", in: result))

    #expect(result.index.symbols.filter {
        result.names.resolve($0.nameID) == "handler"
            && $0.kind == .pythonFunction
    }.count == 1)
    #expect(handler.kind == .pythonFunction)
    #expect(text(in: result.source, range: handler.range)?.hasPrefix("@app.route") == true)
    #expect(text(in: result.source, range: handler.range)?.contains("async def handler") == true)
    #expect(inner.kind == .pythonClass)
    #expect(inner.parentFacetIndex == handler.symbolGroupID.rawValue)
    #expect(method.kind == .pythonFunction)
    #expect(method.parentFacetIndex == inner.symbolGroupID.rawValue)
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "data"
            && $0.kind == .param
    })
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "limit"
            && $0.kind == .param
    })
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "x"
            && $0.kind == .param
    })
    #expect(result.index.scopes.contains {
        $0.kind == .closure
            && $0.range.contains(bindingRange("y", in: result).lowerBound)
    })
    #expect(result.index.executableRegions.contains {
        $0.kind == .closure
    })
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "cb"
            && $0.kind == .assignment
    })
}

@Test
func coversParameterDefaultMethodAndOuterLexicalParent() throws {
    let source = """
        class C:
            def method(self, value=1, *args, **kwargs):
                def nested():
                    return value
                return nested
        """
    let result = try extract(source)
    let c = try #require(facet(named: "C", in: result))
    let method = try #require(facet(named: "method", in: result))
    let nested = try #require(facet(named: "nested", in: result))
    let methodRegion = try #require(result.index.executableRegions.first {
        $0.associatedFacetIndex == method.symbolGroupID.rawValue
    })
    let nestedRegion = try #require(result.index.executableRegions.first {
        $0.associatedFacetIndex == nested.symbolGroupID.rawValue
    })
    let methodScope = try #require(result.index.scopes.first {
        $0.kind == .function
            && $0.range == methodRegion.range
    })
    let nestedScope = try #require(result.index.scopes.first {
        $0.kind == .function
            && $0.range == nestedRegion.range
    })

    #expect(c.kind == .pythonClass)
    #expect(method.kind == .pythonFunction)
    #expect(method.parentFacetIndex == c.symbolGroupID.rawValue)
    #expect(nested.parentFacetIndex == method.symbolGroupID.rawValue)
    #expect(methodRegion.kind == .method)
    #expect(nestedRegion.kind == .function)
    #expect(methodScope.parent?.rawValue == result.index.scopes.first {
        $0.kind == .module
    }?.id.rawValue)
    #expect(nestedScope.parent?.rawValue == methodScope.id.rawValue)
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "self"
            && $0.kind == .param
    })
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "value"
            && $0.kind == .param
    })
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "args"
            && $0.kind == .param
    })
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "kwargs"
            && $0.kind == .param
    })
}

@Test
func assignmentBindingActivatesAfterRHSAndShadowsInNestedScope() throws {
    let result = try extract(
        """
        def outer():
            x = use(x)
            def inner():
                x = x + 1
                return x
            return inner
        """
    )
    let bindings = result.index.bindings.filter {
        result.names.resolve($0.localNameID) == "x"
    }

    #expect(bindings.count == 2)
    #expect(bindings[0].declarationRange < bindings[1].declarationRange)
    #expect(bindings.allSatisfy { $0.kind == .assignment })
}

@Test
func recordsDirectMethodAndInnerComputedCalls() throws {
    let source = """
        def caller(obj):
            direct()
            obj.method(1, 2)
            (factory())()
        """
    let result = try extract(source)
    let names = result.index.calls.map { result.names.resolve($0.nameID) }
    let direct = try #require(result.index.calls.first {
        result.names.resolve($0.nameID) == "direct"
    })
    let method = try #require(result.index.calls.first {
        result.names.resolve($0.nameID) == "method"
    })
    let factory = try #require(result.index.calls.first {
        result.names.resolve($0.nameID) == "factory"
    })

    #expect(names == ["direct", "method", "factory"])
    #expect(direct.syntacticKind == .directCall)
    #expect(method.syntacticKind == .methodCall)
    #expect(factory.syntacticKind == .directCall)
    #expect(text(in: result.source, range: method.receiverRange) == "obj")
    #expect(method.argumentCount == 2)
    #expect(text(in: result.source, range: factory.range) == "factory()")
}

@Test
func importsAbsoluteRelativeAliasAndWildcardOnce() throws {
    let source = """
        import os
        import pkg.sub as alias
        from pkg import model
        from .models import Model as M
        from other import *
        """
    let result = try extract(source)
    let importSpecs = result.index.imports.map {
        (
            result.strings.resolve($0.moduleSpecifier),
            $0.importedName.map(result.names.resolve),
            $0.localName.map(result.names.resolve),
            $0.kind,
            $0.flags
        )
    }

    #expect(importSpecs.count == 5)
    #expect(importSpecs.map(\.0) == ["os", "pkg.sub", "pkg", ".models", "other"])
    #expect(importSpecs.contains {
        $0.0 == "os" && $0.1 == nil && $0.2 == "os"
    })
    #expect(importSpecs.contains {
        $0.0 == "pkg.sub" && $0.1 == nil && $0.2 == "alias"
    })
    #expect(importSpecs.contains {
        $0.0 == "pkg" && $0.1 == "model" && $0.2 == "model"
    })
    #expect(importSpecs.contains {
        $0.0 == ".models" && $0.1 == "Model" && $0.2 == "M"
    })
    #expect(importSpecs.contains {
        $0.0 == "other" && $0.3 == .namespace && $0.4.contains(.wildcard)
    })
}

@Test
func unicodeRangesExcludeStringsAndComments() throws {
    let source = """
        # alpha
        s = "name"
        α = 1
        alpha()
        """
    let result = try extract(source)
    let bytes = Array(source.utf8)
    let alpha = try #require(result.index.calls.first {
        result.names.resolve($0.nameID) == "alpha"
    })
    let binding = try #require(result.index.bindings.first {
        result.names.resolve($0.localNameID) == "α"
    })

    #expect(text(in: source, range: alpha.range) == "alpha()")
    #expect(text(in: source, range: binding.declarationRange) == "α")
    let alphaRanges = try PythonExtractor().identifierRanges(
        named: "alpha",
        in: bytes
    )
    #expect(alphaRanges == [alpha.nameRange])
}

@Test
func syntaxErrorKeepsPartialIndex() throws {
    let source = """
        def good():
            return 1
        def broken(
        """
    let result = try extract(source)
    let diagnostic = try extractWithDiagnostics(source)

    #expect(facet(named: "good", in: result) != nil)
    #expect(diagnostic.containsErrorNodes)
}

@Test
func twoExtractionsAreStableAndKeyIsPassthrough() throws {
    let source = "def f(x):\n    return x\n"
    let first = try extract(source)
    let second = try extract(source)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    #expect(
        try encoder.encode(first.index) == encoder.encode(second.index)
    )
    #expect(first.index.key == ContentIndexKey(
        contentID: ContentID.sha256(of: Array(source.utf8)),
        languageMode: LanguageMode(language: .python),
        grammarVersion: PythonExtractor.grammarVersion,
        extractorVersion: PythonExtractor.extractorVersion
    ))
}

@Test
func wrongModeAndVariantFail() throws {
    let extractor = PythonExtractor()
    var rejectedModes = 0
    for mode in [
        LanguageMode(language: .rust),
        LanguageMode(language: .python, variant: "bad"),
        LanguageMode(language: .typescript),
    ] {
        do {
            _ = try extractor.extractWithDiagnostics(
                bytes: Array("def f(): pass".utf8),
                key: ContentIndexKey(
                    contentID: ContentID.sha256(of: Array("def f(): pass".utf8)),
                    languageMode: mode,
                    grammarVersion: PythonExtractor.grammarVersion,
                    extractorVersion: PythonExtractor.extractorVersion
                ),
                interner: ExtractionInterners(
                    names: Interner<NameID>(),
                    strings: Interner<StringID>()
                )
            )
        } catch is CocoaError {
            rejectedModes += 1
        } catch {
            rejectedModes += 1
        }
    }
    #expect(rejectedModes == 3)
}

@Test
func basicPackageFixtureCoversFileExtractionAndPythonFeatures() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/basic_package", isDirectory: true)

    for relativePath in [
        "pyproject.toml",
        "sample/__init__.py",
        "sample/models.py",
        "sample/service.py",
        "main.py",
    ] {
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(relativePath).path
            ),
            "missing fixture file: \(relativePath)"
        )
    }

    let models = try extract(fileURL: root.appendingPathComponent("sample/models.py"))
    let service = try extract(fileURL: root.appendingPathComponent("sample/service.py"))
    let main = try extract(fileURL: root.appendingPathComponent("main.py"))
    let modelFacet = try #require(facet(named: "Model", in: models))

    #expect(models.index.symbols.count == 4)
    #expect(modelFacet.kind == .pythonClass)
    #expect(facet(named: "__init__", in: models)?.parentFacetIndex == modelFacet.symbolGroupID.rawValue)
    #expect(facet(named: "describe", in: models)?.parentFacetIndex == modelFacet.symbolGroupID.rawValue)
    #expect(facet(named: "create_model", in: models)?.kind == .pythonFunction)

    let serviceImports = service.index.imports.map {
        (
            service.strings.resolve($0.moduleSpecifier),
            $0.importedName.map(service.names.resolve),
            $0.localName.map(service.names.resolve)
        )
    }
    #expect(serviceImports.contains {
        $0.0 == ".models" && $0.1 == "Model" && $0.2 == "M"
    })
    #expect(serviceImports.contains {
        $0.0 == "sample.models" && $0.1 == "create_model" && $0.2 == "make"
    })
    #expect(service.index.calls.contains {
        service.names.resolve($0.nameID) == "make"
            && $0.syntacticKind == .directCall
    })
    #expect(service.index.calls.contains {
        service.names.resolve($0.nameID) == "append"
            && $0.syntacticKind == .methodCall
            && text(in: service.source, range: $0.receiverRange) == "self.local"
    })

    #expect(main.index.imports.count == 1)
    #expect(main.index.calls.contains {
        main.names.resolve($0.nameID) == "Svc"
            && $0.syntacticKind == .directCall
    })
    #expect(main.index.calls.contains {
        main.names.resolve($0.nameID) == "refresh"
            && $0.syntacticKind == .methodCall
    })
}


private struct ExtractionResult {
    let source: String
    let index: ContentIndex
    let names: Interner<NameID>
    let strings: Interner<StringID>
}

private func extractWithDiagnostics(
    _ source: String
) throws -> (index: ContentIndex, containsErrorNodes: Bool) {
    let bytes = Array(source.utf8)
    return try PythonExtractor().extractWithDiagnostics(
        bytes: bytes,
        key: ContentIndexKey(
            contentID: ContentID.sha256(of: bytes),
            languageMode: LanguageMode(language: .python),
            grammarVersion: PythonExtractor.grammarVersion,
            extractorVersion: PythonExtractor.extractorVersion
        ),
        interner: ExtractionInterners(
            names: Interner<NameID>(),
            strings: Interner<StringID>()
        )
    )
}

private func extract(_ source: String) throws -> ExtractionResult {
    let bytes = Array(source.utf8)
    let names = Interner<NameID>()
    let strings = Interner<StringID>()
    let key = ContentIndexKey(
        contentID: ContentID.sha256(of: bytes),
        languageMode: LanguageMode(language: .python),
        grammarVersion: PythonExtractor.grammarVersion,
        extractorVersion: PythonExtractor.extractorVersion
    )
    return ExtractionResult(
        source: source,
        index: try PythonExtractor().extract(
            bytes: bytes,
            key: key,
            interner: ExtractionInterners(
                names: names,
                strings: strings
            )
        ),
        names: names,
        strings: strings
    )
}

private func extract(fileURL: URL) throws -> ExtractionResult {
    try extract(String(contentsOf: fileURL, encoding: .utf8))
}

private func text(in source: String, range: CodeInsightCore.ByteRange?) -> String? {
    guard let range else { return nil }
    let bytes = Array(source.utf8)
    return String(
        bytes: bytes[Int(range.lowerBound)..<Int(range.upperBound)],
        encoding: .utf8
    )
}

private func facet(
    named name: String,
    in result: ExtractionResult
) -> DeclarationFacet? {
    result.index.symbols.first {
        result.names.resolve($0.nameID) == name
    }
}

private func bindingRange(
    _ name: String,
    in result: ExtractionResult
) -> CodeInsightCore.ByteRange {
    result.index.bindings.first {
        result.names.resolve($0.localNameID) == name
    }?.declarationRange
        ?? ByteRange(lowerBound: 0, upperBound: 0)
}
