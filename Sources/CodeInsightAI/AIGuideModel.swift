import CryptoKit
import Foundation
import Observation

/// One window's file guides: shows the saved guide of the file in front and
/// writes a new one on request. A guide is saved by file content, so it shows
/// again while the file is unchanged and is marked out of date after.
@MainActor
@Observable
public final class AIGuideModel {
    public enum State: Equatable, Sendable {
        case idle
        case working
        case done
        case cancelled
        case failed(String)

        public var isRunning: Bool { self == .working }
    }

    public struct Guide: Sendable, Equatable, Codable {
        public let path: String
        /// SHA-256 of the file's bytes the guide was written from.
        public let contentHash: String
        public let promptVersion: String
        public let model: String
        public let draft: String
        public let createdAt: Date
    }

    /// The file in front, by project-relative path.
    public private(set) var path: String?
    /// The file's saved guide, if any; it may be out of date.
    public private(set) var guide: Guide?
    /// The file changed (or the format did) since `guide` was written.
    public private(set) var isStale = false
    /// The file a guide is being written for; it keeps going when another
    /// file comes to the front.
    public private(set) var runningPath: String?
    public private(set) var state = State.idle
    /// The file the last run was for; `state` is about it.
    public private(set) var statePath: String?
    public private(set) var steps: [AIToolStep] = []
    public private(set) var runningStep: AIToolStep?
    /// The snapshot the shown file is read from.
    public private(set) var snapshot: AISnapshot?

    @ObservationIgnored private let access: AIAccess
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var run: AIRun!
    @ObservationIgnored private var checked: GuideDraft?
    @ObservationIgnored private var runFile: (file: GuideFile, hash: String, model: String)?
    @ObservationIgnored private var nudged = false

    public init(
        helper: @escaping @MainActor () throws -> AIHelper? = { try AIHelper.shared() },
        settings: @escaping @MainActor () -> AIProviderSettings = { AIProviderSettings.load() },
        apiKey: @escaping @MainActor () -> String? = { AIKeychain.read() },
        hasKey: (@MainActor () -> Bool)? = nil,
        consent: AIConsentStore = AIConsentStore(),
        directory: URL = AIGuideModel.defaultDirectory
    ) {
        access = AIAccess(settings: settings, apiKey: apiKey, hasKey: hasKey ?? { AIKeychain.exists() }, consent: consent)
        self.directory = directory
        run = AIRun(
            helper: helper, tools: AITools.specs + [AIGuide.submitTool], maxRounds: AIGuide.maxRounds,
            answerAbove: AIConversationModel.answerAbove, trimAbove: AIConversationModel.trimAbove,
            whenOverBudget: "call submit_guide now with what you have read",
            terminal: AIRun.Terminal(name: "submit_guide") { [weak self] call in self?.check(call) }
        )
        run.update = { [weak self] in self?.apply($0) }
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cairn", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.cairn.Cairn", isDirectory: true)
            .appendingPathComponent("guides", isDirectory: true)
    }

    /// Whether a guide is being written for the file in front.
    public var isRunningHere: Bool { runningPath != nil && runningPath == path }

    public func blocker(project: URL?) -> AIAccess.Blocker? {
        access.blocker(project: snapshot?.root ?? project, helperConnected: run.connectedHelper != nil)
    }

    public func allowSending(project: URL) { access.allow(project) }

    /// Brings `path` of `snapshot` to the front and loads its saved guide.
    public func show(path: String, in snapshot: AISnapshot) {
        self.path = path
        self.snapshot = snapshot
        guide = nil
        isStale = false
        guard let saved = try? Data(contentsOf: fileURL(project: snapshot.root, path: path)),
              let decoded = try? JSONDecoder().decode(Guide.self, from: saved)
        else { return }
        guide = decoded
        let current = (try? snapshot.bytes(of: path)).map(Self.hash)
        isStale = decoded.contentHash != current || decoded.promptVersion != AIGuide.promptVersion
    }

    /// No file in front (a run for another file keeps going).
    public func showNothing() {
        path = nil
        snapshot = nil
        guide = nil
        isStale = false
    }

    /// Writes a guide for the file in front. The caller checks `blocker` first.
    public func generate(language: String) {
        guard let path, let snapshot, runningPath == nil else { return }
        statePath = path
        let file: GuideFile
        let bytes: [UInt8]
        do {
            file = try GuideFile(path: path, in: snapshot)
            bytes = try snapshot.bytes(of: path)
        } catch {
            state = .failed(String(describing: error))
            return
        }
        runningPath = path
        runFile = (file, Self.hash(bytes), access.settings().model)
        state = .working
        steps = []
        runningStep = nil
        checked = nil
        nudged = false
        run.reset()
        run.ask(AIGuide.request(for: file, language: language), in: snapshot, system: AIGuide.system,
                config: access.helperConfig)
    }

    public func cancel() {
        guard run.cancel() else { return }
        finish(.cancelled)
    }

    private func check(_ call: AIToolCall) -> String? {
        guard let runFile else { return "error: nothing is being written" }
        let draft = (try? JSONSerialization.jsonObject(with: call.arguments) as? [String: Any])?["draft"] as? String ?? ""
        let (parsed, errors) = GuideDraft.check(draft, in: runFile.file)
        guard errors.isEmpty else {
            return "error: the draft has \(errors.count) problem\(errors.count == 1 ? "" : "s"):\n"
                + errors.joined(separator: "\n") + "\nFix only these lines and call submit_guide again with the whole draft."
        }
        checked = parsed
        return nil
    }

    private func apply(_ update: AIRun.Update) {
        switch update {
        case .text, .tools:
            break
        case .stepStarted(let step):
            runningStep = step
        case .stepFinished(let step, _):
            runningStep = nil
            steps.append(step)
        case .submitted(let call):
            guard let runFile, let runningPath, let snapshot,
                  let draft = (try? JSONSerialization.jsonObject(with: call.arguments) as? [String: Any])?["draft"] as? String
            else { return finish(.failed("noDraft")) }
            let written = Guide(path: runningPath, contentHash: runFile.hash, promptVersion: AIGuide.promptVersion,
                                model: runFile.model, draft: draft, createdAt: Date())
            save(written, project: snapshot.root)
            if path == runningPath {
                guide = written
                isStale = false
            }
            finish(.done)
        case .done:
            // The model wrote its answer as text instead of handing it in.
            guard !nudged, let snapshot else { return finish(.failed("noDraft")) }
            nudged = true
            run.ask("You ended without handing in the guide. Call submit_guide with the whole draft now.",
                    in: snapshot, system: AIGuide.system, config: access.helperConfig)
        case .failed(let message):
            finish(.failed(message))
        }
    }

    private func finish(_ state: State) {
        self.state = state
        runningStep = nil
        runningPath = nil
        runFile = nil
        run.reset()
    }

    static func hash(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(project: URL, path: String) -> URL {
        let key = Self.hash(Array((project.resolvingSymlinksInPath().standardizedFileURL.path + "\n" + path).utf8))
        return directory.appendingPathComponent(key + ".json")
    }

    private func save(_ guide: Guide, project: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(guide) else { return }
        try? data.write(to: fileURL(project: project, path: guide.path), options: .atomic)
    }
}
