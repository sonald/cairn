import CodeInsightCore
import CodeInsightEngine
import Foundation
import Testing
@testable import CodeInsightAppModel

/// SplitMix64: a fixed seed reproduces a failing listing.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let snapshot = SnapshotID(rawValue: UUID())
private let names = ["Log", "append", "Config", "run", "Engine", "_cache", "scan", "State"]

/// Random Rust and Python units: types with fields, impls (some in other
/// files, some sharing a type name), traits with methods, inline modules.
private func randomListings(seed: UInt64) -> [ProjectSymbolListing] {
    var random = SeededGenerator(state: seed)
    func visibility() -> DeclarationVisibility? { [.public, .restricted, .private].randomElement(using: &random) }
    var listings: [ProjectSymbolListing] = []
    for (unit, language) in [LanguageID.rust, .python].enumerated() {
        var files: [ProjectSymbolListing.File] = []
        var symbols: [ProjectSymbol] = []
        for fileIndex in 0..<Int.random(in: 1...4, using: &random) {
            let path = "u\(unit)/\(["src", "src/net", "examples"].randomElement(using: &random)!)/f\(fileIndex).\(language == .rust ? "rs" : "py")"
            let mounted = !path.contains("examples")
            files.append(.init(
                path: path,
                contentID: ContentID(algorithm: 1, bytes: [UInt8(unit), UInt8(fileIndex)]),
                modulePath: language == .python || mounted ? path.split(separator: "/").dropFirst(2).map(String.init) : nil,
                crateRoot: language == .rust && mounted ? "u\(unit)/src/main.rs" : nil
            ))
            var facets: [(DeclarationKind, UInt32?, DeclarationVisibility?)] = []
            for _ in 0..<Int.random(in: 0...6, using: &random) {
                let top = UInt32(facets.count)
                if language == .python {
                    let isClass = Bool.random(using: &random)
                    facets.append((isClass ? .pythonClass : .pythonFunction, nil, visibility()))
                    if isClass {
                        for _ in 0..<Int.random(in: 0...2, using: &random) {
                            facets.append((.pythonFunction, top, visibility()))
                        }
                    }
                    continue
                }
                switch Int.random(in: 0..<6, using: &random) {
                case 0:
                    facets.append((.rustStruct, nil, visibility()))
                    for _ in 0..<Int.random(in: 0...2, using: &random) { facets.append((.rustField, top, visibility())) }
                case 1:
                    facets.append((.rustImpl, nil, nil))
                    for _ in 0..<Int.random(in: 0...3, using: &random) { facets.append((.rustMethod, top, visibility())) }
                case 2:
                    facets.append((.rustTrait, nil, visibility()))
                    for _ in 0..<Int.random(in: 0...2, using: &random) { facets.append((.rustMethod, top, nil)) }
                case 3:
                    facets.append((.rustMod, nil, visibility()))
                    for _ in 0..<Int.random(in: 0...2, using: &random) { facets.append((.rustFn, top, visibility())) }
                case 4: facets.append((.rustEnum, nil, visibility()))
                default: facets.append(([.rustFn, .rustConst, .rustTypeAlias].randomElement(using: &random)!, nil, visibility()))
                }
            }
            for (offset, facet) in facets.enumerated() {
                let start = UInt32(offset * 10)
                symbols.append(ProjectSymbol(
                    occurrence: SymbolOccurrenceID(snapshotID: snapshot, pathID: PathID(rawValue: UInt32(unit * 100 + fileIndex)),
                                                   localKind: .declarationFacet, localIndex: UInt32(offset)),
                    fileIndex: fileIndex,
                    name: names.randomElement(using: &random)!,
                    kind: facet.0,
                    visibility: facet.1 == nil || facet.0 != .rustMethod ? facet.2 : facet.2,
                    nameRange: ByteRange(lowerBound: start, upperBound: start + 3),
                    range: ByteRange(lowerBound: start, upperBound: start + 9),
                    line: UInt32(offset + 1),
                    parentFacetIndex: facet.1,
                    implTraitName: nil
                ))
            }
        }
        listings.append(ProjectSymbolListing(language: language, unitRoot: "u\(unit)", files: files, symbols: symbols))
    }
    return listings
}

@MainActor
private func loaded(_ listings: [ProjectSymbolListing]) async -> ProjectSymbolsPanelModel {
    let model = ProjectSymbolsPanelModel(defaults: UserDefaults(suiteName: NSTemporaryDirectory() + "ProjectSymbolsTests-\(UUID())")!)
    model.load(listings: listings)
    await model.pendingLoad?.value
    return model
}

/// The filter rules restated from the spec, independent of the model.
private func referencePasses(
    _ row: ProjectSymbolRow, text: String, groups: Set<ProjectSymbolGroup>,
    publicOnly: Bool, directory: String?
) -> Bool {
    if !groups.contains(row.group) { return false }
    if publicOnly && !(row.visibility == .public || (row.visibility == nil && row.kind != .rustImpl)) { return false }
    if let directory, !(row.path == directory || row.path.hasPrefix(directory + "/")) { return false }
    // Text matching is `⌘P #`'s own matcher (tested in the engine); the
    // property under test is how the tree keeps and counts what it matches.
    return text.isEmpty || SymbolNameMatcher(names: names).matches(text)[row.name] != nil
}

@MainActor
@Test(arguments: 0..<40)
func projectSymbolsKeepContainersExactlyForMatchingDescendantsAndCountVisibleRows(seed: Int) async {
    let listings = randomListings(seed: UInt64(seed))
    let model = await loaded(listings)
    var random = SeededGenerator(state: UInt64(seed) &* 31)
    for organization in ProjectSymbolOrganization.allCases {
        model.setOrganization(organization)
        for _ in 0..<6 {
            let text = ["", "", "log", "ap", "cfg", "st"].randomElement(using: &random)!
            let groups = Set(ProjectSymbolGroup.allCases.filter { _ in Int.random(in: 0..<5, using: &random) > 0 })
            let publicOnly = Bool.random(using: &random)
            let directory: String? = Bool.random(using: &random) ? "u0/src" : nil
            model.setFilterText(text)
            for group in ProjectSymbolGroup.allCases { model.setGroup(group, enabled: groups.contains(group)) }
            model.setPublicOnly(publicOnly)
            model.setCurrentFile(directory.map { $0 + "/x.rs" })
            model.setScope(directory == nil ? .project : .currentDirectory)

            func passes(_ node: Int) -> Bool {
                guard case let .symbol(row, _) = model.node(node)!.content else { return false }
                return referencePasses(model.row(row)!, text: text, groups: groups,
                                       publicOnly: publicOnly, directory: directory)
            }
            // Expected visibility, bottom-up over the full tree.
            func expectedVisible(_ node: Int) -> Bool {
                let content = model.node(node)!.content
                let anyChild = model.node(node)!.children.map(expectedVisible).contains(true)
                switch content {
                case let .group(group): return groups.contains(group) && anyChild
                case .symbol: return passes(node) || anyChild
                default: return anyChild || node == model.rootNode
                }
            }
            func selfPassingNodes(under node: Int) -> Int {
                model.node(node)!.children.reduce(0) { total, child in
                    total + (model.isVisible(child) && passes(child) ? 1 : 0) + selfPassingNodes(under: child)
                }
            }
            var pending = [model.rootNode]
            while let node = pending.popLast() {
                let label = "seed \(seed) \(organization) text=\(text) node \(model.key(of: node))"
                #expect(model.isVisible(node) == expectedVisible(node), "\(label)")
                if case .symbol = model.node(node)!.content {
                    #expect(model.isDimmed(node) == !passes(node), "\(label)")
                }
                let shown = model.visibleChildren(of: node)
                #expect(Set(shown) == Set(model.node(node)!.children.filter(expectedVisible)), "\(label)")
                switch model.node(node)!.content {
                case .group:
                    #expect(model.count(of: node) == shown.filter { !model.isDimmed($0) }.count, "\(label)")
                case .symbol, .root:
                    break
                default:
                    #expect(model.count(of: node) == selfPassingNodes(under: node), "\(label)")
                }
                pending += model.node(node)!.children
            }
            var expectedRows = 0
            var index = 0
            while let row = model.row(index) {
                if referencePasses(row, text: text, groups: groups, publicOnly: publicOnly, directory: directory) {
                    expectedRows += 1
                }
                index += 1
            }
            #expect(model.summary.shown == expectedRows)
            #expect(model.summary.total == index)
        }
    }
}

@MainActor
@Test(arguments: 0..<20)
func projectSymbolsRestoreSelectionOnlyWhenContentIDMatches(seed: Int) async {
    let listings = randomListings(seed: UInt64(seed) + 1_000)
    let model = await loaded(listings)
    var index = 0
    var rows: [Int] = []
    while model.row(index) != nil { rows.append(index); index += 1 }
    var random = SeededGenerator(state: UInt64(seed))
    guard let chosen = rows.randomElement(using: &random),
          let node = model.node(forRow: chosen)
    else { return }
    model.select(node: node)
    let target = model.selectedTarget!

    // Same bytes in a new snapshot: the selection follows.
    model.load(listings: listings)
    await model.pendingLoad?.value
    #expect(model.selectedTarget?.path == target.path)
    #expect(model.selectedTarget?.nameRange == target.nameRange)
    #expect(model.selectedTarget?.contentID == target.contentID)

    // The file changed (another content ID, same path and range): cleared.
    let changed = listings.map { listing in
        ProjectSymbolListing(
            language: listing.language, unitRoot: listing.unitRoot,
            files: listing.files.map {
                .init(path: $0.path, contentID: $0.path == target.path ? ContentID(algorithm: 1, bytes: [0xFF]) : $0.contentID,
                      modulePath: $0.modulePath, crateRoot: $0.crateRoot)
            },
            symbols: listing.symbols
        )
    }
    model.load(listings: changed)
    await model.pendingLoad?.value
    #expect(model.selectedTarget == nil)
}

@MainActor
@Test
func projectSymbolsMergeImplsAcrossFilesOnlyForUniqueTypeNames() async {
    func symbol(_ file: Int, _ index: UInt32, _ name: String, _ kind: DeclarationKind, parent: UInt32? = nil) -> ProjectSymbol {
        ProjectSymbol(
            occurrence: SymbolOccurrenceID(snapshotID: snapshot, pathID: PathID(rawValue: UInt32(file)), localKind: .declarationFacet, localIndex: index),
            fileIndex: file, name: name, kind: kind, visibility: kind == .rustImpl ? nil : .public,
            nameRange: ByteRange(lowerBound: index * 10, upperBound: index * 10 + 3),
            range: ByteRange(lowerBound: index * 10, upperBound: index * 10 + 9),
            line: index + 1, parentFacetIndex: parent, implTraitName: nil
        )
    }
    let files = ["src/main.rs", "src/a.rs", "src/b.rs"].enumerated().map { offset, path in
        ProjectSymbolListing.File(path: path, contentID: ContentID(algorithm: 1, bytes: [UInt8(offset)]),
                                  modulePath: [], crateRoot: "src/main.rs")
    }
    let listing = ProjectSymbolListing(language: .rust, unitRoot: ".", files: files, symbols: [
        symbol(0, 0, "Log", .rustStruct),        // unique name: other files' impls merge
        symbol(1, 0, "Log", .rustImpl),
        symbol(1, 1, "append", .rustMethod, parent: 0),
        symbol(1, 2, "Config", .rustStruct),     // declared twice: only same-file impls
        symbol(1, 3, "Config", .rustImpl),
        symbol(2, 0, "Config", .rustStruct),
        symbol(2, 1, "Config", .rustImpl),
        symbol(0, 1, "Config", .rustImpl),
    ])
    let model = await loaded([listing])
    let typeGroup = model.visibleChildren(of: model.rootNode).first { model.node($0)?.content == .group(.type) }!
    func children(ofType name: String, in path: String) -> [ProjectSymbolNode.Content] {
        let node = model.visibleChildren(of: typeGroup).first {
            guard case let .symbol(row, _) = model.node($0)!.content else { return false }
            return model.row(row)!.name == name && model.row(row)!.path == path
        }!
        return model.visibleChildren(of: node).map { model.node($0)!.content }
    }
    let log = children(ofType: "Log", in: "src/main.rs")
    #expect(log.count == 1)
    if case let .symbol(_, merged) = log.first { #expect(merged) }
    for path in ["src/a.rs", "src/b.rs"] {
        let config = children(ofType: "Config", in: path)
        #expect(config.count == 1, "\(path)")
        if case let .symbol(row, merged) = config.first {
            #expect(!merged && model.row(row)!.path == path)
        }
    }
}

@MainActor
@Test
func projectSymbolsFollowFirstPaintThenFullSilentlyAndGoStaleAcrossCommits() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectSymbols-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "pub struct Log;\nimpl Log { pub fn append(&self) {} }\n"
        .write(to: root.appendingPathComponent("main.rs"), atomically: true, encoding: .utf8)
    let initial = try ProjectIndexer().index(root: root)
    let service = ControlledSnapshotIndexService(
        initialSnapshotID: initial.snapshotID,
        snapshots: ["C": TestSnapshot(label: "C", files: [
            "main.rs": "pub struct Log;\nimpl Log { pub fn append(&self) {} }\n",
            "extra.rs": "fn extra() {}\n",
        ])],
        blockedCached: ["C"],
        blockedFull: ["C"]
    )
    let app = AppModel(indexService: service)
    let panel = ProjectSymbolsPanelModel(defaults: UserDefaults(suiteName: NSTemporaryDirectory() + "ProjectSymbolsTests-\(UUID())")!)
    app.openProject(root: root)
    #expect(await testWaitUntil("full") { app.snapshotPhase == .fullReady })
    panel.update(from: app)
    await panel.pendingLoad?.value
    #expect(panel.status == .ready)
    panel.setOrganization(.kind)

    let methodGroup = panel.visibleChildren(of: panel.rootNode).first { panel.node($0)?.content == .group(.method) }!
    let append = panel.visibleChildren(of: methodGroup).first!
    panel.select(node: append)
    panel.expandedKeys = [panel.key(of: methodGroup)]
    let selected = try #require(panel.selectedTarget)

    app.switchToCommit("C")
    #expect(await testWaitUntil("first paint") { app.snapshotPhase == .firstPaint })
    panel.update(from: app)
    #expect(panel.isStale)
    #expect(panel.selectedTarget == nil, "stale rows cannot be opened")

    await service.releaseCached("C")
    #expect(await testWaitUntil("cached") { app.snapshotPhase == .cachedReady })
    panel.update(from: app)
    await panel.pendingLoad?.value
    #expect(!panel.isStale)
    #expect(panel.selectedTarget?.path == selected.path)
    #expect(panel.selectedTarget?.nameRange == selected.nameRange)

    await service.releaseFull("C")
    #expect(await testWaitUntil("full C") { app.snapshotPhase == .fullReady })
    panel.update(from: app)
    #expect(!panel.isStale, "the same snapshot replaces the list silently")
    await panel.pendingLoad?.value
    #expect(panel.selectedTarget?.path == selected.path)
    #expect(panel.expandedKeys == [panel.key(of: methodGroup)])
    #expect(panel.summary.files == 2)
}
