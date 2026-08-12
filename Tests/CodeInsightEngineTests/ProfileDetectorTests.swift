import CodeInsightCore
@testable import CodeInsightEngine
import CodeInsightGit
import Foundation
import Testing

@Test
func analysisProfileIDMatchesTheCrossLanguageV1Vector() {
    let id = AnalysisProfileID.derived(
        language: .rust,
        projectUnitName: "sample",
        configFingerprint: "ABCDEF",
        environmentFingerprint: "1234",
        featureSelection: .allFeatures
    )

    #expect(id.rawValue.uuidString == "C0CD9A90-6B46-D9E0-57B1-1CA56DD84598")
}

@Test
func pythonProfileDetectorUsesPyrightConfigOverPyprojectAndUvLock() throws {
    try withProfileProject([
        "pyrightconfig.json": #"{"venvPath": "."}"#,
        "pyproject.toml": "[project]\nname = \"sample\"\n",
        "uv.lock": "version = 1\n",
        "main.py": "print('main')\n",
    ]) { root in
        let config = [UInt8](try Data(
            contentsOf: root.appendingPathComponent("pyrightconfig.json")
        ))
        let uv = [UInt8](try Data(
            contentsOf: root.appendingPathComponent("uv.lock")
        ))
        let profile = ProfileDetector.detect(
            projectURL: root,
            language: .python,
            projectRoot: PathID(rawValue: 7)
        )

        #expect(profile.language == .python)
        #expect(profile.projectRoot == PathID(rawValue: 7))
        #expect(profile.projectUnitName == root.lastPathComponent)
        #expect(profile.configFingerprint == sha256Hex(
            Array("pyrightconfig.json\0".utf8) + config
        ))
        #expect(profile.environmentFingerprint == sha256Hex(
            Array("uv.lock\0".utf8) + uv
        ))
        #expect(profile.featureSelection == .defaultFeatures)
        #expect(profile.featureNames.isEmpty)
        #expect(profile.edition == nil)
        if case .safe = profile.trustMode {} else {
            Issue.record("Python profiles must start in safe mode")
        }
    }
}

@Test
func pythonProfileDetectorFallsBackToPyprojectAndEmptyUvLock() throws {
    try withProfileProject([
        "pyproject.toml": "[project]\nname = \"sample\"\n",
        "main.py": "print('main')\n",
    ]) { root in
        let profile = ProfileDetector.detect(
            projectURL: root,
            language: .python,
            projectRoot: PathID(rawValue: 8)
        )
        let expectedConfig = sha256Hex(
            Array("pyproject.toml\0".utf8) + [UInt8](try Data(
                contentsOf: root.appendingPathComponent("pyproject.toml")
            ))
        )

        #expect(profile.language == .python)
        #expect(profile.configFingerprint == expectedConfig)
        #expect(profile.environmentFingerprint == "")
    }
}

@Test
func pythonProfileDetectorConfigDeviationChangesOnlyItsFingerprint() throws {
    try withProfileProject([
        "pyrightconfig.json": #"{"venvPath": "."}"#,
        "uv.lock": "version = 1\n",
        "main.py": "print('main')\n",
    ]) { root in
        let initial = ProfileDetector.detect(
            projectURL: root,
            language: .python,
            projectRoot: PathID(rawValue: 9)
        )
        try Data("version = 2\n".utf8).write(
            to: root.appendingPathComponent("uv.lock")
        )
        let changedLock = ProfileDetector.detect(
            projectURL: root,
            language: .python,
            projectRoot: PathID(rawValue: 9)
        )
        try Data(#"{"venv": "other"}"#.utf8).write(
            to: root.appendingPathComponent("pyrightconfig.json")
        )
        let changedConfig = ProfileDetector.detect(
            projectURL: root,
            language: .python,
            projectRoot: PathID(rawValue: 9)
        )

        #expect(initial.environmentFingerprint != changedLock.environmentFingerprint)
        #expect(initial.configFingerprint == changedLock.configFingerprint)
        #expect(changedLock.configFingerprint != changedConfig.configFingerprint)
        #expect(changedLock.environmentFingerprint == changedConfig.environmentFingerprint)
    }
}

@Test
func pythonProfileDetectorMissingConfigUsesFixedNonemptySentinel() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightMissingPython-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = ProfileDetector.detect(
        projectURL: root,
        language: .python,
        projectRoot: PathID(rawValue: 10)
    )

    #expect(profile.language == .python)
    #expect(profile.configFingerprint ==
        "ad63780a0cbd089b3305c2cf137e6b6bf21da9bd79e5c110172db574a847be12")
    #expect(profile.environmentFingerprint == "")
}

@Test
func snapshotPythonProfileReadsRootConfigBytesForDeterministicIdentity() throws {
    let main = Array("print('main')\n".utf8)
    let config = Array(#"{"venvPath": "."}"#.utf8)
    let env = Array("version = 1\n".utf8)
    let snapshot = ProfileSnapshot(
        projectRootName: "snapshot-python",
        visiblePaths: ["main.py"],
        bytesByPath: [
            "main.py": main,
            "pyrightconfig.json": config,
            "uv.lock": env,
        ]
    )

    let one = ProfileDetector.detect(
        snapshot: snapshot,
        language: .python,
        projectRoot: PathID(rawValue: 11)
    )
    let two = ProfileDetector.detect(
        snapshot: snapshot,
        language: .python,
        projectRoot: PathID(rawValue: 12)
    )

    let worktreeParent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "PythonWorktreeIdentity-\(UUID().uuidString)",
        isDirectory: true
    )
    let worktreeRoot = worktreeParent.appendingPathComponent(
        "snapshot-python",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: worktreeParent) }
    try Data(config).write(to: worktreeRoot.appendingPathComponent("pyrightconfig.json"))
    try Data(env).write(to: worktreeRoot.appendingPathComponent("uv.lock"))
    let worktree = ProfileDetector.detect(
        projectURL: worktreeRoot,
        language: .python,
        projectRoot: PathID(rawValue: 13)
    )

    #expect(one.language == .python)
    #expect(one.configFingerprint == sha256Hex(
        Array("pyrightconfig.json\0".utf8) + config
    ))
    #expect(one.environmentFingerprint == sha256Hex(
        Array("uv.lock\0".utf8) + env
    ))
    #expect(worktree.configFingerprint == one.configFingerprint)
    #expect(worktree.environmentFingerprint == one.environmentFingerprint)
    #expect(worktree.configFingerprint ==
        "b6889f386c36d8ec8584cb829b44ba761eb5e806e76efdfb1503d1dbdcf4da1a")
    #expect(worktree.environmentFingerprint ==
        "64fb59631c8cea5db88cf2a47a66fa0353d8c090b517488ff0311dd08989d679")
    #expect(worktree.id == one.id)
    #expect(one.id == two.id)
}

@Test
func profileDetectorReadsPackageFeaturesEditionAndLockfile() throws {
    try withProfileProject([
        "Cargo.toml": """
            [package]
            name = "sample"
            edition = "2021"

            [features]
            default = ["serde"]
            serde = []
            """,
        "Cargo.lock": "version = 4\n",
        "src/main.rs": "fn main() {}\n",
    ]) { root in
        let first = try ProjectIndexer().index(root: root).analysisProfile
        let cargoBytes = [UInt8](try Data(
            contentsOf: root.appendingPathComponent("Cargo.toml")
        ))
        let lockBytes = [UInt8](try Data(
            contentsOf: root.appendingPathComponent("Cargo.lock")
        ))
        try "version = 4\n# changed\n".write(
            to: root.appendingPathComponent("Cargo.lock"),
            atomically: true,
            encoding: .utf8
        )
        let changedLock = try ProjectIndexer().index(root: root).analysisProfile

        #expect(first.projectUnitName == "sample")
        #expect(first.configFingerprint == sha256Hex(cargoBytes + lockBytes))
        #expect(first.configFingerprint != changedLock.configFingerprint)
        #expect(first.environmentFingerprint == "")
        #expect(first.featureSelection == .defaultFeatures)
        #expect(first.featureNames == ["default", "serde"])
        #expect(first.edition == "2021")
        #expect(first.language == .rust)
        if case .safe = first.trustMode {} else {
            Issue.record("Detected profiles must start in safe mode")
        }
    }
}

@Test
func profileDetectorReadsWorkspaceMemberManifests() throws {
    try withProfileProject([
        "Cargo.toml": """
            [workspace]
            members = [
                "crates/alpha",
                "crates/beta",
            ]
            """,
        "crates/alpha/Cargo.toml": """
            [package]
            name = "alpha"
            edition = "2021"

            [features]
            serde = []
            """,
        "crates/beta/Cargo.toml": """
            [package]
            name = "beta"
            edition = "2024"

            [features]
            cli = [
                "serde",
            ]
            """,
        "src/main.rs": "fn main() {}\n",
    ]) { root in
        let profile = try ProjectIndexer().index(root: root).analysisProfile

        #expect(profile.projectUnitName == root.lastPathComponent)
        #expect(profile.configFingerprint.count == 64)
        #expect(profile.environmentFingerprint == "")
        #expect(profile.featureSelection == .defaultFeatures)
        #expect(profile.featureNames == ["cli", "serde"])
        #expect(profile.edition == "2021")
    }
}

@Test
func profileDetectorReadsSelectedWorkspaceMemberEdition() throws {
    try withProfileProject([
        "Cargo.toml": """
            [workspace]
            members = ["crates/selected"]
            """,
        "crates/selected/Cargo.toml": """
            [package]
            name = "selected"
            edition = "2021"
            """,
        "src/main.rs": "fn main() {}\n",
    ]) { root in
        let profile = try ProjectIndexer().index(root: root).analysisProfile

        #expect(profile.edition == "2021")
    }
}

@Test
func profileDetectorResolvesInheritedWorkspaceEdition() throws {
    try withProfileProject([
        "Cargo.toml": """
            [workspace]
            members = ["crates/selected"]

            [workspace.package]
            edition = "2024"
            """,
        "crates/selected/Cargo.toml": """
            [package]
            name = "selected"
            edition.workspace = true
            """,
        "src/main.rs": "fn main() {}\n",
    ]) { root in
        let profile = try ProjectIndexer().index(root: root).analysisProfile

        #expect(profile.edition == "2024")
    }
}

@Test
func profileDetectorLeavesMissingWorkspaceEditionUnknown() throws {
    try withProfileProject([
        "Cargo.toml": """
            [workspace]
            members = ["crates/selected"]
            """,
        "crates/selected/Cargo.toml": """
            [package]
            name = "selected"
            """,
        "src/main.rs": "fn main() {}\n",
    ]) { root in
        let profile = try ProjectIndexer().index(root: root).analysisProfile

        #expect(profile.edition == nil)
    }
}

@Test
func malformedCargoManifestFallsBackWithoutInventingFields() throws {
    try withProfileProject([
        "Cargo.toml": """
            [package
            name = "invented"
            edition = "2024"
            """,
        "src/main.rs": "fn main() {}\n",
    ]) { root in
        let profile = try ProjectIndexer().index(root: root).analysisProfile

        expectFallback(profile, rootName: root.lastPathComponent)
    }
}

@Test
func malformedWorkspaceMemberFallsBackWithoutInventingFields() throws {
    try withProfileProject([
        "Cargo.toml": """
            [workspace]
            members = ["crates/broken"]
            """,
        "crates/broken/Cargo.toml": "[package\nname = \"broken\"\n",
        "src/main.rs": "fn main() {}\n",
    ]) { root in
        let profile = try ProjectIndexer().index(root: root).analysisProfile

        expectFallback(profile, rootName: root.lastPathComponent)
    }
}

@Test
func missingCargoManifestFallsBackToDirectoryName() throws {
    try withProfileProject([
        "src/main.rs": "fn main() {}\n",
    ]) { root in
        let profile = try ProjectIndexer().index(root: root).analysisProfile

        expectFallback(profile, rootName: root.lastPathComponent)
    }
}

@Test
func snapshotProfileReadsCargoDirectlyWithoutIndexingIt() throws {
    let rust = Array("fn main() {}\n".utf8)
    let cargo = Array("""
        [package]
        name = "snapshot-package"
        edition = "2021"

        [features]
        fast = []

        """.utf8)
    let snapshot = ProfileSnapshot(
        projectRootName: "snapshot-root",
        visiblePaths: ["src/main.rs"],
        bytesByPath: [
            "src/main.rs": rust,
            "Cargo.toml": cargo,
            "Cargo.lock": Array("version = 4\n".utf8),
        ]
    )

    let session = try ProjectIndexer().indexSnapshot(
        snapshot,
        into: ProjectIndexStore()
    )

    #expect(session.analysisProfile.projectUnitName == "snapshot-package")
    #expect(session.analysisProfile.featureNames == ["fast"])
    #expect(session.analysisProfile.edition == "2021")
    #expect(session.manifest.files.count == 1)
    #expect(session.paths.resolve(session.manifest.files[0].pathID) == "src/main.rs")
    #expect(session.contentIndexes.count == 1)
    #expect(session.sourceBytesByContent[ContentID.sha256(of: cargo)] == nil)
}

@Test
func reprofileSharesContentAndRejectsTheOldContext() throws {
    try withProfileProject([
        "Cargo.toml": """
            [package]
            name = "reprofile"
            edition = "2021"
            """,
        "src/main.rs": "fn main() {}\n",
    ]) { root in
        let original = try ProjectIndexer().index(root: root)
        let oldContext = QueryContext(
            snapshotID: original.snapshotID,
            analysisProfileID: original.analysisProfile.id,
            generation: 1
        )
        let reprofiled = original.reprofiled(featureSelection: .allFeatures)

        #expect(reprofiled.store === original.store)
        #expect(reprofiled.snapshotID == original.snapshotID)
        #expect(reprofiled.manifest.files.map(\.pathID)
            == original.manifest.files.map(\.pathID))
        #expect(reprofiled.moduleChildren == original.moduleChildren)
        #expect(reprofiled.contentIndexes.keys == original.contentIndexes.keys)
        #expect(reprofiled.stats.extractedCount == 0)
        #expect(reprofiled.analysisProfile.featureSelection == .allFeatures)
        #expect(reprofiled.analysisProfile.id != original.analysisProfile.id)

        do {
            _ = try reprofiled.definitions(of: "main", context: oldContext)
            Issue.record("Old profile context must be rejected after reprofile")
        } catch let EngineError.profileMismatch(expected, actual) {
            #expect(expected == reprofiled.analysisProfile.id)
            #expect(actual == original.analysisProfile.id)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Test
func snapshotTypeScriptProfileMatchesWorktreeFixedVector() throws {
    let snapshot = ProfileSnapshot(
        projectRootName: "snapshot-typescript",
        visiblePaths: ["src/a.ts", "src/b.tsx"],
        bytesByPath: [
            "src/a.ts": Array("export const a = 1\n".utf8),
            "src/b.tsx": Array("export const b = 1\n".utf8),
            "tsconfig.json": Array("{}".utf8),
            "package.json": Array("{\"name\":\"sample\"}".utf8),
            "bun.lockb": Array(repeating: 0x62, count: 4),
        ]
    )

    let one = ProfileDetector.detect(
        snapshot: snapshot,
        language: .typescript,
        projectRoot: PathID(rawValue: 21)
    )
    let two = ProfileDetector.detect(
        snapshot: snapshot,
        language: .typescript,
        projectRoot: PathID(rawValue: 22)
    )
    let worktreeParent = FileManager.default.temporaryDirectory.appendingPathComponent(
        "TypeScriptWorktreeIdentity-\(UUID().uuidString)",
        isDirectory: true
    )
    let worktreeRoot = worktreeParent.appendingPathComponent(
        "snapshot-typescript",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: worktreeParent) }
    try Data("{}".utf8).write(to: worktreeRoot.appendingPathComponent("tsconfig.json"))
    try Data("{\"name\":\"sample\"}".utf8).write(
        to: worktreeRoot.appendingPathComponent("package.json")
    )
    try Data([0x62, 0x62, 0x62, 0x62]).write(
        to: worktreeRoot.appendingPathComponent("bun.lockb")
    )
    let worktree = ProfileDetector.detect(
        projectURL: worktreeRoot,
        language: .typescript,
        projectRoot: PathID(rawValue: 23)
    )

    let lock = Array(repeating: UInt8(ascii: "b"), count: 4)
    #expect(one.language == .typescript)
    #expect(one.projectUnitName == "tsconfig.json")
    #expect(one.configFingerprint ==
        "8e301229d858189807c55a25575c30ce65c4fa46f1ed73f32dc9e5987b1f910c")
    #expect(one.environmentFingerprint == sha256Hex(
        Array("bun.lockb\0".utf8) + lock
    ))
    #expect(worktree.configFingerprint == one.configFingerprint)
    #expect(worktree.environmentFingerprint == one.environmentFingerprint)
    #expect(one.id == two.id)
    #expect(worktree.id == one.id)
    #expect(one.featureSelection == .defaultFeatures)
    #expect(one.featureNames.isEmpty)
    #expect(one.edition == nil)
}

@Test
func typescriptProfileChangesOnlyMatchingIdentityAndMissingConfigUsesSentinel() throws {
    try withProfileProject([
        "src/a.ts": "export const a = 1\n",
        "tsconfig.json": "{}",
        "package.json": "{\"version\":\"1\"}",
    ]) { root in
        try Data(repeating: 0x61, count: 3).write(
            to: root.appendingPathComponent("bun.lockb")
        )
        let initial = ProfileDetector.detect(
            projectURL: root,
            language: .typescript,
            projectRoot: PathID(rawValue: 24)
        )
        try Data("{\"compilerOptions\":{}}".utf8).write(
            to: root.appendingPathComponent("tsconfig.json")
        )
        let afterTsconfig = ProfileDetector.detect(
            projectURL: root,
            language: .typescript,
            projectRoot: PathID(rawValue: 24)
        )
        try Data("{\"version\":\"2\"}".utf8).write(
            to: root.appendingPathComponent("package.json")
        )
        let afterPackage = ProfileDetector.detect(
            projectURL: root,
            language: .typescript,
            projectRoot: PathID(rawValue: 24)
        )
        try Data([0x62, 0x62]).write(to: root.appendingPathComponent("bun.lockb"))
        let afterLock = ProfileDetector.detect(
            projectURL: root,
            language: .typescript,
            projectRoot: PathID(rawValue: 24)
        )

        #expect(afterTsconfig.configFingerprint != initial.configFingerprint)
        #expect(afterTsconfig.environmentFingerprint == initial.environmentFingerprint)
        #expect(afterPackage.configFingerprint != afterTsconfig.configFingerprint)
        #expect(afterPackage.environmentFingerprint == afterTsconfig.environmentFingerprint)
        #expect(afterLock.configFingerprint == afterPackage.configFingerprint)
        #expect(afterLock.environmentFingerprint != afterPackage.environmentFingerprint)
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightMissingTypeScript-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = ProfileDetector.detect(
        projectURL: root,
        language: .typescript,
        projectRoot: PathID(rawValue: 25)
    )
    #expect(missing.language == .typescript)
    #expect(missing.projectUnitName == root.lastPathComponent)
    #expect(missing.configFingerprint != "")
    #expect(missing.environmentFingerprint == "")
}

@Test
func typescriptCommitAndWorktreeProfilesShareRootConfigIdentity() throws {
    try withGitProject([
        "src/a.ts": Data("export const a = 1\n".utf8),
        "tsconfig.json": Data("{}".utf8),
        "package.json": Data("{\"name\":\"sample\"}\n".utf8),
        "bun.lockb": Data(repeating: UInt8(ascii: "b"), count: 4),
    ]) { root in
        let worktree = ProfileDetector.detect(
            snapshot: try WorktreeSnapshot(
                repositoryURL: root,
                language: .typescript
            ),
            language: .typescript,
            projectRoot: PathID(rawValue: 31)
        )
        let commit = ProfileDetector.detect(
            snapshot: try CommitSnapshot(repositoryURL: root),
            language: .typescript,
            projectRoot: PathID(rawValue: 32)
        )

        #expect(commit.language == .typescript)
        #expect(commit.projectUnitName == worktree.projectUnitName)
        #expect(commit.configFingerprint == worktree.configFingerprint)
        #expect(commit.environmentFingerprint == worktree.environmentFingerprint)
        #expect(commit.id == worktree.id)
    }
}

private func withGitProject(
    _ files: [String: Data],
    body: (URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightProfileGit-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try git(in: root, "init", "-q")
    for (path, contents) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url)
    }
    try git(in: root, "add", ".")
    try git(
        in: root,
        "-c", "user.name=CodeInsight",
        "-c", "user.email=codeinsight@example.com",
        "commit", "-q", "-m", "fixture"
    )
    try body(root)
}

private func git(in root: URL, _ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root.path] + arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown, userInfo: [
            NSLocalizedFailureReasonErrorKey: "git failed with \(process.terminationStatus)"
        ])
    }
}

private func expectFallback(_ profile: AnalysisProfile, rootName: String) {
    #expect(profile.projectUnitName == rootName)
    #expect(profile.configFingerprint == "")
    #expect(profile.environmentFingerprint == "")
    #expect(profile.featureSelection == .defaultFeatures)
    #expect(profile.featureNames.isEmpty)
    #expect(profile.edition == nil)
}

private func sha256Hex(_ bytes: [UInt8]) -> String {
    ContentID.sha256(of: bytes).bytes
        .map { String(format: "%02x", $0) }
        .joined()
}

private func withProfileProject(
    _ files: [String: String],
    test: (URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodeInsightProfileDetectorTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    for (path, contents) in files {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }
    try test(root)
}

private struct ProfileSnapshot: Snapshot {
    let snapshotID = SnapshotID(rawValue: UUID())
    let objectFormat: GitObjectFormat = .sha1
    let sourceKind: SourceKind = .untracked
    let projectRootName: String
    let visiblePaths: [String]
    let bytesByPath: [String: [UInt8]]

    func listFiles() -> [(
        path: String,
        contentID: ContentID,
        fileMode: FileMode
    )] {
        visiblePaths.map { path in
            (path, ContentID.sha256(of: bytesByPath[path]!), .regular)
        }
    }

    func readBytes(path: String) throws -> [UInt8] {
        guard let bytes = bytesByPath[path] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return bytes
    }
}
