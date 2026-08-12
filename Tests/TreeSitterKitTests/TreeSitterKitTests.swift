import CTreeSitterRust
import CTreeSitterPython
import CTreeSitterTypeScript
import Testing
import TreeSitterKit

@Test
func parsesRustSource() throws {
    let source = """
        use std::fmt;

        fn run() {
            let closure = |value: i32| value + 1;
            let _ = closure(41);
        }

        struct Reader;

        impl Reader {
            fn format(&self) -> String {
                format!("{}", 42)
            }
        }
        """

    let parser = try #require(makeRustParser())
    let tree = try #require(parser.parse(Array(source.utf8)))

    #expect(tree.rootNode.kind == "source_file")
    #expect(tree.rootNode.hasError == false)
    #expect(tree.rootNode.namedChildren.map(\.kind) == [
        "use_declaration",
        "function_item",
        "struct_item",
        "impl_item",
    ])
}

@Test
func returnsTreeForInvalidRustSource() throws {
    let parser = try #require(makeRustParser())
    let tree = try #require(parser.parse(Array("fn broken( {".utf8)))

    #expect(tree.rootNode.hasError)
}

@Test
func findsPythonFunctionNamedFields() throws {
    let source = """
        def add(a, b):
            return a + b
        """

    let parser = try #require(makePythonParser())
    let tree = try #require(parser.parse(Array(source.utf8)))

    #expect(tree.rootNode.kind == "module")
    #expect(tree.rootNode.hasError == false)

    let definition = try #require(tree.rootNode.namedChildren.first {
        $0.kind == "function_definition"
    })
    let name = try #require(definition.child(namedField: "name"))
    let parameters = try #require(definition.child(namedField: "parameters"))
    let body = try #require(definition.child(namedField: "body"))

    #expect(name.kind == "identifier")
    #expect(text(of: name, in: source) == "add")
    #expect(parameters.kind == "parameters")
    #expect(parameters.namedChildren.count == 2)
    #expect(body.kind == "block")
    #expect(body.namedChildren.count == 1)
}

@Test
func returnsTreeForInvalidPythonSource() throws {
    let parser = try #require(makePythonParser())
    let tree = try #require(parser.parse(Array("def broken(:".utf8)))

    #expect(tree.rootNode.hasError)
}

private func makeRustParser() -> Parser? {
    guard let language = tree_sitter_rust() else { return nil }
    return Parser(language: language)
}

private func makePythonParser() -> Parser? {
    guard let language = tree_sitter_python() else { return nil }
    return Parser(language: language)
}

@Test
func exposesFrozenTypeScriptAndTsxParsers() throws {
    let typescript = try #require(tree_sitter_typescript())
    let tsx = try #require(tree_sitter_tsx())

    let tsParser = ts_parser_new()
    let tsxParser = ts_parser_new()
    defer {
        ts_parser_delete(tsParser)
        ts_parser_delete(tsxParser)
    }
    #expect(ts_parser_set_language(tsParser, typescript))
    #expect(ts_parser_set_language(tsxParser, tsx))
    #expect([typescript, tsx].map { ts_language_version($0) } == [14, 14])
}

@Test
func findsTypeScriptFunctionNamedFields() throws {
    let source = """
        function add(a: number, b: number): number {
            return a + b
        }
        """

    let parser = try #require(makeTypeScriptParser())
    let tree = try #require(parser.parse(Array(source.utf8)))

    #expect(tree.rootNode.kind == "program")
    #expect(tree.rootNode.hasError == false)

    let declaration = try #require(tree.rootNode.namedChildren.first {
        $0.kind == "function_declaration"
    })
    let name = try #require(declaration.child(namedField: "name"))
    let body = try #require(declaration.child(namedField: "body"))

    #expect(name.kind == "identifier")
    #expect(text(of: name, in: source) == "add")
    #expect(body.kind == "statement_block")
}

@Test
func parsesTypeScriptJsxAndRejectsItWithTypeScriptGrammar() throws {
    let source = "export const view = <Component />;"

    let tsxParser = try #require(makeTsxParser())
    let tsxTree = try #require(tsxParser.parse(Array(source.utf8)))
    #expect(tsxTree.rootNode.kind == "program")
    #expect(tsxTree.rootNode.hasError == false)

    let tsParser = try #require(makeTypeScriptParser())
    let tsTree = try #require(tsParser.parse(Array(source.utf8)))
    #expect(tsTree.rootNode.hasError)
}

private func makeTypeScriptParser() -> Parser? {
    guard let language = tree_sitter_typescript() else { return nil }
    return Parser(language: language)
}

private func makeTsxParser() -> Parser? {
    guard let language = tree_sitter_tsx() else { return nil }
    return Parser(language: language)
}

private func text(of node: Node, in source: String) -> String {
    let range = node.byteRange
    return String(
        decoding: Array(source.utf8)[Int(range.lowerBound)..<Int(range.upperBound)],
        as: UTF8.self
    )
}
