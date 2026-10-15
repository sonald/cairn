/// Source languages Cairn does not analyze but can color in a text preview,
/// the way Source Insight's language files do: a keyword list plus comment
/// and string delimiters. Nothing here drives navigation.
public enum CodeLanguage: String, CaseIterable, Hashable, Sendable {
    case c, cpp, objectiveC, csharp, java, kotlin, go, swift, php, perl
    case css, sql, pascal, visualBasic, ada, assembly

    public var displayName: String {
        switch self {
        case .c: "C"
        case .cpp: "C++"
        case .objectiveC: "Objective-C"
        case .csharp: "C#"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .go: "Go"
        case .swift: "Swift"
        case .php: "PHP"
        case .perl: "Perl"
        case .css: "CSS"
        case .sql: "SQL"
        case .pascal: "Pascal"
        case .visualBasic: "Visual Basic"
        case .ada: "Ada"
        case .assembly: "Assembly"
        }
    }

    /// `.h` is shared by C, C++ and Objective-C; the C++ keyword set covers C.
    static let byExtension: [String: CodeLanguage] = [
        "c": .c,
        "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "c++": .cpp, "h": .cpp, "hh": .cpp,
        "hpp": .cpp, "hxx": .cpp, "ipp": .cpp, "tpp": .cpp, "inl": .cpp,
        "m": .objectiveC, "mm": .objectiveC,
        "cs": .csharp, "java": .java, "kt": .kotlin, "kts": .kotlin,
        "go": .go, "swift": .swift, "php": .php, "pl": .perl, "pm": .perl,
        "css": .css, "scss": .css, "less": .css, "sql": .sql,
        "pas": .pascal, "dpr": .pascal, "lpr": .pascal,
        "vb": .visualBasic, "bas": .visualBasic, "vbs": .visualBasic,
        "adb": .ada, "ads": .ada, "ada": .ada,
        "asm": .assembly, "s": .assembly, "nasm": .assembly,
    ]

    static func fromLanguageHint(_ hint: String) -> CodeLanguage? {
        switch hint {
        case "c", "h": .c
        case "cpp", "c++", "cc", "cxx", "hpp": .cpp
        case "objc", "objective-c", "objectivec", "objc++", "objective-c++": .objectiveC
        case "cs", "csharp", "c#": .csharp
        case "java": .java
        case "kotlin", "kt": .kotlin
        case "go", "golang": .go
        case "swift": .swift
        case "php": .php
        case "perl", "pl": .perl
        case "css", "scss", "less": .css
        case "sql", "mysql", "postgresql", "plsql", "tsql": .sql
        case "pascal", "delphi", "pas": .pascal
        case "vb", "vbnet", "vbscript", "vba": .visualBasic
        case "ada": .ada
        case "asm", "nasm", "x86asm", "armasm", "assembly", "s": .assembly
        default: nil
        }
    }

    var syntax: CodeSyntax { Self.syntaxes[self]! }

    private static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double",
        "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long",
        "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct",
        "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "_Bool",
        "_Atomic", "_Static_assert", "_Thread_local", "bool", "true", "false", "NULL",
    ]
    private static let cppKeywords = cKeywords.union([
        "alignas", "alignof", "catch", "class", "concept", "consteval", "constexpr",
        "constinit", "const_cast", "co_await", "co_return", "co_yield", "decltype", "delete",
        "dynamic_cast", "explicit", "export", "final", "friend", "mutable", "namespace",
        "new", "noexcept", "nullptr", "operator", "override", "private", "protected",
        "public", "reinterpret_cast", "requires", "static_assert", "static_cast",
        "template", "this", "thread_local", "throw", "try", "typeid", "typename", "using",
        "virtual", "wchar_t", "char8_t", "char16_t", "char32_t",
    ])

    private static let syntaxes: [CodeLanguage: CodeSyntax] = [
        .c: CodeSyntax(keywords: cKeywords, preprocessor: true),
        .cpp: CodeSyntax(keywords: cppKeywords, preprocessor: true),
        .objectiveC: CodeSyntax(
            keywords: cppKeywords.union([
                "@interface", "@implementation", "@end", "@protocol", "@property",
                "@synthesize", "@dynamic", "@class", "@selector", "@encode", "@optional",
                "@required", "@try", "@catch", "@finally", "@throw", "@autoreleasepool",
                "@import", "@private", "@public", "@protected", "@package", "@available",
                "self", "super", "nil", "Nil", "YES", "NO", "id", "instancetype", "BOOL",
                "SEL", "IMP", "nonatomic", "atomic", "strong", "weak", "copy", "assign",
                "readonly", "readwrite", "nullable", "nonnull", "__block", "__weak",
            ]),
            preprocessor: true
        ),
        .csharp: CodeSyntax(
            keywords: [
                "abstract", "as", "async", "await", "base", "bool", "break", "byte", "case",
                "catch", "char", "checked", "class", "const", "continue", "decimal", "default",
                "delegate", "do", "double", "dynamic", "else", "enum", "event", "explicit",
                "extern", "false", "finally", "fixed", "float", "for", "foreach", "get", "goto",
                "if", "implicit", "in", "init", "int", "interface", "internal", "is", "lock",
                "long", "namespace", "new", "null", "object", "operator", "out", "override",
                "params", "partial", "private", "protected", "public", "readonly", "record",
                "ref", "required", "return", "sbyte", "sealed", "set", "short", "sizeof",
                "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true",
                "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort", "using",
                "value", "var", "virtual", "void", "volatile", "when", "where", "while",
                "yield",
            ],
            preprocessor: true,
            tripleQuotes: true
        ),
        .java: CodeSyntax(
            keywords: [
                "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
                "class", "const", "continue", "default", "do", "double", "else", "enum",
                "extends", "final", "finally", "float", "for", "goto", "if", "implements",
                "import", "instanceof", "int", "interface", "long", "native", "new", "package",
                "private", "protected", "public", "record", "return", "sealed", "permits",
                "short", "static", "strictfp", "super", "switch", "synchronized", "this",
                "throw", "throws", "transient", "try", "var", "void", "volatile", "while",
                "yield", "true", "false", "null",
            ],
            tripleQuotes: true
        ),
        .kotlin: CodeSyntax(
            keywords: [
                "abstract", "annotation", "as", "break", "by", "catch", "class", "companion",
                "const", "constructor", "continue", "crossinline", "data", "do", "else", "enum",
                "external", "false", "final", "finally", "for", "fun", "get", "if", "import",
                "in", "infix", "init", "inline", "inner", "interface", "internal", "is",
                "lateinit", "noinline", "null", "object", "open", "operator", "out", "override",
                "package", "private", "protected", "public", "reified", "return", "sealed",
                "set", "super", "suspend", "tailrec", "this", "throw", "true", "try",
                "typealias", "val", "value", "var", "vararg", "when", "where", "while",
            ],
            tripleQuotes: true
        ),
        .go: CodeSyntax(
            keywords: [
                "break", "case", "chan", "const", "continue", "default", "defer", "else",
                "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
                "package", "range", "return", "select", "struct", "switch", "type", "var",
                "true", "false", "nil", "iota", "bool", "byte", "rune", "string", "error",
                "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32",
                "uint64", "uintptr", "float32", "float64", "complex64", "complex128", "any",
            ],
            rawBackticks: true
        ),
        .swift: CodeSyntax(
            keywords: [
                "actor", "as", "associatedtype", "async", "await", "break", "case", "catch",
                "class", "continue", "convenience", "default", "defer", "deinit", "do",
                "dynamic", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
                "final", "for", "func", "get", "guard", "if", "import", "in", "indirect",
                "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil",
                "nonisolated", "open", "operator", "optional", "override", "package",
                "private", "protocol", "public", "repeat", "required", "rethrows", "return",
                "self", "Self", "set", "some", "any", "static", "struct", "subscript", "super",
                "switch", "throw", "throws", "true", "try", "typealias", "unowned", "var",
                "weak", "where", "while", "willSet", "didSet",
            ],
            preprocessor: true,
            tripleQuotes: true
        ),
        .php: CodeSyntax(
            keywords: [
                "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class",
                "clone", "const", "continue", "declare", "default", "do", "echo", "else",
                "elseif", "empty", "enddeclare", "endfor", "endforeach", "endif", "endswitch",
                "endwhile", "enum", "extends", "false", "final", "finally", "fn", "for",
                "foreach", "function", "global", "if", "implements", "include",
                "include_once", "instanceof", "insteadof", "interface", "isset", "list",
                "match", "namespace", "new", "null", "or", "print", "private", "protected",
                "public", "readonly", "require", "require_once", "return", "static", "switch",
                "throw", "trait", "true", "try", "unset", "use", "var", "while", "xor", "yield",
            ],
            lineComments: ["//", "#"],
            caseInsensitive: true
        ),
        .perl: CodeSyntax(
            keywords: [
                "my", "our", "local", "sub", "package", "use", "no", "require", "if", "elsif",
                "else", "unless", "while", "until", "for", "foreach", "do", "last", "next",
                "redo", "return", "and", "or", "not", "eq", "ne", "lt", "gt", "le", "ge", "cmp",
                "BEGIN", "END", "undef", "defined", "print", "die", "bless", "ref", "scalar",
            ],
            lineComments: ["#"],
            blockComments: []
        ),
        .css: CodeSyntax(keywords: ["!important"], lineComments: []),
        .sql: CodeSyntax(
            keywords: [
                "select", "from", "where", "and", "or", "not", "in", "is", "null", "like",
                "between", "exists", "insert", "into", "values", "update", "set", "delete",
                "create", "alter", "drop", "table", "view", "index", "primary", "foreign",
                "key", "references", "unique", "default", "constraint", "join", "inner",
                "left", "right", "outer", "full", "cross", "on", "using", "group", "by",
                "order", "having", "limit", "offset", "union", "all", "distinct", "as", "case",
                "when", "then", "else", "end", "begin", "commit", "rollback", "transaction",
                "declare", "procedure", "function", "returns", "return", "trigger", "if",
                "with", "asc", "desc", "true", "false", "int", "integer", "varchar", "char",
                "text", "date", "timestamp", "boolean", "numeric", "decimal", "float",
            ],
            lineComments: ["--"],
            backslashEscapes: false,
            caseInsensitive: true
        ),
        .pascal: CodeSyntax(
            keywords: [
                "and", "array", "as", "asm", "begin", "case", "class", "const", "constructor",
                "destructor", "div", "do", "downto", "else", "end", "except", "exports", "file",
                "finally", "for", "function", "goto", "if", "implementation", "in",
                "inherited", "initialization", "finalization", "inline", "interface", "is",
                "label", "library", "mod", "nil", "not", "object", "of", "or", "out", "packed",
                "procedure", "program", "property", "raise", "record", "repeat", "set", "shl",
                "shr", "string", "then", "to", "try", "type", "unit", "until", "uses", "var",
                "while", "with", "xor", "true", "false", "private", "protected", "public",
                "published", "override", "virtual", "abstract", "overload", "result", "self",
                "integer", "boolean", "char", "real", "double", "cardinal", "byte", "word",
            ],
            blockComments: [("{", "}"), ("(*", "*)")],
            quotes: [0x27],
            backslashEscapes: false,
            caseInsensitive: true
        ),
        .visualBasic: CodeSyntax(
            keywords: [
                "addhandler", "and", "andalso", "as", "boolean", "byref", "byte", "byval",
                "call", "case", "catch", "class", "const", "dim", "do", "double", "each",
                "else", "elseif", "end", "enum", "error", "event", "exit", "false", "finally",
                "for", "friend", "function", "get", "goto", "handles", "if", "implements",
                "imports", "in", "inherits", "integer", "interface", "is", "isnot", "let",
                "long", "loop", "me", "mod", "module", "mustinherit", "mustoverride",
                "mybase", "namespace", "new", "next", "not", "nothing", "object", "of", "on",
                "option", "optional", "or", "orelse", "overridable", "overrides",
                "paramarray", "private", "property", "protected", "public", "raiseevent",
                "readonly", "redim", "rem", "resume", "return", "select", "set", "shadows",
                "shared", "single", "static", "step", "stop", "string", "structure", "sub",
                "then", "throw", "to", "true", "try", "typeof", "until", "variant", "wend",
                "when", "while", "with", "withevents", "writeonly", "xor",
            ],
            lineComments: ["'"],
            blockComments: [],
            quotes: [0x22],
            backslashEscapes: false,
            caseInsensitive: true
        ),
        .ada: CodeSyntax(
            keywords: [
                "abort", "abs", "abstract", "accept", "access", "aliased", "all", "and",
                "array", "at", "begin", "body", "case", "constant", "declare", "delay",
                "delta", "digits", "do", "else", "elsif", "end", "entry", "exception", "exit",
                "for", "function", "generic", "goto", "if", "in", "interface", "is", "limited",
                "loop", "mod", "new", "not", "null", "of", "or", "others", "out",
                "overriding", "package", "pragma", "private", "procedure", "protected",
                "raise", "range", "record", "rem", "renames", "requeue", "return", "reverse",
                "select", "separate", "some", "subtype", "synchronized", "tagged", "task",
                "terminate", "then", "type", "until", "use", "when", "while", "with", "xor",
                "true", "false",
            ],
            lineComments: ["--"],
            blockComments: [],
            quotes: [0x22],
            backslashEscapes: false,
            caseInsensitive: true
        ),
        // ponytail: comments, strings and numbers only; mnemonics differ per
        // architecture, add a keyword list when a real assembly corpus needs one.
        .assembly: CodeSyntax(keywords: [], lineComments: [";", "//"]),
    ]
}

struct CodeSyntax {
    var keywords: Set<String>
    var lineComments: [String] = ["//"]
    var blockComments: [(open: String, close: String)] = [("/*", "*/")]
    /// Single-line string delimiters.
    var quotes: [UInt16] = [0x22, 0x27]
    var backslashEscapes = true
    /// Keywords compare lowercased (SQL, Pascal, Visual Basic, Ada, PHP).
    var caseInsensitive = false
    /// `#include`-style directives at line start.
    var preprocessor = false
    /// `"""` text blocks spanning lines (C#, Java, Kotlin, Swift).
    var tripleQuotes = false
    /// Go's backtick raw strings spanning lines.
    var rawBackticks = false
}

extension TextLexer {
    /// Comments, strings, numbers, keywords, directives, `@annotations` and
    /// call-shaped identifiers (`name(`).
    mutating func code(_ syntax: CodeSyntax) {
        let lineComments = syntax.lineComments.map { Array($0.utf16) }
        let blockComments = syntax.blockComments.map { (Array($0.open.utf16), Array($0.close.utf16)) }
        var i = 0
        var lineStart = true
        scan: while i < n {
            let c = s[i]
            if c == Self.newline { lineStart = true; i += 1; continue }
            if Self.isSpace(c) { i += 1; continue }
            let atLineStart = lineStart
            lineStart = false
            for marker in lineComments where has(marker, at: i) {
                let end = lineEnd(i)
                emit(i, end, .comment)
                i = end
                continue scan
            }
            for (open, close) in blockComments where has(open, at: i) {
                var end = i + open.count
                while end < n, !has(close, at: end) { end += 1 }
                end = min(n, end + close.count)
                emit(i, end, .comment)
                i = end
                continue scan
            }
            if syntax.preprocessor, atLineStart, c == 0x23 {
                var end = skipSpaces(i + 1, n)
                while end < n, Self.isWord(s[end]) { end += 1 }
                emit(i, end, .macro)
                i = end
                continue
            }
            if syntax.tripleQuotes, c == 0x22, char(i + 1) == 0x22, char(i + 2) == 0x22 {
                var end = i + 3
                while end < n, !(s[end] == 0x22 && char(end + 1) == 0x22 && char(end + 2) == 0x22) {
                    end += s[end] == 0x5C ? 2 : 1
                }
                end = min(n, end + 3)
                emit(i, end, .string)
                i = end
                continue
            }
            if syntax.rawBackticks, c == 0x60 {
                var end = i + 1
                while end < n, s[end] != 0x60 { end += 1 }
                end = min(n, end + 1)
                emit(i, end, .string)
                i = end
                continue
            }
            if syntax.quotes.contains(c) {
                let end = quoted(i, limit: lineEnd(i), escapes: syntax.backslashEscapes)
                emit(i, end, .string)
                i = end
                continue
            }
            if Self.isDigit(c) || (c == 0x2E && Self.isDigit(char(i + 1))) {
                var end = i + 1
                while end < n {
                    let k = s[end]
                    if Self.isWord(k) || k == 0x2E || k == 0x27 && Self.isDigit(char(end + 1)) {
                        end += 1
                    } else if (k == 0x2B || k == 0x2D), (s[end - 1] | 0x20) == 0x65 {
                        end += 1
                    } else {
                        break
                    }
                }
                emit(i, end, .number)
                i = end
                continue
            }
            // `$name` (PHP, Perl), `@name` (annotations, Objective-C), `!important`.
            let sigil = c == 0x24 || c == 0x40 || c == 0x21
            if Self.isAlpha(c) || c == 0x5F || (sigil && Self.isAlpha(char(i + 1))) {
                var end = i + 1
                while end < n, Self.isWord(s[end]) { end += 1 }
                var text = word(i, end)
                if syntax.caseInsensitive { text = text.lowercased() }
                if syntax.keywords.contains(text) {
                    emit(i, end, .keyword)
                } else if c == 0x40 {
                    emit(i, end, .attribute)
                } else if c != 0x24, c != 0x21, char(end) == 0x28 {
                    emit(i, end, .functionCall)
                }
                i = end
                continue
            }
            i += 1
        }
    }

    private func has(_ marker: [UInt16], at i: Int) -> Bool {
        guard i + marker.count <= n else { return false }
        for (offset, unit) in marker.enumerated() where s[i + offset] != unit { return false }
        return true
    }
}
