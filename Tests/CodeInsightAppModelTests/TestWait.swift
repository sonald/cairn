import Testing

@MainActor
func testWaitUntil(
    _ description: String,
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    // This wall-clock bound is only a hang fuse; performance has separate budget tests.
    let deadline = ContinuousClock.now + .seconds(120)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        do {
            try await Task.sleep(for: .milliseconds(10))
        } catch {
            Issue.record("Cancelled while waiting for: \(description)")
            return false
        }
    }
    if await condition() { return true }
    Issue.record("Hang fuse expired while waiting for: \(description)")
    return false
}
