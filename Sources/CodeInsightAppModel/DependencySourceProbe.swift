import Foundation

/// Tells whether a Rust path root names a declared dependency whose source is
/// not available locally, so the hover card can say so instead of showing
/// nothing. Runs only after a hover settled with no answer from either layer;
/// never on the pointer-tracking path. Nothing is fetched.
struct DependencySourceProbe: Sendable {
    let registrySourceRoots: [URL]

    init(registrySourceRoots: [URL]) {
        self.registrySourceRoots = registrySourceRoots
    }

    /// `~/.cargo/registry/src/*` (or `$CARGO_HOME/registry/src/*`).
    static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let cargoHome = environment["CARGO_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cargo")
        let source = cargoHome.appendingPathComponent("registry/src")
        let indexes = (try? FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        )) ?? []
        return Self(registrySourceRoots: indexes)
    }

    /// `true` when `pathRoot` is a dependency declared by the manifest that
    /// governs `file` (searched upward to `projectRoot`) and no local copy of
    /// its source exists in the registry caches or a `vendor/` directory.
    func isMissingSource(pathRoot: String, file: URL, projectRoot: URL) -> Bool {
        guard !["crate", "self", "super", "Self", "std", "core", "alloc"].contains(pathRoot),
              let manifest = nearestManifest(for: file, projectRoot: projectRoot),
              let text = try? String(contentsOf: manifest, encoding: .utf8)
        else { return false }
        let wanted = Self.normalized(pathRoot)
        guard let crate = Self.declaredDependencies(in: text)
            .first(where: { Self.normalized($0) == wanted })
        else { return false }
        return !hasLocalSource(crate: crate, projectRoot: projectRoot)
    }

    private func nearestManifest(for file: URL, projectRoot: URL) -> URL? {
        let root = projectRoot.standardizedFileURL.path
        var directory = file.deletingLastPathComponent().standardizedFileURL
        while directory.path.hasPrefix(root) {
            let manifest = directory.appendingPathComponent("Cargo.toml")
            if FileManager.default.fileExists(atPath: manifest.path) { return manifest }
            guard directory.path != root else { break }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private func hasLocalSource(crate: String, projectRoot: URL) -> Bool {
        let names = Set([crate, crate.replacingOccurrences(of: "_", with: "-"),
                         crate.replacingOccurrences(of: "-", with: "_")])
        let vendor = projectRoot.appendingPathComponent("vendor")
        for name in names
            where FileManager.default.fileExists(atPath: vendor.appendingPathComponent(name).path)
        {
            return true
        }
        for root in registrySourceRoots {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            if entries.contains(where: { entry in
                names.contains { entry.hasPrefix("\($0)-") && entry.dropFirst($0.count + 1).first?.isNumber == true }
            }) {
                return true
            }
        }
        return false
    }

    static func normalized(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: "_")
    }

    /// Dependency names from `[dependencies]`, `[dev-dependencies]`,
    /// `[build-dependencies]`, target-specific tables and
    /// `[dependencies.<name>]` headers. A line scan, not a TOML parser.
    static func declaredDependencies(in manifest: String) -> [String] {
        var names: [String] = []
        var inDependencies = false
        for rawLine in manifest.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                let parts = header.split(separator: ".").map(String.init)
                if let index = parts.firstIndex(where: { $0.hasSuffix("dependencies") }) {
                    if index + 1 < parts.count {
                        names.append(parts[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                        inDependencies = false
                    } else {
                        inDependencies = true
                    }
                } else {
                    inDependencies = false
                }
                continue
            }
            guard inDependencies,
                  let key = line.split(separator: "=", maxSplits: 1).first
            else { continue }
            let name = key.split(separator: ".").first.map(String.init)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if let name, !name.isEmpty { names.append(name) }
        }
        return names
    }
}
