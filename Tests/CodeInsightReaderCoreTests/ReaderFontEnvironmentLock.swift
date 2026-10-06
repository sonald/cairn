import Testing

/// `ReaderFontResolver.shared.refresh()` is process-wide. After it, every
/// mounted Reader rejects its queued anchor corrections until the host applies
/// settings again (the app does; tests do not). In a parallel run, a refresh
/// that lands while another test awaits those corrections leaves that Reader's
/// anchor uncorrected. Tests that refresh the environment and tests that await
/// corrections hold this lock; all other tests stay parallel.
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
