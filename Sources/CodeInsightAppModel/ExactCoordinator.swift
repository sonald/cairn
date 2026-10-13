import CodeInsightCore
import CodeInsightExact
import CodeInsightGit
import Darwin
import Foundation
import Observation

public enum ExactOrigin: Equatable, Sendable {
    case worktree
    case materialized(commitOID: String)
}

/// ExactCoordinator maps locations inside the project/checkout root to
/// relative paths before models see them. RustAnalyzerProvider leaves
/// dependency locations absolute. Review every caller if that convention changes.
public func exactLocationIsInDependency(_ file: String) -> Bool {
    file.hasPrefix("/")
}

/// A dependency file's language: what a project source would be, plus
/// `.d.ts` (TypeScript) and `.pyi` (Python), which most packages ship in
/// place of sources. Project language detection and source counts never
/// use this; such files are read and highlighted, not indexed.
package func dependencyFileLanguageMode(
    path: String,
    languages: [LanguageID]
) -> LanguageMode? {
    if let mode = LanguageMode.classify(path: path, languages: languages) {
        return mode
    }
    if path.hasSuffix(".d.ts"), languages.contains(.typescript) {
        return LanguageMode(language: .typescript)
    }
    if path.hasSuffix(".pyi"), languages.contains(.python) {
        return LanguageMode(language: .python)
    }
    return nil
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

        /// Decision 6: a running session may follow `next` only when nothing
        /// but the version and the configuration content differ; those the
        /// server reloads itself. Rust's environment fingerprint is the
        /// Cargo.lock hash, which rust-analyzer reloads like Cargo.toml (S0
        /// item 4), so it does not count. `analysisProfileID` is derived
        /// from the configuration fingerprint, so the unit is compared by
        /// the caller.
        func allowsWarmSwitch(to next: ReuseKey) -> Bool {
            language == next.language
                && featureSelection == next.featureSelection
                && (language == .rust
                    || environmentFingerprint == next.environmentFingerprint)
                && trustMode == next.trustMode
                && toolVersion == next.toolVersion
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
    /// typeDefinition replies live in their own mapping so they can never
    /// evict or shadow a definition entry for the same position (P2).
    private var typeDefinitions: [ReuseKey: [Position: [Entry]]] = [:]

    public init() {}

    public func typeDefinition(
        for key: ReuseKey,
        file: String,
        byteOffset: Int
    ) -> [Entry]? {
        typeDefinitions[key]?[Position(file: file, byteOffset: byteOffset)]
    }

    public mutating func storeTypeDefinition(
        _ entries: [Entry],
        for key: ReuseKey,
        file: String,
        byteOffset: Int
    ) {
        typeDefinitions[key, default: [:]][Position(
            file: file,
            byteOffset: byteOffset
        )] = entries
    }

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

    public enum TypeDefinitionResult: Sendable {
        case completed([ExactOverlay.Entry])
        case cancelled
        case unsupported
        case unavailable(String)
    }

    public enum HoverResult: Equatable, Sendable {
        case completed(String?, limitations: Set<ExactAnalysisLimitation>)
        case unsupported
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

    /// Decision 7: one session per root the window reads — its workspace
    /// and its checkout directory.
    enum Slot: Sendable {
        case worktree
        case checkout
    }

    private struct Active: Sendable {
        let generation: UInt64
        let key: ExactOverlay.ReuseKey
        let provider: any ExactProvider
        var session: any ExactSession
        let providerSnapshot: any Snapshot
        let profile: ExactProfileKey
        let trustMode: TrustMode
        let workspaceRoot: URL
        let profilePrefix: String
        let checkoutRoot: URL?
        let slot: Slot
        /// The whole project snapshot, the base of the next switch's diff.
        let snapshot: any Snapshot
        let unitName: String
        let dependencies: DependencyContext

        /// The directory the server reads, whose files a switch rewrites.
        var serverDirectory: URL { checkoutRoot ?? workspaceRoot }
    }

    private struct ProfileSnapshot: Snapshot {
        let snapshotID: SnapshotID
        let objectFormat: GitObjectFormat
        let sourceKind: SourceKind
        let projectRootName: String
        let configurationPaths: [String]
        let languages: [LanguageID]
        let wrapped: any Snapshot
        private let prefix: String

        init?(_ wrapped: any Snapshot, prefix: String) {
            guard !prefix.isEmpty else { return nil }
            self.wrapped = wrapped
            self.prefix = prefix
            snapshotID = wrapped.snapshotID
            objectFormat = wrapped.objectFormat
            sourceKind = wrapped.sourceKind
            projectRootName = wrapped.projectRootName
            languages = wrapped.languages
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
        let dependencyRoots: [URL]
        let active: Active
    }

    /// A parked slot closes after this long without use, or once its server
    /// holds more than `standbyMemoryLimit` (decision 7; S0 measured
    /// rust-analyzer at 4–5 GB on codex). Constants, not settings.
    static let standbyIdleLimit: TimeInterval = 600
    static let standbyMemoryLimit: UInt64 = 2 << 30
    /// Reads a server's resident memory; tests substitute their own.
    @ObservationIgnored var residentMemory: (Int32) -> UInt64? = residentBytes(of:)

    public private(set) var readiness: Readiness = .off(localized("model.exact.noProject"))
    public private(set) var analysisEnvironment: ExactAnalysisEnvironment?
    public private(set) var trustMode: TrustMode?
    public private(set) var trustedRepositories: [TrustedRepository] = []
    public var attribution: ExactAttribution? { active?.session.attribution }

    /// Where the provider finds dependencies: the interpreter Pyright is
    /// told to use, and whether a commit borrows the workspace's.
    private struct DependencyContext: Equatable, Sendable {
        let pythonPath: URL?
        let borrowedFromWorkspace: Bool
    }

    @ObservationIgnored private let providerFactory: @Sendable (
        URL,
        LanguageID,
        DependencyContext
    ) throws -> any ExactProvider
    /// Workspace directories the active analysis reads dependencies from
    /// (borrowed `node_modules`, the virtual environment). Files under
    /// them are dependency files even though they sit under the project.
    @ObservationIgnored private var dependencyRoots: [URL] = []
    @ObservationIgnored private let snapshotFactory: SnapshotFactory?
    @ObservationIgnored private let sandboxAvailable: @Sendable () -> Bool
    /// The registry this coordinator consults; application-owned shared
    /// instance in production (§8.2).
    public let trustRegistry: TrustRegistry
    @ObservationIgnored private let checkoutStore: CheckoutStore
    /// The window identity under which this coordinator's checkout
    /// directory lives; released when the coordinator shuts down.
    @ObservationIgnored private let checkoutOwner = UUID()
    @ObservationIgnored private var overlay = ExactOverlay()
    private var active: Active?
    /// Every live session by root; `active` is one of them, the other waits
    /// for the window to come back to its root.
    @ObservationIgnored private var slots: [Slot: Active] = [:]
    @ObservationIgnored private var standbySince: [Slot: Date] = [:]
    /// Sessions a prepare took out of their slot to switch them.
    @ObservationIgnored private var takenSessions: [any ExactSession] = []
    /// Advances whenever every slot closes, so a prepare finishing later
    /// closes the session it took instead of parking it again.
    @ObservationIgnored private var slotEpoch: UInt64 = 0
    @ObservationIgnored private var standbyMonitor: Task<Void, Never>?
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    /// Project root the in-flight prepare targets; lets an app-level trust
    /// revoke stop only the affected project's preparation (§8.2).
    @ObservationIgnored private var prepareRoot: URL?
    /// Projects whose prepares are suspended (trust revocation in flight,
    /// cache maintenance): no new session may read the registry or claim
    /// cache directories until the coordinating operation finishes (§8.2,
    /// §8.4).
    @ObservationIgnored private var suspendedPrepares: Set<String> = []
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var expectedGeneration: UInt64 = 0
    @ObservationIgnored private var closeTask: Task<Void, Never>?

    public init(
        providerFactory: ProviderFactory? = nil,
        snapshotFactory: SnapshotFactory? = nil,
        sandboxAvailable: @escaping @Sendable () -> Bool = {
            FileManager.default.isExecutableFile(
                atPath: "/usr/bin/sandbox-exec"
            )
        },
        trustRegistry: TrustRegistry = TrustRegistry(),
        checkoutStore: CheckoutStore = CheckoutStore()
    ) {
        if let providerFactory {
            self.providerFactory = { projectURL, language, _ in
                try providerFactory(projectURL, language)
            }
        } else {
            self.providerFactory = Self.defaultProviderFactory
        }
        self.snapshotFactory = snapshotFactory
        self.sandboxAvailable = sandboxAvailable
        self.trustRegistry = trustRegistry
        self.checkoutStore = checkoutStore
    }

    private static let defaultProviderFactory: @Sendable (
        URL,
        LanguageID,
        DependencyContext
    ) throws -> any ExactProvider = { projectURL, language, dependencies in
        switch language {
        case .python:
            guard let executable = PyrightProvider.findExecutable(
                projectURL: projectURL
            ) else {
                throw ExactError.unavailable(
                    localized("model.exact.pyrightMissing")
                )
            }
            return try PyrightProvider(
                projectURL: projectURL,
                executableURL: executable,
                pythonPath: dependencies.pythonPath,
                borrowedFromWorkspace: dependencies.borrowedFromWorkspace
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
                    localized("model.exact.typescriptMissing")
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
                    localized("model.exact.typescriptMissing")
                )
            }
            return try TypeScriptLanguageServerProvider(
                projectURL: projectURL,
                nodeURL: node,
                languageServerURL: languageServer,
                tsserverURL: tsserver,
                borrowedFromWorkspace: dependencies.borrowedFromWorkspace
            )
        case .javascript:
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedFailureReasonErrorKey:
                    localizedFormat("model.exact.unsupportedLanguage", String(describing: language)),
            ])
        }
        guard let executable = RustAnalyzerProvider.findExecutable() else {
            throw ExactError.unavailable(localized("model.exact.rustMissing"))
        }
        return try RustAnalyzerProvider(
            projectURL: projectURL,
            executableURL: executable
        )
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
        checkoutStore: CheckoutStore = CheckoutStore()
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
            checkoutStore: checkoutStore
        )
    }

    /// Retires the current generation. The active session is parked in its
    /// slot, not closed: in-flight requests are cancelled, and a later
    /// `prepare` either switches it warm or closes it.
    public func invalidate(generation: UInt64) {
        epoch &+= 1
        expectedGeneration = generation
        let previousClose = closeTask
        let previousPrepare = prepareTask
        if let parked = active {
            parked.session.cancel()
            park(parked.slot)
        }
        prepareTask?.cancel()
        prepareTask = nil
        prepareRoot = nil
        if previousClose != nil || previousPrepare != nil {
            closeTask = Task.detached(priority: .utility) {
                await previousClose?.value
                await previousPrepare?.value
            }
        } else {
            closeTask = nil
        }
        active = nil
        dependencyRoots = []
        readiness = .preparing
        analysisEnvironment = nil
        trustMode = nil
    }

    public func shutdown() {
        epoch &+= 1
        let previousClose = closeTask
        let previousPrepare = prepareTask
        prepareTask?.cancel()
        prepareTask = nil
        prepareRoot = nil
        closeTask = nil
        let oldSession = active?.session
        let parkedSessions = takeAllSessions()
        let checkoutStore = checkoutStore
        let checkoutOwner = checkoutOwner
        active = nil
        // The active session closes synchronously (existing contract); the
        // cancelled prepare, the parked slot and the prior close chain
        // finish in the background with a completion handle nobody loses
        // (§7.1). The checkout directory is deleted only after all of them,
        // so no language server still reads it.
        oldSession?.close()
        readiness = .off(localized("model.exact.terminating"))
        analysisEnvironment = nil
        trustMode = nil
        closeTask = Task.detached(priority: .utility) {
            await previousClose?.value
            await previousPrepare?.value
            for session in parkedSessions { session.close() }
            try? checkoutStore.release(owner: checkoutOwner)
        }
    }

    /// Empties both slots and stops any switch in progress (decision 7:
    /// trust revocation, closing, clearing checkouts). The caller closes
    /// the returned sessions after the prepare that may hold one finished.
    private func takeAllSessions() -> [any ExactSession] {
        slotEpoch &+= 1
        let sessions = slots.values.map(\.session) + takenSessions
        slots.removeAll()
        standbySince.removeAll()
        takenSessions.removeAll()
        standbyMonitor?.cancel()
        standbyMonitor = nil
        for session in sessions { session.cancel() }
        return sessions
    }

    private func park(_ slot: Slot) {
        guard slots[slot] != nil, standbySince[slot] == nil else { return }
        standbySince[slot] = Date()
        guard standbyMonitor == nil else { return }
        standbyMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                self.releaseStandby(now: Date())
                if self.standbySince.isEmpty {
                    self.standbyMonitor = nil
                    return
                }
            }
        }
    }

    /// Closes parked slots idle past `standbyIdleLimit` or whose server
    /// holds more than `standbyMemoryLimit`; the next visit starts cold.
    func releaseStandby(now: Date) {
        for (slot, since) in standbySince {
            guard let parked = slots[slot] else {
                standbySince[slot] = nil
                continue
            }
            let resident = parked.session.processIdentifier
                .flatMap(residentMemory) ?? 0
            guard now.timeIntervalSince(since) > Self.standbyIdleLimit
                || resident > Self.standbyMemoryLimit
            else { continue }
            slots[slot] = nil
            standbySince[slot] = nil
            let session = parked.session
            Task.detached(priority: .utility) { session.close() }
        }
    }

    /// Whether `slot` holds a session, for tests.
    func hasSession(in slot: Slot) -> Bool { slots[slot] != nil }

    /// Awaitable, idempotent shutdown used by explicit window/project
    /// close: waits until cancelled prepare work, the previous close chain,
    /// and the old session's provider have all finished exiting, so the
    /// caller may safely release or delete cache directories afterwards.
    public func shutdownAndWait() async {
        shutdown()
        let chain = closeTask
        await chain?.value
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
        // A suspended project rejects the prepare outright: its trust or
        // its cache is being revoked, and a session that slipped through
        // now could keep running on stale permissions (§8.2).
        guard !suspendedPrepares.contains(Self.canonicalRepositoryPath(root))
        else {
            invalidate(generation: generation)
            readiness = .off(localized("model.exact.revoking"))
            return
        }
        guard !checkoutStore.isUnderMaintenance else {
            invalidate(generation: generation)
            readiness = .off(localized("model.exact.maintenance"))
            return
        }
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
        let checkoutStore = checkoutStore
        let checkoutOwner = checkoutOwner
        prepareRoot = root

        let priorClose = closeTask
        let slot: Slot = revision == nil ? .worktree : .checkout
        let unitName = analysisProfile.projectUnitName
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
                self.readiness = .off(localized("model.exact.sandboxMissing"))
                self.prepareTask = nil
                return
            }

            // Decision 7: this prepare owns its root's slot; the other one
            // stays parked unless it serves another project, language,
            // unit, feature selection or trust mode.
            var retired: [any ExactSession] = []
            for (other, parked) in self.slots where other != slot
                && !(parked.workspaceRoot == root
                    && parked.key.language == language
                    && parked.profilePrefix == profilePrefix
                    && parked.unitName == unitName
                    && parked.key.featureSelection == featureSelection
                    && parked.key.trustMode == trustMode)
            {
                self.slots[other] = nil
                self.standbySince[other] = nil
                retired.append(parked.session)
            }
            let candidate = self.slots.removeValue(forKey: slot)
            self.standbySince[slot] = nil
            let takenEpoch = self.slotEpoch
            self.takenSessions = candidate.map { [$0.session] } ?? []

            do {
                let prepared = try await Task.detached(priority: .utility) {
                    for session in retired { session.close() }
                    let snapshot: any Snapshot = if let snapshotFactory {
                        try snapshotFactory(root, revision)
                    } else {
                        try makeSnapshot(root: root, revision: revision)
                    }
                    let commit = snapshot as? CommitSnapshot
                    // Both modes answer Pyright the workspace unit's
                    // interpreter; links exist only in a commit checkout.
                    let pythonPath = language == .python
                        ? DependencyBorrowing.pythonInterpreter(
                            unitRoot: profileRootURL(workspaceRoot: root, prefix: profilePrefix)
                        )
                        : nil
                    let links = DependencyBorrowing.links(
                        language: language,
                        snapshot: snapshot,
                        workspaceRoot: root,
                        unitPrefix: profilePrefix
                    )
                    var dependencyRoots = Array(links.values)
                    if let pythonPath {
                        dependencyRoots.append(
                            pythonPath.deletingLastPathComponent().deletingLastPathComponent()
                        )
                    }
                    let profile = try ExactProfileKey(
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
                    let providerSnapshot = ProfileSnapshot(
                        snapshot,
                        prefix: profilePrefix
                    ) ?? snapshot
                    func reuseKey(
                        versionIdentity: String,
                        toolVersion: String
                    ) -> ExactOverlay.ReuseKey {
                        ExactOverlay.ReuseKey(
                            versionIdentity: versionIdentity,
                            language: language,
                            analysisProfileID: analysisProfile.id,
                            configFingerprint: profile.configFingerprint,
                            environmentFingerprint: profile.environmentFingerprint,
                            featureSelection: profile.featureSelection,
                            trustMode: trustMode,
                            toolVersion: toolVersion
                        )
                    }
                    let worktreeIdentity = "worktree:" + profileRootURL(
                        workspaceRoot: root,
                        prefix: profilePrefix
                    ).resolvingSymlinksInPath().path
                    let versionIdentity = commit?.commitOID.hex
                        ?? worktreeIdentity

                    // Decision 6. The slot's provider is reused, so its tool
                    // version is the one the key compares.
                    var warm: Active?
                    if let candidate {
                        let key = reuseKey(
                            versionIdentity: versionIdentity,
                            toolVersion: candidate.provider.toolVersion
                        )
                        if candidate.workspaceRoot == root,
                           candidate.profilePrefix == profilePrefix,
                           candidate.unitName == unitName,
                           (candidate.checkoutRoot != nil) == (commit != nil),
                           candidate.dependencies.pythonPath == pythonPath,
                           candidate.key.allowsWarmSwitch(to: key)
                        {
                            warm = candidate
                        } else {
                            candidate.session.close()
                        }
                    }

                    // The window's own checkout follows the commit; only a
                    // session switched below, or none, reads it.
                    let checkout = try commit.map { _ in
                        try checkoutStore.root(owner: checkoutOwner, source: root)
                    }
                    let checkOut: () throws -> Void = {
                        if let checkout, let commit {
                            try checkout.checkout(commit: commit.commitOID, links: links)
                        }
                    }
                    // Read after the checkout: links the commit's own
                    // content displaces are not borrowed.
                    func dependencies() -> DependencyContext {
                        DependencyContext(
                            pythonPath: pythonPath,
                            borrowedFromWorkspace: checkout.map {
                                !$0.borrowedLinks.isEmpty || pythonPath != nil
                            } ?? false
                        )
                    }
                    let providerRoot = profileRootURL(
                        workspaceRoot: checkout?.url ?? root,
                        prefix: profilePrefix
                    )
                    func active(
                        provider: any ExactProvider,
                        session: any ExactSession,
                        key: ExactOverlay.ReuseKey,
                        dependencies: DependencyContext
                    ) -> Prepared {
                        Prepared(dependencyRoots: dependencyRoots, active: Active(
                            generation: generation,
                            key: key,
                            provider: provider,
                            session: session,
                            providerSnapshot: providerSnapshot,
                            profile: profile,
                            trustMode: trustMode,
                            workspaceRoot: root,
                            profilePrefix: profilePrefix,
                            checkoutRoot: checkout?.url,
                            slot: slot,
                            snapshot: snapshot,
                            unitName: unitName,
                            dependencies: dependencies
                        ))
                    }

                    if let warm {
                        do {
                            try warm.session.switchSnapshot(
                                to: providerSnapshot,
                                profile: profile,
                                changes: ExactFileChange.changes(
                                    from: warm.snapshot,
                                    to: snapshot,
                                    under: warm.serverDirectory
                                ),
                                configChanged: warm.profile.configFingerprint
                                    != profile.configFingerprint,
                                prepareFiles: checkOut
                            )
                            // The provider labels borrowed dependencies at
                            // start; a commit that starts or stops
                            // borrowing needs a new one.
                            if dependencies() == warm.dependencies {
                                return active(
                                    provider: warm.provider,
                                    session: warm.session,
                                    key: reuseKey(
                                        versionIdentity: versionIdentity,
                                        toolVersion: warm.provider.toolVersion
                                    ),
                                    dependencies: warm.dependencies
                                )
                            }
                            warm.session.close()
                        } catch {
                            // Checkout or confirmation failed: the session
                            // is unavailable; a fresh one replaces it.
                            warm.session.close()
                        }
                    }

                    try checkOut()
                    let provider = try providerFactory(
                        providerRoot,
                        language,
                        dependencies()
                    )
                    guard provider.language == language else {
                        throw ExactError.unavailable(
                            "exact provider language "
                                + "\(String(describing: provider.language)) does not match "
                                + "analysis profile language \(String(describing: language))"
                        )
                    }
                    let session = try provider.prepare(
                        snapshot: providerSnapshot,
                        profile: profile,
                        trustMode: trustMode
                    )
                    return active(
                        provider: provider,
                        session: session,
                        key: reuseKey(
                            versionIdentity: versionIdentity,
                            toolVersion: provider.toolVersion
                        ),
                        dependencies: dependencies()
                    )
                }.value
                self.takenSessions = []
                guard self.slotEpoch == takenEpoch else {
                    // Every slot closed meanwhile (trust, close, clearing).
                    await Task.detached {
                        prepared.active.session.close()
                    }.value
                    return
                }
                self.slots[slot] = prepared.active
                guard self.epoch == currentEpoch,
                      self.expectedGeneration == generation,
                      !Task.isCancelled
                else {
                    // Superseded: the session waits in its slot for the
                    // next prepare.
                    self.park(slot)
                    return
                }
                self.activate(prepared.active)
                self.dependencyRoots = prepared.dependencyRoots
            } catch {
                self.takenSessions = []
                if let candidate {
                    let session = candidate.session
                    Task.detached(priority: .utility) { session.close() }
                }
                if error is CancellationError { return }
                guard self.epoch == currentEpoch,
                      self.expectedGeneration == generation
                else { return }
                self.readiness = trustMode == .safe && isSandboxUnavailable(error)
                    ? .off(localizedFormat("model.exact.safeDisabled", exactFailureReason(error)))
                    : .unavailable(exactFailureReason(error))
            }
            if self.epoch == currentEpoch {
                self.prepareTask = nil
                self.prepareRoot = nil
            }
        }
    }

    private func activate(_ next: Active) {
        active = next
        slots[next.slot] = next
        standbySince[next.slot] = nil
        for other in slots.keys where other != next.slot { park(other) }
        observeEnvironment(from: next)
        analysisEnvironment = next.session.attribution.environment
        switch next.session.readiness {
        case .unavailable(let reason):
            readiness = .unavailable(reason)
        case .closed:
            readiness = .unavailable(localized("model.exact.closed"))
        case .preparing, .ready:
            readiness = .ready
        }
    }

    public func refreshReadiness() {
        if case .unavailable(let reason) = active?.session.readiness {
            readiness = .unavailable(reason)
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
        // From the first line, new prepares for this project are refused:
        // waiting for old work to exit must not race a fresh trusted
        // prepare that still reads the unrevoked registry (§8.2).
        let suspendedRoot = Self.canonicalRepositoryPath(repositoryURL)
        suspendedPrepares.insert(suspendedRoot)
        defer { suspendedPrepares.remove(suspendedRoot) }
        await stopWorkspaces(rootedAt: repositoryURL)
        try await trustRegistry.revoke(repositoryURL)
        await refreshTrust()
    }

    /// Whether prepares for `repositoryURL` are currently suspended.
    public func prepareIsSuspended(for repositoryURL: URL) -> Bool {
        suspendedPrepares.contains(Self.canonicalRepositoryPath(repositoryURL))
    }

    /// Suspends and resumes prepares for tests and app-level maintenance.
    func suspendPrepares(for repositoryURL: URL) {
        suspendedPrepares.insert(Self.canonicalRepositoryPath(repositoryURL))
    }

    func resumePrepares(for repositoryURL: URL) {
        suspendedPrepares.remove(Self.canonicalRepositoryPath(repositoryURL))
    }

    /// Stops and awaits the exit of every prepare/session this coordinator
    /// runs for `repositoryURL`. Safe to call for unrelated roots.
    public func stopWorkspaces(rootedAt repositoryURL: URL) async {
        let target = Self.canonicalRepositoryPath(repositoryURL)
        let affectsSession = slots.values.contains {
            Self.canonicalRepositoryPath($0.workspaceRoot) == target
        }
        let affectsPrepare = prepareRoot.map {
            Self.canonicalRepositoryPath($0) == target
        } ?? false
        guard affectsSession || affectsPrepare else { return }
        let stoppedGeneration = expectedGeneration
        invalidate(generation: stoppedGeneration)
        closeAllSessions()
        await closeTask?.value
        readiness = .off(localized("model.exact.revoked"))
    }

    /// Adds closing both slots to the close chain.
    private func closeAllSessions() {
        let sessions = takeAllSessions()
        guard !sessions.isEmpty else { return }
        let previousClose = closeTask
        closeTask = Task.detached(priority: .utility) {
            await previousClose?.value
            for session in sessions { session.close() }
        }
    }

    nonisolated private static func canonicalRepositoryPath(
        _ url: URL
    ) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Stops and awaits every prepare/session this coordinator runs,
    /// regardless of project, and deletes its checkout directory — used by
    /// the app-level clear (§8.4).
    public func stopAllWorkForCacheClear() async {
        let stoppedGeneration = expectedGeneration
        invalidate(generation: stoppedGeneration)
        closeAllSessions()
        await closeTask?.value
        let checkoutStore = checkoutStore
        let checkoutOwner = checkoutOwner
        await Task.detached(priority: .utility) {
            try? checkoutStore.release(owner: checkoutOwner)
        }.value
        readiness = .off(localized("model.exact.cacheCleared"))
    }

    /// Bytes the checkout directories occupy, for the settings page.
    public var checkoutDirectorySize: UInt64 { checkoutStore.totalSize() }

    /// Single-coordinator clear: stops this coordinator's work, then deletes
    /// every checkout directory. Refused while another coordinator still
    /// holds one.
    public func clearCheckouts() async throws {
        epoch &+= 1
        let previousClose = closeTask
        let previousPrepare = prepareTask
        prepareTask?.cancel()
        prepareTask = nil
        prepareRoot = nil
        let sessions = takeAllSessions()
        active = nil
        readiness = .off(localized("model.exact.cacheCleared"))
        analysisEnvironment = nil
        trustMode = nil
        let checkoutStore = checkoutStore
        let checkoutOwner = checkoutOwner
        await previousClose?.value
        await previousPrepare?.value
        try await Task.detached(priority: .utility) {
            for session in sessions { session.close() }
            try checkoutStore.release(owner: checkoutOwner)
            try checkoutStore.removeAll()
        }.value
    }

    /// True for a file under a workspace directory the active analysis
    /// borrows dependencies from: it is read from disk, never from the
    /// project snapshot, although it lies under the project root.
    public func isDependencyFile(_ file: URL) -> Bool {
        let components = file.standardizedFileURL.pathComponents
        return dependencyRoots.contains {
            components.starts(with: $0.standardizedFileURL.pathComponents)
        }
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
            if case .unavailable(let reason) = current.session.readiness {
                readiness = .unavailable(reason)
            }
            return .unavailable(exactFailureReason(error))
        }
    }

    /// P2: `textDocument/typeDefinition` with the same generation checks,
    /// batching, and drift admissions as `definition`, but its own cache.
    public func typeDefinition(
        file: String,
        byteOffset: UInt32,
        generation: UInt64,
        batch: ExactRequestBatch? = nil
    ) async -> TypeDefinitionResult? {
        if let prepareTask { await prepareTask.value }
        guard batch?.isCurrent != false else { return .cancelled }
        guard expectedGeneration == generation else { return nil }
        guard let current = active else {
            return .unavailable(String(describing: readiness))
        }
        guard current.generation == generation else { return nil }
        guard current.session.negotiatedCapabilities.contains(.typeDefinition)
        else {
            return .unsupported
        }
        guard let requestFile = providerRelativeRequestPath(
            file: file,
            source: current
        ) else {
            return .completed([])
        }
        let offset = Int(byteOffset)
        if let cached = overlay.typeDefinition(
            for: current.key,
            file: file,
            byteOffset: offset
        ) {
            return .completed(cached)
        }

        do {
            let result = try await requestTypeDefinition(
                session: current.session,
                file: requestFile,
                byteOffset: offset,
                batch: batch
            )
            guard batch?.isCurrent != false else { return .cancelled }
            return publishTypeDefinition(
                result,
                from: current,
                file: file,
                byteOffset: offset
            )
        } catch {
            guard isCurrent(current) else { return nil }
            if case .unavailable(let reason) = current.session.readiness {
                readiness = .unavailable(reason)
            }
            return .unavailable(exactFailureReason(error))
        }
    }

    public func hover(
        file: String,
        byteOffset: UInt32,
        generation: UInt64,
        batch: ExactRequestBatch
    ) async -> HoverResult? {
        if let prepareTask { await prepareTask.value }
        guard batch.isCurrent else { return .cancelled }
        guard expectedGeneration == generation else { return nil }
        guard let current = active else {
            return .unavailable(String(describing: readiness))
        }
        guard current.generation == generation else { return nil }
        guard current.session.negotiatedCapabilities.contains(.hover) else {
            return .unsupported
        }
        guard let requestFile = providerRelativeRequestPath(
            file: file,
            source: current
        ) else {
            return .completed(nil, limitations: [])
        }
        let session = current.session
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try session.hover(
                    file: requestFile,
                    byteOffset: Int(byteOffset),
                    batch: batch
                )
            }.value
            guard batch.isCurrent, isCurrent(current) else { return .cancelled }
            switch result {
            case nil:
                return .unsupported
            case .cancelled:
                return .cancelled
            case .completed(let markdown):
                let environment = analysisEnvironment
                    ?? session.attribution.environment
                return .completed(markdown, limitations: environment.limitations)
            }
        } catch {
            guard isCurrent(current) else { return nil }
            return .unavailable(exactFailureReason(error))
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
            if case .unavailable(let reason) = current.session.readiness {
                readiness = .unavailable(reason)
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
            var restarted = previous
            restarted.session = newSession
            active = restarted
            slots[restarted.slot] = restarted
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
                    localizedFormat("model.exact.restartExhausted", exactFailureReason(error))
                )
                return .unavailable(localizedFormat("model.exact.restartExhausted", exactFailureReason(error)))
            }
        } catch {
            guard batch?.isCurrent != false, isCurrent(previous) else { return nil }
            readiness = .unavailable(localizedFormat("model.exact.restartFailed", exactFailureReason(error)))
            return .unavailable(localizedFormat("model.exact.restartFailed", exactFailureReason(error)))
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

    private func requestTypeDefinition(
        session: any ExactSession,
        file: String,
        byteOffset: Int,
        batch: ExactRequestBatch?
    ) async throws -> ExactDefinitionQueryResult {
        try await Task.detached(priority: .userInitiated) {
            if let batch {
                try session.typeDefinition(
                    file: file,
                    byteOffset: byteOffset,
                    batch: batch
                )
            } else {
                try session.typeDefinition(file: file, byteOffset: byteOffset)
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
            var restarted = previous
            restarted.session = newSession
            active = restarted
            slots[restarted.slot] = restarted
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
                    localizedFormat("model.exact.restartExhausted", exactFailureReason(error))
                )
                return nil
            }
        } catch {
            guard batch?.isCurrent != false, isCurrent(previous) else { return nil }
            readiness = .unavailable(localizedFormat("model.exact.restartFailed", exactFailureReason(error)))
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
                origin: source.checkoutRoot != nil
                    ? .materialized(commitOID: source.key.versionIdentity)
                    : .worktree
            )
        }
        overlay.store(entries, for: source.key, file: file, byteOffset: byteOffset)
        return .completed(entries)
    }

    private func publishTypeDefinition(
        _ result: ExactDefinitionQueryResult,
        from source: Active,
        file: String,
        byteOffset: Int
    ) -> TypeDefinitionResult? {
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
            // rust-analyzer answers primitive types with toolchain
            // primitive_docs.rs positions; they are not jump targets.
            if workspaceLocation.file.contains("primitive_docs.rs") {
                return nil
            }
            return ExactOverlay.Entry(
                location: workspaceLocation,
                attribution: source.session.attribution,
                origin: source.checkoutRoot != nil
                    ? .materialized(commitOID: source.key.versionIdentity)
                    : .worktree
            )
        }
        overlay.storeTypeDefinition(
            entries, for: source.key, file: file, byteOffset: byteOffset
        )
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
        let origin: ExactOrigin = source.checkoutRoot != nil
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
            // A path under the checkout or workspace is a project file only
            // when the snapshot holds it; anything else there (a borrowed
            // `node_modules`, the venv) stays an absolute dependency path.
            let snapshot = (source.providerSnapshot as? ProfileSnapshot)?.wrapped
                ?? source.providerSnapshot
            var mappedUnderWorkspace: String?
            let roots = [
                source.checkoutRoot,
                source.workspaceRoot,
            ].compactMap { $0 }
            for root in roots {
                if let path = snapshotPath(
                    for: URL(fileURLWithPath: location.file),
                    under: root
                ), (try? snapshot.readBytes(path: path)) != nil {
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
                localizedFormat("model.exact.unsupportedLanguage", String(describing: language)),
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

/// The snapshot-relative path of a file under `root`, or nil when the file
/// lies outside it.
private func snapshotPath(for file: URL, under root: URL) -> String? {
    let rootComponents = root.standardizedFileURL.pathComponents
    let components = file.standardizedFileURL.pathComponents
    guard components.starts(with: rootComponents),
          components.count > rootComponents.count
    else { return nil }
    return components.dropFirst(rootComponents.count).joined(separator: "/")
}

/// Resident memory of a process, for the standby limit; nil when unknown.
private func residentBytes(of pid: Int32) -> UInt64? {
    var info = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else {
        return nil
    }
    return info.pti_resident_size
}

private func makeSnapshot(root: URL, revision: String?) throws -> any Snapshot {
    if let revision {
        return try CommitSnapshot(repositoryURL: root, revision: revision)
    }
    return try WorktreeSnapshot(repositoryURL: root)
}

private func supportedTarget(
    file: String,
    language: LanguageID
) -> Bool {
    exactLocationIsInDependency(file)
        ? dependencyFileLanguageMode(path: file, languages: [language]) != nil
        : LanguageMode.classify(path: file, language: language) != nil
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

private func exactFailureReason(_ error: Error) -> String {
    if case ExactError.unavailable(let detail) = error { return detail }
    return String(describing: error)
}
