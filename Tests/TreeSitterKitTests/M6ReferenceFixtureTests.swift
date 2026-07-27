import CTreeSitterRust
import Foundation
import Testing
import TreeSitterKit

@Test
func m6ReferenceFixtureHasRequiredResolvedLocalDensity() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixture = repositoryRoot.appendingPathComponent(
        "Tests/Fixtures/m6_reference_density.rust"
    )
    let bytes = [UInt8](try Data(contentsOf: fixture))
    let parser = try #require(m6RustParser())
    let startedAt = ContinuousClock.now
    let tree = try #require(parser.parse(bytes))
    let parseMS = milliseconds(from: startedAt, to: .now)

    #expect(tree.rootNode.hasError == false)
    #expect(bytes.lazy.filter { $0 == 0x0A }.count == 100_000)

    let functions = tree.rootNode.namedChildren.filter {
        $0.kind == "function_item"
    }
    var bindingCount = 0
    var referenceCount = 0

    for function in functions {
        let nodes = function.depthFirst()
        let functionName = try #require(function.namedChildren.first {
            $0.kind == "identifier"
        })
        let parameters = nodes.filter { $0.kind == "parameter" }
        let lets = nodes.filter { $0.kind == "let_declaration" }
        #expect(parameters.count == 2)
        #expect(lets.count == 18)

        let declarations = try (parameters + lets).map { declaration in
            try #require(declaration.namedChildren.first {
                $0.kind == "identifier"
            })
        }
        bindingCount += declarations.count

        for identifier in nodes where identifier.kind == "identifier" {
            if identifier.byteRange == functionName.byteRange
                || declarations.contains(where: {
                    $0.byteRange == identifier.byteRange
                })
            {
                continue
            }
            let name = fixtureText(identifier, in: bytes)
            #expect(declarations.contains {
                $0.byteRange.lowerBound < identifier.byteRange.lowerBound
                    && fixtureText($0, in: bytes) == name
            })
            referenceCount += 1
        }
    }

    #expect(functions.count == 1_000)
    #expect(bindingCount == 20_000)
    #expect(referenceCount == 35_000)
    print(String(
        format: "M6_REFERENCE_FIXTURE parseMS=%.3f bindings=%d references=%d",
        parseMS,
        bindingCount,
        referenceCount
    ))
}

private func m6RustParser() -> Parser? {
    guard let language = tree_sitter_rust() else { return nil }
    return Parser(language: language)
}

private func fixtureText(_ node: Node, in bytes: [UInt8]) -> String {
    let range = node.byteRange
    return String(
        decoding: bytes[Int(range.lowerBound)..<Int(range.upperBound)],
        as: UTF8.self
    )
}

private func milliseconds(
    from start: ContinuousClock.Instant,
    to end: ContinuousClock.Instant
) -> Double {
    let duration = start.duration(to: end)
    return Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}
