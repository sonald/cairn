import Foundation
import Testing
@testable import CodeInsightAppModel

/// Deterministic generator so a failing seed reproduces.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func expectInvariants(_ layout: PanelLayout, _ context: String) {
    let placed = PanelZone.allCases.flatMap(layout.panels(in:))
    #expect(placed.count == PanelID.allCases.count && Set(placed) == Set(PanelID.allCases),
            "each panel exactly once: \(context)")
    #expect(layout.hidden.isSubset(of: Set(PanelID.allCases)), "\(context)")
    for zone in PanelZone.allCases {
        let width = layout.width(of: zone)
        #expect(width.isFinite && width > 0, "width \(zone): \(context)")
        let fractions = layout.heightFractions(for: layout.panels(in: zone))
        #expect(fractions.allSatisfy { $0.isFinite && $0 >= 0 }, "fractions: \(context)")
        if !fractions.isEmpty { #expect(abs(fractions.reduce(0, +) - 1) < 1e-9, "\(context)") }
    }
    for panel in PanelID.allCases {
        let weight = layout.heights[panel] ?? -1
        #expect(weight.isFinite && (0...1).contains(weight), "height \(panel): \(context)")
    }
    #expect(layout.readerSplitFraction > 0 && layout.readerSplitFraction < 1, "\(context)")
    #expect(PanelLayout.decode(layout.encoded()) == layout, "round trip: \(context)")
}

/// The panels of `zone` without `panel`: moves must keep everyone else in order.
private func others(_ layout: PanelLayout, _ zone: PanelZone, without panel: PanelID) -> [PanelID] {
    layout.panels(in: zone).filter { $0 != panel }
}

@Test
func randomPanelOperationsKeepEveryPanelExactlyOnceAndOthersInOrder() {
    var rng = SplitMix64(state: 0x5EED_CA1E)
    for sequence in 0..<300 {
        var layout = PanelLayout.standard
        for step in 0..<40 {
            let context = "seed 0x5EEDCA1E sequence \(sequence) step \(step)"
            let panel = PanelID.allCases.randomElement(using: &rng)!
            let zone = PanelZone.allCases.randomElement(using: &rng)!
            let before = layout
            switch Int.random(in: 0..<6, using: &rng) {
            case 0:
                let index = Int.random(in: -2...8, using: &rng)
                let from = before.zone(of: panel)
                layout.move(panel, to: zone, at: index)
                #expect(layout.zone(of: panel).zone == zone, "\(context)")
                for each in PanelZone.allCases {
                    #expect(others(layout, each, without: panel) == others(before, each, without: panel),
                            "move keeps the others' order: \(context)")
                }
                var expected = min(max(index, 0), others(before, zone, without: panel).count)
                if from.zone == zone, from.index < index, index <= before.panels(in: zone).count {
                    expected = index - 1
                }
                #expect(layout.zone(of: panel).index == expected, "move index: \(context)")
            case 1:
                let delta = [-2, -1, 1, 2].randomElement(using: &rng)!
                let home = before.zone(of: panel).zone
                let visible = before.visible(in: home)
                layout.shift(panel, by: delta)
                if let index = visible.firstIndex(of: panel), visible.indices.contains(index + delta) {
                    var expected = visible
                    expected.remove(at: index)
                    let neighbour = visible[index + delta]
                    let anchor = expected.firstIndex(of: neighbour)!
                    expected.insert(panel, at: delta < 0 ? anchor : anchor + 1)
                    #expect(layout.visible(in: home) == expected, "shift order: \(context)")
                    #expect(layout.panels(in: home).filter(before.hidden.contains)
                        == before.panels(in: home).filter(before.hidden.contains),
                            "hidden panels keep their order: \(context)")
                } else {
                    #expect(layout == before, "impossible shift is a no-op: \(context)")
                }
            case 2:
                let visible = Bool.random(using: &rng)
                layout.setVisible(panel, visible)
                #expect(layout.hidden.contains(panel) == !visible, "\(context)")
                #expect(layout.zones == before.zones, "\(context)")
            case 3:
                let preset = PanelPresetModel.allCases.randomElement(using: &rng)!
                layout.apply(preset)
                #expect(Set(PanelID.allCases).subtracting(layout.hidden) == preset.visiblePanels, "\(context)")
                #expect(layout.zones == before.zones && layout.zoneWidths == before.zoneWidths
                    && layout.heights == before.heights,
                        "a preset only changes visibility: \(context)")
            case 4:
                let panels = layout.visible(in: zone)
                let measured = panels.map { _ in Double.random(in: 0...900, using: &rng) }
                layout.recordHeights(measured, for: panels)
                let total = measured.reduce(0, +)
                if total > 0, !panels.isEmpty {
                    let fractions = layout.heightFractions(for: panels)
                    for (fraction, height) in zip(fractions, measured) {
                        #expect(abs(fraction - height / total) < 1e-9, "recorded heights replay: \(context)")
                    }
                }
            default:
                layout.zoneWidths[zone] = Double.random(in: 72...900, using: &rng)
                layout.readerSplitFraction = Double.random(in: 0.05...0.95, using: &rng)
            }
            expectInvariants(layout, context)
        }
    }
}

@Test
func panelLayoutDecodingRepairsBadFieldsAndRejectsNonLayouts() throws {
    func decode(_ json: String) -> PanelLayout {
        PanelLayout.decode(Data(json.utf8))
    }
    let standard = PanelLayout.standard
    // Not a layout at all, or a field of the wrong type: the whole layout is default.
    for json in ["", "garbage", "[]", #"{"zones": 5}"#, #"{"hidden": "files"}"#,
                 #"{"zoneWidths": {"left": NaN}}"#, #"{"zoneWidths": {"left": "wide"}}"#] {
        #expect(decode(json) == standard, "\(json)")
    }
    #expect(PanelLayout.decode(nil) == standard)
    // Empty or missing zones put every panel back where it starts.
    #expect(decode("{}") == standard)
    #expect(decode(#"{"zones": {}}"#).zones == standard.zones)
    #expect(decode(#"{"zones": {"left": [], "right": []}}"#).zones == standard.zones)

    // Unknown IDs drop with their heights, duplicates keep the first place,
    // missing panels go to the end of their default zone.
    let repaired = decode(#"""
    {"zones": {"left": ["search", "bogus", "files", "search"], "right": ["files", "docs"]},
     "panelHeights": {"left": [0.3, 0.9, 0.7, 0.1], "right": [0.2, 0.5]},
     "hidden": ["bogus", "files"],
     "zoneWidths": {"left": -5, "right": 410, "middle": 3},
     "readerSplitFraction": 1.5}
    """#)
    #expect(repaired.panels(in: .left) == [.search, .files, .outline])
    #expect(repaired.panels(in: .right) == [.docs, .relations, .context])
    #expect(repaired.heights[.search] == 0.3)
    #expect(repaired.heights[.files] == 0.7)
    #expect(repaired.heights[.docs] == 0.5)
    #expect(repaired.heights[.outline] == standard.heights[.outline])
    #expect(repaired.hidden == [.files])
    #expect(repaired.width(of: .left) == 240)
    #expect(repaired.width(of: .right) == 410)
    #expect(repaired.readerSplitFraction == 0.5)
    expectInvariants(repaired, "repaired")

    // Out-of-range heights fall back per panel; a missing hidden list is the default one.
    let heights = decode(#"{"panelHeights": {"left": [2, -1]}, "zoneWidths": {"left": 1e999}}"#)
    #expect(heights.heights[.files] == standard.heights[.files])
    #expect(heights.heights[.outline] == standard.heights[.outline])
    #expect(heights.hidden == standard.hidden)
    expectInvariants(heights, "heights")
    expectInvariants(standard, "standard")
}
