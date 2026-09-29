import Foundation
import Testing
@testable import CodeInsightAppModel

@Test
func dependencyProbeReadsDeclaredDependenciesFromManifestTables() {
    let manifest = """
    [package]
    name = "demo"
    version = "0.1.0"

    [dependencies]
    anyhow = "1"
    serde_json = { version = "1" }
    tokio.workspace = true
    # skipped = "1"

    [dev-dependencies]
    pretty-assertions = "1"

    [target.'cfg(unix)'.dependencies]
    libc = "0.2"

    [dependencies.ureq]
    version = "2"
    """
    #expect(DependencySourceProbe.declaredDependencies(in: manifest)
        == ["anyhow", "serde_json", "tokio", "pretty-assertions", "libc", "ureq"])
}

@Test
func dependencyProbeReportsOnlyDeclaredCratesWithoutLocalSource() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("probe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("project")
    let registry = root.appendingPathComponent("registry/index")
    try FileManager.default.createDirectory(
        at: project.appendingPathComponent("src"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: registry.appendingPathComponent("anyhow-1.0.104"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: project.appendingPathComponent("vendor/pretty-assertions"),
        withIntermediateDirectories: true
    )
    try """
    [dependencies]
    anyhow = "1"
    ureq = "2"
    anyhow_ext = "1"
    pretty_assertions = "1"
    """.write(to: project.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)

    let probe = DependencySourceProbe(registrySourceRoots: [registry])
    let file = project.appendingPathComponent("src/lib.rs")
    #expect(probe.isMissingSource(pathRoot: "ureq", file: file, projectRoot: project))
    #expect(probe.isMissingSource(pathRoot: "anyhow_ext", file: file, projectRoot: project))
    #expect(!probe.isMissingSource(pathRoot: "anyhow", file: file, projectRoot: project))
    #expect(!probe.isMissingSource(pathRoot: "pretty_assertions", file: file, projectRoot: project))
    #expect(!probe.isMissingSource(pathRoot: "undeclared", file: file, projectRoot: project))
    #expect(!probe.isMissingSource(pathRoot: "crate", file: file, projectRoot: project))
}
