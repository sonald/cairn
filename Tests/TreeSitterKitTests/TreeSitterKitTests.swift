import CTreeSitterRust
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

private func makeRustParser() -> Parser? {
    guard let language = tree_sitter_rust() else { return nil }
    return Parser(language: language)
}
