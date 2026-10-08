import CodeInsightCore
@testable import CodeInsightAppModel
import Foundation
import Testing

// Results recorded from Dash 8.1.1's `/search` on 2026-10-08 (max_results=20,
// every docset). Entries marked "built" follow the live URL pattern of their
// docset for cases this machine's Dash did not return.
private let dash = "http://127.0.0.1:59166/Dash"

private func candidate(
    _ name: String, _ kind: String, _ docset: String, _ url: String, platform: String = ""
) -> DocumentationCandidate {
    DocumentationCandidate(name: name, kind: kind, docset: docset, loadURL: URL(string: url)!, sourceName: "Dash",
                           platform: platform)
}

private func encoded(_ url: String) -> String {
    url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
}

private let threadingResults: [DocumentationCandidate] = [
    candidate("threading", "Module", "Python", "\(dash)/lfexfdfn/doc/library/threading.html#//apple_ref/Module/threading"),
    candidate("ThreadingMock", "Class", "Python", "\(dash)/lfexfdfn/doc/library/unittest.mock.html#//apple_ref/Class/unittest.mock.ThreadingMock"),
    candidate("ThreadingMixIn", "Class", "Python", "\(dash)/lfexfdfn/doc/library/socketserver.html#//apple_ref/Class/socketserver.ThreadingMixIn"),
    candidate("ThreadingTCPServer", "Class", "Python", "\(dash)/lfexfdfn/doc/library/socketserver.html#//apple_ref/Class/socketserver.ThreadingTCPServer"),
    candidate("ThreadingHTTPServer", "Class", "Python", "\(dash)/lfexfdfn/doc/library/http.server.html#//apple_ref/Class/http.server.ThreadingHTTPServer"),
    candidate("threading_setup", "Function", "Python", "\(dash)/lfexfdfn/doc/library/test.html#//apple_ref/Function/test.support.threading_helper.threading_setup"),
    candidate("Threading Environment Variables", "Guide", "PyTorch 2.11.0", "\(dash)/zsvkebcr/threading_environment_variables.html"),
    candidate("Python support for free threading", "Guide", "Python", "\(dash)/lfexfdfn/doc/howto/free-threading-python.html"),
    candidate("Multi-threading", "Section", "Python", "\(dash)/lfexfdfn/doc/tutorial/stdlib2.html#//apple_ref/Section/Multi-threading"),
    candidate("Concurrency and Multithreading", "Section", "Python",
              encoded("\(dash)/lfexfdfn/doc/library/asyncio-dev.html#//apple_ref/Section/Concurrency and Multithreading")),
    candidate("test.support.threading_helper", "Module", "Python", "\(dash)/lfexfdfn/doc/library/test.html#//apple_ref/Module/test.support.threading_helper"),
    candidate("catch_threading_exception", "Function", "Python", "\(dash)/lfexfdfn/doc/library/test.html#//apple_ref/Function/test.support.threading_helper.catch_threading_exception"),
    candidate("set_multithreading_enabled", "Class", "PyTorch 2.11.0", "\(dash)/zsvkebcr/generated/torch.autograd.grad_mode.set_multithreading_enabled.html#torch.autograd.grad_mode.set_multithreading_enabled"),
]

// `Mutex::lock`, the query rust-analyzer's `std::sync::poison::mutex::Mutex`
// location now yields; Dash lists the poison/nonpoison copies in between.
private let mutexLockResults: [DocumentationCandidate] = [
    candidate("lock", "Method", "Rust", "\(dash)/eyztlmjg/doc.rust-lang.org/1.98.1/std/sync/struct.Mutex.html#//dash_ref_183062/Method/lock/0", platform: "rust"),
    candidate("lock", "Method", "Rust", "\(dash)/eyztlmjg/doc.rust-lang.org/1.98.1/std/sync/nonpoison/struct.Mutex.html#//dash_ref_184787/Method/lock/0", platform: "rust"),
    candidate("lock", "Method", "Rust", "\(dash)/eyztlmjg/doc.rust-lang.org/1.98.1/std/sync/poison/struct.Mutex.html#//dash_ref_183984/Method/lock/0", platform: "rust"),
    candidate("lock", "Method", "C++", "\(dash)/flkkgwpw/en.cppreference.com/cpp/thread/mutex/lock.html", platform: "cpp"),
    candidate("lock", "Method", "tokio", "\(dash)/pktemvcm/docs/tokio/sync/struct.Mutex.html#//dash_ref_8066/Method/lock/0", platform: "crate"),
    candidate("try_lock", "Method", "Rust", "\(dash)/eyztlmjg/doc.rust-lang.org/1.98.1/std/sync/struct.Mutex.html#//dash_ref_183063/Method/try_lock/0", platform: "rust"),
]

private let getenvResults: [DocumentationCandidate] = [
    candidate("getenv", "Function", "C++", "\(dash)/flkkgwpw/en.cppreference.com/cpp/utility/program/getenv.html", platform: "cpp"),
    candidate("Getenv", "Function", "Go", "\(dash)/jstznmnl/pkg.go.dev/os@go1.27.html#//dash_ref_Getenv/Function/Getenv/0", platform: "go"),
    candidate("getenv", "Function", "Python", "\(dash)/lfexfdfn/doc/library/os.html#//apple_ref/Function/os.getenv", platform: "python"),
    // built: a user-contributed docset, to place the third-party group
    candidate("getenv", "Function", "PyTorch 2.11.0", "\(dash)/zsvkebcr/generated/torch.getenv.html#torch.getenv", platform: "usercontribPyTorch"),
    candidate("get_envs", "Method", "Rust", "\(dash)/eyztlmjg/doc.rust-lang.org/1.98.1/std/process/struct.Command.html#//dash_ref_213816/Method/get_envs/0", platform: "rust"),
]

private let acquireResults: [DocumentationCandidate] = [
    candidate("Acquire", "Variant", "Rust", "\(dash)/eyztlmjg/doc.rust-lang.org/1.98.1/std/sync/atomic/enum.Ordering.html#//dash_ref_183260/Variant/Acquire/0"),
    candidate("acquire", "Method", "C++", "\(dash)/flkkgwpw/en.cppreference.com/cpp/thread/counting_semaphore/acquire.html"),
    candidate("acquire", "Method", "tokio", "\(dash)/pktemvcm/docs/tokio/sync/struct.Semaphore.html#//dash_ref_7523/Method/acquire/0"),
    // built from the live `asyncio.Condition.acquire` entry
    candidate("acquire", "Method", "Python", "\(dash)/lfexfdfn/doc/library/threading.html#//apple_ref/Method/threading.Lock.acquire"),
    candidate("acquire", "Method", "Python", "\(dash)/lfexfdfn/doc/library/asyncio-sync.html#//apple_ref/Method/asyncio.Lock.acquire"),
    candidate("anyio.Lock.acquire", "Method", "AnyIO", "\(dash)/hwqepstz/anyio.readthedocs.io/en/stable/api.html#//apple_ref/Method/anyio.Lock.acquire"),
    candidate("try_acquire", "Method", "tokio", "\(dash)/pktemvcm/docs/tokio/sync/struct.Semaphore.html#//dash_ref_7525/Method/try_acquire/0"),
]

private let ioOpenResults: [DocumentationCandidate] = [
    candidate("open", "Function", "Python", "\(dash)/lfexfdfn/doc/library/io.html#//apple_ref/Function/io.open"),
    candidate("anyio.open_file", "Function", "AnyIO", "\(dash)/hwqepstz/anyio.readthedocs.io/en/stable/api.html#//apple_ref/Function/anyio.open_file"),
    candidate("open_connection", "Function", "Python", "\(dash)/lfexfdfn/doc/library/asyncio-stream.html#//apple_ref/Function/asyncio.open_connection"),
    candidate("open", "Method", "NumPy", "\(dash)/bdxiqpmt/doc/reference/generated/numpy.lib.npyio.DataSource.open.html#//apple_ref/Method/numpy.lib.npyio.DataSource.open"),
    candidate("open", "Method", "torchaudio 2.1.0", "\(dash)/lnjxxzec/generated/torchaudio.io.StreamWriter.html#torchaudio.io.StreamWriter.open"),
]

private func autoLoad(_ query: String, _ candidates: [DocumentationCandidate]) -> DocumentationCandidate? {
    DocumentationPanelModel.autoLoadIndex(query: query, candidates: candidates) {
        DashDocumentationSource.isExactMatch(name: $0.name, loadURL: $0.loadURL, query: query)
    }.map { candidates[$0] }
}

@Test
func dashExactMatchAndAutoLoadFollowRecordedResults() {
    // `threading`: only the module entry is an exact match among the results.
    #expect(autoLoad("threading", threadingResults) == threadingResults[0])
    // A qualified Sphinx name sits in the fragment; the lone result loads.
    let start = candidate("start", "Method", "Python",
                          "\(dash)/lfexfdfn/doc/library/threading.html#//apple_ref/Method/threading.Thread.start")
    #expect(DashDocumentationSource.isExactMatch(name: start.name, loadURL: start.loadURL, query: "threading.Thread.start"))
    #expect(autoLoad("threading.Thread.start", [start]) == start)
    // `Mutex` must be a whole, case-sensitive URL token: std's three copies
    // and tokio's match, cppreference's `mutex/lock.html` does not.
    #expect(mutexLockResults.filter {
        DashDocumentationSource.isExactMatch(name: $0.name, loadURL: $0.loadURL, query: "Mutex::lock")
    }.map(\.docset) == ["Rust", "Rust", "Rust", "tokio"])
    // Several exact matches: the shortest path in the first one's docset,
    // whatever order Dash lists std's re-exported copies in.
    #expect(autoLoad("Mutex::lock", mutexLockResults) == mutexLockResults[0])
    let poisonFirst = [mutexLockResults[2], mutexLockResults[1], mutexLockResults[4], mutexLockResults[0]]
    #expect(autoLoad("Mutex::lock", poisonFirst) == mutexLockResults[0])
    // A receiver prefix (`os.getenv`) leaves one exact match.
    #expect(autoLoad("os.getenv", getenvResults) == getenvResults[2])
    // A bare `acquire` names several entries (case-sensitively, so not `Acquire`): the user picks.
    #expect(acquireResults.filter {
        DashDocumentationSource.isExactMatch(name: $0.name, loadURL: $0.loadURL, query: "acquire")
    }.map(\.docset) == ["C++", "tokio", "Python", "Python"])
    #expect(autoLoad("acquire", acquireResults) == nil)
    #expect(autoLoad("threading.Lock.acquire", acquireResults) == acquireResults[3])
    // Whole tokens: `io` is not `asyncio` and not `npyio`.
    #expect(!DashDocumentationSource.isExactMatch(
        name: ioOpenResults[2].name, loadURL: ioOpenResults[2].loadURL, query: "io.open_connection"))
    #expect(!DashDocumentationSource.isExactMatch(
        name: ioOpenResults[3].name, loadURL: ioOpenResults[3].loadURL, query: "io.open"))
    #expect(autoLoad("io.open", ioOpenResults) == ioOpenResults[0])
    // A segment with an underscore is matched token by token.
    #expect(DashDocumentationSource.isExactMatch(
        name: threadingResults[5].name, loadURL: threadingResults[5].loadURL,
        query: "test.support.threading_helper.threading_setup"))
    // No exact match among several results: nothing loads.
    #expect(autoLoad("Threading", threadingResults) == nil)
}

@Test
func dashResultsRankTheReadingLanguageFirstThenThirdPartyDocsets() {
    let ranked = DashDocumentationSource.ranked(getenvResults, language: .python)
    #expect(ranked.map(\.docset) == ["Python", "PyTorch 2.11.0", "C++", "Go", "Rust"])
    #expect(ranked.map(\.matchesLanguage) == [true, false, false, false, false])
    let rust = DashDocumentationSource.ranked(mutexLockResults, language: .rust)
    #expect(rust.map(\.docset) == ["Rust", "Rust", "Rust", "tokio", "Rust", "C++"], "rust and crate docsets both match")
    // A bare identifier with several exact matches loads the one in the
    // reading language's docset, and only when it is the only one.
    #expect(autoLoad("getenv", ranked) == ranked[0])
    #expect(autoLoad("getenv", getenvResults) == nil, "Unranked results match no language")
    #expect(autoLoad("lock", rust) == nil, "std and tokio both document Rust")
}

@Test
func dashSearchResponseDropsTheEmptyResultAndMalformedEntries() {
    let empty = Data(#"{"results":[{}]}"#.utf8)
    #expect(DashDocumentationSource.candidates(fromSearchResponse: empty, sourceName: "Dash").isEmpty)
    let body = Data(#"""
    {"results":[{"docset":"Python","description":"threading.Thread","load_url":"http:\/\/127.0.0.1:59166\/Dash\/lfexfdfn\/doc\/library\/threading.html#\/\/apple_ref\/Method\/threading.Thread.start","name":"start","type":"Method","platform":"python"},{"name":"orphan"},{}]}
    """#.utf8)
    let parsed = DashDocumentationSource.candidates(fromSearchResponse: body, sourceName: "Dash")
    #expect(parsed == [candidate("start", "Method", "Python",
                                 "\(dash)/lfexfdfn/doc/library/threading.html#//apple_ref/Method/threading.Thread.start",
                                 platform: "python")])
    #expect(DashDocumentationSource.isTrialExpired(
        status: 403, body: Data("API access blocked due to Dash trial expiration".utf8)))
    #expect(!DashDocumentationSource.isTrialExpired(status: 403, body: Data("Forbidden".utf8)))
}

// MARK: - Panel model

private actor StubSource: DocumentationSource {
    nonisolated let name = "Stub"
    private let state: DocumentationAvailability
    private let results: [String: [DocumentationCandidate]]
    private let failure: DocumentationSourceError?
    private let blockedQuery: String?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var started: [String] = []
    private(set) var languages: [LanguageID?] = []

    init(
        availability: DocumentationAvailability = .available,
        results: [String: [DocumentationCandidate]] = [:],
        failure: DocumentationSourceError? = nil,
        blockedQuery: String? = nil
    ) {
        state = availability
        self.results = results
        self.failure = failure
        self.blockedQuery = blockedQuery
    }

    func availability() async -> DocumentationAvailability { state }

    func search(_ query: String, language: LanguageID?) async throws -> [DocumentationCandidate] {
        started.append(query)
        languages.append(language)
        if query == blockedQuery { await withCheckedContinuation { waiting = $0 } }
        if let failure { throw failure }
        return DashDocumentationSource.ranked(results[query] ?? [], language: language)
    }

    func release() { waiting?.resume(); waiting = nil }
    var isBlocked: Bool { waiting != nil }

    nonisolated func isExactMatch(_ candidate: DocumentationCandidate, for query: String) -> Bool {
        DashDocumentationSource.isExactMatch(name: candidate.name, loadURL: candidate.loadURL, query: query)
    }
}

@MainActor
private func settled(_ model: DocumentationPanelModel) async -> DocumentationPanelModel.State {
    _ = await testWaitUntil("search settles") {
        if case .searching = model.state { return false }
        return true
    }
    return model.state
}

@MainActor
@Test
func documentationPanelModelReportsUnavailableSourcesAndMissingResults() async {
    for (availability, notice) in [
        (DocumentationAvailability.notInstalled, DocumentationPanelModel.Notice.notInstalled),
        (.notRunning, .notRunning),
        (.apiDisabled, .apiDisabled),
    ] {
        let model = DocumentationPanelModel(source: StubSource(availability: availability))
        model.show(query: "lock")
        #expect(model.state == .searching("lock"))
        #expect(await settled(model) == .unavailable(notice))
    }
    let empty = DocumentationPanelModel(source: StubSource())
    empty.show(query: "nothing")
    #expect(await settled(empty) == .unavailable(.noResults))
    #expect(empty.query == "nothing")
    let expired = DocumentationPanelModel(source: StubSource(failure: .trialExpired))
    expired.show(query: "lock")
    #expect(await settled(expired) == .unavailable(.trialExpired))
}

@MainActor
@Test
func documentationPanelModelLoadsSingleAndExactResultsAndWaitsOnAmbiguousOnes() async {
    let lone = threadingResults[1]
    let source = StubSource(results: [
        "ThreadingMock": [lone],
        "threading": threadingResults,
        "acquire": acquireResults,
        "getenv": getenvResults,
    ])
    let model = DocumentationPanelModel(source: source)
    model.show(query: "ThreadingMock")
    #expect(await settled(model) == .showing(lone, [lone]))
    model.show(query: "threading")
    #expect(await settled(model) == .showing(threadingResults[0], threadingResults))
    model.show(query: "acquire")
    #expect(await settled(model) == .candidates(acquireResults))
    model.select(acquireResults[4])
    #expect(model.state == .showing(acquireResults[4], acquireResults))
    model.select(threadingResults[0])
    #expect(model.state == .showing(acquireResults[4], acquireResults), "A stale candidate is ignored")
    // The reading file's language reaches the source; its one exact match loads.
    model.show(query: "getenv", language: .python)
    let ranked = DashDocumentationSource.ranked(getenvResults, language: .python)
    #expect(await settled(model) == .showing(ranked[0], ranked))
    #expect(ranked[0].docset == "Python")
    #expect(await source.languages.last == .python)
}

@MainActor
@Test
func documentationPanelModelDropsTheResultOfASupersededSearch() async {
    let source = StubSource(results: ["old": [threadingResults[0]], "new": [mutexLockResults[0]]], blockedQuery: "old")
    let model = DocumentationPanelModel(source: source)
    model.show(query: "old")
    #expect(await testWaitUntil("old search is in flight") { await source.isBlocked })
    model.show(query: "new")
    #expect(await settled(model) == .showing(mutexLockResults[0], [mutexLockResults[0]]))
    await source.release()
    // Give the released search time to return before checking it was dropped.
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(model.state == .showing(mutexLockResults[0], [mutexLockResults[0]]))
    #expect(model.query == "new")
    #expect(await source.started == ["old", "new"])
}

// MARK: - Live Dash

/// The real HTTP path against this machine's Dash. Skipped when Dash or its
/// API server is not available (CI has no Dash).
private func dashAPIAnswers() async -> Bool {
    guard let data = try? Data(contentsOf: DashDocumentationSource.defaultStatusFile),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let port = object["port"] as? Int,
          let url = URL(string: "http://127.0.0.1:\(port)/health")
    else { return false }
    let response = try? await URLSession(configuration: .ephemeral)
        .data(for: URLRequest(url: url, timeoutInterval: 1)).1
    return (response as? HTTPURLResponse)?.statusCode == 200
}

@Test(.enabled("Dash with its API server enabled is not available on this machine") {
    await dashAPIAnswers()
})
func dashSourceSearchesTheLocalDashAPI() async throws {
    let source = DashDocumentationSource(isInstalled: { true }, isRunning: { true })
    #expect(await source.availability() == .available)
    let results = try await source.search("threading.Thread.start", language: .python)
    let exact = try #require(results.first { source.isExactMatch($0, for: "threading.Thread.start") })
    #expect(exact.loadURL.host == "127.0.0.1")
    #expect(exact.loadURL.fragment?.contains("threading.Thread.start") == true)
    #expect(try await source.search("zzzqqq-no-such-symbol", language: nil).isEmpty)
    // Live ranking: Python's `getenv` comes first for a Python file.
    let getenv = try await source.search("getenv", language: .python)
    #expect(getenv.first?.platform == "python" && getenv.first?.matchesLanguage == true)
    let missing = DashDocumentationSource(
        isInstalled: { true }, isRunning: { true },
        statusFile: URL(fileURLWithPath: "/nonexistent/status.json"))
    #expect(await missing.availability() == .apiDisabled)
    #expect(await DashDocumentationSource(isInstalled: { false }, isRunning: { true }).availability() == .notInstalled)
    #expect(await DashDocumentationSource(isInstalled: { true }, isRunning: { false }).availability() == .notRunning)
}
