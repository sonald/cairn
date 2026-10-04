import CodeInsightCore
import Foundation
import Testing
@testable import CodeInsightReaderCore

private func load(_ source: String, _ mode: LanguageMode, name: String) throws -> ReaderDocument {
    try DocumentLoader(source: { _ in Array(source.utf8) })
        .load(file: URL(fileURLWithPath: "/" + name), languageMode: mode).document
}

private func body(_ lines: Int, indent: String = "        ") -> String {
    (0..<lines).map { "\(indent)let v\($0) = \($0);\n" }.joined()
}

@Test
func blockEndAnnotationsNameLongRustBlocksAndSkipShortOrContinuedOnes() throws {
    let source = """
        impl Semaphore {
            pub fn release(&self, added: usize) {
                match added {
                    0 => {}
                    _ => {
        \(body(12, indent: "                "))\
                    }
                }
                if added > 1 {
        \(body(12))\
                } else {
                    return;
                }
                {
        \(body(12))\
                }
            }

            fn short() {
                let x = 1;
            }
        }

        """
    let document = try load(source, .init(language: .rust), name: "lib.rs")
    let labels = BlockEndAnnotations.compute(for: document).map(\.label)
    #expect(labels.contains("match added"))
    #expect(labels.contains("fn release"))
    #expect(labels.contains("impl Semaphore"))
    #expect(!labels.contains { $0.hasPrefix("fn short") }, "short blocks stay unlabeled")
    #expect(!labels.contains { $0.hasPrefix("if added") }, "`} else {` opens the next block")
    #expect(!labels.contains(""), "bare blocks have no header")
    for annotation in BlockEndAnnotations.compute(for: document) {
        #expect(document.bytes[Int(annotation.closingBrace)] == UInt8(ascii: "}"))
        #expect(annotation.headerOffset < annotation.closingBrace)
    }
}

@Test
func blockEndAnnotationsLabelTypeScriptMethodsAndIgnorePython() throws {
    let typescript = """
        export class ConnectionPool<T> {
          async acquire(): Promise<T> {
            try {
        \(body(12, indent: "      "))\
            } catch (err) {
              throw err;
            }
          }
        \(body(4, indent: "  "))\
        }

        """
    let document = try load(typescript, .init(language: .typescript), name: "pool.ts")
    let labels = BlockEndAnnotations.compute(for: document).map(\.label)
    #expect(labels.contains("acquire()"))
    #expect(labels.contains("class ConnectionPool<T>"))
    #expect(!labels.contains { $0.hasPrefix("try") }, "`} catch (err) {` continues the statement")

    let python = "def f():\n" + (0..<20).map { "    v\($0) = \($0)\n" }.joined()
    #expect(BlockEndAnnotations.compute(for: try load(python, .init(language: .python), name: "f.py")).isEmpty)
}

@Test
func blockEndLabelsStayWithinTheLengthLimitForAnyHeader() {
    let headers = [
        "fn " + String(repeating: "长名字", count: 30) + "(x: i32)",
        "if " + String(repeating: "🚀", count: 60),
        "match state.permits.checked_sub(needed) /* \(String(repeating: "é", count: 50)) */",
        "pub(crate) struct Wide" + String(repeating: "_", count: 80),
        "",
    ]
    for header in headers {
        for language in [LanguageID.rust, .typescript] {
            let label = BlockEndAnnotations.label(forHeader: header, language: language)
            #expect((label?.count ?? 0) <= BlockEndAnnotations.maximumLabelLength)
            #expect(header.isEmpty == (label == nil))
        }
    }
    #expect(BlockEndAnnotations.normalizedHeader("#[inline]\n  pub fn  go(\n    a: u8,\n  )") == "pub fn go( a: u8, )")
}
