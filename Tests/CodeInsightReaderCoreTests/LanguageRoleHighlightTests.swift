import CodeInsightCore
import Foundation
import Testing
@testable import CodeInsightReaderCore

@Test
func pythonReaderRolesPreserveCallsPropertiesBindingsAndAtomicStrings() throws {
    let source = #"""
        @trace(level="info")
        class Store:
            count: int = 0

            @tools.logged
            def read(self, value: str = "seed") -> str:
                local = value
                self.count = len(local)
                return self.normalize(local)

            def literal(self):
                return f"{self.count if True else 0}"
        """#
    let result = try pythonReaderHighlightWithFolds(bytes: Array(source.utf8))

    #expect(role("trace", within: "@trace", source: source, spans: result.spans) == .attribute)
    #expect(role("logged", within: "@tools.logged", source: source, spans: result.spans) == .attribute)
    #expect(role("read", within: "def read", source: source, spans: result.spans) == .functionName)
    #expect(role("len", within: "len(local)", source: source, spans: result.spans) == .functionCall)
    #expect(role("normalize", within: "self.normalize", source: source, spans: result.spans) == .functionCall)
    #expect(role("count", within: "count: int", source: source, spans: result.spans) == .property)
    #expect(role("count", within: "self.count =", source: source, spans: result.spans) == .property)
    #expect(role("value", within: "value: str", source: source, spans: result.spans) == .parameter)
    #expect(role("value", within: "local = value", source: source, spans: result.spans) == .parameter)
    #expect(role("local", within: "local = value", source: source, spans: result.spans) == .localBinding)
    #expect(role("local", within: "len(local)", source: source, spans: result.spans) == .localBinding)
    #expect(role("str", within: "-> str", source: source, spans: result.spans) == .typeName)

    let field = try #require(result.outlineFacets.first { $0.kind == .field })
    #expect(field.name == "count")
    #expect(field.depth == 1)
    #expect(field.detail == ": int")
    let method = try #require(result.outlineFacets.first { $0.name == "read" })
    #expect(method.detail == #"(self, value: str = "seed") -> str"#)
    expectDisjointSpans(result.spans, source: source)
}

@Test
func typeScriptReaderRolesIncludeEnumFieldsAndSignatures() throws {
    let source = #"""
        @sealed
        class Store {
            count: number = 0;
            @logged("read")
            read(value: string): string {
                const local = value;
                this.count = size(local);
                return this.normalize(local);
            }
        }
        enum Phase {
            Idle,
            Ready = 2
        }
        const describe = (phase: Phase): string => {
            const text = `${phase ? "a" : "b"}`;
            return render(phase);
        };
        """#
    let result = try typeScriptReaderHighlightWithFolds(
        bytes: Array(source.utf8), mode: LanguageMode(language: .typescript)
    )

    #expect(role("sealed", within: "@sealed", source: source, spans: result.spans) == .attribute)
    #expect(role("logged", within: "@logged", source: source, spans: result.spans) == .attribute)
    #expect(role("read", within: "read(value", source: source, spans: result.spans) == .functionName)
    #expect(role("size", within: "size(local)", source: source, spans: result.spans) == .functionCall)
    #expect(role("normalize", within: "this.normalize", source: source, spans: result.spans) == .functionCall)
    #expect(role("count", within: "count: number", source: source, spans: result.spans) == .property)
    #expect(role("count", within: "this.count", source: source, spans: result.spans) == .property)
    #expect(role("value", within: "value: string", source: source, spans: result.spans) == .parameter)
    #expect(role("value", within: "local = value", source: source, spans: result.spans) == .parameter)
    #expect(role("local", within: "local = value", source: source, spans: result.spans) == .localBinding)
    #expect(role("local", within: "size(local)", source: source, spans: result.spans) == .localBinding)
    #expect(role("Idle", within: "Idle,", source: source, spans: result.spans) == .enumMember)
    #expect(role("Ready", within: "Ready =", source: source, spans: result.spans) == .enumMember)

    #expect(result.outlineFacets.map(\.kind) == [.class, .field, .method, .enum, .enumMember, .enumMember, .fn])
    #expect(result.outlineFacets.map(\.depth) == [0, 1, 1, 0, 1, 1, 0])
    #expect(result.outlineFacets.first { $0.name == "count" }?.detail == ": number")
    #expect(result.outlineFacets.first { $0.name == "read" }?.detail == "(value: string): string")
    #expect(result.outlineFacets.first { $0.name == "describe" }?.detail == "(phase: Phase): string")
    expectDisjointSpans(result.spans, source: source)
}

@Test
func typeScriptTemplateSubstitutionsKeepNestedStructureAndDisjointRoles() throws {
    let source = #"""
        function render(value: string) {
            const text = `prefix ${(() => {
                function nested() {
                    return `inner ${value.trim()}`;
                }
                class Box {
                    read() {
                        return nested();
                    }
                }
                return new Box().read();
            })()} suffix`;
            return text;
        }
        """#
    let result = try typeScriptReaderHighlightWithFolds(
        bytes: Array(source.utf8), mode: LanguageMode(language: .typescript)
    )
    #expect(result.outlineFacets.map(\.name) == ["render", "nested", "Box", "read"])
    #expect(role("nested", within: "function nested", source: source, spans: result.spans) == .functionName)
    #expect(role("nested", within: "return nested()", source: source, spans: result.spans) == .functionCall)
    #expect(role("trim", within: "value.trim()", source: source, spans: result.spans) == .functionCall)
    #expect(role("value", within: "value.trim()", source: source, spans: result.spans) == .parameter)
    for name in ["nested", "Box", "read"] {
        let facet = try #require(result.outlineFacets.first { $0.name == name })
        #expect(result.folds.contains {
            $0.headerRange.lowerBound == facet.range.lowerBound
                && $0.bodyRange.upperBound <= facet.range.upperBound
        })
    }
    #expect(result.spans.contains {
        $0.kind == .string && String(bytes: Array(source.utf8)[
            Int($0.range.lowerBound)..<Int($0.range.upperBound)
        ], encoding: .utf8)?.contains("prefix") == true
    })
    expectDisjointSpans(result.spans, source: source)
}

@Test
func typeScriptReaderCallsRemainDistinctFromShadowedBindingsInTsx() throws {
    let source = """
        function render(value: string) {
            const local = value;
            { const local = value; consume(local); }
            return <Box title={local} onClick={() => consume(value)} />;
        }
        """
    let result = try typeScriptReaderHighlightWithFolds(
        bytes: Array(source.utf8),
        mode: LanguageMode(language: .typescript, variant: "tsx")
    )
    #expect(role("consume", within: "consume(local)", source: source, spans: result.spans) == .functionCall)
    #expect(role("consume", within: "consume(value)", source: source, spans: result.spans) == .functionCall)
    #expect(role("local", within: "title={local}", source: source, spans: result.spans) == .localBinding)
    #expect(role("value", within: "consume(value)", source: source, spans: result.spans) == .parameter)
    #expect(result.bindings.filter { $0.kind == .letBinding }.count == 2)
    expectDisjointSpans(result.spans, source: source)
}

private func role(
    _ token: String,
    within fragment: String,
    source: String,
    spans: [HighlightSpan]
) -> HighlightKind? {
    guard let fragmentRange = source.range(of: fragment),
          let tokenRange = source.range(of: token, range: fragmentRange)
    else {
        Issue.record("Missing source token \(token) in \(fragment)")
        return nil
    }
    let range = ByteRange(
        lowerBound: UInt32(source[..<tokenRange.lowerBound].utf8.count),
        upperBound: UInt32(source[..<tokenRange.upperBound].utf8.count)
    )
    return spans.first { $0.range == range }?.kind
}

private func expectDisjointSpans(_ spans: [HighlightSpan], source: String) {
    for span in spans {
        #expect(span.range.lowerBound < span.range.upperBound)
        #expect(span.range.upperBound <= UInt32(source.utf8.count))
    }
    for (left, right) in zip(spans, spans.dropFirst()) {
        #expect(left.range.upperBound <= right.range.lowerBound)
    }
}
