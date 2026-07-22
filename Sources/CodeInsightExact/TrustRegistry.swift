import CodeInsightCore
import Foundation

public actor TrustRegistry {
    private struct Entry: Codable {
        let mode: String
        let grantedAt: Date
    }

    private let fileURL: URL
    private var entries: [String: Entry]

    public init(fileURL: URL? = nil) {
        let fileURL = fileURL ?? Self.defaultFileURL
        self.fileURL = fileURL
        entries = Self.load(fileURL)
    }

    public func grant(
        _ repositoryURL: URL,
        mode: TrustMode,
        grantedAt: Date = Date()
    ) throws {
        let path = Self.canonicalPath(repositoryURL)
        let previous = entries[path]
        entries[path] = Entry(mode: Self.name(mode), grantedAt: grantedAt)
        do {
            try save()
        } catch {
            entries[path] = previous
            throw error
        }
    }

    public func revoke(_ repositoryURL: URL) throws {
        let path = Self.canonicalPath(repositoryURL)
        guard let previous = entries.removeValue(forKey: path) else { return }
        do {
            try save()
        } catch {
            entries[path] = previous
            throw error
        }
    }

    public func query(_ repositoryURL: URL) -> TrustMode? {
        switch entries[Self.canonicalPath(repositoryURL)]?.mode {
        case "safe": .safe
        case "trusted": .trusted
        default: nil
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
    }

    private static func load(_ fileURL: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func name(_ mode: TrustMode) -> String {
        switch mode {
        case .safe: "safe"
        case .trusted: "trusted"
        }
    }

    private static var defaultFileURL: URL {
        let root =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return root.appendingPathComponent(
            "CodeInsight/trust.json",
            isDirectory: false
        )
    }
}
