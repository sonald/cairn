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
