import CodeInsightCore
import Foundation
import Testing
@testable import CodeInsightAppModel

@Test
func sessionCodecRoundTripsHighlightedNamesAndDropsInvalidEntries() throws {
    var names = HighlightedNames()
    #expect(names.toggle("state") == .added(slot: 1))
    #expect(names.toggle("permits") == .added(slot: 2))
    #expect(names.toggle("state") == .removed)
    #expect(names.toggle("waker") == .added(slot: 1), "the lowest free color is reused")
    for name in ["a", "b", "c", "d"] { names.toggle(name) }
    #expect(names.toggle("e") == .full, "a seventh name never evicts an earlier one")
    names.assign("e", slot: 2)
    #expect(names.slotsByName["e"] == 2 && names.slotsByName["permits"] == nil)

    let snapshot = SessionCodec.Snapshot(
        projectRoot: "/tmp/project",
        language: .rust,
        revision: nil,
        activeTabOrdinal: nil,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: [],
        highlights: names.entries
    )
    let data = try SessionCodec.encode(snapshot, maximumTabCount: 10, dependencyAllowed: { _ in false })
    let decoded = try SessionCodec.decode(data, maximumTabCount: 10, dependencyAllowed: { _ in false })
    #expect(decoded.highlights == names.entries)

    // One bad record degrades to omission instead of failing the session.
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["highlights"] = [
        ["name": "ok", "slot": 3],
        ["name": "", "slot": 4],
        ["name": "slotless", "slot": 9],
        ["name": "ok", "slot": 5],
        ["name": "other", "slot": 3],
    ]
    let tampered = try JSONSerialization.data(withJSONObject: object)
    let sanitized = try SessionCodec.decode(tampered, maximumTabCount: 10, dependencyAllowed: { _ in false })
    #expect(sanitized.highlights == [HighlightedNames.Entry(name: "ok", slot: 3)])

    // Version 3 files keep loading, without highlights.
    object["schemaVersion"] = 3
    object.removeValue(forKey: "highlights")
    let v3 = try JSONSerialization.data(withJSONObject: object)
    #expect(try SessionCodec.decode(v3, maximumTabCount: 10, dependencyAllowed: { _ in false }).highlights.isEmpty)
}

@Test
func sessionCodecRoundTripsTheSplitReferencePaneAndDropsUnsafePaths() throws {
    func snapshot(_ pane: SessionCodec.ReferencePane?) -> SessionCodec.Snapshot {
        SessionCodec.Snapshot(
            projectRoot: "/tmp/project",
            language: .rust,
            revision: nil,
            activeTabOrdinal: nil,
            panelPreset: PanelPresetModel.reading.rawValue,
            tabs: [],
            referencePane: pane
        )
    }
    let pane = SessionCodec.ReferencePane(path: "src/trait.rs", byteOffset: 42)
    let data = try SessionCodec.encode(snapshot(pane), maximumTabCount: 10, dependencyAllowed: { _ in false })
    #expect(try SessionCodec.decode(data, maximumTabCount: 10, dependencyAllowed: { _ in false }).referencePane == pane)

    // A pane outside the project degrades to no split; the rest still loads.
    for unsafe in ["../outside.rs", "/etc/passwd", ""] {
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["referencePane"] = ["path": unsafe, "byteOffset": 0]
        let tampered = try JSONSerialization.data(withJSONObject: object)
        let decoded = try SessionCodec.decode(tampered, maximumTabCount: 10, dependencyAllowed: { _ in true })
        #expect(decoded.referencePane == nil, "\(unsafe)")
        #expect(decoded.projectRoot == "/tmp/project")
    }

    let none = try SessionCodec.encode(snapshot(nil), maximumTabCount: 10, dependencyAllowed: { _ in false })
    #expect(String(decoding: none, as: UTF8.self).contains("referencePane") == false)
}
