@testable import CodeInsightApp
import Testing

@Test func provenanceBadgeStyleTracksCertaintyText() {
    #expect(provenanceBadgeStyle(for: "Exact · lsp") == .exact)
    #expect(provenanceBadgeStyle(for: "Strong · direct") == .strong)
    #expect(provenanceBadgeStyle(for: "Possible · method") == .possible)
    #expect(provenanceBadgeStyle(for: "External") == .fallback)
}
