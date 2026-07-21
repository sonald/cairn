public enum PanelPresetModel: String, CaseIterable, Sendable {
    case reading
    case relations
    case compare
    case focus

    public var layout: PanelLayoutDescription {
        switch self {
        case .reading:
            PanelLayoutDescription(
                sidebarCollapsed: false,
                readerCollapsed: false,
                contextCollapsed: false,
                relationsCollapsed: true,
                readerSplit: false,
                sidebarFraction: 0.20,
                contextFraction: 0.24,
                relationsFraction: 0,
                secondaryReaderFraction: 0
            )
        case .relations:
            PanelLayoutDescription(
                sidebarCollapsed: true,
                readerCollapsed: false,
                contextCollapsed: false,
                relationsCollapsed: false,
                readerSplit: false,
                sidebarFraction: 0,
                contextFraction: 0.24,
                relationsFraction: 0.28,
                secondaryReaderFraction: 0
            )
        case .compare:
            PanelLayoutDescription(
                sidebarCollapsed: true,
                readerCollapsed: false,
                contextCollapsed: false,
                relationsCollapsed: true,
                readerSplit: true,
                sidebarFraction: 0,
                contextFraction: 0.24,
                relationsFraction: 0,
                secondaryReaderFraction: 0.5
            )
        case .focus:
            PanelLayoutDescription(
                sidebarCollapsed: true,
                readerCollapsed: false,
                contextCollapsed: true,
                relationsCollapsed: true,
                readerSplit: false,
                sidebarFraction: 0,
                contextFraction: 0,
                relationsFraction: 0,
                secondaryReaderFraction: 0
            )
        }
    }
}

public struct PanelLayoutDescription: Equatable, Sendable {
    public let sidebarCollapsed: Bool
    public let readerCollapsed: Bool
    public let contextCollapsed: Bool
    public let relationsCollapsed: Bool
    public let readerSplit: Bool
    public let sidebarFraction: Double
    public let contextFraction: Double
    public let relationsFraction: Double
    public let secondaryReaderFraction: Double

    public init(
        sidebarCollapsed: Bool,
        readerCollapsed: Bool,
        contextCollapsed: Bool,
        relationsCollapsed: Bool,
        readerSplit: Bool,
        sidebarFraction: Double,
        contextFraction: Double,
        relationsFraction: Double,
        secondaryReaderFraction: Double
    ) {
        self.sidebarCollapsed = sidebarCollapsed
        self.readerCollapsed = readerCollapsed
        self.contextCollapsed = contextCollapsed
        self.relationsCollapsed = relationsCollapsed
        self.readerSplit = readerSplit
        self.sidebarFraction = sidebarFraction
        self.contextFraction = contextFraction
        self.relationsFraction = relationsFraction
        self.secondaryReaderFraction = secondaryReaderFraction
    }
}
