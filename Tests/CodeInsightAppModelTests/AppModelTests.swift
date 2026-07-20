import Testing
@testable import CodeInsightAppModel

@MainActor
@Test
func projectStateAcceptsLegalTransitions() {
    let model = AppModel()

    #expect(model.transition(to: .indexing))
    #expect(model.transition(to: .failed))
    #expect(model.transition(to: .indexing))
}

@MainActor
@Test
func projectStateRejectsIllegalTransitions() {
    let model = AppModel()

    #expect(!model.transition(to: .failed))
    #expect(model.transition(to: .indexing))
    #expect(!model.transition(to: .indexing))
}
