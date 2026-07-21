import CodeInsightAppModel
import Testing

@Test
func panelPresetsDescribeReadingRelationsCompareAndFocusLayouts() {
    #expect(PanelPresetModel.reading.layout == PanelLayoutDescription(
        sidebarCollapsed: false,
        readerCollapsed: false,
        contextCollapsed: false,
        relationsCollapsed: true,
        readerSplit: false,
        sidebarFraction: 0.20,
        contextFraction: 0.24,
        relationsFraction: 0,
        secondaryReaderFraction: 0
    ))
    #expect(PanelPresetModel.relations.layout == PanelLayoutDescription(
        sidebarCollapsed: true,
        readerCollapsed: false,
        contextCollapsed: false,
        relationsCollapsed: false,
        readerSplit: false,
        sidebarFraction: 0,
        contextFraction: 0.24,
        relationsFraction: 0.28,
        secondaryReaderFraction: 0
    ))
    #expect(PanelPresetModel.compare.layout == PanelLayoutDescription(
        sidebarCollapsed: true,
        readerCollapsed: false,
        contextCollapsed: false,
        relationsCollapsed: true,
        readerSplit: true,
        sidebarFraction: 0,
        contextFraction: 0.24,
        relationsFraction: 0,
        secondaryReaderFraction: 0.5
    ))
    #expect(PanelPresetModel.focus.layout == PanelLayoutDescription(
        sidebarCollapsed: true,
        readerCollapsed: false,
        contextCollapsed: true,
        relationsCollapsed: true,
        readerSplit: false,
        sidebarFraction: 0,
        contextFraction: 0,
        relationsFraction: 0,
        secondaryReaderFraction: 0
    ))
}
