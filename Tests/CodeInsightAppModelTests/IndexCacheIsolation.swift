import Foundation

/// Points `IndexCache` at one scratch root per test process instead of the
/// user's Application Support. Temporary-project helpers touch this before
/// any model indexes; a root already set by the caller is left alone.
let isolatedIndexCacheRoot: Void = {
    let variable = "CODEINSIGHT_INDEX_CACHE_ROOT"
    guard ProcessInfo.processInfo.environment[variable]?.isEmpty ?? true else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightTestIndexCache-\(UUID().uuidString)",
        isDirectory: true
    )
    setenv(variable, root.path, 1)
    atexit {
        guard let path = getenv("CODEINSIGHT_INDEX_CACHE_ROOT") else { return }
        try? FileManager.default.removeItem(atPath: String(cString: path))
    }
}()
