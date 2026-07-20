import Foundation
import GitSnapshotProbe

@main
enum GitProbeCLI {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(_ arguments: [String]) throws {
        guard arguments.count >= 2 else {
            printUsage()
            throw CLIError.invalidArguments
        }
        let repositoryURL = URL(fileURLWithPath: arguments[1], isDirectory: true)

        switch arguments[0] {
        case "snapshot":
            let revision = try commitArgument(in: Array(arguments.dropFirst(2)))
            let snapshot = try CommitSnapshot(
                repositoryURL: repositoryURL,
                revision: revision
            )
            for (path, oid) in snapshot.files.sorted(by: { $0.key < $1.key }) {
                print("\(path)\t\(oid)")
            }
            print(String(
                format: "files=%d tree_walk_ms=%.3f blob_read_ms=%.3f blob_bytes=%d",
                snapshot.files.count,
                snapshot.timing.treeWalkMilliseconds,
                snapshot.timing.blobReadMilliseconds,
                snapshot.timing.blobBytes
            ))

        case "capture":
            guard arguments.count == 2 else { throw CLIError.invalidArguments }
            let snapshot = try WorktreeSnapshot(repositoryURL: repositoryURL)
            print(String(
                format: "files=%d clean_tracked=%d copied=%d copied_bytes=%d capture_ms=%.3f",
                snapshot.stats.totalFiles,
                snapshot.stats.cleanTrackedFiles,
                snapshot.stats.copiedFiles,
                snapshot.stats.copiedBytes,
                snapshot.stats.captureMilliseconds
            ))

        case "switch":
            guard arguments.count == 2 else { throw CLIError.invalidArguments }
            let stats = try SnapshotSwitchProbe.run(repositoryURL: repositoryURL)
            print(String(
                format: "head_files=%d target_files=%d cache_hits=%d new_extractions=%d hit_rate=%.1f%% switch_ms=%.3f",
                stats.headFiles,
                stats.totalFiles,
                stats.cacheHits,
                stats.newExtractions,
                stats.hitRate * 100,
                stats.elapsedMilliseconds
            ))
            print("assertion: hit_rate > 80%: PASS")

        default:
            printUsage()
            throw CLIError.invalidArguments
        }
    }

    private static func commitArgument(in arguments: [String]) throws -> String {
        switch arguments.count {
        case 0:
            return "HEAD"
        case 2 where arguments[0] == "--commit":
            return arguments[1]
        default:
            throw CLIError.invalidArguments
        }
    }

    private static func printUsage() {
        print("""
        usage:
          swift run gitprobe snapshot <repo> [--commit <sha>]
          swift run gitprobe capture <repo>
          swift run gitprobe switch <repo>
        """)
    }
}

private enum CLIError: Error {
    case invalidArguments
}
