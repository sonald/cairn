import CodeInsightCore
import CodeInsightExact
import CodeInsightGit
import Foundation
import Observation

public enum ExactOrigin: Equatable, Sendable {
    case worktree
    case materialized(commitOID: String)
}

/// ExactCoordinator maps locations inside the project/materialized root to
/// relative paths before models see them. RustAnalyzerProvider leaves
/// dependency locations absolute. Review every caller if that convention changes.
public func exactLocationIsInDependency(_ file: String) -> Bool {
    file.hasPrefix("/")
}

public struct ExactOverlay: Sendable {
    public struct ReuseKey: Hashable, Sendable {
        public let versionIdentity: String
        public let language: LanguageID
        public let analysisProfileID: AnalysisProfileID
        public let configFingerprint: String
        public let environmentFingerprint: String
        public let featureSelection: FeatureSelection
        public let trustMode: TrustMode
        public let toolVersion: String

        public init(
            versionIdentity: String,
            language: LanguageID,
            analysisProfileID: AnalysisProfileID,
            configFingerprint: String,
            environmentFingerprint: String,
            featureSelection: FeatureSelection,
            trustMode: TrustMode,
            toolVersion: String
        ) {
            self.versionIdentity = versionIdentity
            self.language = language
            self.analysisProfileID = analysisProfileID
            self.configFingerprint = configFingerprint
            self.environmentFingerprint = environmentFingerprint
            self.featureSelection = featureSelection
            self.trustMode = trustMode
            self.toolVersion = toolVersion
        }
    }

    public struct Entry: Sendable {
        public let location: ExactLocation
        public let attribution: ExactAttribution
        public let origin: ExactOrigin

        public init(
            location: ExactLocation,
            attribution: ExactAttribution,
            origin: ExactOrigin
        ) {
            self.location = location
            self.attribution = attribution
            self.origin = origin
        }
    }

    private struct Position: Hashable, Sendable {
        let file: String
        let byteOffset: Int
    }

    private var definitions: [ReuseKey: [Position: [Entry]]] = [:]

    public init() {}

    public func definition(
        for key: ReuseKey,
        file: String,
        byteOffset: Int
    ) -> [Entry]? {
        definitions[key]?[Position(file: file, byteOffset: byteOffset)]
    }

    public mutating func store(
        _ entries: [Entry],
        for key: ReuseKey,
        file: String,
        byteOffset: Int
    ) {
        definitions[key, default: [:]][Position(
            file: file,
            byteOffset: byteOffset
        )] = entries
    }
}

@MainActor
@Observable
public final class ExactCoordinator {
    public enum Readiness: Equatable, Sendable {
        case preparing
        case ready
        case unavailable(String)
        case off(String)
    }

    public typealias ProviderFactory = @Sendable (
        URL,
        LanguageID
    ) throws -> any ExactProvider
    public typealias SnapshotFactory = @Sendable (
        URL,
        String?
    ) throws -> any Snapshot

    enum RelationQueryResult: Sendable {
        case unsupported
        case notApplicable
        case relations(
            [Relation],
            origin: ExactOrigin,
            attribution: ExactAttribution
        )
    }

    public enum DefinitionResult: Sendable {
        case completed([ExactOverlay.Entry])
        case cancelled
        case unavailable(String)
    }

    struct Relation: Sendable {
        let name: String?
        let location: ExactLocation
        let item: ExactCallHierarchyItem?
        let callSites: [ExactLocation]
    }

    private enum RawRelationQueryResult: Sendable {
        case unsupported
        case notApplicable
        case calls([ExactCallRelation])
        case locations([ExactLocation])
    }

    private struct Active: Sendable {
        let generation: UInt64
        let key: ExactOverlay.ReuseKey
        let provider: any ExactProvider
        let session: any ExactSession
        let providerSnapshot: any Snapshot
        let profile: ExactProfileKey
        let trustMode: TrustMode
        let workspaceRoot: URL
        let profilePrefix: String
        let materializedRoot: URL?
    }

    private struct ProfileSnapshot: Snapshot {
        let snapshotID: SnapshotID
        let objectFormat: GitObjectFormat
        let sourceKind: SourceKind
        let projectRootName: String
        let configurationPaths: [String]
        private let wrapped: any Snapshot
        private let prefix: String

        init?(_ wrapped: any Snapshot, prefix: String) {
            guard !prefix.isEmpty else { return nil }
            self.wrapped = wrapped
            self.prefix = prefix
            snapshotID = wrapped.snapshotID
            objectFormat = wrapped.objectFormat
            sourceKind = wrapped.sourceKind
            projectRootName = wrapped.projectRootName
            configurationPaths = wrapped.configurationPaths.filter {
                $0.hasPrefix("\(prefix)/")
            }.map { String($0.dropFirst(prefix.count + 1)) }
        }

        func listFiles() -> [(
            path: String,
            contentID: ContentID,
            fileMode: FileMode
        )] {
            wrapped.listFiles().filter { file in
                file.path.hasPrefix("\(prefix)/")
            }.map { file in
                (
                    String(file.path.dropFirst(prefix.count + 1)),
                    file.contentID,
                    file.fileMode
                )
            }
        }

        func readBytes(path: String) throws -> [UInt8] {
            try wrapped.readBytes(path: "\(prefix)/\(path)")
        }
    }

    private struct Prepared: Sendable {
        let active: Active
    }

    public private(set) var readiness: Readiness = .off("no project")
    public private(set) var analysisEnvironment: ExactAnalysisEnvironment?
    public private(set) var trustMode: TrustMode?
    public private(set) var trustedRepositories: [TrustedRepository] = []
    public var attribution: ExactAttribution? { active?.session.attribution }

    @ObservationIgnored private let providerFactory: ProviderFactory
    @ObservationIgnored private let snapshotFactory: SnapshotFactory?
    @ObservationIgnored private let sandboxAvailable: @Sendable () -> Bool
    @ObservationIgnored private let trustRegistry: TrustRegistry
    @ObservationIgnored private let materializer: Materializer
    @ObservationIgnored private var overlay = ExactOverlay()
    private var active: Active?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var expectedGeneration: UInt64 = 0
    @ObservationIgnored private var closeTask: Task<Void, Never>?

    public init(
        providerFactory: @escaping ProviderFactory = { projectURL, language in
            switch language {
            case .python:
                guard let executable = PyrightProvider.findExecutable(
                    projectURL: projectURL
                ) else {
                    throw ExactError.unavailable(
                        "pyright-langserver is not installed"
                    )
                }
                return try PyrightProvider(
                    projectURL: projectURL,
                    executableURL: executable
                )
            case .rust:
                break
            case .typescript:
                guard let node = TypeScriptLanguageServerProvider
                    .findExecutable(
                        named: "node",
                        projectURL: projectURL
                    ),
                    let languageServer = TypeScriptLanguageServerProvider
                        .findExecutable(
                            named: "typescript-language-server",
                            projectURL: projectURL
                        )
                else {
                    throw ExactError.unavailable(
                        "typescript-language-server is not installed"
                    )
                }
                let tsserver = TypeScriptLanguageServerProvider
                    .findExecutable(
                        named: "tsserver.js",
                        projectURL: projectURL
                    )
                    ?? TypeScriptLanguageServerProvider.tsserverURL(
                        fromLanguageServer: languageServer
                    )
                    ?? [
                        "/opt/homebrew/lib/node_modules/typescript/lib/tsserver.js",
                        "/usr/local/lib/node_modules/typescript/lib/tsserver.js",
                    ].first { FileManager.default.isReadableFile(atPath: $0) }
                    .map(URL.init(fileURLWithPath:))
                guard let tsserver else {
                    throw ExactError.unavailable(
                        "typescript-language-server is not installed"
                    )
                }
                return try TypeScriptLanguageServerProvider(
                    projectURL: projectURL,
                    nodeURL: node,
                    languageServerURL: languageServer,
                    tsserverURL: tsserver
                )
            case .javascript:
                throw CocoaError(.featureUnsupported, userInfo: [
                    NSLocalizedFailureReasonErrorKey:
                        "Exact analysis does not support "
                            + String(describing: language),
                ])
            }
            guard let executable = RustAnalyzerProvider.findExecutable() else {
                throw ExactError.unavailable("rust-analyzer is not installed")
            }
            return try RustAnalyzerProvider(
                projectURL: projectURL,
                executableURL: executable
            )
        },
        snapshotFactory: SnapshotFactory? = nil,
        sandboxAvailable: @escaping @Sendable () -> Bool = {
            FileManager.default.isExecutableFile(
                atPath: "/usr/bin/sandbox-exec"
            )
        },
        trustRegistry: TrustRegistry = TrustRegistry(),
        materializer: Materializer = Materializer()
    ) {
        self.providerFactory = providerFactory
        self.snapshotFactory = snapshotFactory
        self.sandboxAvailable = sandboxAvailable
        self.trustRegistry = trustRegistry
        self.materializer = materializer
    }

    public convenience init(
        providerFactory legacyProviderFactory: @escaping @Sendable (
            URL
        ) throws -> any ExactProvider,
        snapshotFactory: SnapshotFactory? = nil,
        sandboxAvailable: @escaping @Sendable () -> Bool = {
            FileManager.default.isExecutableFile(
                atPath: "/usr/bin/sandbox-exec"
            )
        },
        trustRegistry: TrustRegistry = TrustRegistry(),
        materializer: Materializer = Materializer()
    ) {
        let providerFactory: ProviderFactory
        providerFactory = { projectURL, language in
            try validateExactLanguage(language)
            return try legacyProviderFactory(projectURL)
        }
        self.init(
            providerFactory: providerFactory,
            snapshotFactory: snapshotFactory,
            sandboxAvailable: sandboxAvailable,
            trustRegistry: trustRegistry,
            materializer: materializer
        )
    }

    public func invalidate(generation: UInt64) {
        epoch &+= 1
        expectedGeneration = generation
        let previousClose = closeTask
        let previousPrepare = prepareTask
        let oldSession = active?.session
        oldSession?.cancel()
        prepareTask?.cancel()
        prepareTask = nil
        if previousClose != nil || previousPrepare != nil || oldSession != nil {
            closeTask = Task.detached(priority: .utility) {
                await previousClose?.value
                await previousPrepare?.value
                if let oldSession {
                    oldSession.close()
                }
            }
        } else {
            closeTask = nil
        }
        active = nil
        readiness = .preparing
        analysisEnvironment = nil
        trustMode = nil
    }

    public func shutdown() {
        epoch &+= 1
        prepareTask?.cancel()
        prepareTask = nil
        closeTask?.cancel()
        closeTask = nil
        let oldSession = active?.session
        active = nil
        oldSession?.cancel()
        oldSession?.close()
        readiness = .off("application terminating")
        analysisEnvironment = nil
        trustMode = nil
    }

    func cancel(batch: ExactRequestBatch) {
        batch.cancel()
        active?.session.cancel(batch: batch)
    }

    public func prepare(
        projectURL: URL,
        revision: String?,
        featureSelection: FeatureSelection = .defaultFeatures,
        generation: UInt64
    ) {
        prepareSupported(
            projectURL: projectURL,
            revision: revision,
            analysisProfile: AnalysisProfile(
                language: .rust,
                projectRoot: PathID(rawValue: 0),
                projectUnitName: ".",
                configFingerprint: "",
                environmentFingerprint: "",
                featureSelection: featureSelection,
                featureNames: [],
                edition: nil,
                trustMode: .safe
            ),
            profileRoot: "",
            verifyProfileMatches: false,
            generation: generation
        )
    }

    public func prepare(
        projectURL: URL,
        revision: String?,
        analysisProfile: AnalysisProfile,
        generation: UInt64
    ) throws {
        try prepare(
            projectURL: projectURL,
            revision: revision,
            analysisProfile: analysisProfile,
            profileRoot: ".",
            generation: generation
        )
    }

    public func prepare(
        projectURL: URL,
        revision: String?,
        analysisProfile: AnalysisProfile,
        profileRoot: String,
        generation: UInt64
    ) throws {
        try validateExactLanguage(analysisProfile.language)
        let profilePrefix = try exactProfilePrefix(profileRoot)
        prepareSupported(
            projectURL: projectURL,
            revision: revision,
            analysisProfile: analysisProfile,
            profileRoot: profilePrefix,
            verifyProfileMatches: true,
            generation: generation
        )
    }

    private func prepareSupported(
        projectURL: URL,
        revision: String?,
        analysisProfile: AnalysisProfile,
        profileRoot: String,
        verifyProfileMatches: Bool,
        generation: UInt64
    ) {
        let root = projectURL.standardizedFileURL
        let language = analysisProfile.language
        let featureSelection = analysisProfile.featureSelection
        let profilePrefix = profileRoot
        invalidate(generation: generation)
        let currentEpoch = epoch
        let verifyProfileMatches = verifyProfileMatches
        let providerFactory = providerFactory
        let snapshotFactory = snapshotFactory
        let sandboxAvailable = sandboxAvailable
        let trustRegistry = trustRegistry
        let materializer = materializer

        let priorClose = closeTask
        prepareTask = Task { [weak self] in
            await priorClose?.value
            guard let self else { return }
            let currentEpoch = currentEpoch
            let generation = generation
            guard self.epoch == currentEpoch else { return }
            let trustMode = await trustRegistry.query(root) ?? .safe
            let trustedRepositories = await trustRegistry.trustedRepositories()
            guard self.epoch == currentEpoch,
                  self.expectedGeneration == generation,
                  !Task.isCancelled
            else { return }
            self.trustedRepositories = trustedRepositories
            self.trustMode = trustMode
            guard trustMode != .safe || sandboxAvailable() else {
                self.readiness = .off("Safe exact disabled: sandbox-exec unavailable")
                self.prepareTask = nil
                return
            }

            do {
                let prepared = try await Task.detached(priority: .utility) {
                    let snapshot: any Snapshot = if let snapshotFactory {
                        try snapshotFactory(root, revision)
                    } else {
                        try makeSnapshot(
                            root: root,
                            revision: revision,
                            language: language
                        )
                    }
                    let profile: ExactProfileKey
                    let providerRoot: URL
                    let materializedRoot: URL?
                    let versionIdentity: String
                    if let commit = snapshot as? CommitSnapshot {
                        profile = try ExactProfileKey(
                            snapshot: commit,
                            language: language,
                            featureSelection: featureSelection,
                            pathPrefix: profilePrefix
                        )
                        if verifyProfileMatches {
                            try validateProfile(
                                profile,
                                matches: analysisProfile,
                                language: language
                            )
                        }
                        let resolvedWorkspaceRoot = try materializer.materialize(
                            commit,
                            configFingerprint: profile.configFingerprint
                        ).url
                        materializedRoot = resolvedWorkspaceRoot
                        providerRoot = profileRootURL(
                            workspaceRoot: resolvedWorkspaceRoot,
                            prefix: profilePrefix
                        )
                        versionIdentity = commit.commitOID.hex
                    } else {
                        profile = try ExactProfileKey(
                            snapshot: snapshot,
                            language: language,
                            featureSelection: featureSelection,
                            pathPrefix: profilePrefix
                        )
                        if verifyProfileMatches {
                            try validateProfile(
                                profile,
                                matches: analysisProfile,
                                language: language
                            )
                        }
                        providerRoot = profileRootURL(
                            workspaceRoot: root,
                            prefix: profilePrefix
                        )
                        materializedRoot = nil
                        versionIdentity =
                            "worktree:\(providerRoot.resolvingSymlinksInPath().path)"
                    }
                    let provider = try providerFactory(providerRoot, language)
                    guard provider.language == language else {
                        throw ExactError.unavailable(
                            "exact provider language "
                                + "\(String(describing: provider.language)) does not match "
                                + "analysis profile language \(String(describing: language))"
                        )
                    }
                    let key = ExactOverlay.ReuseKey(
                        versionIdentity: versionIdentity,
                        language: language,
                        analysisProfileID: analysisProfile.id,
                        configFingerprint: profile.configFingerprint,
                        environmentFingerprint: profile.environmentFingerprint,
                        featureSelection: profile.featureSelection,
                        trustMode: trustMode,
                        toolVersion: provider.toolVersion
                    )
                    let providerSnapshot = ProfileSnapshot(
                        snapshot,
                        prefix: profilePrefix
                    ) ?? snapshot
                    let session = try provider.prepare(
                        snapshot: providerSnapshot,
                        profile: profile,
                        trustMode: trustMode
                    )
                    return Prepared(active: Active(
                        generation: generation,
                        key: key,
                        provider: provider,
                        session: session,
                        providerSnapshot: providerSnapshot,
                        profile: profile,
                        trustMode: trustMode,
                        workspaceRoot: root,
                        profilePrefix: profilePrefix,
                        materializedRoot: materializedRoot
                    ))
                }.value
                guard self.epoch == currentEpoch,
                  self.expectedGeneration == generation,
                  !Task.isCancelled
                else {
                    await Task.detached { prepared.active.session.close() }.value
                    return
                }
                self.active = prepared.active
                self.observeEnvironment(from: prepared.active)
                self.analysisEnvironment = prepared.active.session.attribution.environment
                switch prepared.active.session.readiness {
                case .unavailable(let reason):
                    self.readiness = .unavailable(reason)
                case .closed:
                    self.readiness = .unavailable("exact session closed during prepare")
                case .preparing, .ready:
                    self.readiness = .ready
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.epoch == currentEpoch,
                      self.expectedGeneration == generation
                else { return }
                self.readiness = trustMode == .safe && isSandboxUnavailable(error)
                    ? .off("Safe exact disabled: \(error)")
                    : .unavailable(String(describing: error))
            }
            if self.epoch == currentEpoch { self.prepareTask = nil }
        }
    }

    public func refreshTrust() async {
        trustedRepositories = await trustRegistry.trustedRepositories()
    }

    public func grantTrust(
        _ repositoryURL: URL,
        grantedAt: Date = Date()
    ) async throws {
        try await trustRegistry.grant(
            repositoryURL,
            mode: .trusted,
            grantedAt: grantedAt
        )
        await refreshTrust()
    }

    public func revokeTrust(_ repositoryURL: URL) async throws {
        try await trustRegistry.revoke(repositoryURL)
        await refreshTrust()
    }

    public func clearMaterializedCache() async throws {
        epoch &+= 1
        let previousClose = closeTask
        let previousPrepare = prepareTask
        prepareTask?.cancel()
        prepareTask = nil
        let oldSession = active?.session
        active = nil
        oldSession?.cancel()
        readiness = .off("materialized cache cleared")
        analysisEnvironment = nil
        trustMode = nil
        let materializer = materializer
        await previousClose?.value
        await previousPrepare?.value
        try await Task.detached(priority: .utility) {
            if let oldSession {
                oldSession.close()
            }
            try materializer.clear()
        }.value
    }

    func isTrusted(_ repositoryURL: URL) -> Bool {
        let path = repositoryURL.resolvingSymlinksInPath().standardizedFileURL.path
        return trustedRepositories.contains { $0.path == path }
    }

    public func definition(
        file: String,
        byteOffset: UInt32,
        generation: UInt64,
        batch: ExactRequestBatch? = nil
    ) async -> DefinitionResult? {
        if let prepareTask { await prepareTask.value }
        guard batch?.isCurrent != false else { return .cancelled }
        guard expectedGeneration == generation else { return nil }
        guard let current = active else {
            return .unavailable(String(describing: readiness))
        }
        guard current.generation == generation else { return nil }
        guard let requestFile = providerRelativeRequestPath(
            file: file,
            source: current
        ) else {
            return .completed([])
        }
        let offset = Int(byteOffset)
        if let cached = overlay.definition(
            for: current.key,
            file: file,
            byteOffset: offset
        ) {
            return .completed(cached)
        }

        do {
            let result = try await request(
                session: current.session,
                file: requestFile,
                byteOffset: offset,
                batch: batch
            )
            guard batch?.isCurrent != false else { return .cancelled }
            return publish(
                result,
                from: current,
                file: file,
                byteOffset: offset
            )
        } catch where isHelperCrash(error)
            && !isUnavailable(current.session.readiness)
        {
            return await restartOnce(
                current,
                file: requestFile,
                byteOffset: offset,
                batch: batch
            )
        } catch {
            guard isCurrent(current) else { return nil }
            if isUnavailable(current.session.readiness) {
                readiness = .unavailable(String(describing: error))
            }
            return .unavailable(String(describing: error))
        }
    }

    func relations(
        file: String,
        byteOffset: UInt32,
        item: ExactCallHierarchyItem?,
        direction: RelationTreeModel.Direction,
        generation: UInt64,
        batch: ExactRequestBatch? = nil
    ) async -> RelationQueryResult? {
        if let prepareTask { await prepareTask.value }
        guard batch?.isCurrent != false,
              expectedGeneration == generation,
              let current = active,
              current.generation == generation
        else { return nil }
        guard let requestFile = providerRelativeRequestPath(
            file: file,
            source: current
        ) else { return nil }

        do {
            let result = try await requestRelations(
                session: current.session,
                file: requestFile,
                byteOffset: Int(byteOffset),
                item: item,
                direction: direction,
                batch: batch
            )
            guard batch?.isCurrent != false else { return nil }
            return publish(result, from: current)
        } catch where isHelperCrash(error)
            && !isUnavailable(current.session.readiness)
        {
            return await restartRelationsOnce(
                current,
                file: requestFile,
                byteOffset: Int(byteOffset),
                item: item,
                direction: direction,
                batch: batch
            )
        } catch {
            guard isCurrent(current) else { return nil }
            if isUnavailable(current.session.readiness) {
                readiness = .unavailable(String(describing: error))
            }
            return nil
        }
    }

    private func restartOnce(
        _ previous: Active,
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch?
    ) async -> DefinitionResult? {
        guard batch?.isCurrent != false else { return .cancelled }
        guard isCurrent(previous) else { return nil }
        readiness = .preparing
        try? await Task.sleep(for: .milliseconds(100))
        guard batch?.isCurrent != false else { return .cancelled }
        guard isCurrent(previous) else { return nil }

        do {
            let newSession = try await Task.detached(priority: .utility) {
                try previous.provider.prepare(
                    snapshot: previous.providerSnapshot,
                    profile: previous.profile,
                    trustMode: previous.trustMode
                )
            }.value
            guard batch?.isCurrent != false, isCurrent(previous) else {
                await Task.detached { newSession.close() }.value
                return batch?.isCurrent == false ? .cancelled : nil
            }
            let restarted = Active(
                generation: previous.generation,
                key: previous.key,
                provider: previous.provider,
                session: newSession,
                providerSnapshot: previous.providerSnapshot,
                profile: previous.profile,
                trustMode: previous.trustMode,
                workspaceRoot: previous.workspaceRoot,
                profilePrefix: previous.profilePrefix,
                materializedRoot: previous.materializedRoot
            )
            active = restarted
            observeEnvironment(from: restarted)
            analysisEnvironment = newSession.attribution.environment
            Task.detached { previous.session.close() }

            do {
                let result = try await request(
                    session: newSession,
                    file: file,
                    byteOffset: byteOffset,
                    batch: batch
                )
                guard batch?.isCurrent != false else { return .cancelled }
                return publish(
                    result,
                    from: restarted,
                    file: file,
                    byteOffset: byteOffset
                )
            } catch {
                guard batch?.isCurrent != false, isCurrent(restarted) else {
                    return batch?.isCurrent == false ? .cancelled : nil
                }
                readiness = .unavailable(
                    "exact helper restart exhausted: \(error)"
                )
                return .unavailable("exact helper restart exhausted: \(error)")
            }
        } catch {
            guard batch?.isCurrent != false, isCurrent(previous) else { return nil }
            readiness = .unavailable("exact helper restart failed: \(error)")
            return .unavailable("exact helper restart failed: \(error)")
        }
    }

    private func request(
        session: any ExactSession,
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch?
    ) async throws -> ExactDefinitionQueryResult {
        try await Task.detached(priority: .userInitiated) {
            if let batch {
                try session.definition(
                    file: file,
                    byteOffset: byteOffset,
                    batch: batch
                )
            } else {
                try session.definition(file: file, byteOffset: byteOffset)
            }
        }.value
    }

    private func requestRelations(
        session: any ExactSession,
        file: String,
        byteOffset: Int,
        item: ExactCallHierarchyItem?,
        direction: RelationTreeModel.Direction,
        batch: ExactRequestBatch?
    ) async throws -> RawRelationQueryResult {
        try await Task.detached(priority: .userInitiated) {
            switch direction {
            case .references:
                guard session.negotiatedCapabilities.contains(.references)
                else { return .unsupported }
                let locations = if let batch {
                    try session.references(
                        file: file,
                        byteOffset: byteOffset,
                        includeDeclaration: false,
                        batch: batch
                    ) ?? []
                } else {
                    try session.references(
                        file: file,
                        byteOffset: byteOffset,
                        includeDeclaration: false
                    ) ?? []
                }
                return .locations(locations)
            case .implementations:
                guard session.negotiatedCapabilities.contains(.implementations)
                else { return .unsupported }
                let locations = if let batch {
                    try session.implementations(
                        file: file,
                        byteOffset: byteOffset,
                        batch: batch
                    ) ?? []
                } else {
                    try session.implementations(
                        file: file,
                        byteOffset: byteOffset
                    ) ?? []
                }
                return .locations(locations)
            case .callers, .calls:
                guard session.negotiatedCapabilities.contains(.callHierarchy)
                else { return .unsupported }
                let items: [ExactCallHierarchyItem]
                if let item {
                    items = [item]
                } else {
                    let prepared = if let batch {
                        try session.prepareCallHierarchy(
                            file: file,
                            byteOffset: byteOffset,
                            batch: batch
                        )
                    } else {
                        try session.prepareCallHierarchy(
                            file: file,
                            byteOffset: byteOffset
                        )
                    }
                    guard let prepared, !prepared.isEmpty
                    else { return .notApplicable }
                    items = prepared
                }
                var relations: [ExactCallRelation] = []
                for item in items {
                    switch direction {
                    case .callers:
                        if let batch {
                            relations += try session.incomingCalls(
                                item: item,
                                batch: batch
                            ) ?? []
                        } else {
                            relations += try session.incomingCalls(item: item) ?? []
                        }
                    case .calls:
                        if let batch {
                            relations += try session.outgoingCalls(
                                item: item,
                                batch: batch
                            ) ?? []
                        } else {
                            relations += try session.outgoingCalls(item: item) ?? []
                        }
                    case .implementations:
                        break
                    case .references:
                        break
                    }
                }
                return .calls(relations)
            }
        }.value
    }

    private func restartRelationsOnce(
        _ previous: Active,
        file: String,
        byteOffset: Int,
        item: ExactCallHierarchyItem?,
        direction: RelationTreeModel.Direction,
        batch: ExactRequestBatch?
    ) async -> RelationQueryResult? {
        guard batch?.isCurrent != false, isCurrent(previous) else { return nil }
        readiness = .preparing
        try? await Task.sleep(for: .milliseconds(100))
        guard batch?.isCurrent != false, isCurrent(previous) else { return nil }

        do {
            let newSession = try await Task.detached(priority: .utility) {
                try previous.provider.prepare(
                    snapshot: previous.providerSnapshot,
                    profile: previous.profile,
                    trustMode: previous.trustMode
                )
            }.value
            guard batch?.isCurrent != false, isCurrent(previous) else {
                await Task.detached { newSession.close() }.value
                return nil
            }
            let restarted = Active(
                generation: previous.generation,
                key: previous.key,
                provider: previous.provider,
                session: newSession,
                providerSnapshot: previous.providerSnapshot,
                profile: previous.profile,
                trustMode: previous.trustMode,
                workspaceRoot: previous.workspaceRoot,
                profilePrefix: previous.profilePrefix,
                materializedRoot: previous.materializedRoot
            )
            active = restarted
            observeEnvironment(from: restarted)
            analysisEnvironment = newSession.attribution.environment
            Task.detached { previous.session.close() }

            do {
                let result = try await requestRelations(
                    session: newSession,
                    file: file,
                    byteOffset: byteOffset,
                    item: item,
                    direction: direction,
                    batch: batch
                )
                guard batch?.isCurrent != false else { return nil }
                return publish(result, from: restarted)
            } catch {
                guard batch?.isCurrent != false, isCurrent(restarted) else {
                    return nil
                }
                readiness = .unavailable(
                    "exact helper restart exhausted: \(error)"
                )
                return nil
            }
        } catch {
            guard batch?.isCurrent != false, isCurrent(previous) else { return nil }
            readiness = .unavailable("exact helper restart failed: \(error)")
            return nil
        }
    }

    private func publish(
        _ result: ExactDefinitionQueryResult,
        from source: Active,
        file: String,
        byteOffset: Int
    ) -> DefinitionResult? {
        guard isCurrent(source) else { return nil }
        if case .cancelled = result { return .cancelled }
        if case .unavailable(let reason) = result { return .unavailable(reason) }
        readiness = .ready
        analysisEnvironment = analysisEnvironment
            ?? source.session.attribution.environment
        guard case .completed(let targets) = result else { return nil }
        let entries = targets.compactMap { target -> ExactOverlay.Entry? in
            guard let workspaceLocation = providerAdmissibleLocation(
                location: target.location,
                source: source
            ) else { return nil }
            guard supportedTarget(
                file: workspaceLocation.file,
                language: source.profile.language
            )
            else { return nil }
            return ExactOverlay.Entry(
                location: workspaceLocation,
                attribution: source.session.attribution,
                origin: source.materializedRoot != nil
                    ? .materialized(commitOID: source.key.versionIdentity)
                    : .worktree
            )
        }
        overlay.store(entries, for: source.key, file: file, byteOffset: byteOffset)
        return .completed(entries)
    }

    private func publish(
        _ result: RawRelationQueryResult,
        from source: Active
    ) -> RelationQueryResult? {
        guard isCurrent(source) else { return nil }
        readiness = .ready
        let environment = analysisEnvironment
            ?? source.session.attribution.environment
        analysisEnvironment = environment
        let origin: ExactOrigin = source.materializedRoot != nil
            ? .materialized(commitOID: source.key.versionIdentity)
            : .worktree
        let value: RelationQueryResult
        switch result {
        case .unsupported:
            value = .unsupported
        case .notApplicable:
            value = .notApplicable
        case .calls(let relations):
            var foreignDropped = false
            let mapped = relations.compactMap { raw -> Relation? in
                guard let itemLocation = providerAdmissibleLocation(
                    location: raw.item.selectionRange,
                    source: source
                ) else { return nil }
                if !supportedTarget(
                    file: itemLocation.file,
                    language: source.profile.language
                ) {
                    foreignDropped = true
                    return nil
                }
                let callSites = raw.callSites.compactMap {
                    providerAdmissibleLocation(location: $0, source: source)
                }.filter { location in
                    if !supportedTarget(
                        file: location.file,
                        language: source.profile.language
                    ) {
                        foreignDropped = true
                        return false
                    }
                    return true
                }
                return Relation(
                    name: raw.item.name,
                    location: itemLocation,
                    item: raw.item,
                    callSites: callSites
                )
            }
            value = foreignDropped
                ? .unsupported
                : .relations(mapped, origin: origin, attribution: source.session.attribution)
        case .locations(let locations):
            var foreignDropped = false
            let mapped = locations.compactMap { location -> Relation? in
                guard let itemLocation = providerAdmissibleLocation(
                    location: location,
                    source: source
                ) else { return nil }
                if !supportedTarget(
                    file: itemLocation.file,
                    language: source.profile.language
                ) {
                    foreignDropped = true
                    return nil
                }
                return Relation(
                    name: nil,
                    location: itemLocation,
                    item: nil,
                    callSites: []
                )
            }
            value = foreignDropped
                ? .unsupported
                : .relations(mapped, origin: origin, attribution: source.session.attribution)
        }
        return value
    }

    private func observeEnvironment(from source: Active) {
        let generation = source.generation
        let sessionID = ObjectIdentifier(source.session)
        source.session.onEnvironmentChange = { [weak self] environment in
            Task { @MainActor [weak self] in
                guard let self,
                      self.expectedGeneration == generation,
                      let active = self.active,
                      active.generation == generation,
                      ObjectIdentifier(active.session) == sessionID
                else { return }
                self.analysisEnvironment = environment
            }
        }
    }

    private func providerRelativeRequestPath(
        file: String,
        source: Active
    ) -> String? {
        guard !file.hasPrefix("/") else { return nil }
        guard safeRelativeComponents(file) else { return nil }
        guard !source.profilePrefix.isEmpty else { return file }
        return file.hasPrefix("\(source.profilePrefix)/")
            ? String(file.dropFirst(source.profilePrefix.count + 1))
            : nil
    }

    private func providerAdmissibleLocation(
        location: ExactLocation,
        source: Active
    ) -> ExactLocation? {
        let file: String
        if location.file.hasPrefix("/") {
            var mappedUnderWorkspace: String?
            let roots = [
                source.materializedRoot,
                source.workspaceRoot,
            ].compactMap { $0 }
            for root in roots {
                if let path = try? Materializer.snapshotPath(
                    for: URL(fileURLWithPath: location.file),
                    under: root
                ) {
                    mappedUnderWorkspace = path
                    break
                }
            }
            if let path = mappedUnderWorkspace {
                guard source.profilePrefix.isEmpty
                    || path.hasPrefix("\(source.profilePrefix)/")
                else {
                    return nil
                }
                file = path
            } else {
                file = location.file
            }
        } else {
            guard safeRelativeComponents(location.file) else { return nil }
            let prefix = source.profilePrefix
            file = !prefix.isEmpty
                && location.file.hasPrefix("\(prefix)/")
                ? location.file
                : prefix.isEmpty ? location.file : "\(prefix)/\(location.file)"
        }
        return ExactLocation(
            file: file,
            byteOffset: location.byteOffset,
            line: location.line,
            column: location.column
        )
    }

    private func safeRelativeComponents(
        _ file: String
    ) -> Bool {
        !file.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).contains { $0 == "." || $0 == ".." || $0.isEmpty }
    }

    private func isCurrent(_ candidate: Active) -> Bool {
        expectedGeneration == candidate.generation
            && active?.generation == candidate.generation
            && active?.key == candidate.key
            && active?.session === candidate.session
    }
}

private func isUnavailable(_ readiness: ExactReadiness) -> Bool {
    if case .unavailable = readiness { return true }
    return false
}

private func isHelperCrash(_ error: any Error) -> Bool {
    guard let error = error as? LSPError else { return false }
    return switch error {
    case .connectionClosed, .processExited:
        true
    default:
        false
    }
}

private func isSandboxUnavailable(_ error: any Error) -> Bool {
    guard case let ExactError.unavailable(detail) = error else { return false }
    return detail.contains("sandbox-exec")
}

private func validateExactLanguage(_ language: LanguageID) throws {
    switch language {
    case .rust, .python, .typescript:
        return
    case .javascript:
        throw CocoaError(.featureUnsupported, userInfo: [
            NSLocalizedFailureReasonErrorKey:
                "Exact analysis does not support \(String(describing: language))",
        ])
    }
}

private func exactProfilePrefix(_ profileRoot: String) throws -> String {
    guard !profileRoot.isEmpty, profileRoot != "." else { return "" }
    let components = profileRoot.split(
        separator: "/",
        omittingEmptySubsequences: false
    )
    guard !profileRoot.hasPrefix("/"),
          !components.isEmpty,
          components.allSatisfy({
              $0 != "." && $0 != ".." && !$0.isEmpty
          })
    else { throw ExactError.invalidPath(profileRoot) }
    return components.joined(separator: "/")
}

private func profileRootURL(
    workspaceRoot: URL,
    prefix: String
) -> URL {
    guard !prefix.isEmpty else { return workspaceRoot }
    return prefix.split(separator: "/").reduce(workspaceRoot) {
        $0.appendingPathComponent(String($1))
    }
}

private func makeSnapshot(
    root: URL,
    revision: String?,
    language: LanguageID
) throws -> any Snapshot {
    if let revision {
        return try CommitSnapshot(repositoryURL: root, revision: revision)
    }
    return try WorktreeSnapshot(
        repositoryURL: root,
        language: language
    )
}

private func supportedTarget(
    file: String,
    language: LanguageID
) -> Bool {
    LanguageMode.classify(
        path: file,
        language: language
    ) != nil
}

private func validateProfile(
    _ profile: ExactProfileKey,
    matches analysisProfile: AnalysisProfile,
    language: LanguageID
) throws {
    guard profile.language == language else {
        throw ExactError.unavailable(
            "exact profile language does not match analysis profile"
        )
    }
    let matches: Bool
    switch language {
    case .python:
        matches = profile.configFingerprint == analysisProfile.configFingerprint
            && profile.environmentFingerprint
                == analysisProfile.environmentFingerprint
            && profile.featureSelection == analysisProfile.featureSelection
    case .rust:
        matches = profile.featureSelection == analysisProfile.featureSelection
    case .typescript:
        matches = profile.configFingerprint == analysisProfile.configFingerprint
            && profile.environmentFingerprint
                == analysisProfile.environmentFingerprint
            && profile.featureSelection == analysisProfile.featureSelection
    case .javascript:
        matches = false
    }
    guard matches else {
        throw ExactError.unavailable(
            "exact profile does not match analysis profile"
        )
    }
}
