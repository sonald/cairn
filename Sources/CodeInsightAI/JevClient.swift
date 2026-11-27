import CodeInsightCore
import CodeInsightReaderCore
import CryptoKit
import Foundation

/// TypeSafe's Jev service, for its one call: score a file's skeleton
/// questions. Nothing it throws or describes carries the key.
public struct JevClient: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case notConfigured
        case status(Int)
        case transport
        case malformedResponse
    }

    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let retries = 3

    private let session: URLSession
    private let key: @Sendable () -> String?
    private let pause: @Sendable (_ seconds: Int) async throws -> Void

    public init(
        session: URLSession = .shared,
        key: @escaping @Sendable () -> String? = { AIKeychain.jev.read() },
        pause: @escaping @Sendable (_ seconds: Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.session = session
        self.key = key
        self.pause = pause
    }

    /// A score from 0 to 1 for every question. A busy service (429, 529) and
    /// a failed connection are each tried again up to three times, after
    /// 1, 2 and 4 seconds. Cancelling throws `CancellationError`.
    public func scores(for questions: SkeletonQuestions) async throws -> [String: Double] {
        guard let key = key()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        else { throw Failure.notConfigured }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = questions.requestBody

        var busy = 0
        var failed = 0
        while true {
            try Task.checkCancellation()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                guard failed < Self.retries else { throw Failure.transport }
                try await pause(1 << failed)
                failed += 1
                continue
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status == 529 {
                guard busy < Self.retries else { throw Failure.status(status) }
                try await pause(1 << busy)
                busy += 1
                continue
            }
            guard (200..<300).contains(status) else { throw Failure.status(status) }
            return try Self.scores(in: data, for: questions.questions.map(\.id))
        }
    }

    /// `{"answers": {id: {"noul": score}}}`, with a score in 0...1 for every id.
    static func scores(in data: Data, for ids: [String]) throws -> [String: Double] {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = body["answers"] as? [String: Any]
        else { throw Failure.malformedResponse }
        var scores: [String: Double] = [:]
        for id in ids {
            guard let answer = answers[id] as? [String: Any], let score = answer["noul"] as? Double,
                  (0...1).contains(score)
            else { throw Failure.malformedResponse }
            scores[id] = score
        }
        return scores
    }
}

/// Jev scores on disk, by file content, language and its grammar variant
/// (`.tsx` against `.ts`), rule version and model.
/// Only the scores are stored: never code, skeleton text or questions.
public struct JevScoreCache: Sendable {
    public let directory: URL
    private let ruleVersion: Int

    public static var defaultDirectory: URL {
        AIGuideModel.defaultDirectory.deletingLastPathComponent()
            .appendingPathComponent("overview-scores", isDirectory: true)
    }

    public init(directory: URL = JevScoreCache.defaultDirectory, ruleVersion: Int = SkeletonQuestions.ruleVersion) {
        self.directory = directory
        self.ruleVersion = ruleVersion
    }

    public func scores(contentHash: String, language: LanguageID, variant: String? = nil) -> [String: Double]? {
        guard let data = try? Data(contentsOf: fileURL(contentHash, language, variant)) else { return nil }
        return try? JSONDecoder().decode([String: Double].self, from: data)
    }

    public func save(_ scores: [String: Double], contentHash: String, language: LanguageID, variant: String? = nil) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(scores) else { return }
        try? data.write(to: fileURL(contentHash, language, variant), options: .atomic)
    }

    private func fileURL(_ contentHash: String, _ language: LanguageID, _ variant: String?) -> URL {
        // No variant keeps the key it had before variants counted.
        let key = ([contentHash, "\(language)", String(ruleVersion), SkeletonQuestions.model] + (variant.map { [$0] } ?? []))
            .joined(separator: "\n")
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }
}
