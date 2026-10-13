import CodeInsightCore
import CodeInsightGit
import Foundation

/// Ignored dependency directories that a commit's analysis borrows from
/// the user's workspace: a commit checkout holds tracked files only, so
/// `node_modules` and virtual environments come from the working copy.
public enum DependencyBorrowing {
    /// Checkout-relative link path → workspace directory, for `snapshot`
    /// (the whole repository at the target commit) and the analysis unit
    /// at `unitPrefix` ("" for the root).
    ///
    /// TypeScript: `node_modules` beside the root and every tracked
    /// `package.json`, where the workspace has one. Python: the commit's
    /// own relative `venvPath` (`pyrightconfig.json`, else
    /// `[tool.pyright]` in `pyproject.toml`), joined with `venv` when set.
    /// Rust borrows nothing: Safe mode reads dependencies from `~/.cargo`.
    public static func links(
        language: LanguageID,
        snapshot: any Snapshot,
        workspaceRoot: URL,
        unitPrefix: String
    ) -> [String: URL] {
        var links: [String: URL] = [:]
        func borrow(_ path: String) {
            let target = path.split(separator: "/").reduce(workspaceRoot.standardizedFileURL) {
                $0.appendingPathComponent(String($1), isDirectory: true)
            }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
               isDirectory.boolValue
            {
                links[path] = target
            }
        }
        switch language {
        case .typescript:
            var packages: Set<String> = [""]
            for file in snapshot.listFiles() {
                let components = file.path.split(separator: "/")
                if components.last == "package.json" {
                    packages.insert(components.dropLast().joined(separator: "/"))
                }
            }
            for package in packages {
                borrow(package.isEmpty ? "node_modules" : "\(package)/node_modules")
            }
        case .python:
            let unit = unitPrefix.isEmpty ? "" : "\(unitPrefix)/"
            let read = { (name: String) in try? snapshot.readBytes(path: unit + name) }
            guard let setting = pyrightVenvSetting(
                pyrightconfig: read("pyrightconfig.json"),
                pyproject: read("pyproject.toml")
            ), let path = normalizedRelativePath(
                unitPrefix,
                setting.venvPath,
                setting.venv ?? ""
            ), path != unitPrefix
            else { break }
            borrow(path)
        case .rust, .javascript:
            break
        }
        return links
    }

    /// The interpreter Pyright is told to use: `.venv/bin/python`, else
    /// `venv/bin/python`, under the workspace unit root. Nil keeps the
    /// server's own discovery (PATH).
    public static func pythonInterpreter(unitRoot: URL) -> URL? {
        [".venv", "venv"].lazy
            .map {
                unitRoot.standardizedFileURL
                    .appendingPathComponent($0, isDirectory: true)
                    .appendingPathComponent("bin/python")
            }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `venvPath` and `venv` from the commit's Pyright configuration; the
    /// JSON file wins, as it does for Pyright.
    static func pyrightVenvSetting(
        pyrightconfig: [UInt8]?,
        pyproject: [UInt8]?
    ) -> (venvPath: String, venv: String?)? {
        if let pyrightconfig {
            guard let object = try? JSONSerialization.jsonObject(
                with: Data(pyrightconfig),
                options: [.json5Allowed]
            ) as? [String: Any],
                let venvPath = object["venvPath"] as? String
            else { return nil }
            return (venvPath, object["venv"] as? String)
        }
        guard let pyproject, let text = String(bytes: pyproject, encoding: .utf8) else {
            return nil
        }
        // ponytail: line scan of `[tool.pyright]` string keys only; inline
        // tables and multi-line strings are not configuration Pyright users write here.
        var table = ""
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            guard table == "tool.pyright",
                  let equals = line.firstIndex(of: "=")
            else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard let quote = value.first, quote == "\"" || quote == "'",
                  let end = value.dropFirst().firstIndex(of: quote)
            else { continue }
            values[key] = String(value[value.index(after: value.startIndex)..<end])
        }
        return values["venvPath"].map { ($0, values["venv"]) }
    }

    /// Joins repository-relative pieces, resolving `.` and `..`; nil when
    /// a piece is absolute or home-relative, or the result leaves the
    /// repository or is the repository root.
    static func normalizedRelativePath(_ pieces: String...) -> String? {
        var components: [Substring] = []
        for piece in pieces {
            guard !piece.hasPrefix("/"), !piece.hasPrefix("~") else { return nil }
            for component in piece.split(separator: "/") {
                switch component {
                case ".": continue
                case "..":
                    guard components.popLast() != nil else { return nil }
                default: components.append(component)
                }
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }
}
