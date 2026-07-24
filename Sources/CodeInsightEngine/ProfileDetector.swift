import CodeInsightCore
import CodeInsightGit
import Foundation

enum ProfileDetector {
    static func detect(
        root: URL,
        projectRoot: PathID
    ) -> AnalysisProfile {
        let root = root.standardizedFileURL
        return detect(
            projectRootName: root.lastPathComponent,
            projectRoot: projectRoot
        ) { path in
            try? [UInt8](Data(
                contentsOf: root.appendingPathComponent(path),
                options: .mappedIfSafe
            ))
        }
    }

    static func detect(
        snapshot: any Snapshot,
        projectRoot: PathID
    ) -> AnalysisProfile {
        detect(
            projectRootName: snapshot.projectRootName,
            projectRoot: projectRoot
        ) { path in
            try? snapshot.readBytes(path: path)
        }
    }

    private static func detect(
        projectRootName: String,
        projectRoot: PathID,
        readBytes: (String) -> [UInt8]?
    ) -> AnalysisProfile {
        guard let rootBytes = readBytes("Cargo.toml"),
              let rootManifest = CargoManifestSubset(bytes: rootBytes)
        else {
            return fallback(
                projectRootName: projectRootName,
                projectRoot: projectRoot
            )
        }

        var features = Set(rootManifest.featureNames)
        var fingerprintBytes = rootBytes
        if let lockBytes = readBytes("Cargo.lock") {
            fingerprintBytes += lockBytes
        }

        for member in rootManifest.workspaceMembers.sorted() {
            guard let member = normalizedMemberPath(member) else {
                return fallback(
                    projectRootName: projectRootName,
                    projectRoot: projectRoot
                )
            }
            let path = member.isEmpty ? "Cargo.toml" : "\(member)/Cargo.toml"
            guard let bytes = readBytes(path),
                  let manifest = CargoManifestSubset(bytes: bytes),
                  manifest.packageName != nil
            else {
                return fallback(
                    projectRootName: projectRootName,
                    projectRoot: projectRoot
                )
            }
            fingerprintBytes += bytes
            features.formUnion(manifest.featureNames)
        }

        guard rootManifest.packageName != nil || rootManifest.hasWorkspace else {
            return fallback(
                projectRootName: projectRootName,
                projectRoot: projectRoot
            )
        }
        let unitName: String
        if rootManifest.hasWorkspace {
            unitName = projectRootName
        } else if let packageName = rootManifest.packageName {
            unitName = packageName
        } else {
            return fallback(
                projectRootName: projectRootName,
                projectRoot: projectRoot
            )
        }
        return AnalysisProfile(
            language: .rust,
            projectRoot: projectRoot,
            projectUnitName: unitName,
            configFingerprint: ContentID.sha256(of: fingerprintBytes).bytes
                .map { String(format: "%02x", $0) }
                .joined(),
            environmentFingerprint: "",
            featureSelection: .defaultFeatures,
            featureNames: Array(features),
            edition: rootManifest.hasWorkspace
                ? nil : rootManifest.edition,
            trustMode: .safe
        )
    }

    private static func fallback(
        projectRootName: String,
        projectRoot: PathID
    ) -> AnalysisProfile {
        AnalysisProfile(
            language: .rust,
            projectRoot: projectRoot,
            projectUnitName: projectRootName,
            configFingerprint: "",
            environmentFingerprint: "",
            featureSelection: .defaultFeatures,
            featureNames: [],
            edition: nil,
            trustMode: .safe
        )
    }

    private static func normalizedMemberPath(_ path: String) -> String? {
        guard !path.hasPrefix("/"),
              !path.contains("*"),
              !path.contains("?")
        else { return nil }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            guard component != ".." else { return nil }
            components.append(component)
        }
        return components.joined(separator: "/")
    }

}

private struct CargoManifestSubset {
    let packageName: String?
    let workspaceMembers: [String]
    let featureNames: [String]
    let edition: String?
    let hasWorkspace: Bool

    init?(bytes: [UInt8]) {
        guard let source = String(bytes: bytes, encoding: .utf8) else {
            return nil
        }
        let lines = source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var section = ""
        var packageName: String?
        var workspaceMembers: [String]?
        var featureNames: Set<String> = []
        var edition: String?
        var hasPackage = false
        var hasWorkspace = false
        var seenKeys: Set<String> = []
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = Self.withoutComment(lines[lineIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lineIndex += 1
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[") {
                guard let parsed = Self.sectionName(line) else { return nil }
                section = parsed
                hasPackage = hasPackage || section == "package"
                hasWorkspace = hasWorkspace || section == "workspace"
                continue
            }
            guard let equals = Self.unquotedEquals(in: line) else {
                continue
            }
            let rawKey = String(line[..<equals])
                .trimmingCharacters(in: .whitespaces)
            var rawValue = String(line[line.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)

            switch (section, rawKey) {
            case ("package", "name"):
                guard seenKeys.insert("package.name").inserted,
                      let value = Self.string(rawValue)
                else { return nil }
                packageName = value
            case ("package", "edition"):
                guard seenKeys.insert("package.edition").inserted,
                      let value = Self.string(rawValue)
                else { return nil }
                edition = value
            case ("workspace", "members"):
                guard seenKeys.insert("workspace.members").inserted
                else { return nil }
                while !Self.arrayIsComplete(rawValue), lineIndex < lines.count {
                    rawValue += "\n" + Self.withoutComment(lines[lineIndex])
                    lineIndex += 1
                }
                guard Self.arrayIsComplete(rawValue),
                      let members = Self.stringArray(rawValue)
                else { return nil }
                workspaceMembers = members
            case ("features", _):
                while !Self.arrayIsComplete(rawValue), lineIndex < lines.count {
                    rawValue += "\n" + Self.withoutComment(lines[lineIndex])
                    lineIndex += 1
                }
                guard let name = Self.key(rawKey),
                      !name.isEmpty,
                      rawValue.hasPrefix("["),
                      Self.arrayIsComplete(rawValue),
                      seenKeys.insert("features.\(name)").inserted
                else { return nil }
                featureNames.insert(name)
            default:
                continue
            }
        }

        guard !hasPackage || packageName != nil || hasWorkspace else {
            return nil
        }
        self.packageName = packageName
        self.workspaceMembers = workspaceMembers ?? []
        self.featureNames = featureNames.sorted()
        self.edition = edition
        self.hasWorkspace = hasWorkspace
    }

    private static func sectionName(_ line: String) -> String? {
        if line.hasPrefix("[[") {
            guard line.hasSuffix("]]"), line.count > 4 else { return nil }
            return String(line.dropFirst(2).dropLast(2))
                .trimmingCharacters(in: .whitespaces)
        }
        guard line.hasSuffix("]"), line.count > 2 else { return nil }
        return String(line.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespaces)
    }

    private static func unquotedEquals(in line: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\", quote == "\"" {
                escaped = true
            } else if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
            } else if character == "=", quote == nil {
                return index
            }
        }
        return nil
    }

    private static func withoutComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\", quote == "\"" {
                escaped = true
            } else if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
            } else if character == "#", quote == nil {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func string(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quote = value.first,
              quote == "\"" || quote == "'",
              value.last == quote,
              value.count >= 2
        else { return nil }
        let content = value.dropFirst().dropLast()
        if quote == "'" {
            return String(content)
        }

        var result = ""
        var escaped = false
        for character in content {
            if escaped {
                switch character {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: return nil
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return nil
            } else {
                result.append(character)
            }
        }
        return escaped ? nil : result
    }

    private static func key(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") || value.hasPrefix("'") {
            return string(value)
        }
        guard !value.isEmpty,
              value.allSatisfy({
                $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-"
                    || $0 == "+" || $0 == "."
              })
        else { return nil }
        return value
    }

    private static func arrayIsComplete(_ value: String) -> Bool {
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in value {
            if escaped {
                escaped = false
            } else if character == "\\", quote == "\"" {
                escaped = true
            } else if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
            } else if quote == nil {
                if character == "[" { depth += 1 }
                if character == "]" { depth -= 1 }
                if depth < 0 { return false }
            }
        }
        return quote == nil && depth == 0 && value.contains("[")
    }

    private static func stringArray(_ value: String) -> [String]? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.first == "[", value.last == "]" else { return nil }
        let content = value.dropFirst().dropLast()
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        func appendCurrent() -> Bool {
            let token = current.trimmingCharacters(in: .whitespacesAndNewlines)
            current = ""
            guard !token.isEmpty else { return true }
            guard let parsed = string(token) else { return false }
            result.append(parsed)
            return true
        }

        for character in content {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quote == "\"" {
                current.append(character)
                escaped = true
            } else if character == "\"" || character == "'" {
                current.append(character)
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                }
            } else if character == ",", quote == nil {
                guard appendCurrent() else { return nil }
            } else {
                current.append(character)
            }
        }
        guard quote == nil, appendCurrent() else { return nil }
        return result
    }
}
