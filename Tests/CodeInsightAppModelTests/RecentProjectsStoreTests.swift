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
}

@Test
func recentProjectsStoreLastSessionProjectSurvivesRecentsClear() {
    let suiteName = "RecentProjectsStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecentProjectsStore(defaults: defaults)

    #expect(store.lastSessionProjectPath == nil)
    store.lastSessionProjectPath = "/projects/with-snapshot"
    #expect(store.lastSessionProjectPath == "/projects/with-snapshot")

    let reloaded = RecentProjectsStore(defaults: UserDefaults(suiteName: suiteName)!)
    #expect(reloaded.lastSessionProjectPath == "/projects/with-snapshot")

    // Clearing the recents list is a UI entry-point action; it must not
    // delete any project's saved reading session pointer.
    store.clear()
    #expect(store.lastSessionProjectPath == "/projects/with-snapshot")

    store.lastSessionProjectPath = nil
    #expect(store.lastSessionProjectPath == nil)
}

@Test
func recentProjectsStoreDropsTheRetiredLanguageMapAndKeepsPaths() {
    let suiteName = "RecentProjectsStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["/projects/a", "/projects/b"], forKey: "Cairn.RecentProjects")
    defaults.set(
        ["/projects/a": [NSNumber(value: 1)]],
        forKey: "Cairn.RecentProjectLanguages"
    )

    let store = RecentProjectsStore(defaults: defaults)

    #expect(store.paths == ["/projects/a", "/projects/b"])
    #expect(defaults.object(forKey: "Cairn.RecentProjectLanguages") == nil)
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
