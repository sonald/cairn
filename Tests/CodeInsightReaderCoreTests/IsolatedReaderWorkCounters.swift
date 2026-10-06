import CodeInsightCore
import Testing

/// Runs a test inside its own `ReaderWorkCounters` scope, so work done by
/// concurrently running tests cannot change the deltas it asserts.
struct IsolatedReaderWorkCounters: TestTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await ReaderWorkCounters.withIsolatedScope { try await function() }
    }
}

extension Trait where Self == IsolatedReaderWorkCounters {
    static var isolatedReaderWorkCounters: Self { Self() }
}
