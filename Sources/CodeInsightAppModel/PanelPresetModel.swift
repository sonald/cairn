public enum PanelPresetModel: String, CaseIterable, Sendable {
    case reading
    case relations
    case compare
    case focus

    /// Panels the preset leaves visible; everything else is hidden. Context
    /// stays on its automatic rule unless the preset hides it (Focus).
    public var visiblePanels: Set<PanelID> {
        switch self {
        case .reading: [.files, .outline, .context]
        case .relations: [.files, .outline, .relations, .context]
        case .compare: [.files, .context]
        case .focus: []
        }
    }

    /// Compare opens the second reader beside the primary one.
    public var opensReaderSplit: Bool { self == .compare }
}
