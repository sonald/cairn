import CodeInsightReaderCore
import Testing

private func tokens(_ format: TextFormat, _ text: String) -> [String] {
    let units = Array(text.utf16)
    return format.highlight(text).map { span in
        let slice = String(utf16CodeUnits: Array(units[span.range]), count: span.range.count)
        return "\(span.kind):\(slice)"
    }
}

private func kind(_ format: TextFormat, _ text: String, of fragment: String) -> HighlightKind? {
    let units = Array(text.utf16)
    return format.highlight(text).first { span in
        String(utf16CodeUnits: Array(units[span.range]), count: span.range.count) == fragment
    }?.kind
}

@Test
func textFormatDetectsConfigTemplateAndScriptFiles() {
    #expect(TextFormat.detect(fileName: "pyproject.toml") == .toml)
    #expect(TextFormat.detect(fileName: "Cargo.lock") == .toml)
    #expect(TextFormat.detect(fileName: "ci.yml") == .yaml)
    #expect(TextFormat.detect(fileName: "tsconfig.json") == .json)
    #expect(TextFormat.detect(fileName: ".env.local") == .ini)
    #expect(TextFormat.detect(fileName: "setup.cfg") == .ini)
    #expect(TextFormat.detect(fileName: "ci.sh") == .shell)
    #expect(TextFormat.detect(fileName: "run", firstLine: "#!/usr/bin/env bash") == .shell)
    #expect(TextFormat.detect(fileName: "run", firstLine: "#!/usr/bin/env python3") == nil)
    #expect(TextFormat.detect(fileName: "Dockerfile.dev") == .dockerfile)
    #expect(TextFormat.detect(fileName: "Makefile") == .makefile)
    #expect(TextFormat.detect(fileName: "fix.patch") == .diff)
    #expect(TextFormat.detect(fileName: "system_prompt.jinja2") == .jinja(host: nil))
    #expect(TextFormat.detect(fileName: "values.yaml.j2") == .jinja(host: .yaml))
    #expect(TextFormat.detect(fileName: "page.html.j2") == .jinja(host: nil))
    #expect(TextFormat.detect(fileName: "notes.txt") == nil)
    #expect(TextFormat.detect(fileName: "README.md") == nil)
}

@Test
func tomlHighlightsTablesKeysInlineTablesAndValues() {
    let text = """
    [project]
    name = "jaz-lang" # package
    authors = [
        { name = "Zhening Li", email = "z@x.edu" },
    ]
    "quoted.key".bare = 0x1F
    released = 1979-05-27 07:32:00
    debug = true
    body = \"\"\"
    multi = "not a key"
    \"\"\"
    [[bin]]
    """
    let result = tokens(.toml, text)
    #expect(result.contains("declarationTitle:[project]"))
    #expect(result.contains("declarationTitle:[[bin]]"))
    #expect(result.contains("property:name"))
    #expect(result.contains("string:\"jaz-lang\""))
    #expect(result.contains("comment:# package"))
    #expect(result.contains("property:email"))
    #expect(result.contains("string:\"Zhening Li\""))
    #expect(result.contains("property:\"quoted.key\".bare"))
    #expect(result.contains("number:0x1F"))
    #expect(result.contains("number:1979-05-27 07:32:00"))
    #expect(result.contains("keyword:true"))
    #expect(result.contains("string:\"\"\"\nmulti = \"not a key\"\n\"\"\""))
    #expect(!result.contains("property:multi"))
}

@Test
func yamlHighlightsKeysScalarsBlockScalarsAndAnchors() {
    let text = """
    ---
    name: CI # workflow
    on:
      push:
        branches: [main, "release/*"]
    defaults: &defaults
      retries: 3
      enabled: yes
      url: http://example.com:80/a
    jobs:
      - <<: *defaults
        run: |
          swift build
          key: not-a-key
        tag: !!str 12
    """
    let result = tokens(.yaml, text)
    #expect(result.contains("keyword:---"))
    #expect(result.contains("declarationTitle:name"))
    #expect(result.contains("string:CI"))
    #expect(result.contains("comment:# workflow"))
    #expect(result.contains("property:push"))
    #expect(result.contains("property:branches"))
    #expect(result.contains("string:main"))
    #expect(result.contains("string:\"release/*\""))
    #expect(result.contains("attribute:&defaults"))
    #expect(result.contains("attribute:*defaults"))
    #expect(result.contains("number:3"))
    #expect(result.contains("keyword:yes"))
    #expect(result.contains("string:http://example.com:80/a"))
    #expect(result.contains("keyword:|"))
    #expect(result.contains("string:swift build"))
    #expect(result.contains("string:key: not-a-key"))
    #expect(result.contains("property:tag"))
    #expect(result.contains("attribute:!!str"))
}

@Test
func jsonSeparatesKeysFromValuesAndAcceptsComments() {
    let text = """
    {
      // compiler options
      "strict": true, "target": "es2022",
      "paths": { "@/*": ["src/*"] }, "n": -1.5e3, "x": null
    }
    """
    let result = tokens(.json, text)
    #expect(result.contains("comment:// compiler options"))
    #expect(result.contains("property:\"strict\""))
    #expect(result.contains("keyword:true"))
    #expect(result.contains("string:\"es2022\""))
    #expect(result.contains("property:\"@/*\""))
    #expect(result.contains("string:\"src/*\""))
    #expect(result.contains("number:-1.5e3"))
    #expect(result.contains("keyword:null"))
}

@Test
func iniAndEnvHighlightSectionsKeysAndContinuations() {
    let text = """
    ; top
    [metadata]
    name = cairn
    install_requires =
        requests>=2
    [user]
    \tname = Sian
    export API_URL="${HOST}/v1" # remote
    """
    let result = tokens(.ini, text)
    #expect(result.contains("comment:; top"))
    #expect(result.contains("declarationTitle:[metadata]"))
    #expect(result.contains("property:name"))
    #expect(result.contains("string:cairn"))
    #expect(result.contains("string:requests>=2"))
    #expect(!result.contains("property:requests>"))
    #expect(result.contains("string:Sian"))
    #expect(result.contains("keyword:export"))
    #expect(result.contains("property:API_URL"))
    #expect(result.contains("parameter:${HOST}"))
    #expect(result.contains("comment:# remote"))
}

@Test
func shellHighlightsKeywordsVariablesStringsAndHeredocs() {
    let text = """
    #!/usr/bin/env bash
    set -euo pipefail
    for file in "$@"; do
      echo "done: ${file}" # trailing
    done
    build() { swift build; }
    NAME=cairn cat <<'EOF'
    if this stays text $NAME
    EOF
    echo in 42
    """
    let result = tokens(.shell, text)
    #expect(result.contains("comment:#!/usr/bin/env bash"))
    #expect(result.contains("keyword:set"))
    #expect(result.contains("keyword:for"))
    #expect(result.contains("keyword:in"))
    #expect(result.contains("parameter:$@"))
    #expect(result.contains("keyword:do"))
    #expect(result.contains("string:\"done: "))
    #expect(result.contains("parameter:${file}"))
    #expect(result.contains("comment:# trailing"))
    #expect(result.contains("keyword:done"))
    #expect(result.contains("functionName:build"))
    #expect(result.contains("property:NAME"))
    #expect(result.contains("string:if this stays text $NAME\n"))
    #expect(result.contains("keyword:EOF"))
    #expect(!result.contains("keyword:if"))
    // `in` after echo is an argument, not the loop keyword.
    #expect(result.filter { $0 == "keyword:in" }.count == 1)
    #expect(result.contains("number:42"))
}

@Test
func shellMarksCommandNamesOptionsAndContinuations() {
    let result = tokens(.shell, """
    uv run tail.py \\
      --image data/dog.png -n 3 \\
      --out=dir 2>&1 | tee log
    export PATH
    if grep -q x f; then make; fi
    """)
    #expect(result.contains("declarationTitle:uv"))
    #expect(!result.contains("declarationTitle:run"))
    #expect(result.filter { $0 == "comment:\\" }.count == 2)
    #expect(result.contains("attribute:--image"))
    #expect(result.contains("attribute:-n"))
    #expect(result.contains("attribute:--out"))
    #expect(result.contains("declarationTitle:tee"))
    #expect(!result.contains("declarationTitle:log"))
    #expect(!result.contains("declarationTitle:PATH"))
    #expect(result.contains("declarationTitle:grep"))
    #expect(result.contains("attribute:-q"))
    #expect(result.contains("declarationTitle:make"))
}

@Test
func dockerfileAndMakefileHighlightTheirStructure() {
    let docker = tokens(.dockerfile, """
    FROM swift:6.1 AS build
    ARG MODE=release
    RUN swift build -c "$MODE"
    """)
    #expect(docker.contains("keyword:FROM"))
    #expect(docker.contains("keyword:AS"))
    #expect(docker.contains("property:MODE"))
    #expect(docker.contains("keyword:RUN"))
    #expect(docker.contains("parameter:$MODE"))

    let make = tokens(.makefile, """
    PREFIX ?= /usr/local
    .PHONY: build
    build: $(SOURCES) # compile
    \tswift build --prefix $(PREFIX) && echo $@
    ifeq ($(CI),1)
    endif
    """)
    #expect(make.contains("property:PREFIX"))
    #expect(make.contains("keyword:.PHONY"))
    #expect(make.contains("functionName:build"))
    #expect(make.contains("parameter:$(SOURCES)"))
    #expect(make.contains("comment:# compile"))
    #expect(make.contains("parameter:$(PREFIX)"))
    #expect(make.contains("parameter:$@"))
    #expect(make.contains("keyword:ifeq"))
    #expect(make.contains("keyword:endif"))
}

@Test
func jinjaPromptTemplateOverlaysTemplateHolesOnMarkupHost() {
    let text = """
    {# One block per input. #}
    {% for inp in input_blocks %}
    <{{ inp.name }} type="{{ inp.type }}">
    {{ inp.value | trim }}
    </{{ inp.name }}>
    {%- endfor %}
    The input variable{{ "s" if plural else "" }} is `{{ names | join("`, `") }}`.
    {% raw %}{{ untouched }}{% endraw %}
    """
    let format = TextFormat.jinja(host: nil)
    let result = tokens(format, text)
    #expect(result.contains("comment:{# One block per input. #}"))
    #expect(result.contains("macro:{%"))
    #expect(result.contains("keyword:for"))
    #expect(result.contains("parameter:inp"))
    #expect(result.contains("keyword:in"))
    #expect(result.contains("parameter:input_blocks"))
    #expect(result.contains("property:name"))
    #expect(result.contains("property:type"))
    #expect(result.contains("macro:{%-"))
    #expect(result.contains("keyword:endfor"))
    #expect(result.contains("functionCall:trim"))
    #expect(result.contains("functionCall:join"))
    #expect(result.contains("string:\"s\""))
    #expect(result.contains("keyword:if"))
    #expect(result.contains("typeName:</"))
    // The attribute string is split around the template hole it contains.
    #expect(result.contains("string:\""))
    #expect(!result.contains { $0.hasPrefix("string:\"{{") })
    #expect(!result.contains("parameter:untouched"))
    // Template spans never overlap host spans.
    let spans = format.highlight(text)
    for (a, b) in zip(spans, spans.dropFirst()) {
        #expect(a.range.upperBound <= b.range.lowerBound)
    }
}

@Test
func jinjaOverYAMLKeepsHostKeysAroundTemplateValues() {
    let text = """
    image: {{ registry }}/cairn:{{ tag | default("latest") }}
    {% if debug %}
    log_level: debug
    {% endif %}
    """
    let format = TextFormat.jinja(host: .yaml)
    #expect(kind(format, text, of: "image") == .declarationTitle)
    #expect(kind(format, text, of: "log_level") == .declarationTitle)
    #expect(kind(format, text, of: "registry") == .parameter)
    #expect(kind(format, text, of: "default") == .functionCall)
    #expect(kind(format, text, of: "\"latest\"") == .string)
    #expect(kind(format, text, of: "/cairn:") == .string)
    #expect(kind(format, text, of: "debug") == .parameter)
}

@Test
func codeSnippetHighlighterCoversReaderLanguagesAndFormats() {
    let rust = "fn main() { let x = \"é\"; }"
    let rustSpans = CodeSnippetHighlighter.spans(for: rust, languageHint: "rust")
    let units = Array(rust.utf16)
    let text = rustSpans.map { String(utf16CodeUnits: Array(units[$0.range]), count: $0.range.count) }
    #expect(text.contains("fn"))
    #expect(text.contains("\"é\""))
    #expect(!CodeSnippetHighlighter.spans(for: "def f(): pass", languageHint: "python").isEmpty)
    #expect(!CodeSnippetHighlighter.spans(for: "const a = 1", languageHint: "js").isEmpty)
    #expect(!CodeSnippetHighlighter.spans(for: "a: 1", languageHint: "yaml").isEmpty)
    #expect(CodeSnippetHighlighter.spans(for: "int main() {}", languageHint: "c").isEmpty)
}
