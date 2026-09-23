import Foundation
import os
func milliseconds(since instant: ContinuousClock.Instant) -> Double {
    let c = instant.duration(to: .now).components
    return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
}
@main struct Probe {
@MainActor static func main() throws {
    let stallWindow = OSAllocatedUnfairLock(initialState: (
        generation: UInt64(0), max: 0.0, ignoredPreWindowSamples: 0
    ))
    let stallQueue = DispatchQueue(label: "com.codeinsight.wrap-perf-stall")
    let stallTimer = DispatchSource.makeTimerSource(queue: stallQueue)
    stallTimer.schedule(
        deadline: .now(),
        repeating: .milliseconds(5),
        leeway: .milliseconds(1)
    )
    // Explicit @Sendable typing keeps this handler nonisolated: it runs on the
    // probe queue, only its main-queue continuation touches main state.
    let heartbeat: @Sendable () -> Void = {
        let sample = stallWindow.withLock {
            (generation: $0.generation, scheduled: ContinuousClock.now)
        }
        DispatchQueue.main.async {
            let lateness = milliseconds(since: sample.scheduled)
            stallWindow.withLock {
                guard $0.generation == sample.generation else {
                    $0.ignoredPreWindowSamples += 1
                    return
                }
                $0.max = max($0.max, lateness)
            }
        }
    }
    stallTimer.setEventHandler(handler: heartbeat)
    stallTimer.resume()

    func resetStallProbe() {
        stallWindow.withLock {
            $0.generation &+= 1
            $0.max = 0
            $0.ignoredPreWindowSamples = 0
        }
    }


    Thread.sleep(forTimeInterval: 0.12)
    resetStallProbe()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.06))
    let afterReset = stallWindow.withLock { $0 }
    Thread.sleep(forTimeInterval: 0.12)
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.06))
    let inWindow = stallWindow.withLock { $0 }
    stallTimer.cancel()
    stallQueue.sync {}
    let passed = afterReset.ignoredPreWindowSamples > 0 && afterReset.max < 80 && inWindow.max >= 90
    let result: [String: Any] = ["passed": passed, "ignoredPreWindowSamples": afterReset.ignoredPreWindowSamples, "afterResetMaximumMs": afterReset.max, "inWindowMaximumMs": inWindow.max]
    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    exit(passed ? 0 : 1)
}}
