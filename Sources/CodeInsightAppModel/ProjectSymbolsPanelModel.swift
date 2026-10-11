import CodeInsightCore
import CodeInsightEngine
import Foundation
import Observation

/// The project-symbols panel's kind groups. `field` is only a filter: fields
/// appear under their type, never as a group of their own.
public enum ProjectSymbolGroup: String, CaseIterable, Sendable {
    case function, method, type, enumeration, trait, typeAlias, impl, module, value, field

    public static let groups: [ProjectSymbolGroup] = allCases.filter { $0 != .field }
}

public enum ProjectSymbolOrganization: String, CaseIterable, Sendable {
    case kind, module
}

public enum ProjectSymbolScope: String, CaseIterable, Sendable {
    case project, currentDirectory
}

/// One declaration of the merged listings.
public struct ProjectSymbolRow: Sendable {
    public let symbol: ProjectSymbol
    public let unit: Int
    /// Manifest path.
    public let path: String
    public let contentID: ContentID
    public let group: ProjectSymbolGroup
    /// The enclosing row in the same file, if any.
    public let parentRow: Int?
    public var name: String { symbol.name }
    public var kind: DeclarationKind { symbol.kind }
    public var visibility: DeclarationVisibility? { symbol.visibility }
}

/// A node of the panel's tree. Every row appears once as a direct listing
/// and again under its container wherever that container is expanded.
public struct ProjectSymbolNode: Sendable {
    public enum Content: Sendable, Equatable {
        case root
        case group(ProjectSymbolGroup)
        /// An analysis unit (language and root), shown only with several units.
        case unit(Int)
        /// A Rust crate root file (path relative to the unit root).
        case crate(String)
        case module(String)
        /// Files no crate root reaches (`examples/`, `tests/`, unmounted).
        case unmounted
        case file(String)
        /// `mergedByName`: an impl in another file attached to a type only
        /// because the type's name is unique in its unit (D7).
        case symbol(row: Int, mergedByName: Bool)
    }

    public let content: Content
    public let parent: Int?
    public fileprivate(set) var children: [Int] = []
    /// This node's part of its expansion key.
    let keyComponent: String
}

/// The data and tree for one load; immutable, built off the main thread.
struct ProjectSymbolsData: Sendable {
    let listings: [ProjectSymbolListing]
    let rows: [ProjectSymbolRow]
    let childRows: [[Int]]
    let matcher: SymbolNameMatcher
    let fileCount: Int

    init(listings: [ProjectSymbolListing]) {
        self.listings = listings
        struct FileKey: Hashable { let unit: Int; let file: Int }
        var flat: [(unit: Int, symbol: ProjectSymbol)] = []
        for (unit, listing) in listings.enumerated() {
            flat += listing.symbols.map { (unit, $0) }
        }
        var rowByFacet: [FileKey: [UInt32: Int]] = [:]
        for (index, entry) in flat.enumerated() {
            rowByFacet[FileKey(unit: entry.unit, file: entry.symbol.fileIndex), default: [:]][entry.symbol.facetIndex] = index
        }
        let parents: [Int?] = flat.map { entry in
            entry.symbol.parentFacetIndex.flatMap {
                rowByFacet[FileKey(unit: entry.unit, file: entry.symbol.fileIndex)]?[$0]
            }
        }
        rows = flat.enumerated().map { index, entry in
            let file = listings[entry.unit].files[entry.symbol.fileIndex]
            return ProjectSymbolRow(
                symbol: entry.symbol,
                unit: entry.unit,
                path: file.path,
                contentID: file.contentID,
                group: Self.group(of: entry.symbol.kind, parentKind: parents[index].map { flat[$0].symbol.kind }),
                parentRow: parents[index]
            )
        }
        var childRows = Array(repeating: [Int](), count: flat.count)
        for (index, parent) in parents.enumerated() {
            if let parent { childRows[parent].append(index) }
        }
        self.childRows = childRows
        matcher = SymbolNameMatcher(names: Set(flat.map(\.symbol.name)))
        fileCount = listings.reduce(0) { $0 + $1.files.count }
    }

    /// B1.3: a method is a function whose parent is a type, impl or trait.
    static func group(of kind: DeclarationKind, parentKind: DeclarationKind?) -> ProjectSymbolGroup {
        switch kind.shape {
        case .function:
            guard let parentKind else { return .function }
            return [.struct, .enum, .class, .trait, .impl].contains(parentKind.shape) ? .method : .function
        case .struct, .class: return .type
        case .enum: return .enumeration
        case .trait: return .trait
        case .typeAlias: return .typeAlias
        case .impl: return .impl
        case .module: return .module
        case .value: return kind == .rustField ? .field : .value
        }
    }
}

struct ProjectSymbolsTree: Sendable {
    private(set) var nodes: [ProjectSymbolNode] = [ProjectSymbolNode(content: .root, parent: nil, keyComponent: "")]
    /// Each row's direct listing (its group entry or its module entry).
    private(set) var primaryNode: [Int?]

    init(data: ProjectSymbolsData, organization: ProjectSymbolOrganization) {
        primaryNode = Array(repeating: nil, count: data.rows.count)
        let order = data.rows.indices.sorted {
            let lhs = data.rows[$0], rhs = data.rows[$1]
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            return lhs.symbol.nameRange.lowerBound < rhs.symbol.nameRange.lowerBound
        }
        switch organization {
        case .kind: buildByKind(data: data, order: order)
        case .module: buildByModule(data: data, order: order)
        }
    }

    private mutating func add(_ content: ProjectSymbolNode.Content, under parent: Int, key: String) -> Int {
        let index = nodes.count
        nodes.append(ProjectSymbolNode(content: content, parent: parent, keyComponent: key))
        nodes[parent].children.append(index)
        return index
    }

    /// `listing`: the row's own entry (its group or module), which locate
    /// and selection prefer over its copies under expanded containers.
    private mutating func addSymbol(
        _ row: Int, under parent: Int, data: ProjectSymbolsData, listing: Bool = false,
        mergedByName: Bool = false, implsByType: ((Int) -> [(row: Int, merged: Bool)])? = nil
    ) {
        let symbol = data.rows[row]
        let node = add(
            .symbol(row: row, mergedByName: mergedByName), under: parent,
            key: "\(symbol.path)|\(symbol.kind.rawValue)|\(symbol.name)"
        )
        if listing || primaryNode[row] == nil { primaryNode[row] = node }
        for child in data.childRows[row] {
            addSymbol(child, under: node, data: data, implsByType: implsByType)
        }
        for impl in implsByType?(row) ?? [] {
            addSymbol(impl.row, under: node, data: data, mergedByName: impl.merged)
        }
    }

    private mutating func buildByKind(data: ProjectSymbolsData, order: [Int]) {
        // D7: same-file impls always; other files' only for a name declared
        // by exactly one type in the unit.
        struct UnitName: Hashable { let unit: Int; let name: String }
        var impls: [UnitName: [Int]] = [:]
        var typeCount: [UnitName: Int] = [:]
        for row in order {
            let entry = data.rows[row]
            let key = UnitName(unit: entry.unit, name: entry.name)
            switch entry.kind {
            case .rustImpl: impls[key, default: []].append(row)
            case .rustStruct, .rustEnum, .rustTrait, .rustTypeAlias: typeCount[key, default: 0] += 1
            default: break
            }
        }
        let implsByType: (Int) -> [(row: Int, merged: Bool)] = { row in
            let entry = data.rows[row]
            guard entry.kind == .rustStruct || entry.kind == .rustEnum else { return [] }
            let key = UnitName(unit: entry.unit, name: entry.name)
            let unique = typeCount[key] == 1
            return (impls[key] ?? []).compactMap { impl in
                let sameFile = data.rows[impl].path == entry.path
                return sameFile || unique ? (impl, !sameFile) : nil
            }
        }
        var groups: [ProjectSymbolGroup: Int] = [:]
        for group in ProjectSymbolGroup.groups {
            groups[group] = add(.group(group), under: 0, key: "group:\(group.rawValue)")
        }
        for row in order {
            guard let group = groups[data.rows[row].group] else { continue }
            addSymbol(row, under: group, data: data, listing: true, implsByType: implsByType)
        }
    }

    private mutating func buildByModule(data: ProjectSymbolsData, order: [Int]) {
        var topLevel: [Int: [Int]] = [:]  // file key → rows without a parent
        func fileKey(_ row: ProjectSymbolRow) -> Int { row.unit << 32 | row.symbol.fileIndex }
        for row in order where data.rows[row].parentRow == nil {
            topLevel[fileKey(data.rows[row]), default: []].append(row)
        }
        let multipleUnits = data.listings.count > 1
        for (unit, listing) in data.listings.enumerated() {
            let unitNode = multipleUnits ? add(.unit(unit), under: 0, key: "unit:\(listing.unitRoot)") : 0
            // A module trie per root; files attach where their path ends.
            var trie: [Int: [String: Int]] = [:]
            var pendingSymbols: [Int: [Int]] = [:]
            func node(for components: [String], from start: Int, finalFile: String?) -> Int {
                var current = start
                for (offset, component) in components.enumerated() {
                    if let next = trie[current]?[component] { current = next; continue }
                    let isFile = finalFile != nil && offset == components.count - 1
                    let next = nodes.count
                    nodes.append(ProjectSymbolNode(
                        content: isFile ? .file(finalFile!) : .module(component),
                        parent: current,
                        keyComponent: "mod:\(component)"
                    ))
                    trie[current, default: [:]][component] = next
                    current = next
                }
                return current
            }
            let relative = { (path: String) -> String in
                listing.unitRoot == "." || !path.hasPrefix(listing.unitRoot + "/")
                    ? path : String(path.dropFirst(listing.unitRoot.count + 1))
            }
            var crates: [String: Int] = [:]
            var unmounted: Int?
            var unmountedFiles: [(String, Int)] = []
            for (fileIndex, file) in listing.files.enumerated() {
                let rows = topLevel[unit << 32 | fileIndex] ?? []
                let target: Int
                if listing.language == .rust {
                    if let root = file.crateRoot, let path = file.modulePath {
                        let crate = crates[root] ?? {
                            let index = nodes.count
                            nodes.append(ProjectSymbolNode(content: .crate(relative(root)), parent: unitNode, keyComponent: "crate:\(root)"))
                            crates[root] = index
                            return index
                        }()
                        target = node(for: path, from: crate, finalFile: nil)
                    } else {
                        let holder = unmounted ?? {
                            let index = nodes.count
                            nodes.append(ProjectSymbolNode(content: .unmounted, parent: unitNode, keyComponent: "unmounted"))
                            unmounted = index
                            return index
                        }()
                        let index = nodes.count
                        nodes.append(ProjectSymbolNode(content: .file(relative(file.path)), parent: holder, keyComponent: "file:\(file.path)"))
                        unmountedFiles.append((relative(file.path), index))
                        target = index
                    }
                } else {
                    let components = file.modulePath ?? relative(file.path).split(separator: "/").map(String.init)
                    target = node(for: components, from: unitNode,
                                  finalFile: listing.language == .typescript ? relative(file.path) : nil)
                }
                pendingSymbols[target, default: []] += rows
            }
            // Children: the module's own declarations by position, then its
            // submodules by name; crates by path, unmounted files last.
            func finish(_ index: Int) {
                for row in pendingSymbols[index] ?? [] {
                    addSymbol(row, under: index, data: data)
                }
                for (_, child) in (trie[index] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    nodes[index].children.append(child)
                    finish(child)
                }
            }
            for (_, crate) in crates.sorted(by: { $0.key < $1.key }) {
                nodes[unitNode].children.append(crate)
                finish(crate)
            }
            if listing.language != .rust {
                let ownRows = pendingSymbols[unitNode] ?? []
                pendingSymbols[unitNode] = nil
                for row in ownRows { addSymbol(row, under: unitNode, data: data) }
                for (_, child) in (trie[unitNode] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    nodes[unitNode].children.append(child)
                    finish(child)
                }
            }
            if let unmounted {
                nodes[unitNode].children.append(unmounted)
                for (_, file) in unmountedFiles.sorted(by: { $0.0 < $1.0 }) {
                    nodes[unmounted].children.append(file)
                    finish(file)
                }
            }
        }
    }
}

@MainActor
@Observable
public final class ProjectSymbolsPanelModel {
    public enum Status: Equatable, Sendable {
        case empty
        case indexing
        case ready
    }

    public enum LocateResult: Equatable, Sendable {
        case found(Int)
        case hiddenByFilter
        case notFound
    }

    public private(set) var status: Status = .empty
    /// The list comes from a previous snapshot; rows cannot be opened.
    public private(set) var isStale = false
    public private(set) var organization: ProjectSymbolOrganization
    public private(set) var enabledGroups: Set<ProjectSymbolGroup>
    public private(set) var publicOnly: Bool
    public private(set) var scope: ProjectSymbolScope
    public private(set) var filterText = ""
    /// Directory (manifest path) of the focused source file, for `.currentDirectory`.
    public private(set) var currentDirectory: String?
    public private(set) var selectedRow: Int?
    /// Bumps whenever the visible tree changes shape.
    public private(set) var revision: UInt64 = 0
    public var expandedKeys: Set<String> = []

    @ObservationIgnored private var data: ProjectSymbolsData?
    @ObservationIgnored private var tree: ProjectSymbolsTree?
    @ObservationIgnored private var selfPasses: [Bool] = []
    @ObservationIgnored private var visible: [Bool] = []
    @ObservationIgnored private var counts: [Int] = []
    @ObservationIgnored private var matches: [String: SymbolNameMatcher.Match] = [:]
    @ObservationIgnored private var visibleChildCache: [Int: [Int]] = [:]
    @ObservationIgnored private var passingRowCount = 0
    @ObservationIgnored private var sessionKeys: [SessionKey] = []
    @ObservationIgnored private var loadID: UInt64 = 0
    @ObservationIgnored private var selectionToRestore: (path: String, contentID: ContentID, nameRange: ByteRange)?
    @ObservationIgnored private let defaults: UserDefaults
    /// The running load, for tests that await it.
    @ObservationIgnored package private(set) var pendingLoad: Task<Void, Never>?
    @ObservationIgnored package private(set) var lastLoadMilliseconds: Double?

    private struct SessionKey: Equatable {
        let session: ObjectIdentifier
        let snapshotID: SnapshotID
        let profileID: AnalysisProfileID
        let generation: UInt64
    }

    private enum Keys {
        static let organization = "ProjectSymbols.organization"
        static let hiddenGroups = "ProjectSymbols.hiddenGroups"
        static let publicOnly = "ProjectSymbols.publicOnly"
        static let scope = "ProjectSymbols.scope"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        organization = defaults.string(forKey: Keys.organization)
            .flatMap(ProjectSymbolOrganization.init(rawValue:)) ?? .kind
        let hidden = Set((defaults.stringArray(forKey: Keys.hiddenGroups) ?? [])
            .compactMap(ProjectSymbolGroup.init(rawValue:)))
        enabledGroups = Set(ProjectSymbolGroup.allCases).subtracting(hidden)
        publicOnly = defaults.bool(forKey: Keys.publicOnly)
        scope = defaults.string(forKey: Keys.scope)
            .flatMap(ProjectSymbolScope.init(rawValue:)) ?? .project
    }

    // MARK: Loading

    /// Follows the window's query sessions. The same snapshots replace the
    /// list silently (first paint → full index); other snapshots mark the
    /// list stale until the new one arrives (B5).
    public func update(sessions: [(EngineSession, QueryContext)], indexing: Bool) {
        let keys = sessions.map {
            SessionKey(session: ObjectIdentifier($0.0), snapshotID: $0.1.snapshotID,
                       profileID: $0.1.analysisProfileID, generation: $0.1.generation)
        }
        guard keys != sessionKeys else { return }
        guard !sessions.isEmpty else {
            if indexing {
                if data != nil { markStale() } else { status = .indexing }
                return
            }
            sessionKeys = []
            loadID &+= 1
            pendingLoad?.cancel()
            clear()
            return
        }
        let sameSnapshots = Set(keys.map(\.snapshotID)) == Set(sessionKeys.map(\.snapshotID))
        sessionKeys = keys
        if !sameSnapshots, data != nil { markStale() }
        if data == nil { status = .indexing }
        let captured = sessions
        load { try captured.map { session, context in try session.projectSymbols(context: context) } }
    }

    /// The window's state: its query sessions once cached or full; while a
    /// project indexes (or shows its first paint) the old list stays, stale.
    public func update(from appModel: AppModel) {
        let sessions = appModel.querySessions
        let indexing: Bool = switch appModel.projectState {
        case .indexing, .ready: true
        case .empty, .failed: false
        }
        update(sessions: sessions, indexing: indexing)
    }

    /// Loads listings directly (tests).
    package func load(listings: [ProjectSymbolListing]) {
        load { listings }
    }

    private func load(_ listings: @escaping @Sendable () throws -> [ProjectSymbolListing]) {
        loadID &+= 1
        let id = loadID
        let organization = organization
        pendingLoad?.cancel()
        pendingLoad = Task { [weak self] in
            let started = ContinuousClock.now
            let built = await Task.detached(priority: .userInitiated) { () -> (ProjectSymbolsData, ProjectSymbolsTree)? in
                // B5.3: one stale session voids the whole result.
                guard let listings = try? listings() else { return nil }
                let data = ProjectSymbolsData(listings: listings)
                return (data, ProjectSymbolsTree(data: data, organization: organization))
            }.value
            guard let self, self.loadID == id, let built else { return }
            let parts = started.duration(to: .now).components
            self.lastLoadMilliseconds = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
            self.install(data: built.0, tree: built.1)
        }
    }

    private func install(data: ProjectSymbolsData, tree: ProjectSymbolsTree) {
        if let selectedRow, let old = self.data, old.rows.indices.contains(selectedRow), selectionToRestore == nil {
            let row = old.rows[selectedRow]
            selectionToRestore = (row.path, row.contentID, row.symbol.nameRange)
        }
        self.data = data
        self.tree = tree
        status = .ready
        isStale = false
        matches = filterText.isEmpty ? [:] : data.matcher.matches(filterText)
        selectedRow = selectionToRestore.flatMap { wanted in
            data.rows.indices.first {
                data.rows[$0].path == wanted.path && data.rows[$0].contentID == wanted.contentID
                    && data.rows[$0].symbol.nameRange == wanted.nameRange
            }
        }
        selectionToRestore = nil
        refilter()
    }

    private func markStale() {
        guard !isStale else { return }
        if let selectedRow, let data, data.rows.indices.contains(selectedRow) {
            let row = data.rows[selectedRow]
            selectionToRestore = (row.path, row.contentID, row.symbol.nameRange)
        }
        isStale = true
    }

    private func clear() {
        data = nil
        tree = nil
        status = .empty
        isStale = false
        selectedRow = nil
        selectionToRestore = nil
        refilter()
    }

    // MARK: Filters and preferences

    public func setOrganization(_ organization: ProjectSymbolOrganization) {
        guard organization != self.organization else { return }
        self.organization = organization
        defaults.set(organization.rawValue, forKey: Keys.organization)
        guard let data else { return }
        // Switching rebuilds the tree from the same rows; no re-enumeration.
        tree = ProjectSymbolsTree(data: data, organization: organization)
        refilter()
    }

    public func setGroup(_ group: ProjectSymbolGroup, enabled: Bool) {
        guard enabledGroups.contains(group) != enabled else { return }
        if enabled { enabledGroups.insert(group) } else { enabledGroups.remove(group) }
        defaults.set(ProjectSymbolGroup.allCases.filter { !enabledGroups.contains($0) }.map(\.rawValue),
                     forKey: Keys.hiddenGroups)
        refilter()
    }

    public func setPublicOnly(_ enabled: Bool) {
        guard publicOnly != enabled else { return }
        publicOnly = enabled
        defaults.set(enabled, forKey: Keys.publicOnly)
        refilter()
    }

    public func setScope(_ scope: ProjectSymbolScope) {
        guard self.scope != scope else { return }
        self.scope = scope
        defaults.set(scope.rawValue, forKey: Keys.scope)
        refilter()
    }

    public func setFilterText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != filterText else { return }
        filterText = trimmed
        matches = trimmed.isEmpty ? [:] : (data?.matcher.matches(trimmed) ?? [:])
        refilter()
    }

    /// The focused source file (manifest path); the current-directory scope
    /// lists its directory and below.
    public func setCurrentFile(_ path: String?) {
        let directory = path.map { $0.split(separator: "/").dropLast().joined(separator: "/") }
        let resolved = directory.map { $0.isEmpty ? "." : $0 }
        guard resolved != currentDirectory else { return }
        currentDirectory = resolved
        if scope == .currentDirectory { refilter() }
    }

    // MARK: Filtering

    private func rowPasses(_ row: ProjectSymbolRow) -> Bool {
        guard enabledGroups.contains(row.group) else { return false }
        if publicOnly {
            // "Not applicable" leaves pass; an impl block passes only through
            // its members (B3.3).
            let passes = row.visibility == .public || (row.visibility == nil && row.group != .impl)
            if !passes { return false }
        }
        if scope == .currentDirectory, let currentDirectory,
           !isWithin(root: currentDirectory, path: row.path) { return false }
        return filterText.isEmpty || matches[row.name] != nil
    }

    private func refilter() {
        revision &+= 1
        visibleChildCache = [:]
        guard let tree, let data else {
            selfPasses = []; visible = []; counts = []; passingRowCount = 0
            return
        }
        let rowPass = data.rows.map(rowPasses)
        passingRowCount = rowPass.filter { $0 }.count
        let nodes = tree.nodes
        selfPasses = nodes.map {
            if case let .symbol(row, _) = $0.content { return rowPass[row] }
            return false
        }
        visible = Array(repeating: false, count: nodes.count)
        counts = Array(repeating: 0, count: nodes.count)
        // Children always follow their parent, so one reverse pass settles
        // every subtree.
        for index in nodes.indices.reversed() {
            let node = nodes[index]
            let anyChild = node.children.contains { visible[$0] }
            switch node.content {
            case let .group(group):
                visible[index] = enabledGroups.contains(group) && anyChild
                counts[index] = node.children.filter { visible[$0] && selfPasses[$0] }.count
            case .symbol:
                visible[index] = selfPasses[index] || anyChild
                counts[index] = (selfPasses[index] ? 1 : 0) + node.children.reduce(0) { $0 + counts[$1] }
            default:
                visible[index] = anyChild || index == 0
                counts[index] = node.children.reduce(0) { $0 + counts[$1] }
            }
        }
    }

    // MARK: Tree access (lazy: the view asks only for expanded nodes)

    public var rootNode: Int { 0 }

    public func node(_ index: Int) -> ProjectSymbolNode? {
        tree.flatMap { $0.nodes.indices.contains(index) ? $0.nodes[index] : nil }
    }

    public func row(_ index: Int) -> ProjectSymbolRow? {
        data.flatMap { $0.rows.indices.contains(index) ? $0.rows[index] : nil }
    }

    public func listing(_ unit: Int) -> ProjectSymbolListing? {
        data.flatMap { $0.listings.indices.contains(unit) ? $0.listings[unit] : nil }
    }

    /// Visible children; with filter text a group lists its rows by score.
    public func visibleChildren(of index: Int) -> [Int] {
        if let cached = visibleChildCache[index] { return cached }
        guard let tree, tree.nodes.indices.contains(index) else { return [] }
        var children = tree.nodes[index].children.filter { visible[$0] }
        if !filterText.isEmpty, case .group = tree.nodes[index].content, let data {
            func score(_ node: Int) -> Double {
                guard case let .symbol(row, _) = tree.nodes[node].content else { return 0 }
                return matches[data.rows[row].name]?.score ?? 0
            }
            children = children.enumerated().sorted {
                let lhs = score($0.element), rhs = score($1.element)
                return lhs != rhs ? lhs > rhs : $0.offset < $1.offset
            }.map(\.element)
        }
        visibleChildCache[index] = children
        return children
    }

    public func isVisible(_ index: Int) -> Bool { visible.indices.contains(index) && visible[index] }
    /// A container kept only for its matching descendants (shown dimmed).
    public func isDimmed(_ index: Int) -> Bool {
        guard let node = node(index), case .symbol = node.content else { return false }
        return !selfPasses[index]
    }
    public func count(of index: Int) -> Int { counts.indices.contains(index) ? counts[index] : 0 }
    public func matchRanges(for name: String) -> [Range<Int>] { matches[name]?.ranges ?? [] }

    /// Footer numbers: rows passing the filters, every row, files, languages.
    public var summary: (shown: Int, total: Int, files: Int, languages: [LanguageID], filtered: Bool) {
        let total = data?.rows.count ?? 0
        let languages = Array(Set(data?.listings.map(\.language) ?? []))
            .sorted { $0.rawValue < $1.rawValue }
        let filtered = !filterText.isEmpty || publicOnly || scope == .currentDirectory
            || enabledGroups.count < ProjectSymbolGroup.allCases.count
        return (passingRowCount, total, data?.fileCount ?? 0, languages, filtered)
    }

    public var isMultiLanguage: Bool { Set(data?.listings.map(\.language) ?? []).count > 1 }

    public func key(of index: Int) -> String {
        var parts: [String] = []
        var current: Int? = index
        while let node = current.flatMap(node(_:)) {
            parts.append(node.keyComponent)
            current = node.parent
        }
        return parts.reversed().joined(separator: "/")
    }

    // MARK: Selection and navigation

    public func select(node index: Int?) {
        guard let index, let node = node(index), case let .symbol(row, _) = node.content else {
            selectedRow = nil
            return
        }
        selectedRow = row
    }

    /// Where the selected row lives; `nil` while the list is stale.
    public var selectedTarget: (path: String, nameRange: ByteRange, contentID: ContentID)? {
        guard !isStale, let selectedRow, let row = row(selectedRow) else { return nil }
        return (row.path, row.symbol.nameRange, row.contentID)
    }

    /// The row's node in the current tree (its own listing first).
    public func node(forRow row: Int) -> Int? { tree?.primaryNode[row] }

    /// B4.4: the declaration named at `offset` (Context's target), else the
    /// innermost one holding it (the caret).
    public func locate(path: String, offset: UInt32) -> LocateResult {
        guard let data else { return .notFound }
        let candidates = data.rows.indices.filter { data.rows[$0].path == path }
        let named = candidates.first { data.rows[$0].symbol.nameRange.contains(offset) }
        let holding = candidates.filter { data.rows[$0].symbol.range.contains(offset) }
            .min { data.rows[$0].symbol.range.count < data.rows[$1].symbol.range.count }
        guard let row = named ?? holding, let node = node(forRow: row) else { return .notFound }
        var ancestor: Int? = node
        while let current = ancestor {
            guard visible[current] else { return .hiddenByFilter }
            ancestor = tree?.nodes[current].parent
        }
        selectedRow = row
        return .found(node)
    }

    /// `raft::log::Log::append`: the file's module path, the enclosing
    /// declarations, then the name.
    public func qualifiedName(ofRow index: Int) -> String? {
        guard let data, let row = row(index) else { return nil }
        let file = data.listings[row.unit].files[row.symbol.fileIndex]
        var module = file.modulePath ?? []
        if data.listings[row.unit].language == .typescript, let last = module.popLast() {
            module.append(last.split(separator: ".").first.map(String.init) ?? last)
        }
        var chain: [String] = [row.name]
        var parent = row.parentRow
        while let current = parent {
            chain.append(data.rows[current].name)
            parent = data.rows[current].parentRow
        }
        return (module + chain.reversed()).joined(separator: row.kind.qualifiedNameSeparator)
    }
}

private extension ByteRange {
    func contains(_ offset: UInt32) -> Bool { lowerBound <= offset && offset <= upperBound }
    var count: UInt32 { upperBound - lowerBound }
}
