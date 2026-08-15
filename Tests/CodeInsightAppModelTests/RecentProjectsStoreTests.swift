import Foundation
import Testing
@testable import CodeInsightAppModel

@Test
func recentProjectsStoreRecordsDeduplicatesMovesToFrontLimitsAndPersists() {
    let suiteName = "RecentProjectsStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecentProjectsStore(defaults: defaults)

    for index in 0..<10 {
        store.record(URL(fileURLWithPath: "/projects/\(index)", isDirectory: true))
    }
    #expect(store.paths == (2..<10).reversed().map { "/projects/\($0)" })

    store.record(URL(fileURLWithPath: "/projects/5", isDirectory: true))
    #expect(store.paths.first == "/projects/5")
    #expect(store.paths.count == 8)
    #expect(store.paths.filter { $0 == "/projects/5" }.count == 1)

    let reloaded = RecentProjectsStore(defaults: UserDefaults(suiteName: suiteName)!)
    #expect(reloaded.paths == store.paths)
    #expect(reloaded.languages(for: "/projects/9") == [.rust])
}

@Test
func recentProjectsStoreTracksLanguageByPathAndOverridesOnReRecord() {
    let suiteName = "RecentProjectsStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecentProjectsStore(defaults: defaults)
    let rustPath = "/projects/rust"
    let pythonPath = "/projects/python"

    store.record(URL(fileURLWithPath: rustPath, isDirectory: true), language: .rust)
    store.record(
        URL(fileURLWithPath: pythonPath, isDirectory: true),
        language: .python
    )
    #expect(store.languages(for: rustPath) == [.rust])
    #expect(store.languages(for: pythonPath) == [.python])

    store.record(
        URL(fileURLWithPath: pythonPath, isDirectory: true),
        language: .rust
    )
    #expect(store.paths == [pythonPath, rustPath])
    #expect(store.languages(for: pythonPath) == [.rust])

    store.record(
        URL(fileURLWithPath: pythonPath, isDirectory: true),
        language: .python
    )
    #expect(store.paths == [pythonPath, rustPath])
    #expect(store.languages(for: pythonPath) == [.python])
}

@Test
func recentProjectsStoreRecordsAndPrunesLanguageArrays() {
    let suiteName = "RecentProjectsStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecentProjectsStore(defaults: defaults)

    store.record(
        URL(fileURLWithPath: "/projects/mixed", isDirectory: true),
        languages: [.typescript, .rust]
    )
    #expect(store.languages(for: "/projects/mixed") == [.rust, .typescript])
    #expect(store.language(for: "/projects/mixed") == .rust)

    for index in 0..<10 {
        store.record(
            URL(fileURLWithPath: "/projects/\(index)", isDirectory: true),
            languages: [.python, .rust]
        )
    }
    #expect(store.paths.count == 8)
    #expect(store.languages(for: "/projects/2") == [.rust, .python])
    #expect(store.language(for: "/projects/2") == .rust)
    #expect(store.languages(for: "/projects/0") == [.rust])
}

@Test
func recentProjectsStorePrunesLanguageMapWithPathLimitAndClearsBothKeys() {
    let suiteName = "RecentProjectsStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecentProjectsStore(defaults: defaults)

    for index in 0..<10 {
        store.record(
            URL(fileURLWithPath: "/projects/\(index)", isDirectory: true),
            language: index.isMultiple(of: 2) ? .python : .rust
        )
    }

    #expect(store.paths.count == 8)
    #expect(store.languages(for: "/projects/2") == [.python])
    #expect(store.languages(for: "/projects/3") == [.rust])
    #expect(store.languages(for: "/projects/0") == [.rust])

    store.clear()
    #expect(store.paths.isEmpty)
    #expect(store.languages(for: "/projects/9") == [.rust])
}

@Test
func recentProjectsStoreLanguageFallsBackForMissingAndInvalidMapValues() {
    let suiteName = "RecentProjectsStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecentProjectsStore(defaults: defaults)
    defaults.set([
        "/bad/invalid": NSNumber(value: 99),
        "/bad/out-of-range": NSNumber(value: 257),
    ], forKey: "Cairn.RecentProjectLanguages")

    #expect(store.languages(for: "/missing") == [.rust])
    #expect(store.languages(for: "/bad/invalid") == [.rust])
    #expect(store.languages(for: "/bad/out-of-range") == [.rust])

    defaults.set([
        "/bad/js": [NSNumber(value: 3)],
        "/bad/empty": [] as [NSNumber],
        "/bad/dup": [NSNumber(value: 0), NSNumber(value: 0)],
    ], forKey: "Cairn.RecentProjectLanguages")

    #expect(store.languages(for: "/bad/js") == [.rust])
    #expect(store.languages(for: "/bad/empty") == [.rust])
    #expect(store.languages(for: "/bad/dup") == [.rust])
}

@Test
func projectDropAcceptsOneDirectoryAndRejectsAFile() {
    let directory = URL(fileURLWithPath: "/projects/cairn", isDirectory: true)
    let file = URL(fileURLWithPath: "/projects/cairn/main.rs")

    #expect(isAcceptedProjectDrop([directory]))
    #expect(!isAcceptedProjectDrop([file]))
    #expect(!isAcceptedProjectDrop([]))
    #expect(!isAcceptedProjectDrop([directory, directory]))
}
