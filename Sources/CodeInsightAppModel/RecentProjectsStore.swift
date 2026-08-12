import CodeInsightCore
import Foundation

public final class RecentProjectsStore {
    private static let pathsDefaultsKey = "Cairn.RecentProjects"
    private static let languageDefaultsKey = "Cairn.RecentProjectLanguages"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var paths: [String] {
        defaults.stringArray(forKey: Self.pathsDefaultsKey) ?? []
    }

    public func record(_ url: URL) {
        record(url, language: .rust)
    }

    public func record(_ url: URL, language: LanguageID) {
        let path = url.standardizedFileURL.path
        let updated = [path] + paths.filter { $0 != path }
        let pruned = Array(updated.prefix(8))
        defaults.set(pruned, forKey: Self.pathsDefaultsKey)

        var languages = readLanguages()
        for path in Set(languages.keys).subtracting(pruned) {
            languages.removeValue(forKey: path)
        }
        languages[path] = language.rawValue
        defaults.set(languages, forKey: Self.languageDefaultsKey)
    }

    public func language(for path: String) -> LanguageID {
        guard let rawValue = readLanguages()[path] else { return .rust }
        return LanguageID(rawValue: rawValue) ?? .rust
    }

    public func clear() {
        defaults.removeObject(forKey: Self.pathsDefaultsKey)
        defaults.removeObject(forKey: Self.languageDefaultsKey)
    }

    private func readLanguages() -> [String: UInt8] {
        guard let raw = defaults.dictionary(forKey: Self.languageDefaultsKey) else {
            return [:]
        }
        var result: [String: UInt8] = [:]
        for (path, value) in raw {
            if let number = value as? NSNumber,
               let rawValue = UInt8(exactly: number.intValue) {
                result[path] = rawValue
            }
        }
        return result
    }
}

public func isAcceptedProjectDrop(_ urls: [URL]) -> Bool {
    urls.count == 1 && urls[0].hasDirectoryPath
}
