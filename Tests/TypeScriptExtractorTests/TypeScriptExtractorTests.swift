import CodeInsightCore
import CodeInsightTypeScriptExtractor
import Foundation
import Testing

@Test
func extractsFunctionsClassesMethodsAndArrowVariables() throws {
    let source = """
        export function alpha(a: number) {
            return a
        }

        const beta = (x: string) => x.toUpperCase()

        class Box {
            constructor(public value: number) {}
            describe(label: string) {
                return label
            }
        }

        export const handler = () => {
            return alpha(1)
        }
        """
    let result = try extract(source, mode: LanguageMode(language: .typescript))

    let alpha = try #require(facet(named: "alpha", in: result))
    let beta = try #require(facet(named: "beta", in: result))
    let box = try #require(facet(named: "Box", in: result))
    let describe = try #require(facet(named: "describe", in: result))
    let handler = try #require(facet(named: "handler", in: result))

    #expect(alpha.kind == .typescriptFunction)
    #expect(alpha.parentFacetIndex == nil)
    #expect(beta.kind == .typescriptFunction)
    #expect(box.kind == .typescriptClass)
    #expect(describe.kind == .typescriptFunction)
    #expect(describe.parentFacetIndex == box.symbolGroupID.rawValue)
    #expect(handler.kind == .typescriptFunction)
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "a"
            && $0.kind == .param
    })
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "x"
            && $0.kind == .param
    })
    #expect(result.index.calls.contains {
        result.names.resolve($0.nameID) == "alpha"
    })
}

@Test
func topLevelClosureVariablesHaveSignatureAndBodyFingerprints() throws {
    let source = """
        const f = (x: string) => x.toUpperCase()
        const g = function (y: number) { return y + 1 }
        """
    let result = try extract(source, mode: .tsTS)
    let f = try #require(facet(named: "f", in: result))
    let g = try #require(facet(named: "g", in: result))

    #expect(f.signatureFingerprint != nil)
    #expect(f.bodyFingerprint != nil)
    #expect(g.signatureFingerprint != nil)
    #expect(g.bodyFingerprint != nil)
}

@Test
func variableClosureFingerprintsSeparateSignatureFromBody() throws {
    let signature = """
        const f = (value: string) => value.toUpperCase()
        """
    let body = """
        const f = (value: string) => value.toLowerCase()
        """
    let signatureChanged = """
        const f = (value: unknown) => value.toUpperCase()
        """

    let baseFacet = try #require(facet(
        named: "f",
        in: try extract(signature, mode: .tsTS)
    ))
    let bodyFacet = try #require(facet(
        named: "f",
        in: try extract(body, mode: .tsTS)
    ))
    let signatureFacet = try #require(facet(
        named: "f",
        in: try extract(signatureChanged, mode: .tsTS)
    ))

    #expect(baseFacet.signatureFingerprint == bodyFacet.signatureFingerprint)
    #expect(baseFacet.bodyFingerprint != bodyFacet.bodyFingerprint)
    #expect(baseFacet.signatureFingerprint != signatureFacet.signatureFingerprint)
    #expect(baseFacet.bodyFingerprint == signatureFacet.bodyFingerprint)
}

@Test
func recordsDirectMethodAndNewCallsInInnermostRegion() throws {
    let source = """
        function caller(obj: { run(x: number): string, computed: string }): number {
            direct()
            obj.run(1)
            obj[computed]()
            return new Clock().tick()
        }
        class Clock {}
        """
    let result = try extract(source, mode: .tsTS)
    let callNames = result.index.calls.map { result.names.resolve($0.nameID) }

    #expect(callNames.contains("direct"))
    #expect(callNames.contains("run"))
    #expect(!callNames.contains("computed"))
    #expect(callNames.contains("Clock"))
    #expect(callNames.contains("tick"))
}

@Test
func newExpressionOnlyRecordsIdentifierConstructorDirectly() throws {
    let source = """
        function f() {
            new Clock()
            new ns.Clock()
            return new data.Models.Clock()
        }
        class Clock {}
        namespace ns { export class Clock {} }
        """
    let result = try extract(source, mode: .tsTS)
    let newCalls = result.index.calls.filter {
        result.names.resolve($0.nameID) == "Clock"
    }

    #expect(newCalls.count == 1)
    #expect(newCalls.allSatisfy { $0.qualifierRange == nil })
}

@Test
func recordsModuleFunctionAndBlockScopesSimpleBindingsAndShadowing() throws {
    let source = """
        const top = 1
        function outer() {
            let x = 1
            if (x) {
                const x = 2
            }
            const y = 3
        }
        """
    let result = try extract(source, mode: .tsTS)
    let moduleScope = try #require(result.index.scopes.first { $0.kind == .module })
    let functionScope = try #require(result.index.scopes.first { $0.kind == .function })
    let blockScopes = result.index.scopes.filter { $0.kind == .block }

    #expect(functionScope.parent == moduleScope.id)
    #expect(!blockScopes.isEmpty)
    #expect(blockScopes.contains { $0.parent == functionScope.id })
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "top"
            && $0.scopeID == moduleScope.id
            && $0.kind == .letBinding
    })
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "x"
            && $0.scopeID == functionScope.id
            && $0.kind == .letBinding
    })
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "x"
            && $0.scopeID == blockScopes.first?.id
            && $0.kind == .letBinding
    })
    #expect(result.index.bindings.contains {
        result.names.resolve($0.localNameID) == "y"
            && $0.scopeID == functionScope.id
            && $0.kind == .letBinding
    })
}

@Test
func onlyExportedNamedDeclarationsBecomeExportRecords() throws {
    let source = """
        export function publicFn() {}
        function privateFn() {}
        export class PublicClass {}
        class PrivateClass {}
        export const publicArrow = () => {}
        const privateArrow = () => {}
        """
    let result = try extract(source, mode: .tsTS)
    let exported = Set(result.index.exports.map { result.names.resolve($0.exportedName) })

    #expect(exported.contains("publicFn"))
    #expect(exported.contains("PublicClass"))
    #expect(exported.contains("publicArrow"))
    #expect(!exported.contains("privateFn"))
    #expect(!exported.contains("PrivateClass"))
    #expect(!exported.contains("privateArrow"))
    #expect(result.index.symbols.contains {
        result.names.resolve($0.nameID) == "privateFn"
    })
    #expect(result.index.symbols.contains {
        result.names.resolve($0.nameID) == "PrivateClass"
    })
}

@Test
func nestedDeclarationsKeepScopesAndRegionsButSkipFacets() throws {
    let source = """
        function outer() {
            function inner() {}
            const innerArrow = () => {
                class InnerClass {}
            }
            class InnerClass {
                method() {}
                nested() {
                    function deep() {}
                }
            }
        }
        """
    let result = try extract(source, mode: .tsTS)

    #expect(result.index.scopes.filter { $0.kind == .function }.count >= 3)
    #expect(result.index.executableRegions.filter {
        $0.kind == .function || $0.kind == .method || $0.kind == .closure
    }.count >= 4)

    for name in ["inner", "InnerClass", "deep", "method"] {
        #expect(facet(named: name, in: result) == nil)
    }
}

@Test
func nestedClassMethodsDoNotGainFacetNorOuterParent() throws {
    let source = """
        class Top {
            render() {
                class Helper {
                    internalMethod() {}
                }
                function helperFn() {}
            }
        }
        """
    let result = try extract(source, mode: .tsTS)
    let top = try #require(facet(named: "Top", in: result))
    let render = try #require(facet(named: "render", in: result))

    #expect(render.parentFacetIndex == top.symbolGroupID.rawValue)
    #expect(facet(named: "Helper", in: result) == nil)
    #expect(facet(named: "internalMethod", in: result) == nil)
    #expect(facet(named: "helper", in: result) == nil)
}

@Test
func identifierRangesIncludeParameterAndJSXValueRefsButExcludeTypePropertyAndTagTokens() throws {
    let source = """
        type TypeName = string
        const obj = { TypeName: 1 }
        function fn(TypeName: string) {
            return <span TypeName={TypeName}>{TypeName}</span>
        }
        """
    let ranges = try TypeScriptExtractor().identifierRanges(
        named: "TypeName",
        in: Array(source.utf8),
        mode: .init(language: .typescript, variant: "tsx")
    )

    #expect(ranges.count == 3)
}

@Test
func identifierRangesIncludeSelfClosingJSXValueRefsButNotTagTokens() throws {
    let source = """
        function fn(TypeName: string) {
            return <Thing TypeName={TypeName} />
        }
        """
    let ranges = try TypeScriptExtractor().identifierRanges(
        named: "TypeName",
        in: Array(source.utf8),
        mode: .init(language: .typescript, variant: "tsx")
    )

    #expect(ranges.count == 2)
}

@Test
func importsExportsReexportAndDefaultNamespaceHonesty() throws {
    let source = """
        export function model(value: string): string {
            return value
        }
        export { model as alias }
        import { model as renamed } from "./models"
        import type { TypeOnly } from "./types"
        import * as all from "./all"
        import defaultThing from "./default"
        import type { TypeOnly as TypeAlias } from "./typeonly"
        import "./side-effect"
        export { renamed } from "./barrel"
        export * from "./wild"
        import { type InlineType } from "./inline"
        export { type ReexportType } from "./type-reexport"
        export type { TypeOnlyExport } from "./type-only-reexport"
        """
    let result = try extract(source, mode: .tsTS)

    let exportNames = result.exports.map { result.names.resolve($0.exportedName) }
    #expect(exportNames.contains("model"))
    #expect(exportNames.contains("alias"))
    #expect(exportNames.contains("renamed"))

    let namedImport = try #require(result.index.imports.first {
        $0.kind == .named
            && result.names.resolve($0.localName ?? NameID(rawValue: 0)) == "renamed"
    })
    #expect(result.names.resolve(namedImport.importedName ?? NameID(rawValue: 0)) == "model")
    #expect(result.strings.resolve(namedImport.moduleSpecifier) == "./models")

    let typeImport = try #require(result.index.imports.first {
        $0.kind == .named
            && $0.flags.contains(.typeOnly)
            && result.strings.resolve($0.moduleSpecifier) == "./typeonly"
            && result.names.resolve($0.localName ?? NameID(rawValue: 0)) == "TypeAlias"
    })
    #expect(typeImport.flags.contains(.typeOnly))
    #expect(result.strings.resolve(typeImport.moduleSpecifier) == "./typeonly")

    let defaultImport = try #require(result.index.imports.first {
        $0.kind == .default
            && result.strings.resolve($0.moduleSpecifier) == "./default"
    })
    #expect(result.names.resolve(defaultImport.localName ?? NameID(rawValue: 0)) == "defaultThing")

    #expect(result.index.imports.contains {
        $0.kind == .namespace
            && $0.flags.contains(.wildcard)
            && result.strings.resolve($0.moduleSpecifier) == "./all"
    })
    #expect(result.index.imports.contains {
        $0.flags.contains(.reexport)
            && result.strings.resolve($0.moduleSpecifier) == "./barrel"
    })
    #expect(result.index.imports.contains {
        $0.flags.contains(.reexport)
            && $0.flags.contains(.wildcard)
            && result.strings.resolve($0.moduleSpecifier) == "./wild"
    })
    #expect(result.index.imports.contains {
        $0.kind == .sideEffect
            && result.strings.resolve($0.moduleSpecifier) == "./side-effect"
    })
    #expect(result.index.imports.contains {
        $0.kind == .named
            && $0.flags.contains(.typeOnly)
            && !$0.flags.contains(.reexport)
            && result.strings.resolve($0.moduleSpecifier) == "./inline"
            && result.names.resolve($0.localName ?? NameID(rawValue: 0)) == "InlineType"
    })
    #expect(result.index.imports.contains {
        $0.kind == .named
            && $0.flags.contains(.reexport)
            && $0.flags.contains(.typeOnly)
            && result.strings.resolve($0.moduleSpecifier) == "./type-reexport"
            && result.names.resolve($0.localName ?? NameID(rawValue: 0)) == "ReexportType"
    })
    #expect(result.index.imports.contains {
        $0.kind == .named
            && $0.flags.contains(.reexport)
            && $0.flags.contains(.typeOnly)
            && result.strings.resolve($0.moduleSpecifier) == "./type-only-reexport"
            && result.names.resolve($0.localName ?? NameID(rawValue: 0)) == "TypeOnlyExport"
    })
}

@Test
func exportStatementWithMultipleDeclaratorsEmitsEachExportedName() throws {
    let source = """
        export const first = 1
        export const second = 2
        export let third = 3
        export function exportFn() {}
        export class ExportClass {}
        """
    let result = try extract(source, mode: .tsTS)
    let exported = Set(result.exports.map { result.names.resolve($0.exportedName) })

    #expect(exported.contains("first"))
    #expect(exported.contains("second"))
    #expect(exported.contains("third"))
    #expect(exported.contains("exportFn"))
    #expect(exported.contains("ExportClass"))
}

@Test
func tsxSourceHasErrorInTsModeButNotTsxMode() throws {
    let source = """
        export const Badge = ({ label }: { label: string }) => {
            return <span>{label}</span>
        }
        """
    let tsx = try extractWithDiagnostics(source, .init(language: .typescript, variant: "tsx"))
    let ts = try extractWithDiagnostics(source, .tsTS)

    #expect(!tsx.containsErrorNodes)
    #expect(ts.containsErrorNodes)
}

@Test
func wrongModeVariantBomAndInvalidUTF8FailBeforeParse() throws {
    let extractor = TypeScriptExtractor()
    let contentID = ContentID.sha256(of: Array("x".utf8))

    for mode in [
        LanguageMode(language: .rust),
        LanguageMode(language: .typescript, variant: "bad"),
    ] {
        do {
            _ = try extractor.extractWithDiagnostics(
                bytes: Array("function f() {}".utf8),
                key: ContentKey.make(contentID: contentID, mode: mode),
                interner: ExtractionInterners(
                    names: Interner<NameID>(),
                    strings: Interner<StringID>()
                )
            )
            Issue.record("Expected failure for \(mode)")
        } catch is CocoaError {
            // expected
        }
    }

    let bom = Array<UInt8>([0xEF, 0xBB, 0xBF]) + Array("function f() {}".utf8)
    do {
        _ = try extractor.extractWithDiagnostics(
            bytes: bom,
            key: ContentKey.make(contentID: ContentID.sha256(of: bom), mode: .tsTS),
            interner: ExtractionInterners(
                names: Interner<NameID>(),
                strings: Interner<StringID>()
            )
        )
        Issue.record("Expected BOM failure")
    } catch is CocoaError {
        // expected
    }

    let invalid = Array<UInt8>([0xFF, 0xFE, 0x00])
    do {
        _ = try extractor.extractWithDiagnostics(
            bytes: invalid,
            key: ContentKey.make(contentID: ContentID.sha256(of: invalid), mode: .tsTS),
            interner: ExtractionInterners(
                names: Interner<NameID>(),
                strings: Interner<StringID>()
            )
        )
        Issue.record("Expected invalid UTF-8 failure")
    } catch is CocoaError {
        // expected
    }
}

@Test
func parserObserverIsZeroCalledForPreParseRejections() throws {
    let extractor = TypeScriptExtractor()
    let base = Array("function f() {}".utf8)
    let cases: [(bytes: [UInt8], mode: LanguageMode)] = [
        (base, LanguageMode(language: .rust)),
        (base, LanguageMode(language: .typescript, variant: "bad")),
        ([0xEF, 0xBB, 0xBF] + base, .tsTS),
        ([0xFF, 0xFE, 0x00], .tsTS),
    ]

    try TypeScriptExtractor.$parseObserver.withValue({
        Issue.record("parse observer was called before rejection")
    }) {
        for case_ in cases {
            do {
                _ = try extractor.extractWithDiagnostics(
                    bytes: case_.bytes,
                    key: ContentKey.make(
                        contentID: ContentID.sha256(of: case_.bytes),
                        mode: case_.mode
                    ),
                    interner: interners()
                )
                Issue.record("Expected failure for \(case_.mode): \(case_.bytes)")
            } catch is CocoaError {
                // expected
            }
        }
    }
}

@Test
func syntaxErrorNodesAreReported() throws {
    let source = """
        function ok() {
            return 1
        }
        function broken( {
        """
    let result = try extractWithDiagnostics(source, .tsTS)

    #expect(result.containsErrorNodes)
}

@Test
func fixedFixtureDumpIsStable() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/basic_project", isDirectory: true)
    let main = root.appendingPathComponent("main.ts")

    #expect(FileManager.default.fileExists(atPath: main.path))

    let result = try extract(fileURL: main, mode: .tsTS)
    let dump = CanonicalDumperProvider.render(result.index, names: result.names, strings: result.strings)

    let goldenURL = root.appendingPathComponent("dump.golden")
    let expected = try String(contentsOf: goldenURL, encoding: .utf8)
    if ProcessInfo.processInfo.environment["RECORD"] == "1" {
        try dump.write(to: goldenURL, atomically: true, encoding: .utf8)
    } else {
        #expect(dump == expected)
    }
}

private struct ExtractionResult {
    let source: String
    let index: ContentIndex
    let names: Interner<NameID>
    let strings: Interner<StringID>
    var exports: [ExportRecord] { index.exports }
}

private func extract(_ source: String, mode: LanguageMode) throws -> ExtractionResult {
    let bytes = Array(source.utf8)
    let names = Interner<NameID>()
    let strings = Interner<StringID>()
    let key = ContentKey.make(contentID: ContentID.sha256(of: bytes), mode: mode)
    let result = try TypeScriptExtractor().extractWithDiagnostics(
        bytes: bytes,
        key: key,
        interner: ExtractionInterners(names: names, strings: strings)
    )
    return ExtractionResult(
        source: source,
        index: result.index,
        names: names,
        strings: strings
    )
}

private func extractWithDiagnostics(
    _ source: String,
    _ mode: LanguageMode
) throws -> (index: ContentIndex, containsErrorNodes: Bool) {
    let bytes = Array(source.utf8)
    return try TypeScriptExtractor().extractWithDiagnostics(
        bytes: bytes,
        key: ContentKey.make(contentID: ContentID.sha256(of: bytes), mode: mode),
        interner: interners()
    )
}

private func extract(fileURL: URL, mode: LanguageMode) throws -> ExtractionResult {
    let data = try Data(contentsOf: fileURL)
    return try extract(String(decoding: data, as: UTF8.self), mode: mode)
}

private func facet(named name: String, in result: ExtractionResult) -> DeclarationFacet? {
    result.index.symbols.first {
        result.names.resolve($0.nameID) == name
    }
}

private func interners() -> ExtractionInterners {
    ExtractionInterners(
        names: Interner<NameID>(),
        strings: Interner<StringID>()
    )
}

private enum ContentKey {
    static func make(contentID: ContentID, mode: LanguageMode? = nil) -> ContentIndexKey {
        ContentIndexKey(
            contentID: contentID,
            languageMode: mode ?? LanguageMode(language: .typescript),
            grammarVersion: TypeScriptExtractor.grammarVersion,
            extractorVersion: TypeScriptExtractor.extractorVersion
        )
    }
}

private extension LanguageMode {
    static let tsTS = LanguageMode(language: .typescript)
}

private enum CanonicalDumperProvider {
    static func render(
        _ index: ContentIndex,
        names: Interner<NameID>,
        strings: Interner<StringID>
    ) -> String {
        var lines = ["facets:"]
        for f in index.symbols.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            lines.append("  - \(names.resolve(f.nameID)) kind=\(f.kind.rawValue) parent=\(f.parentFacetIndex?.description ?? "-")")
        }
        lines.append("bindings:")
        for b in index.bindings.sorted(by: { $0.declarationRange.lowerBound < $1.declarationRange.lowerBound }) {
            lines.append("  - \(names.resolve(b.localNameID)) kind=\(b.kind.rawValue) scope=\(b.scopeID.rawValue)")
        }
        lines.append("calls:")
        for c in index.calls.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            lines.append("  - \(names.resolve(c.nameID)) kind=\(c.syntacticKind.rawValue)")
        }
        lines.append("imports:")
        for i in index.imports.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            lines.append("  - \(strings.resolve(i.moduleSpecifier)) kind=\(i.kind.rawValue) flags=\(i.flags.rawValue)")
        }
        lines.append("exports:")
        for e in index.exports.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            lines.append("  - \(names.resolve(e.exportedName))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
