import CodeInsightCore
import CodeInsightGit
import Foundation

enum ProfileDetector {
    static func detect(
        root: URL,
        projectRoot: PathID
    ) -> AnalysisProfile {
        detect(
            projectURL: root,
            language: .rust,
            projectRoot: projectRoot
        )
    }

    static func detect(
        projectURL: URL,
        language: LanguageID,
        projectRoot: PathID
    ) -> AnalysisProfile {
        let root = projectURL.standardizedFileURL
        return detect(
            projectRootName: root.lastPathComponent,
            projectRoot: projectRoot,
            language: language
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
            projectRoot: projectRoot,
            language: .rust
        ) { path in
            try? snapshot.readBytes(path: path)
        }
    }

    static func detect(
        snapshot: any Snapshot,
        language: LanguageID,
        projectRoot: PathID
    ) -> AnalysisProfile {
        detect(
            projectRootName: snapshot.projectRootName,
            projectRoot: projectRoot,
            language: language
        ) { path in
            try? snapshot.readBytes(path: path)
        }
    }

    static func detect(
        snapshot: any Snapshot,
        language: LanguageID,
        sourcePaths: [String],
        configurationPaths: [String],
        internPath: (String) -> PathID
    ) throws -> AnalysisProfile {
        let selectedRoot = try unitRoot(
            language: language,
            sourcePaths: sourcePaths,
            configurationPaths: configurationPaths
        )
        return detect(
            projectRootName: selectedRoot == "." ? snapshot.projectRootName :
                URL(fileURLWithPath: selectedRoot).lastPathComponent,
            projectRoot: internPath(selectedRoot),
            language: language,
            selectedRoot: selectedRoot
        ) { path in
            try? snapshot.readBytes(path: path)
        }
    }

    private static func unitRoot(
        language: LanguageID,
        sourcePaths: [String],
        configurationPaths: [String]
    ) throws -> String {
        try validateRelativePaths(sourcePaths + configurationPaths)
        let sources = sourcePaths.filter {
            LanguageMode.classify(path: $0, language: language) != nil
        }
        if sources.isEmpty {
            return "."
        }
        let markers = configurationPaths.filter { isMarker($0, language: language) }
        let markerRoots = markers.map(parentDirectory)
        if markerRoots.isEmpty {
            return "."
        }
        let valid = markerRoots.filter { root in
            sources.allSatisfy { isWithin(root: root, path: $0) }
        }
        guard !valid.isEmpty else {
            throw multipleUnits(language)
        }
        return valid.min {
            ($0.isEmpty ? 0 : $0.split(separator: "/").count)
                < ($1.isEmpty ? 0 : $1.split(separator: "/").count)
        } ?? "."
    }

    private static func validateRelativePaths(_ paths: [String]) throws {
        for path in paths {
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.contains("//"),
                  !path.components(separatedBy: "/").contains(where: {
                      $0.isEmpty || $0 == "." || $0 == ".."
                  })
            else {
                throw invalidUnitRoot(path)
            }
        }
    }

    private static func isMarker(
        _ path: String,
        language: LanguageID
    ) -> Bool {
        switch language {
        case .rust:
            return URL(fileURLWithPath: path).lastPathComponent == "Cargo.toml"
        case .python:
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name == "pyrightconfig.json" || name == "pyproject.toml"
        case .typescript:
            return URL(fileURLWithPath: path).lastPathComponent == "tsconfig.json"
        case .javascript:
            return false
        }
    }

    private static func parentDirectory(_ path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }

    private static func isWithin(root: String, path: String) -> Bool {
        if root == "." || root.isEmpty {
            return true
        }
        return path == root
            || path.hasPrefix(root + "/")
    }

    private static func invalidUnitRoot(_ path: String) -> CocoaError {
        CocoaError(.fileReadInvalidFileName, userInfo: [
            NSLocalizedFailureReasonErrorKey:
                "invalid relative path for project unit root: \(path)",
        ])
    }

    private static func multipleUnits(_ language: LanguageID) -> CocoaError {
        CocoaError(.featureUnsupported, userInfo: [
            NSLocalizedFailureReasonErrorKey:
                "multiple \(language) project units are not supported in L3 V0",
        ])
    }

    private static func detect(
        projectRootName: String,
        projectRoot: PathID,
        language: LanguageID,
        selectedRoot: String = ".",
        readBytes: @escaping (String) -> [UInt8]?
    ) -> AnalysisProfile {
        let reader: (String) -> [UInt8]? = { path in
            readBytes(selectedRoot == "." ? path : "\(selectedRoot)/\(path)")
        }
        switch language {
        case .rust:
            return rustProfile(
                projectRootName: projectRootName,
                projectRoot: projectRoot,
                reader: reader
            )
        case .python:
            return pythonProfile(
                projectRootName: projectRootName,
                projectRoot: projectRoot,
                reader: reader
            )
        case .typescript:
            return typescriptProfile(
                projectRootName: projectRootName,
                projectRoot: projectRoot,
                reader: reader
            )
        case .javascript:
            return fallback(
                projectRootName: projectRootName,
                projectRoot: projectRoot,
                language: language
            )
        }
    }

    private static func typescriptProfile(
        projectRootName: String,
        projectRoot: PathID,
        reader: @escaping (String) -> [UInt8]?
    ) -> AnalysisProfile {
        let fingerprints = typescriptConfigIdentity(readBytes: reader)
        return AnalysisProfile(
            language: .typescript,
            projectRoot: projectRoot,
            projectUnitName: reader("tsconfig.json") == nil
                ? projectRootName
                : "tsconfig.json",
            configFingerprint: fingerprints.config,
            environmentFingerprint: fingerprints.environment,
            featureSelection: .defaultFeatures,
            featureNames: [],
            edition: nil,
            trustMode: .safe
        )
    }

    private static func pythonProfile(
        projectRootName: String,
        projectRoot: PathID,
        reader: @escaping (String) -> [UInt8]?
    ) -> AnalysisProfile {
        let fingerprints = pythonConfigIdentity(readBytes: reader)
        return AnalysisProfile(
            language: .python,
            projectRoot: projectRoot,
            projectUnitName: projectRootName,
            configFingerprint: fingerprints.config,
            environmentFingerprint: fingerprints.environment,
            featureSelection: .defaultFeatures,
            featureNames: [],
            edition: nil,
            trustMode: .safe
        )
    }

    private static func rustProfile(
        projectRootName: String,
        projectRoot: PathID,
        reader: @escaping (String) -> [UInt8]?
    ) -> AnalysisProfile {
        guard let rootBytes = reader("Cargo.toml"),
              let rootManifest = CargoManifestSubset(bytes: rootBytes)
        else {
            return fallback(
                projectRootName: projectRootName,
                projectRoot: projectRoot,
                language: .rust
            )
        }

        var features = Set(rootManifest.featureNames)
        var fingerprintBytes = rootBytes
        var selectedEdition = rootManifest.packageName == nil
            ? nil
            : rootManifest.resolvedEdition(
                workspaceEdition: rootManifest.workspacePackageEdition
            )
        let selectedMemberPath = rootManifest.packageName == nil
            ? rootManifest.workspaceMembers.first.flatMap(normalizedMemberPath)
            : nil
        if let lockBytes = reader("Cargo.lock") {
            fingerprintBytes += lockBytes
        }

        for member in rootManifest.workspaceMembers.sorted() {
            guard let member = normalizedMemberPath(member) else {
                return fallback(
                    projectRootName: projectRootName,
                    projectRoot: projectRoot,
                    language: .rust
                )
            }
            let path = member.isEmpty ? "Cargo.toml" : "\(member)/Cargo.toml"
            guard let bytes = reader(path),
                  let manifest = CargoManifestSubset(bytes: bytes),
                  manifest.packageName != nil
            else {
                return fallback(
                    projectRootName: projectRootName,
                    projectRoot: projectRoot,
                    language: .rust
                )
            }
            fingerprintBytes += bytes
            features.formUnion(manifest.featureNames)
            if member == selectedMemberPath {
                selectedEdition = manifest.resolvedEdition(
                    workspaceEdition: rootManifest.workspacePackageEdition
                )
            }
        }

        guard rootManifest.packageName != nil || rootManifest.hasWorkspace else {
            return fallback(
                projectRootName: projectRootName,
                projectRoot: projectRoot,
                language: .rust
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
                projectRoot: projectRoot,
                language: .rust
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
            edition: selectedEdition,
            trustMode: .safe
        )
    }

    private static func fallback(
        projectRootName: String,
        projectRoot: PathID,
        language: LanguageID
    ) -> AnalysisProfile {
        AnalysisProfile(
            language: language,
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
    let editionInheritsWorkspace: Bool
    let workspacePackageEdition: String?
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
        var editionInheritsWorkspace = false
        var workspacePackageEdition: String?
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
            case ("package", "edition.workspace"):
                guard seenKeys.insert("package.edition").inserted,
                      rawValue == "true"
                else { return nil }
                editionInheritsWorkspace = true
            case ("workspace.package", "edition"):
                guard seenKeys.insert("workspace.package.edition").inserted,
                      let value = Self.string(rawValue)
                else { return nil }
                workspacePackageEdition = value
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
        self.editionInheritsWorkspace = editionInheritsWorkspace
        self.workspacePackageEdition = workspacePackageEdition
        self.hasWorkspace = hasWorkspace
    }

    func resolvedEdition(workspaceEdition: String?) -> String? {
        editionInheritsWorkspace ? workspaceEdition : edition
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
