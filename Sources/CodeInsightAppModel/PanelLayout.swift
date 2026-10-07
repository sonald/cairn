import Foundation

/// A panel that sits in one of the window's side zones. `docs` is reserved:
/// it has a place in the layout but no content or entry point yet.
public enum PanelID: String, CaseIterable, Sendable {
    case files
    case outline
    case relations
    case context
    case search
    case docs
}

public enum PanelZone: String, CaseIterable, Sendable {
    case left
    case right
}

/// The one app-wide panel arrangement: which zone holds each panel and in
/// what order, which panels the user hid, zone widths, relative panel
/// heights and the reader split ratio. Temporary overrides (no project,
/// non-source preview, Reading Set, a split that does not fit) never live
/// here; they are subtracted from `hidden` by the window.
public struct PanelLayout: Equatable, Sendable {
    /// Every panel appears exactly once across both zones.
    public private(set) var zones: [PanelZone: [PanelID]]
    public var hidden: Set<PanelID>
    /// Zone widths in points.
    public var zoneWidths: [PanelZone: Double]
    /// Relative height per panel within its zone; 0 means never sized.
    public private(set) var heights: [PanelID: Double]
    /// The primary reader's share of the reader group while it is split.
    public var readerSplitFraction: Double

    public static let standard = PanelLayout(
        zones: [.left: [.files, .outline], .right: [.relations, .context, .search, .docs]],
        hidden: [.relations, .search, .docs],
        zoneWidths: [.left: 240, .right: 300],
        heights: [.files: 0.55, .outline: 0.45, .relations: 0.5, .context: 0.25, .search: 0.25, .docs: 0],
        readerSplitFraction: 0.5
    )

    public func panels(in zone: PanelZone) -> [PanelID] { zones[zone] ?? [] }

    public func visible(in zone: PanelZone) -> [PanelID] {
        panels(in: zone).filter { !hidden.contains($0) }
    }

    public func zone(of panel: PanelID) -> (zone: PanelZone, index: Int) {
        for zone in PanelZone.allCases {
            if let index = panels(in: zone).firstIndex(of: panel) { return (zone, index) }
        }
        preconditionFailure("PanelLayout lost \(panel)")
    }

    public func width(of zone: PanelZone) -> Double {
        zoneWidths[zone] ?? Self.standard.zoneWidths[zone]!
    }

    /// Moves `panel` to `index` of the full list of `zone` (hidden panels
    /// included), clamped; an index past the end appends.
    public mutating func move(_ panel: PanelID, to zone: PanelZone, at index: Int) {
        let from = self.zone(of: panel)
        zones[from.zone]!.remove(at: from.index)
        var target = index
        if from.zone == zone, from.index < target { target -= 1 }
        var list = panels(in: zone)
        list.insert(panel, at: min(max(target, 0), list.count))
        zones[zone] = list
    }

    /// Moves `panel` past `delta` visible neighbours in its zone; hidden
    /// panels in between keep their places.
    public mutating func shift(_ panel: PanelID, by delta: Int) {
        guard canShift(panel, by: delta) else { return }
        let zone = self.zone(of: panel).zone
        let visible = visible(in: zone)
        let neighbour = visible[visible.firstIndex(of: panel)! + delta]
        var list = panels(in: zone)
        list.removeAll { $0 == panel }
        let anchor = list.firstIndex(of: neighbour)!
        list.insert(panel, at: delta < 0 ? anchor : anchor + 1)
        zones[zone] = list
    }

    public func canShift(_ panel: PanelID, by delta: Int) -> Bool {
        let visible = visible(in: zone(of: panel).zone)
        guard delta != 0, let index = visible.firstIndex(of: panel) else { return false }
        return visible.indices.contains(index + delta)
    }

    public mutating func setVisible(_ panel: PanelID, _ visible: Bool) {
        if visible { hidden.remove(panel) } else { hidden.insert(panel) }
    }

    /// A preset is a display combination: it changes visibility only.
    public mutating func apply(_ preset: PanelPresetModel) {
        hidden = Set(PanelID.allCases).subtracting(preset.visiblePanels)
    }

    /// Height shares of `panels` (the ones on screen, in order) summing to
    /// 1. Never-sized panels share 40% of the zone; the rest keep their
    /// stored proportions.
    public func heightFractions(for panels: [PanelID]) -> [Double] {
        guard !panels.isEmpty else { return [] }
        let weights = panels.map { heights[$0] ?? 0 }
        let sized = weights.reduce(0, +)
        let unsized = weights.filter { $0 <= 0 }.count
        guard sized > 0 else { return panels.map { _ in 1 / Double(panels.count) } }
        guard unsized > 0 else { return weights.map { $0 / sized } }
        return weights.map { $0 > 0 ? 0.6 * $0 / sized : 0.4 / Double(unsized) }
    }

    /// Records the on-screen heights of `panels` (one zone, in order).
    /// Hidden panels in the zone keep their weights relative to the rest;
    /// the zone's weights are renormalized to sum to 1.
    public mutating func recordHeights(_ measured: [Double], for panels: [PanelID]) {
        let total = measured.reduce(0, +)
        guard panels.count == measured.count, !panels.isEmpty,
              total.isFinite, total > 0
        else { return }
        let previous = panels.map { heights[$0] ?? 0 }.reduce(0, +)
        let scale = previous > 0 ? previous : 1
        for (panel, height) in zip(panels, measured) {
            heights[panel] = max(height, 0) / total * scale
        }
        let zone = self.zone(of: panels[0]).zone
        let sum = self.panels(in: zone).map { heights[$0] ?? 0 }.reduce(0, +)
        guard sum > 0 else { return }
        for panel in self.panels(in: zone) { heights[panel] = (heights[panel] ?? 0) / sum }
    }

    // MARK: - Persistence

    private struct Stored: Codable {
        var zones: [String: [String]]?
        var hidden: [String]?
        var zoneWidths: [String: Double]?
        var panelHeights: [String: [Double]]?
        var readerSplitFraction: Double?
    }

    /// Decodes a stored layout. Unknown panel IDs are dropped, duplicates
    /// keep their first place, missing panels return to the end of their
    /// default zone, and non-finite or out-of-range numbers fall back to
    /// their defaults. Data that is not a layout at all yields `standard`.
    public static func decode(_ data: Data?) -> PanelLayout {
        guard let data, let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return standard
        }
        var zones: [PanelZone: [PanelID]] = [.left: [], .right: []]
        var heights: [PanelID: Double] = [:]
        for zone in PanelZone.allCases {
            let names = stored.zones?[zone.rawValue] ?? []
            let storedHeights = stored.panelHeights?[zone.rawValue] ?? []
            for (index, name) in names.enumerated() {
                guard let panel = PanelID(rawValue: name),
                      !zones.values.contains(where: { $0.contains(panel) })
                else { continue }
                zones[zone]!.append(panel)
                if index < storedHeights.count, (0...1).contains(storedHeights[index]) {
                    heights[panel] = storedHeights[index]
                }
            }
        }
        for panel in PanelID.allCases where !zones.values.contains(where: { $0.contains(panel) }) {
            zones[standard.zone(of: panel).zone]!.append(panel)
        }
        for panel in PanelID.allCases where heights[panel] == nil {
            heights[panel] = standard.heights[panel]
        }
        var zoneWidths = standard.zoneWidths
        for zone in PanelZone.allCases {
            if let width = stored.zoneWidths?[zone.rawValue], width.isFinite, width > 0 {
                zoneWidths[zone] = width
            }
        }
        let fraction = stored.readerSplitFraction ?? standard.readerSplitFraction
        return PanelLayout(
            zones: zones,
            hidden: stored.hidden.map { Set($0.compactMap(PanelID.init(rawValue:))) } ?? standard.hidden,
            zoneWidths: zoneWidths,
            heights: heights,
            readerSplitFraction: fraction > 0 && fraction < 1 ? fraction : standard.readerSplitFraction
        )
    }

    public func encoded() -> Data {
        let stored = Stored(
            zones: Dictionary(uniqueKeysWithValues: PanelZone.allCases.map {
                ($0.rawValue, panels(in: $0).map(\.rawValue))
            }),
            hidden: PanelID.allCases.filter(hidden.contains).map(\.rawValue),
            zoneWidths: Dictionary(uniqueKeysWithValues: PanelZone.allCases.map {
                ($0.rawValue, width(of: $0))
            }),
            panelHeights: Dictionary(uniqueKeysWithValues: PanelZone.allCases.map {
                ($0.rawValue, panels(in: $0).map { heights[$0] ?? 0 })
            }),
            readerSplitFraction: readerSplitFraction
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // ponytail: every stored number is finite by construction, so encoding cannot fail.
        return (try? encoder.encode(stored)) ?? Data()
    }
}
