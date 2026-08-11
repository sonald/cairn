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
        let snapshot: any Snapshot
        let profile: ExactProfileKey
        let trustMode: TrustMode
        let materializedRoot: URL?
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
    @ObservationIgnored private let snapshotFactory: SnapshotFactory
    @ObservationIgnored private let sandboxAvailable: @Sendable () -> Bool
    @ObservationIgnored private let trustRegistry: TrustRegistry
    @ObservationIgnored private let materializer: Materializer
    @ObservationIgnored private var overlay = ExactOverlay()
    private var active: Active?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var expectedGeneration: UInt64 = 0

    public init(
        providerFactory: @escaping ProviderFactory = { projectURL, language in
            switch language {
            case .rust:
                break
            case .python, .typescript, .javascript:
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
        snapshotFactory: @escaping SnapshotFactory = { root, revision in
            if let revision {
                return try CommitSnapshot(repositoryURL: root, revision: revision)
            }
            return try WorktreeSnapshot(repositoryURL: root)
        },
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
        snapshotFactory: @escaping SnapshotFactory = { root, revision in
            if let revision {
                return try CommitSnapshot(repositoryURL: root, revision: revision)
            }
            return try WorktreeSnapshot(repositoryURL: root)
        },
        sandboxAvailable: @escaping @Sendable () -> Bool = {
            FileManager.default.isExecutableFile(
                atPath: "/usr/bin/sandbox-exec"
            )
        },
        trustRegistry: TrustRegistry = TrustRegistry(),
        materializer: Materializer = Materializer()
    ) {
        self.init(
            providerFactory: { projectURL, language in
                try validateExactLanguage(language)
                return try legacyProviderFactory(projectURL)
            },
            snapshotFactory: snapshotFactory,
            sandboxAvailable: sandboxAvailable,
            trustRegistry: trustRegistry,
            materializer: materializer
        )
    }

    public func invalidate(generation: UInt64) {
        epoch &+= 1
        expectedGeneration = generation
        prepareTask?.cancel()
        prepareTask = nil
        let oldSession = active?.session
        active = nil
        oldSession?.cancel()
        if let oldSession {
            Task.detached { oldSession.close() }
        }
        readiness = .preparing
        analysisEnvironment = nil
        trustMode = nil
    }

    public func shutdown() {
        epoch &+= 1
        prepareTask?.cancel()
        prepareTask = nil
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
            generation: generation
        )
    }

    public func prepare(
        projectURL: URL,
        revision: String?,
        analysisProfile: AnalysisProfile,
        generation: UInt64
    ) throws {
        try validateExactLanguage(analysisProfile.language)
        prepareSupported(
            projectURL: projectURL,
            revision: revision,
            analysisProfile: analysisProfile,
            generation: generation
        )
    }

    private func prepareSupported(
        projectURL: URL,
        revision: String?,
        analysisProfile: AnalysisProfile,
        generation: UInt64
    ) {
        let root = projectURL.standardizedFileURL
        let language = analysisProfile.language
        let featureSelection = analysisProfile.featureSelection
        invalidate(generation: generation)
        let currentEpoch = epoch
        let providerFactory = providerFactory
        let snapshotFactory = snapshotFactory
        let sandboxAvailable = sandboxAvailable
        let trustRegistry = trustRegistry
        let materializer = materializer

        prepareTask = Task { [weak self] in
            let trustMode = await trustRegistry.query(root) ?? .safe
            let trustedRepositories = await trustRegistry.trustedRepositories()
            guard let self, epoch == currentEpoch,
                  expectedGeneration == generation,
                  !Task.isCancelled
            else { return }
            self.trustedRepositories = trustedRepositories
            self.trustMode = trustMode
            guard trustMode != .safe || sandboxAvailable() else {
                readiness = .off("Safe exact disabled: sandbox-exec unavailable")
                prepareTask = nil
                return
            }

            do {
                let prepared = try await Task.detached(priority: .utility) {
                    let snapshot = try snapshotFactory(root, revision)
                    let profile: ExactProfileKey
                    let providerRoot: URL
                    let materializedRoot: URL?
                    let versionIdentity: String
                    if let commit = snapshot as? CommitSnapshot {
                        profile = try ExactProfileKey(
                            snapshot: commit,
                            language: language,
                            featureSelection: featureSelection
                        )
                        let resolvedRoot = try materializer.materialize(
                            commit,
                            configFingerprint: profile.configFingerprint
                        ).url
                        materializedRoot = resolvedRoot
                        providerRoot = resolvedRoot
                        versionIdentity = commit.commitOID.hex
                    } else {
                        profile = try ExactProfileKey(
                            projectURL: root,
                            language: language,
                            featureSelection: featureSelection
                        )
                        providerRoot = root
                        materializedRoot = nil
                        versionIdentity =
                            "worktree:\(root.resolvingSymlinksInPath().path)"
                    }
                    let provider = try providerFactory(providerRoot, language)
                    guard profile.language == language else {
                        throw ExactError.unavailable(
                            "exact profile language "
                                + "\(String(describing: profile.language)) does not match "
                                + "analysis profile language \(String(describing: language))"
                        )
                    }
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
                    let session = try provider.prepare(
                        snapshot: snapshot,
                        profile: profile,
                        trustMode: trustMode
                    )
                    return Prepared(active: Active(
                        generation: generation,
                        key: key,
                        provider: provider,
                        session: session,
                        snapshot: snapshot,
                        profile: profile,
                        trustMode: trustMode,
                        materializedRoot: materializedRoot
                    ))
                }.value
                guard epoch == currentEpoch,
                      expectedGeneration == generation,
                      !Task.isCancelled
                else {
                    Task.detached { prepared.active.session.close() }
                    return
                }
                active = prepared.active
                observeEnvironment(from: prepared.active)
                analysisEnvironment = prepared.active.session.attribution.environment
                switch prepared.active.session.readiness {
                case .unavailable(let reason):
                    readiness = .unavailable(reason)
                case .closed:
                    readiness = .unavailable("exact session closed during prepare")
                case .preparing, .ready:
                    readiness = .ready
                }
            } catch is CancellationError {
                return
            } catch {
                guard epoch == currentEpoch,
                      expectedGeneration == generation
                else { return }
                readiness = trustMode == .safe && isSandboxUnavailable(error)
                    ? .off("Safe exact disabled: \(error)")
                    : .unavailable(String(describing: error))
            }
            if epoch == currentEpoch { prepareTask = nil }
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
        prepareTask?.cancel()
        prepareTask = nil
        let oldSession = active?.session
        active = nil
        oldSession?.cancel()
        readiness = .off("materialized cache cleared")
        analysisEnvironment = nil
        trustMode = nil
        let materializer = materializer
        try await Task.detached(priority: .utility) {
            oldSession?.close()
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
                file: file,
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
                file: file,
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

        do {
            let result = try await requestRelations(
                session: current.session,
                file: file,
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
                file: file,
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
                    snapshot: previous.snapshot,
                    profile: previous.profile,
                    trustMode: previous.trustMode
                )
            }.value
            guard batch?.isCurrent != false, isCurrent(previous) else {
                Task.detached { newSession.close() }
                return batch?.isCurrent == false ? .cancelled : nil
            }
            let restarted = Active(
                generation: previous.generation,
                key: previous.key,
                provider: previous.provider,
                session: newSession,
                snapshot: previous.snapshot,
                profile: previous.profile,
                trustMode: previous.trustMode,
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
                    snapshot: previous.snapshot,
                    profile: previous.profile,
                    trustMode: previous.trustMode
                )
            }.value
            guard batch?.isCurrent != false, isCurrent(previous) else {
                Task.detached { newSession.close() }
                return nil
            }
            let restarted = Active(
                generation: previous.generation,
                key: previous.key,
                provider: previous.provider,
                session: newSession,
                snapshot: previous.snapshot,
                profile: previous.profile,
                trustMode: previous.trustMode,
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
        let entries = targets.map { target in
            ExactOverlay.Entry(
                location: mapped(target.location, from: source.materializedRoot),
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
        return switch result {
        case .unsupported:
            .unsupported
        case .notApplicable:
            .notApplicable
        case .calls(let relations):
            .relations(relations.map {
                Relation(
                    name: $0.item.name,
                    location: mapped(
                        $0.item.selectionRange,
                        from: source.materializedRoot
                    ),
                    item: $0.item,
                    callSites: $0.callSites.map {
                        mapped($0, from: source.materializedRoot)
                    }
                )
            }, origin: origin, attribution: source.session.attribution)
        case .locations(let locations):
            .relations(locations.map {
                Relation(
                    name: nil,
                    location: mapped($0, from: source.materializedRoot),
                    item: nil,
                    callSites: []
                )
            }, origin: origin, attribution: source.session.attribution)
        }
    }

    private func observeEnvironment(from source: Active) {
        let generation = source.generation
        let sessionID = ObjectIdentifier(source.session)
        source.session.onEnvironmentChange = { [weak self] environment in
            Task { @MainActor [weak self] in
                guard let self,
                      expectedGeneration == generation,
                      let active,
                      active.generation == generation,
                      ObjectIdentifier(active.session) == sessionID
                else { return }
                self.analysisEnvironment = environment
            }
        }
    }

    private func mapped(
        _ location: ExactLocation,
        from materializedRoot: URL?
    ) -> ExactLocation {
        guard let materializedRoot,
              location.file.hasPrefix("/"),
              let path = try? Materializer.snapshotPath(
                  for: URL(fileURLWithPath: location.file),
                  under: materializedRoot
              )
        else { return location }
        return ExactLocation(
            file: path,
            byteOffset: location.byteOffset,
            line: location.line,
            column: location.column
        )
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
    case .rust:
        return
    case .python, .typescript, .javascript:
        throw CocoaError(.featureUnsupported, userInfo: [
            NSLocalizedFailureReasonErrorKey:
                "Exact analysis does not support \(String(describing: language))",
        ])
    }
}
