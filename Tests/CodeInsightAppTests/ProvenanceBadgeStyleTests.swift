@testable import CodeInsightApp
import CodeInsightExact
import Foundation
import Testing

@Test func provenanceBadgeStyleTracksCertaintyText() {
    #expect(provenanceBadgeStyle(for: "Exact · lsp") == .exact)
    #expect(provenanceBadgeStyle(for: "Strong · direct") == .strong)
    #expect(provenanceBadgeStyle(for: "Possible · method") == .possible)
    #expect(provenanceBadgeStyle(for: "External") == .fallback)
}

@Test
func inProcessExactProviderReturnsNegotiatedCallRelation() throws {
    let itemLocation = ExactLocation(
        file: "src/lib.rs",
        byteOffset: 7,
        line: 1,
        column: 8
    )
    let callSite = ExactLocation(
        file: "src/main.rs",
        byteOffset: 32,
        line: 2,
        column: 5
    )
    let item = ExactCallHierarchyItem(
        name: "target",
        kind: 12,
        uri: "file:///fixture/src/lib.rs",
        range: itemLocation,
        selectionRange: itemLocation,
        data: nil
    )
    let relation = ExactCallRelation(item: item, callSites: [callSite])
    let provider = InProcessExactProvider(
        location: nil,
        capabilities: [.definition, .callHierarchy],
        negotiatedCapabilities: [.callHierarchy],
        callHierarchyItems: [item],
        incomingRelations: [relation],
        outgoingRelations: [relation]
    )
    let session = try provider.prepare(
        snapshot: ExactSelfTestDirectorySnapshot(root: exactFixtureRoot()),
        profile: ExactProfileKey(
            configFingerprint: "config",
            environmentFingerprint: "environment"
        ),
        trustMode: .safe
    )
    let negotiated = session.negotiatedCapabilities
    let prepared = try #require(
        try session.prepareCallHierarchy(file: "src/lib.rs", byteOffset: 7)
    )
    let incoming = try #require(try session.incomingCalls(item: prepared[0]))

    #expect(negotiated == [.callHierarchy])
    #expect(session.negotiatedCapabilities == negotiated)
    #expect(incoming.count == 1)
    #expect(incoming[0].item.name == "target")
    #expect(incoming[0].callSites == [callSite])
}

@Test
func inProcessExactProviderDefinitionOnlySubsetReturnsNilForNewCapabilities() throws {
    let itemLocation = ExactLocation(
        file: "src/lib.rs",
        byteOffset: 7,
        line: 1,
        column: 8
    )
    let item = ExactCallHierarchyItem(
        name: "target",
        kind: 12,
        uri: "file:///fixture/src/lib.rs",
        range: itemLocation,
        selectionRange: itemLocation,
        data: nil
    )
    let provider = InProcessExactProvider(
        location: itemLocation,
        capabilities: [
            .definition,
            .implementations,
            .callHierarchy,
            .references,
        ],
        negotiatedCapabilities: [.definition],
        // 带上数据：验证守卫按能力拦截，而不是靠 fake 恰好没数据才返回 nil
        referenceLocations: [itemLocation],
        incomingRelations: [ExactCallRelation(item: item, callSites: [itemLocation])],
        outgoingRelations: [ExactCallRelation(item: item, callSites: [itemLocation])]
    )
    let session = try provider.prepare(
        snapshot: ExactSelfTestDirectorySnapshot(root: exactFixtureRoot()),
        profile: ExactProfileKey(
            configFingerprint: "config",
            environmentFingerprint: "environment"
        ),
        trustMode: .safe
    )

    #expect(try session.implementations(file: "src/lib.rs", byteOffset: 7) == nil)
    #expect(
        try session.references(
            file: "src/lib.rs",
            byteOffset: 7,
            includeDeclaration: false
        ) == nil
    )
    #expect(
        try session.prepareCallHierarchy(file: "src/lib.rs", byteOffset: 7) == nil
    )
    #expect(try session.incomingCalls(item: item) == nil)
    #expect(try session.outgoingCalls(item: item) == nil)
}

@Test
func inProcessExactProviderKeepsStaticAndNegotiatedCapabilitiesSeparate() throws {
    let provider = InProcessExactProvider(
        location: nil,
        capabilities: [.callHierarchy],
        negotiatedCapabilities: []
    )
    let session = try provider.prepare(
        snapshot: ExactSelfTestDirectorySnapshot(root: exactFixtureRoot()),
        profile: ExactProfileKey(
            configFingerprint: "config",
            environmentFingerprint: "environment"
        ),
        trustMode: .safe
    )

    #expect(provider.capabilities == [.callHierarchy])
    #expect(session.negotiatedCapabilities.isEmpty)
    #expect(
        try session.prepareCallHierarchy(file: "src/lib.rs", byteOffset: 7) == nil
    )
}

private func exactFixtureRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            "CodeInsightExactTests/Fixtures/exact_fixture",
            isDirectory: true
        )
}
