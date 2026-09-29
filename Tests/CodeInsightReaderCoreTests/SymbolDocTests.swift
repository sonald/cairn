import CodeInsightCore
import Testing
import CodeInsightRustExtractor
@testable import CodeInsightReaderCore

@Test
func syntacticDocStripsLineDocMarkersAndKeepsMarkdown() {
    let doc = rustDoc("""
    /// Opens the snapshot rooted at `oid`.
    ///
    /// # Errors
    ///   Returns an error when the object is absent.
    pub fn open(repo: &Repository, oid: Oid) -> Result<Self, GitError> {
        todo!()
    }
    """, declaration: "pub fn open")

    #expect(doc.source == .syntactic)
    #expect(doc.signatureLanguage == "rust")
    #expect(doc.signature == "pub fn open(repo: &Repository, oid: Oid) -> Result<Self, GitError>")
    #expect(doc.markdown == """
    Opens the snapshot rooted at `oid`.

    # Errors
      Returns an error when the object is absent.
    """)
}

@Test
func syntacticDocReadsBlockDocsAndDocAttributesAcrossAttributes() {
    let block = rustDoc("""
    /**
     * A Git object id.
     *
     * Parsed from hex.
     */
    #[derive(Clone, Copy)]
    pub struct Oid([u8; 20]);
    """, declaration: "pub struct Oid")
    #expect(block.markdown == "A Git object id.\n\nParsed from hex.")
    #expect(block.signature == "pub struct Oid([u8; 20])")

    let attribute = rustDoc("""
    #[doc = "Maximum eager entries.\\nLarger trees walk lazily."]
    #[allow(dead_code)]
    const EAGER_LIMIT: usize = 4_096;
    """, declaration: "const EAGER_LIMIT")
    #expect(attribute.markdown == "Maximum eager entries.\nLarger trees walk lazily.")
    #expect(attribute.signature == "const EAGER_LIMIT: usize = 4_096")
}

@Test
func syntacticDocIgnoresOrdinaryCommentsBlankGapsAndInnerDocs() {
    for prefix in [
        "// ordinary comment\n",
        "/// detached doc\n\n",
        "//! crate docs\n",
        "/* block comment */\n",
        "//// banner\n",
    ] {
        let doc = rustDoc("\(prefix)fn plain() {}", declaration: "fn plain")
        #expect(doc.markdown.isEmpty, "prefix: \(prefix)")
        #expect(doc.signature == "fn plain()")
    }
}

@Test
func syntacticSignatureKeepsWhereClausesAndDedentsNestedItems() {
    let doc = rustDoc("""
    impl Walker {
        /// Visits every entry.
        pub fn visit<F>(
            &self,
            f: F,
        ) -> Result<(), Error>
        where
            F: Fn(&Entry) -> bool,
        {
            todo!()
        }
    }
    """, declaration: "pub fn visit")

    #expect(doc.markdown == "Visits every entry.")
    #expect(doc.signature == """
    pub fn visit<F>(
        &self,
        f: F,
    ) -> Result<(), Error>
    where
        F: Fn(&Entry) -> bool,
    """)
}

@Test
func syntacticSignatureInlinesShortAggregateBodiesOnly() {
    let short = rustDoc("""
    pub struct Snapshot {
        /// Root tree.
        root: Oid,
        files: HashMap<PathBuf, ContentId>,
    }
    """, declaration: "pub struct Snapshot")
    #expect(short.signature == """
    pub struct Snapshot {
        root: Oid,
        files: HashMap<PathBuf, ContentId>,
    }
    """)

    let fields = (1...20).map { "    f\($0): u8," }.joined(separator: "\n")
    let long = rustDoc("pub enum Wide {\n\(fields)\n}", declaration: "pub enum Wide")
    #expect(long.signature == "pub enum Wide { … }")

    let trait = rustDoc("pub trait Store {\n    fn get(&self);\n}", declaration: "pub trait Store")
    #expect(trait.signature == "pub trait Store")
}

@Test
func syntacticDocFallsBackToFirstLineForJavaScript() {
    let source = "export function execute(steps) {\n    return steps;\n}"
    let bytes = Array(source.utf8)
    let document = ReaderDocument(
        bytes: bytes,
        languageMode: LanguageMode(language: .javascript),
        highlightSpans: [],
        outlineFacets: []
    )
    let doc = syntacticSymbolDoc(
        forDeclarationAt: ByteRange(lowerBound: 0, upperBound: UInt32(bytes.count)),
        in: document,
        location: "run.js:1"
    )
    #expect(doc.signature == "export function execute(steps)")
    #expect(doc.signatureLanguage == "javascript")
    #expect(doc.location == "run.js:1")
    #expect(doc.markdown.isEmpty)
}

@Test
func pythonSyntacticDocSkipsDecoratorsAndReadsDocstrings() {
    let doc = pythonDoc("""
    @app.route("/view")
    @cache(timeout=30)
    def view(user: str = "nobody") -> str:
        \"\"\"Render the user's page.

        Longer detail with `code`.
        \"\"\"
        return user
    """, declaration: "def view")

    #expect(doc.source == .syntactic)
    #expect(doc.signatureLanguage == "python")
    #expect(doc.signature == #"def view(user: str = "nobody") -> str"#)
    #expect(doc.markdown == """
    Render the user's page.

    Longer detail with `code`.
    """)
}

@Test
func pythonSyntacticDocDedentsMultiLineHeadersAndQuoteVariants() {
    let multiline = pythonDoc("""
    class Repo:
        def process(
            items: list[int],
            separator: str = ", ",
        ) -> dict[str, int]:
            \"\"\"Map items to counts.\"\"\"
            return {}
    """, declaration: "def process")
    #expect(multiline.signature == """
    def process(
        items: list[int],
        separator: str = ", ",
    ) -> dict[str, int]
    """)
    #expect(multiline.markdown == "Map items to counts.")

    let lambdaDefault = pythonDoc(
        #"def apply(g=lambda x: x): '#'"# + "\n    \"\"\"Apply g.\"\"\"\n    return g\n",
        declaration: "def apply"
    )
    #expect(lambdaDefault.signature == "def apply(g=lambda x: x)")
    // A single-quoted expression after the header is not a docstring.
    #expect(lambdaDefault.markdown.isEmpty)

    let singleQuotedDoc = pythonDoc("""
    def teardown():
        '''Tears down.'''
        pass
    """, declaration: "def teardown")
    #expect(singleQuotedDoc.markdown == "Tears down.")

    let escapedQuote = pythonDoc(
        "def note():\n    \"\"\"Contains \\\"\"\" inside.\"\"\"\n",
        declaration: "def note"
    )
    #expect(escapedQuote.markdown == #"Contains """ inside."#)
}

@Test
func pythonSyntacticDocIgnoresBodiesWithoutLeadingDocstrings() {
    for body in [
        "    count = x + 1\n    return count\n",
        "    'single quoted is not read'\n    return x\n",
        "    # a comment\n    \"\"\"not the first statement\"\"\"\n",
    ] {
        let doc = pythonDoc(
            "def plain(x):\n\(body)",
            declaration: "def plain"
        )
        #expect(doc.markdown.isEmpty, "body: \(body)")
        #expect(doc.signature == "def plain(x)")
    }

    let classDoc = pythonDoc("""
    class Service:
        \"\"\"A service.\"\"\"
        def run(self):
            \"\"\"Run once.\"\"\"
    """, declaration: "class Service")
    #expect(classDoc.signature == "class Service")
    #expect(classDoc.markdown == "A service.")
}

@Test
func typeScriptSyntacticDocReadsJSDocSignaturesAndAggregates() {
    let function = typeScriptDoc("""
    /**
     * Fetches a user.
     *
     * @param id - the user id
     */
    export function fetchUser(
        id: number,
        options: Options = { retries: 1 },
    ): Promise<User> {
        return null;
    }
    """, declaration: "export function fetchUser")
    #expect(function.source == .syntactic)
    #expect(function.signatureLanguage == "typescript")
    #expect(function.signature == """
    export function fetchUser(
        id: number,
        options: Options = { retries: 1 },
    ): Promise<User>
    """)
    #expect(function.markdown == """
    Fetches a user.

    @param id - the user id
    """)

    let arrow = typeScriptDoc(
        "export const parse = (input: string): Result => {\n    return ok(input);\n};\n",
        declaration: "export const parse"
    )
    #expect(arrow.signature == "export const parse = (input: string): Result")

    let alias = typeScriptDoc(
        "export type Options = {\n    retries: number;\n};\n",
        declaration: "export type Options"
    )
    #expect(alias.signature == "export type Options")

    let aggregate = typeScriptDoc("""
    export interface Point<T extends object = {}> {
        x: number;
        y: number;
    }
    """, declaration: "export interface Point")
    #expect(aggregate.signature == """
    export interface Point<T extends object = {}> {
        x: number;
        y: number;
    }
    """)

    let plain = typeScriptDoc(
        "// ordinary comment\nfunction boot() {}\n",
        declaration: "function boot"
    )
    #expect(plain.markdown.isEmpty)
    #expect(plain.signature == "function boot()")
}

@Test
func typeScriptSyntacticDocKeepsDecoratorsBetweenJSDocAndDeclaration() {
    let doc = typeScriptDoc("""
    /**
     * A component.
     */
    @Component({ selector: "demo" })
    export class Demo {
        title = "hi";
    }
    """, declaration: "export class Demo")
    #expect(doc.markdown == "A component.")
    #expect(doc.signature == """
    export class Demo {
        title = "hi";
    }
    """)
}

@Test
func typeScriptDocLinksJSDocReferencesOutsideCodeFences() {
    let doc = typeScriptDoc("""
    /**
     * See {@link Store} and {@link Store#query the query method}.
     *
     * ```
     * const s = "{@link NotALink}";
     * ```
     */
    function boot() {}
    """, declaration: "function boot")
    #expect(doc.markdown == """
    See [Store](cairn-symbol:Store) and \
    [the query method](cairn-symbol:Store#query).

    ```
    const s = "{@link NotALink}";
    ```
    """)
}

private func pythonDoc(_ source: String, declaration: String) -> SymbolDoc {
    syntacticDoc(source, language: .python, declaration: declaration)
}

private func typeScriptDoc(_ source: String, declaration: String) -> SymbolDoc {
    syntacticDoc(source, language: .typescript, declaration: declaration)
}

private func syntacticDoc(
    _ source: String,
    language: LanguageID,
    declaration: String
) -> SymbolDoc {
    let bytes = Array(source.utf8)
    let start = UInt32(source[..<source.range(of: declaration)!.lowerBound].utf8.count)
    let document = ReaderDocument(
        bytes: bytes,
        languageMode: LanguageMode(language: language),
        highlightSpans: [],
        outlineFacets: []
    )
    return syntacticSymbolDoc(
        forDeclarationAt: ByteRange(lowerBound: start, upperBound: UInt32(bytes.count)),
        in: document
    )
}

private func rustDoc(_ source: String, declaration: String) -> SymbolDoc {
    let bytes = Array(source.utf8)
    let start = UInt32(source[..<source.range(of: declaration)!.lowerBound].utf8.count)
    let document = ReaderDocument(bytes: bytes, highlightSpans: [], outlineFacets: [])
    return syntacticSymbolDoc(
        forDeclarationAt: ByteRange(lowerBound: start, upperBound: UInt32(bytes.count)),
        in: document
    )
}

@Test
func syntacticDocLinksIntraDocReferencesOutsideCodeFences() {
    let doc = rustDoc("""
    /// Same [`Oid`] as [Snapshot::open()], see [docs](https://example.com) and [`fmt!`].
    ///
    /// ```
    /// let x = [`NotALink`];
    /// ```
    fn plain() {}
    """, declaration: "fn plain")

    #expect(doc.markdown == """
    Same [`Oid`](cairn-symbol:Oid) as [Snapshot::open()](cairn-symbol:Snapshot::open), \
    see [docs](https://example.com) and [`fmt!`](cairn-symbol:fmt).

    ```
    let x = [`NotALink`];
    ```
    """)
}

@Test
func hoverIdentifierRangeSkipsKeywordsLiteralsCommentsAndPunctuation() throws {
    let source = "pub fn open(oid: Oid) -> u8 { let n = 42; \"text\" } // Oid note"
    let bytes = Array(source.utf8)
    let highlighted = try RustHighlighter().highlight(bytes: bytes)
    let document = ReaderDocument(
        bytes: bytes,
        highlightSpans: highlighted.spans,
        outlineFacets: highlighted.outlineFacets
    )
    func range(at needle: String, occurrence: Int = 0, shift: Int = 1) -> String? {
        var searchStart = source.startIndex
        var found = source.range(of: needle)!
        for _ in 0..<occurrence {
            searchStart = found.upperBound
            found = source.range(of: needle, range: searchStart..<source.endIndex)!
        }
        let offset = UInt32(source[..<found.lowerBound].utf8.count + shift)
        return hoverIdentifierRange(at: offset, in: document).map {
            String(decoding: bytes[Int($0.lowerBound)..<Int($0.upperBound)], as: UTF8.self)
        }
    }

    #expect(range(at: "open") == "open")
    #expect(range(at: "Oid") == "Oid")
    #expect(range(at: "oid") == "oid")
    #expect(range(at: "pub") == nil)
    #expect(range(at: "fn ") == nil)
    #expect(range(at: "42") == nil)
    #expect(range(at: "text") == nil)
    #expect(range(at: "Oid", occurrence: 1) == nil)
    #expect(range(at: "(", shift: 0) == nil)
    #expect(range(at: " {", shift: 0) == nil)
}

@Test
func rustPathRootReadsTheFirstSegmentOfAQualifiedPath() {
    let source = "let a = ureq::agent::get(url); let b = crate::oid::Oid; let c = plain;"
    let bytes = Array(source.utf8)
    let document = ReaderDocument(bytes: bytes, highlightSpans: [], outlineFacets: [])
    func root(_ name: String) -> String? {
        let lower = UInt32(source[..<source.range(of: name)!.lowerBound].utf8.count)
        return rustPathRoot(
            endingAt: ByteRange(lowerBound: lower, upperBound: lower + UInt32(name.utf8.count)),
            in: document
        )
    }
    #expect(root("get") == "ureq")
    #expect(root("Oid") == "crate")
    #expect(root("plain") == nil)
    #expect(root("ureq") == nil)
}

@Test
func syntacticDocHidesRustdocSetupLinesOnlyInRustExamples() {
    let doc = rustDoc("""
    /// ```
    /// # use demo::Oid;
    /// let id = Oid::default();
    /// #
    /// ## not hidden
    /// ```
    ///
    /// ```text
    /// # kept in text
    /// ```
    fn plain() {}
    """, declaration: "fn plain")

    #expect(doc.markdown == """
    ```
    let id = Oid::default();
    # not hidden
    ```

    ```text
    # kept in text
    ```
    """)
}
