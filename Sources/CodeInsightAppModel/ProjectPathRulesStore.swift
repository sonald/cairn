import CodeInsightCore
import Foundation

/// Per-project exclusion rules in application data, one JSON file per
/// project next to the session store. Nothing is read from or written to the
/// project itself: the repository being read never decides what its reader sees.
struct ProjectPathRulesStore {
    private struct Record: Codable {
        let version: Int
        let projectRoot: String
        let lines: [String]
    }

    static let maximumLineCount = 200
    static let maximumLineBytes = 1_024

    let directory: URL

    func load(forProject root: URL) -> ProjectPathRules {
        guard let data = try? Data(contentsOf: fileURL(for: root)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1,
              // The file name alone is not trusted.
              URL(fileURLWithPath: record.projectRoot).resolvingSymlinksInPath().standardizedFileURL.path
                == root.resolvingSymlinksInPath().standardizedFileURL.path
        else { return ProjectPathRules() }
        return ProjectPathRules(lines: Self.sanitized(record.lines))
    }

    func save(_ rules: ProjectPathRules, forProject root: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = Record(version: 1, projectRoot: root.standardizedFileURL.path, lines: Self.sanitized(rules.lines))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: fileURL(for: root), options: .atomic)
    }

    static func sanitized(_ lines: [String]) -> [String] {
        Array(lines.prefix(maximumLineCount)).map { line in
            line.utf8.count <= maximumLineBytes ? line : String(decoding: line.utf8.prefix(maximumLineBytes), as: UTF8.self)
        }
    }

    private func fileURL(for root: URL) -> URL {
        directory.appendingPathComponent(SessionCheckpointStore.projectKey(for: root) + ".json")
    }
}
