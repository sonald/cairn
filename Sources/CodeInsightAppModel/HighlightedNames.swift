import CodeInsightReaderCore

/// Names a project window paints in fixed colors, in the order they were added.
/// Matching is lexical (same spelling), never a claim that they are one symbol.
public struct HighlightedNames: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String
        /// Color slot 1...`ReaderTheme.highlightSlotCount`, also shown as a number.
        public let slot: UInt8
    }

    public enum ToggleResult: Equatable, Sendable {
        case added(slot: UInt8)
        case removed
        /// Every slot is taken; nothing is evicted.
        case full
    }

    public static let maximumNameBytes = 256

    public private(set) var entries: [Entry] = []

    public init() {}

    /// Restores persisted entries, dropping any that are invalid or repeat a
    /// name or slot, so one bad record never costs the rest.
    package init(restoring entries: [Entry]) {
        for entry in entries where Self.isValid(entry.name)
            && (1...ReaderTheme.highlightSlotCount).contains(entry.slot)
            && !self.entries.contains(where: { $0.name == entry.name || $0.slot == entry.slot }) {
            self.entries.append(entry)
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var slotsByName: [String: UInt8] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.slot) })
    }

    @discardableResult
    public mutating func toggle(_ name: String) -> ToggleResult {
        if let index = entries.firstIndex(where: { $0.name == name }) {
            entries.remove(at: index)
            return .removed
        }
        guard Self.isValid(name) else { return .full }
        let used = Set(entries.map(\.slot))
        guard let slot = (1...ReaderTheme.highlightSlotCount).first(where: { !used.contains($0) })
        else { return .full }
        entries.append(Entry(name: name, slot: slot))
        return .added(slot: slot)
    }

    /// Gives `name` the color `slot`; a name already holding that color
    /// gives it up, since the user chose the color explicitly.
    public mutating func assign(_ name: String, slot: UInt8) {
        guard Self.isValid(name), (1...ReaderTheme.highlightSlotCount).contains(slot) else { return }
        entries.removeAll { $0.slot == slot }
        if let index = entries.firstIndex(where: { $0.name == name }) {
            entries[index] = Entry(name: name, slot: slot)
        } else {
            entries.append(Entry(name: name, slot: slot))
        }
    }

    public mutating func remove(_ name: String) {
        entries.removeAll { $0.name == name }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }

    private static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= maximumNameBytes
    }
}
