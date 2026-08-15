import CodeInsightCore
import Foundation

public struct ModuleMap: Sendable {
    public let moduleChildren: [PathID: [NameID: PathID]]

    private let parentModules: [PathID: PathID]
    private let crateRoots: Set<PathID>
    private let language: LanguageID
    private let pythonModuleFiles: [String: [PathID]]
    private let pathsByID: [PathID: String]
    private let pythonRootsByFile: [PathID: String]

    init(
        manifest: SnapshotManifest,
        language: LanguageID,
        indexes: [ContentIndexKey: ContentIndex],
        bytesByContent: [ContentID: [UInt8]],
        names: Interner<NameID>,
        paths: Interner<PathID>,
        projectRoot: String
    ) {
        let files = manifest.files
        switch language {
        case .rust:
            self.language = .rust
            let rust = Self.rustModuleMap(
                files: files,
                indexes: indexes,
                bytesByContent: bytesByContent,
                names: names,
                paths: paths,
                projectRoot: projectRoot
            )
            parentModules = rust.parents
            crateRoots = rust.roots
            pythonModuleFiles = [:]
            pathsByID = [:]
            pythonRootsByFile = [:]
            moduleChildren = rust.children
        case .python:
            let canonical = Self.pythonModuleFiles(
                files: files,
                paths: paths,
                projectRoot: projectRoot
            )
            self.language = .python
            parentModules = [:]
            crateRoots = []
            pythonModuleFiles = canonical
            var rootsByFile: [PathID: String] = [:]
            for file in files {
                let path = paths.resolve(file.pathID)
                let relative = Self.relativePath(path, root: projectRoot)
                if relative.hasPrefix("src/") {
                    rootsByFile[file.pathID] = "src"
                } else {
                    rootsByFile[file.pathID] = "root"
                }
            }
            pathsByID = Dictionary(uniqueKeysWithValues: files.map {
                ($0.pathID, Self.relativePath(paths.resolve($0.pathID), root: projectRoot))
            })
            pythonRootsByFile = rootsByFile
            moduleChildren = [:]
        case .typescript:
            self.language = .typescript
            parentModules = [:]
            crateRoots = []
            pythonModuleFiles = [:]
            pathsByID = Dictionary(uniqueKeysWithValues: files.map {
                ($0.pathID, Self.relativePath(paths.resolve($0.pathID), root: projectRoot))
            })
            pythonRootsByFile = [:]
            moduleChildren = [:]
        case .javascript:
            fatalError("ModuleMap does not support \(String(describing: language))")
        }
    }

    private static func rustModuleMap(
        files: [FileOccurrence],
        indexes: [ContentIndexKey: ContentIndex],
        bytesByContent: [ContentID: [UInt8]],
        names: Interner<NameID>,
        paths: Interner<PathID>,
        projectRoot: String
    ) -> (
        children: [PathID: [NameID: PathID]],
        parents: [PathID: PathID],
        roots: Set<PathID>
    ) {
        let pathIDsByString = Dictionary(uniqueKeysWithValues: files.map {
            (Self.relativePath(paths.resolve($0.pathID), root: projectRoot), $0.pathID)
        })
        var indexesByContent: [ContentID: ContentIndex] = [:]
        for (key, index) in indexes where indexesByContent[key.contentID] == nil {
            indexesByContent[key.contentID] = index
        }
        var children: [PathID: [NameID: PathID]] = [:]
        var parents: [PathID: PathID] = [:]
        var roots: Set<PathID> = []

        for file in files {
            let path = Self.relativePath(paths.resolve(file.pathID), root: projectRoot)
            let fileName = path.split(separator: "/").last.map(String.init) ?? path
            if fileName == "main.rs" || fileName == "lib.rs" {
                roots.insert(file.pathID)
            }
            guard
                let bytes = bytesByContent[file.contentID],
                let index = indexesByContent[file.contentID]
            else { continue }

            let directory = path.split(separator: "/").dropLast()
                .joined(separator: "/")
            for facet in index.symbols
                where facet.kind == .rustMod && facet.parentFacetIndex == nil
            {
                let lower = Int(facet.range.lowerBound)
                let upper = Int(facet.range.upperBound)
                guard lower <= upper, upper <= bytes.count else { continue }
                let declaration = String(decoding: bytes[lower..<upper], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard declaration.hasSuffix(";") else { continue }

                let name = names.resolve(facet.nameID)
                let prefix = directory.isEmpty ? "" : "\(directory)/"
                let candidates = ["\(prefix)\(name).rs", "\(prefix)\(name)/mod.rs"]
                guard let child = candidates.lazy.compactMap({ pathIDsByString[$0] }).first
                else { continue }
                children[file.pathID, default: [:]][facet.nameID] = child
                parents[child] = file.pathID
            }
        }

        return (children, parents, roots)
    }

    private static func pythonModuleFiles(
        files: [FileOccurrence],
        paths: Interner<PathID>,
        projectRoot: String
    ) -> [String: [PathID]] {
        var filesByPath: [String: PathID] = [:]
        for file in files {
            let path = Self.relativePath(paths.resolve(file.pathID), root: projectRoot)
            filesByPath[path] = file.pathID
        }
        var canonical: [String: [PathID]] = [:]
        for (path, pathID) in filesByPath {
            if path.hasPrefix("src/") {
                let modulePath = String(path.dropFirst("src/".count))
                guard modulePath.hasSuffix(".py") else { continue }
                appendModule(path: modulePath, pathID: pathID, to: &canonical)
            } else {
                guard path.hasSuffix(".py") else { continue }
                appendModule(path: path, pathID: pathID, to: &canonical)
            }
        }
        return canonical
    }

    private static func appendModule(
        path: String,
        pathID: PathID,
        to canonical: inout [String: [PathID]]
    ) {
        let module: String
        if path.hasSuffix("/__init__.py") {
            module = String(path.dropLast("/__init__.py".count))
        } else {
            module = String(path.dropLast(".py".count))
        }
        let canonicalModule = module
            .split(separator: "/")
            .map(String.init)
            .joined(separator: ".")
        guard !canonicalModule.isEmpty else { return }
        canonical[canonicalModule, default: []].append(pathID)
    }

    private static func relativePath(_ path: String, root: String) -> String {
        guard root != ".", !root.isEmpty else { return path }
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    func targetFile(
        for importBinding: ImportBinding,
        from source: PathID,
        names: Interner<NameID>,
        strings: Interner<StringID>
    ) -> PathID? {
        switch language {
        case .rust:
            return rustTargetFile(
                for: importBinding,
                from: source,
                names: names,
                strings: strings
            )
        case .python:
            return pythonTargetFile(
                for: importBinding,
                from: source,
                strings: strings
            )
        case .typescript:
            return typescriptTargetFile(
                for: importBinding,
                from: source,
                strings: strings
            )
        case .javascript:
            fatalError("ModuleMap does not support \(String(describing: language))")
        }
    }

    private func rustTargetFile(
        for importBinding: ImportBinding,
        from source: PathID,
        names: Interner<NameID>,
        strings: Interner<StringID>
    ) -> PathID? {
        var components = strings.resolve(importBinding.moduleSpecifier)
            .split(separator: "::").map(String.init)
        if let importedName = importBinding.importedName,
           components.last == names.resolve(importedName)
        {
            components.removeLast()
        }
        guard !components.isEmpty else { return nil }

        var current = source
        switch components.first {
        case "crate":
            current = crateRoot(containing: source) ?? source
            components.removeFirst()
        case "self":
            components.removeFirst()
        case "super":
            repeat {
                guard let parent = parentModules[current] else { return nil }
                current = parent
                components.removeFirst()
            } while components.first == "super"
        default:
            break
        }

        for component in components {
            guard let child = moduleChildren[current]?[names.intern(component)] else {
                return nil
            }
            current = child
        }
        return current
    }

    private func pythonTargetFile(
        for importBinding: ImportBinding,
        from source: PathID,
        strings: Interner<StringID>
    ) -> PathID? {
        let specifier = strings.resolve(importBinding.moduleSpecifier)
        let components = specifier.split(
            separator: ".",
            omittingEmptySubsequences: false
        ).map(String.init)

        if specifier.hasPrefix(".") {
            let sourceRoot = pythonRootsByFile[source] ?? "root"
            guard let sourcePath = pythonSourcePath(for: source),
                  let sourceComponents = pythonPackageComponents(
                    for: sourcePath,
                    root: sourceRoot
                  ),
                  !sourceComponents.isEmpty
            else { return nil }
            guard !components.isEmpty else { return nil }
            var dots = 0
            while dots < components.count, components[dots].isEmpty {
                dots += 1
            }
            guard dots > 0 else { return nil }
            guard dots - 1 <= sourceComponents.count else { return nil }
            var baseComponents = sourceComponents
            baseComponents.removeLast(dots - 1)
            let tail = components.dropFirst(dots)
            let combined = baseComponents + tail
            guard !combined.isEmpty else { return nil }
            return resolveModule(combined.joined(separator: "."))
        }

        return resolveModule(specifier)
    }

    private func typescriptTargetFile(
        for importBinding: ImportBinding,
        from source: PathID,
        strings: Interner<StringID>
    ) -> PathID? {
        let specifier = strings.resolve(importBinding.moduleSpecifier)
        guard specifier.hasPrefix("./") || specifier.hasPrefix("../") else {
            return nil
        }
        guard let sourcePath = pathsByID[source] else { return nil }
        let relative = sourcePath.split(separator: "/").dropLast()
            .map(String.init)
        let parts = specifier.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard let first = parts.first, first == "." || first == ".." else {
            return nil
        }
        var dir = relative
        for part in parts {
            switch part {
            case ".":
                continue
            case "..":
                guard !dir.isEmpty else { return nil }
                dir.removeLast()
            default:
                guard !part.isEmpty else { return nil }
                dir.append(part)
            }
        }
        let targetPath = dir.joined(separator: "/")
        if let direct = pathsByID.first(where: { $0.value == targetPath })?.key,
           LanguageMode.classify(path: targetPath, language: .typescript) != nil
        {
            return direct
        }
        let candidates = [
            targetPath + ".ts",
            targetPath + ".tsx",
            targetPath + "/index.ts",
            targetPath + "/index.tsx",
        ]
        let matches = candidates.compactMap { candidate in
            pathsByID.first(where: { $0.value == candidate })?.key
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func pythonPackageComponents(
        for path: String,
        root: String
    ) -> [String]? {
        let relative = root == "src"
            ? String(path.dropFirst("src/".count))
            : path
        if relative.hasSuffix("/__init__.py") {
            return String(relative.dropLast("/__init__.py".count))
                .split(separator: "/")
                .map(String.init)
        }
        return relative
            .split(separator: "/")
            .dropLast(1)
            .map(String.init)
    }

    private func pythonSourcePath(for pathID: PathID) -> String? {
        pathsByID[pathID]
    }

    private func resolveModule(_ module: String) -> PathID? {
        let components = module.split(separator: ".").map(String.init)
        guard !components.isEmpty else { return nil }
        var package = ""
        for (index, component) in components.enumerated() {
            package = package.isEmpty ? component : "\(package).\(component)"
            if index < components.count - 1 {
                guard singleUniquePackageInit(for: package) != nil else { return nil }
            }
        }
        return singleFileFor(module)
    }

    private func singleUniquePackageInit(for package: String) -> PathID? {
        guard let mapping = pythonModuleFiles[package],
              mapping.count == 1,
              let pathID = mapping.first,
              let path = pathsByID[pathID],
              path.hasSuffix("/__init__.py")
        else { return nil }
        return pathID
    }

    private func singleFileFor(_ module: String) -> PathID? {
        guard let matches = pythonModuleFiles[module], matches.count == 1 else {
            return nil
        }
        return matches[0]
    }

    private func crateRoot(containing path: PathID) -> PathID? {
        var current = path
        var seen: Set<PathID> = []
        while seen.insert(current).inserted {
            if crateRoots.contains(current) { return current }
            guard let parent = parentModules[current] else { return nil }
            current = parent
        }
        return nil
    }
}
