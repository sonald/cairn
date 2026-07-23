import Foundation

public final class RecentProjectsStore {
    private static let key = "Cairn.RecentProjects"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var paths: [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    public func record(_ url: URL) {
        let path = url.standardizedFileURL.path
        let updated = [path] + paths.filter { $0 != path }
        defaults.set(Array(updated.prefix(8)), forKey: Self.key)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}

public func isAcceptedProjectDrop(_ urls: [URL]) -> Bool {
    urls.count == 1 && urls[0].hasDirectoryPath
}
