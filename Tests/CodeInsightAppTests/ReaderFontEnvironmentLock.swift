import Testing

/// The process-wide reader font environment: `ReaderFontResolver.shared`
/// (every `refresh()` and Core Text registration bumps its revision and makes
/// mounted views re-measure) and the argument-domain font preference the
/// registration test sets on `UserDefaults.standard`. In a parallel run a
/// change that lands while another test awaits makes that test see extra
/// measurements or a foreign font. Tests that change the environment and the
/// tests shown to depend on it hold this lock; all other tests stay parallel.
/// Same gate as `CodeInsightReaderCoreTests`; each test target runs in its
/// own process, so the two copies never need to exclude each other.
struct ReaderFontEnvironmentLock: TestTrait, TestScoping {
    func provideScope(
        for test: Test, testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await Gate.shared.acquire()
        do {
            try await function()
        } catch {
            await Gate.shared.release()
            throw error
        }
        await Gate.shared.release()
    }

    private actor Gate {
        static let shared = Gate()
        private var held = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            guard held else {
                held = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
        }
    }
}

extension Trait where Self == ReaderFontEnvironmentLock {
    static var readerFontEnvironment: Self { Self() }
}
