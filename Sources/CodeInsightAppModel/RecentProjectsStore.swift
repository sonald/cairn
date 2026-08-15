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
        record(url, languages: [.rust])
    }

    public func record(_ url: URL, language: LanguageID) {
        record(url, languages: [language])
    }

    public func record(_ url: URL, languages: [LanguageID]) {
        let path = url.standardizedFileURL.path
        let updated = [path] + paths.filter { $0 != path }
        let pruned = Array(updated.prefix(8))
        defaults.set(pruned, forKey: Self.pathsDefaultsKey)

        var stored = readLanguages()
        for storedPath in Set(stored.keys).subtracting(pruned) {
            stored.removeValue(forKey: storedPath)
        }
        stored[path] = normalizedLanguagesForRecord(languages).map(\.rawValue)
        defaults.set(stored, forKey: Self.languageDefaultsKey)
    }

    public func language(for path: String) -> LanguageID {
        languages(for: path).first ?? .rust
    }

    public func languages(for path: String) -> [LanguageID] {
        guard let raw = readLanguages()[path],
              !raw.isEmpty
        else { return [.rust] }
        let languages = raw.compactMap(LanguageID.init(rawValue:))
        guard languages.count == raw.count,
              let normalized = try? LanguageMode.normalize(languages: languages),
              normalized == languages
        else { return [.rust] }
        return normalized
    }

    public func clear() {
        defaults.removeObject(forKey: Self.pathsDefaultsKey)
        defaults.removeObject(forKey: Self.languageDefaultsKey)
    }

    private func readLanguages() -> [String: [UInt8]] {
        guard let raw = defaults.dictionary(forKey: Self.languageDefaultsKey) else {
            return [:]
        }
        var result: [String: [UInt8]] = [:]
        for (path, value) in raw {
            if let number = value as? NSNumber,
               let rawValue = UInt8(exactly: number.intValue) {
                result[path] = [rawValue]
            } else if let array = value as? [NSNumber],
                      !array.isEmpty {
                let rawValues: [UInt8] = array.compactMap {
                    UInt8(exactly: $0.intValue)
                }
                if rawValues.count == array.count {
                    result[path] = rawValues
                }
            }
        }
        return result
    }

    private func normalizedLanguagesForRecord(
        _ languages: [LanguageID]
    ) -> [LanguageID] {
        guard let normalized = try? LanguageMode.normalize(languages: languages)
        else { return [.rust] }
        return normalized
    }
}

public func isAcceptedProjectDrop(_ urls: [URL]) -> Bool {
    urls.count == 1 && urls[0].hasDirectoryPath
}
