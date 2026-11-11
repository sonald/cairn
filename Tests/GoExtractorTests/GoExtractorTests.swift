import CodeInsightCore
import CodeInsightGoExtractor
import Foundation
import Testing

@Test
func goGrammarLinks() {
    #expect(GoExtractor.grammarIsAvailable)
}

/// The extractor contract other slices build on: kinds, spaces, parents,
/// visibility, receiver relations and embedded bases.
@Test
func goDeclarationsFollowTheExtractorContract() throws {
    let result = try extract("""
    package cmd

    type Command struct {
        Use, Short string
        parent *Command
        io.Writer
        *Base
    }

    type Runner interface {
        Reader
        Run(args []string) error
    }

    type Alias = Command
    type Names []string

    const (
        Version = "1"
        hidden, Ünï = 1, 2
    )

    var _ Runner = (*Command)(nil)

    func Execute() {}

    func (c *Command) Execute() error { return nil }

    func (s Stack[T]) push(v T) {}

    func helper() {
        type local struct{}
        var inner = 1
        _ = inner
    }
    """)
    func facet(_ name: String, _ kind: DeclarationKind) throws -> DeclarationFacet {
        try #require(result.index.symbols.first { result.name($0.nameID) == name && $0.kind == kind })
    }
    let command = try facet("Command", .goStruct)
    let commandIndex = command.symbolGroupID.rawValue
    let runner = try facet("Runner", .goInterface)
    #expect(command.space == .type && command.visibility == .public)
    #expect(try facet("Alias", .goType).space == .type)
    #expect(try facet("Names", .goType).space == .type)
    for field in ["Use", "Short", "parent", "Writer", "Base"] {
        #expect(try facet(field, .goField).parentFacetIndex == commandIndex, "\(field)")
    }
    #expect(try facet("parent", .goField).visibility == .private)
    #expect(try facet("parent", .goField).typeRef.map { result.text($0.ranges[0]) } == "Command")
    #expect(try facet("Run", .goMethod).parentFacetIndex == runner.symbolGroupID.rawValue)
    #expect(try facet("Version", .goConst).space == .value)
    #expect(try facet("hidden", .goConst).visibility == .private)
    #expect(try facet("Ünï", .goConst).visibility == .public)
    #expect(try facet("Execute", .goFunction).parentFacetIndex == nil)
    #expect(!result.index.symbols.contains { result.name($0.nameID) == "_" })
    // Locals stay out of the package's declarations.
    #expect(!result.index.symbols.contains { ["local", "inner"].contains(result.name($0.nameID)) })

    let method = try facet("Execute", .goMethod)
    #expect(method.parentFacetIndex == nil && method.space == .value)
    let methodIndex = try #require(result.index.symbols.firstIndex { $0.kind == .goMethod && result.name($0.nameID) == "Execute" })
    let push = try #require(result.index.symbols.firstIndex { result.name($0.nameID) == "push" })
    let relations = result.index.implRelations.map { ($0.implFacetIndex, result.name($0.typeNameID), $0.traitNameID) }
    #expect(relations.count == 2)
    #expect(relations.contains { $0.0 == UInt32(methodIndex) && $0.1 == "Command" && $0.2 == nil })
    #expect(relations.contains { $0.0 == UInt32(push) && $0.1 == "Stack" })

    let bases = result.index.supertypes.map { (result.index.symbols[Int($0.facetIndex)].kind, result.name($0.nameID)) }
    #expect(Set(bases.map { "\($0.0):\($0.1)" }) == ["goStruct:Writer", "goStruct:Base", "goInterface:Reader"])
}

@Test
func goImportsRecordPathLocalNameAndForm() throws {
    let result = try extract("""
    package main

    import "fmt"
    import (
        yaml "gopkg.in/yaml.v3"
        "github.com/spf13/cobra/v2"
        "github.com/x/go-errors"
        "gopkg.in/check.v1"
        . "strings"
        _ "embed"
    )
    """)
    let rows = result.index.imports.map {
        (result.strings.resolve($0.moduleSpecifier), $0.localName.map(result.name), $0.kind, $0.flags)
    }
    #expect(rows.map(\.0) == [
        "fmt", "gopkg.in/yaml.v3", "github.com/spf13/cobra/v2", "github.com/x/go-errors",
        "gopkg.in/check.v1", "strings", "embed",
    ])
    #expect(rows.map(\.1) == ["fmt", "yaml", "cobra", "errors", "check", nil, nil])
    #expect(rows.map(\.2) == [.module, .module, .module, .module, .module, .module, .sideEffect])
    #expect(rows[5].3.contains(.wildcard))
    #expect(result.index.imports.allSatisfy { $0.importedName == nil })
    #expect(result.index.bindings.filter { $0.kind == .importBinding }.map { result.name($0.localNameID) }
        == ["fmt", "yaml", "cobra", "errors", "check"])
}

@Test
func goCallsSeparateDirectMethodAndPackageQualifiedForms() throws {
    let result = try extract("""
    package main

    import "fmt"

    var banner = fmt.Sprintf("%d", 1)

    func run(c *Command) {
        helper(1, 2)
        c.Execute()
        fmt.Println("x")
        c.Flags().Bool("v")
        Map[int](nil)
        defer func() { cleanup() }()
    }
    """)
    func call(_ name: String) throws -> UnresolvedCall {
        try #require(result.index.calls.first { result.name($0.nameID) == name })
    }
    #expect(try call("helper").syntacticKind == .directCall)
    #expect(try call("helper").argumentCount == 2)
    #expect(try call("Execute").syntacticKind == .methodCall)
    #expect(try call("Execute").receiverRange.map(result.text) == "c")
    #expect(try call("Println").syntacticKind == .qualifiedCall)
    #expect(try call("Println").qualifierRange.map(result.text) == "fmt")
    #expect(try call("Bool").receiverRange.map(result.text) == "c.Flags()")
    #expect(try call("Map").syntacticKind == .directCall)
    #expect(try call("Sprintf").syntacticKind == .qualifiedCall)
    // A package variable's initializer runs at package level.
    let sprintfRegion = try call("Sprintf").regionID
    #expect(result.index.executableRegions[Int(sprintfRegion.rawValue)].kind == .moduleInitializer)
    // A closure's calls belong to the function that holds it.
    let cleanupRegion = result.index.executableRegions[Int(try call("cleanup").regionID.rawValue)]
    let run = result.index.symbols.firstIndex { result.name($0.nameID) == "run" }
    #expect(cleanupRegion.kind == .closure && cleanupRegion.associatedFacetIndex == run.map(UInt32.init))
}

@Test
func goBindingsCarryScopesAndTheTypesTheSyntaxSpells() throws {
    let result = try extract("""
    package main

    func (c *Command) run(args []string, n int, opts ...Option) (out *Result, err error) {
        a := Command{}
        b := &pkg.Command{}
        d := new(Command)
        var e Command
        f, g := 1, other()
        for i, v := range args {
            if w := v; w != "" {
                _ = i
            }
        }
        go func(x Config) {}(Config{})
        switch t := x.(type) {
        default:
            _ = t
        }
    }

    func Map[T any](x T) {}
    """)
    func binding(_ name: String) throws -> BindingRecord {
        try #require(result.index.bindings.first { result.name($0.localNameID) == name })
    }
    func scopeKind(_ name: String) throws -> ScopeKind {
        result.index.scopes[Int(try binding(name).scopeID.rawValue)].kind
    }
    let receiver = try binding("c")
    #expect(receiver.kind == .param)
    #expect(receiver.typeRef == .selfType(try #require(result.range(of: "Command", occurrence: 0))))
    #expect(receiver.targetHint.map { (result.name($0.nameID), $0.hintKind) }! == ("Command", .unqualified))
    #expect(try binding("args").typeRef == nil)
    #expect(try binding("n").typeRef.map { if case .primitive = $0 { true } else { false } } == true)
    #expect(try binding("opts").targetHint == nil)
    #expect(try binding("out").targetHint.map { result.name($0.nameID) } == "Result")
    for name in ["a", "b", "d"] {
        let constructed = try binding(name)
        #expect(constructed.kind == .letBinding, "\(name)")
        #expect(constructed.targetHint.map { (result.name($0.nameID), $0.hintKind) }! == ("Command", .member), "\(name)")
        if case let .constructed(range)? = constructed.typeRef {
            #expect(result.text(range) == "Command")
        } else {
            Issue.record("\(name) has no constructed type")
        }
    }
    #expect(try binding("e").targetHint?.hintKind == .unqualified)
    #expect(try binding("f").targetHint == nil && binding("g").kind == .letBinding)
    #expect(try binding("x").targetHint.map { result.name($0.nameID) } == "Config")
    #expect(try scopeKind("c") == .function)
    #expect(try scopeKind("x") == .function)
    #expect(try scopeKind("i") == .block && scopeKind("w") == .block && scopeKind("t") == .block)
    if case .genericUnbounded? = try result.index.bindings.last(where: { result.name($0.localNameID) == "x" })?.typeRef {
    } else {
        Issue.record("a type parameter is not a named type")
    }
    #expect(result.index.scopes[0].kind == .module)
    #expect(result.index.executableRegions.contains { $0.kind == .method && $0.associatedFacetIndex == 0 })
    #expect(result.index.regions.contains { $0.kind == .string })
}

@Test
func goIdentifierRangesCoverEveryIdentifierKind() throws {
    let source = """
    package cobra

    import cobra "x/cobra"

    type cobra struct{ cobra int }

    func f() { cobra.cobra(); var cobra cobra; _ = "cobra" }
    """
    let ranges = try GoExtractor().identifierRanges(
        named: "cobra", in: Array(source.utf8), mode: LanguageMode(language: .go)
    )
    // The package clause, the alias, the type, the field, the selector
    // operand and field, the variable and its type; not the string.
    #expect(ranges.count == 8)
}

/// Reader and search threads have small stacks; a long `+` chain nests the
/// tree thousands deep.
@Test
func goDeeplyNestedExpressionsExtractWithoutRecursion() throws {
    let chain = Array(repeating: "\"kw\"", count: 3000).joined(separator: " + ")
    let source = "package p\n\nfunc f() string { return f() + \(chain) }\n"
    let result = try extract(source)
    #expect(result.index.calls.count == 1)
    let ranges = try GoExtractor().identifierRanges(named: "f", in: Array(source.utf8), mode: LanguageMode(language: .go))
    #expect(ranges.count == 2)
}

/// tree-sitter-go 0.25 does not parse `new(expr)` or methods with their own
/// type parameters; the rest of the file still indexes.
@Test
func goGrammarGapsKeepTheRestOfTheFile() throws {
    let result = try extract("""
    package p

    func first() *int { return new(1 + 2) }

    func (c *C) Map[T any](x T) {}

    func last() { first() }
    """)
    #expect(result.containsErrorNodes)
    #expect(result.index.symbols.contains { result.name($0.nameID) == "first" })
    #expect(result.index.symbols.contains { result.name($0.nameID) == "last" })
    #expect(result.index.calls.contains { result.name($0.nameID) == "first" })
}

// MARK: Helpers

private struct Extraction {
    let index: ContentIndex
    let containsErrorNodes: Bool
    let source: [UInt8]
    let names: Interner<NameID>
    let strings: Interner<StringID>

    func name(_ id: NameID) -> String { names.resolve(id) }

    func text(_ range: CodeInsightCore.ByteRange) -> String {
        String(decoding: source[Int(range.lowerBound)..<Int(range.upperBound)], as: UTF8.self)
    }

    func range(of needle: String, occurrence: Int) -> CodeInsightCore.ByteRange? {
        let haystack = String(decoding: source, as: UTF8.self)
        var searchStart = haystack.startIndex
        var found = 0
        while let match = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            if found == occurrence {
                let lower = haystack.utf8.distance(from: haystack.startIndex, to: match.lowerBound)
                return CodeInsightCore.ByteRange(
                    lowerBound: UInt32(lower), upperBound: UInt32(lower + needle.utf8.count)
                )
            }
            found += 1
            searchStart = match.upperBound
        }
        return nil
    }
}

private func extract(_ source: String) throws -> Extraction {
    let bytes = Array(source.utf8)
    let names = Interner<NameID>()
    let strings = Interner<StringID>()
    let key = ContentIndexKey(
        contentID: ContentID.sha256(of: bytes),
        languageMode: LanguageMode(language: .go),
        grammarVersion: GoExtractor.grammarVersion,
        extractorVersion: GoExtractor.extractorVersion
    )
    let result = try GoExtractor().extractWithDiagnostics(
        bytes: bytes, key: key, interner: ExtractionInterners(names: names, strings: strings)
    )
    return Extraction(
        index: result.index, containsErrorNodes: result.containsErrorNodes,
        source: bytes, names: names, strings: strings
    )
}
