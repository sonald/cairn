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
        public let configFingerprint: String
        public let featureSelection: FeatureSelection
        public let trustMode: TrustMode
        public let toolVersion: String

        public init(
            versionIdentity: String,
            configFingerprint: String,
            featureSelection: FeatureSelection,
            trustMode: TrustMode,
            toolVersion: String
        ) {
            self.versionIdentity = versionIdentity
            self.configFingerprint = configFingerprint
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

    private var definitions: [ReuseKey: [Position: Entry]] = [:]

    public init() {}

    public func definition(
        for key: ReuseKey,
        file: String,
        byteOffset: Int
    ) -> Entry? {
        definitions[key]?[Position(file: file, byteOffset: byteOffset)]
    }

    public mutating func store(
        _ entry: Entry,
        for key: ReuseKey,
        file: String,
        byteOffset: Int
    ) {
        definitions[key, default: [:]][Position(
            file: file,
            byteOffset: byteOffset
        )] = entry
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

    public typealias ProviderFactory = @Sendable (URL) throws -> any ExactProvider
    public typealias SnapshotFactory = @Sendable (
        URL,
        String?
    ) throws -> any Snapshot

    enum RelationQueryResult: Sendable {
        case unsupported
        case notApplicable
        case relations([Relation], origin: ExactOrigin)
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
        case implementations([ExactLocation])
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
    public private(set) var coverage: ExactCoverage?
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
        providerFactory: @escaping ProviderFactory = { projectURL in
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
        coverage = nil
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
        coverage = nil
        trustMode = nil
    }

    public func prepare(
        projectURL: URL,
        revision: String?,
        featureSelection: FeatureSelection = .defaultFeatures,
        generation: UInt64
    ) {
        let root = projectURL.standardizedFileURL
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
                            featureSelection: featureSelection
                        )
                        providerRoot = root
                        materializedRoot = nil
                        versionIdentity =
                            "worktree:\(root.resolvingSymlinksInPath().path)"
                    }
                    let provider = try providerFactory(providerRoot)
                    let key = ExactOverlay.ReuseKey(
                        versionIdentity: versionIdentity,
                        configFingerprint: profile.configFingerprint,
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
                observeCoverage(from: prepared.active)
                coverage = prepared.active.session.attribution.coverage
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
        coverage = nil
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
        generation: UInt64
    ) async -> ExactOverlay.Entry? {
        if let prepareTask { await prepareTask.value }
        guard expectedGeneration == generation,
              let current = active,
              current.generation == generation
        else { return nil }
        let offset = Int(byteOffset)
        if let cached = overlay.definition(
            for: current.key,
            file: file,
            byteOffset: offset
        ) {
            return cached
        }

        do {
            let location = try await request(
                session: current.session,
                file: file,
                byteOffset: offset
            )
            return publish(
                location,
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
                byteOffset: offset
            )
        } catch {
            guard isCurrent(current) else { return nil }
            if isUnavailable(current.session.readiness) {
                readiness = .unavailable(String(describing: error))
            }
            return nil
        }
    }

    func relations(
        file: String,
        byteOffset: UInt32,
        item: ExactCallHierarchyItem?,
        direction: RelationTreeModel.Direction,
        generation: UInt64
    ) async -> RelationQueryResult? {
        if let prepareTask { await prepareTask.value }
        guard expectedGeneration == generation,
              let current = active,
              current.generation == generation
        else { return nil }

        do {
            let result = try await requestRelations(
                session: current.session,
                file: file,
                byteOffset: Int(byteOffset),
                item: item,
                direction: direction
            )
            return publish(result, from: current)
        } catch where isHelperCrash(error)
            && !isUnavailable(current.session.readiness)
        {
            return await restartRelationsOnce(
                current,
                file: file,
                byteOffset: Int(byteOffset),
                item: item,
                direction: direction
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
        byteOffset: Int
    ) async -> ExactOverlay.Entry? {
        guard isCurrent(previous) else { return nil }
        readiness = .preparing
        try? await Task.sleep(for: .milliseconds(100))
        guard isCurrent(previous) else { return nil }

        do {
            let newSession = try await Task.detached(priority: .utility) {
                try previous.provider.prepare(
                    snapshot: previous.snapshot,
                    profile: previous.profile,
                    trustMode: previous.trustMode
                )
            }.value
            guard isCurrent(previous) else {
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
            observeCoverage(from: restarted)
            Task.detached { previous.session.close() }

            do {
                let location = try await request(
                    session: newSession,
                    file: file,
                    byteOffset: byteOffset
                )
                return publish(
                    location,
                    from: restarted,
                    file: file,
                    byteOffset: byteOffset
                )
            } catch {
                guard isCurrent(restarted) else { return nil }
                readiness = .unavailable(
                    "exact helper restart exhausted: \(error)"
                )
                return nil
            }
        } catch {
            guard isCurrent(previous) else { return nil }
            readiness = .unavailable("exact helper restart failed: \(error)")
            return nil
        }
    }

    private func request(
        session: any ExactSession,
        file: String,
        byteOffset: Int
    ) async throws -> ExactLocation? {
        try await Task.detached(priority: .userInitiated) {
            try session.definition(file: file, byteOffset: byteOffset)
        }.value
    }

    private func requestRelations(
        session: any ExactSession,
        file: String,
        byteOffset: Int,
        item: ExactCallHierarchyItem?,
        direction: RelationTreeModel.Direction
    ) async throws -> RawRelationQueryResult {
        try await Task.detached(priority: .userInitiated) {
            switch direction {
            case .implementations:
                guard session.negotiatedCapabilities.contains(.implementations)
                else { return .unsupported }
                return .implementations(
                    try session.implementations(
                        file: file,
                        byteOffset: byteOffset
                    ) ?? []
                )
            case .callers, .calls:
                guard session.negotiatedCapabilities.contains(.callHierarchy)
                else { return .unsupported }
                let items: [ExactCallHierarchyItem]
                if let item {
                    items = [item]
                } else {
                    guard let prepared = try session.prepareCallHierarchy(
                        file: file,
                        byteOffset: byteOffset
                    ), !prepared.isEmpty
                    else { return .notApplicable }
                    items = prepared
                }
                var relations: [ExactCallRelation] = []
                for item in items {
                    switch direction {
                    case .callers:
                        relations += try session.incomingCalls(item: item) ?? []
                    case .calls:
                        relations += try session.outgoingCalls(item: item) ?? []
                    case .implementations:
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
        direction: RelationTreeModel.Direction
    ) async -> RelationQueryResult? {
        guard isCurrent(previous) else { return nil }
        readiness = .preparing
        try? await Task.sleep(for: .milliseconds(100))
        guard isCurrent(previous) else { return nil }

        do {
            let newSession = try await Task.detached(priority: .utility) {
                try previous.provider.prepare(
                    snapshot: previous.snapshot,
                    profile: previous.profile,
                    trustMode: previous.trustMode
                )
            }.value
            guard isCurrent(previous) else {
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
            observeCoverage(from: restarted)
            Task.detached { previous.session.close() }

            do {
                let result = try await requestRelations(
                    session: newSession,
                    file: file,
                    byteOffset: byteOffset,
                    item: item,
                    direction: direction
                )
                return publish(result, from: restarted)
            } catch {
                guard isCurrent(restarted) else { return nil }
                readiness = .unavailable(
                    "exact helper restart exhausted: \(error)"
                )
                return nil
            }
        } catch {
            guard isCurrent(previous) else { return nil }
            readiness = .unavailable("exact helper restart failed: \(error)")
            return nil
        }
    }

    private func publish(
        _ location: ExactLocation?,
        from source: Active,
        file: String,
        byteOffset: Int
    ) -> ExactOverlay.Entry? {
        guard isCurrent(source) else { return nil }
        readiness = .ready
        coverage = source.session.attribution.coverage
        guard let location else { return nil }
        let mappedLocation = mapped(location, from: source.materializedRoot)
        let entry = ExactOverlay.Entry(
            location: mappedLocation,
            attribution: source.session.attribution,
            origin: source.materializedRoot != nil
                ? .materialized(commitOID: source.key.versionIdentity)
                : .worktree
        )
        overlay.store(entry, for: source.key, file: file, byteOffset: byteOffset)
        return entry
    }

    private func publish(
        _ result: RawRelationQueryResult,
        from source: Active
    ) -> RelationQueryResult? {
        guard isCurrent(source) else { return nil }
        readiness = .ready
        coverage = source.session.attribution.coverage
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
            }, origin: origin)
        case .implementations(let locations):
            .relations(locations.map {
                Relation(
                    name: nil,
                    location: mapped($0, from: source.materializedRoot),
                    item: nil,
                    callSites: []
                )
            }, origin: origin)
        }
    }

    private func observeCoverage(from source: Active) {
        let generation = source.generation
        let sessionID = ObjectIdentifier(source.session)
        source.session.onCoverageChange = { [weak self] coverage in
            Task { @MainActor [weak self] in
                guard let self,
                      expectedGeneration == generation,
                      let active,
                      active.generation == generation,
                      ObjectIdentifier(active.session) == sessionID
                else { return }
                self.coverage = coverage
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
