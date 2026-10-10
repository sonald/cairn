import Foundation

public final class RecentProjectsStore {
    private static let pathsDefaultsKey = "Cairn.RecentProjects"
    /// Removed: languages are detected on every open, not remembered.
    private static let retiredLanguageDefaultsKey = "Cairn.RecentProjectLanguages"
    private static let lastSessionProjectDefaultsKey = "Cairn.LastSessionProject"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.removeObject(forKey: Self.retiredLanguageDefaultsKey)
    }

    public var paths: [String] {
        defaults.stringArray(forKey: Self.pathsDefaultsKey) ?? []
    }

    /// The project whose per-project reading session should reopen on
    /// launch. Updated only after that project's session was successfully
    /// saved, so an open that never produced a checkpoint never becomes
    /// the restore target. Clearing the recents list leaves it alone.
    public var lastSessionProjectPath: String? {
        get { defaults.string(forKey: Self.lastSessionProjectDefaultsKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.lastSessionProjectDefaultsKey)
            } else {
                defaults.removeObject(
                    forKey: Self.lastSessionProjectDefaultsKey
                )
            }
        }
    }

    public func record(_ url: URL) {
        let path = url.standardizedFileURL.path
        let updated = [path] + paths.filter { $0 != path }
        defaults.set(Array(updated.prefix(8)), forKey: Self.pathsDefaultsKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.pathsDefaultsKey)
    }
}

public func isAcceptedProjectDrop(_ urls: [URL]) -> Bool {
    urls.count == 1 && urls[0].hasDirectoryPath
}
