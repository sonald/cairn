import ExactProbeCore
import Foundation

do {
    guard CommandLine.arguments.count == 2 else {
        throw LSPError.requestFailed("usage: swift run exactprobe rust|ts|py|safemode|materialize")
    }
    switch CommandLine.arguments[1] {
    case "rust": _ = try ExactProbe.runRust()
    case "ts": _ = try ExactProbe.runTypeScript()
    case "py": _ = try ExactProbe.runPython()
    case "safemode": _ = try ExactProbe.runSafeMode()
    case "materialize": _ = try ExactProbe.runMaterialize()
    default: throw LSPError.requestFailed("usage: swift run exactprobe rust|ts|py|safemode|materialize")
    }
} catch {
    FileHandle.standardError.write(Data("exactprobe: \(error.localizedDescription)\n".utf8))
    exit(1)
}
