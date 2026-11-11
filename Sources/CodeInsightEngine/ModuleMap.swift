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
    private var go: GoPackages?

    /// `goModules` maps each `go.mod` directory, relative to the unit root
    /// (`.` for the root), to the module path it declares.
    init(
        manifest: SnapshotManifest,
        language: LanguageID,
        indexes: [ContentIndexKey: ContentIndex],
        bytesByContent: [ContentID: [UInt8]],
        names: Interner<NameID>,
        paths: Interner<PathID>,
        projectRoot: String,
        goModules: [String: String] = [:]
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
        case .go:
            self.language = .go
            parentModules = [:]
            crateRoots = []
            pythonModuleFiles = [:]
            pathsByID = [:]
            pythonRootsByFile = [:]
            moduleChildren = [:]
            go = GoPackages(files: files.map {
                (
                    $0.pathID,
                    Self.relativePath(paths.resolve($0.pathID), root: projectRoot),
                    bytesByContent[$0.contentID].flatMap(Self.goPackageClause)
                )
            }, modules: goModules)
        case .javascript:
            fatalError("ModuleMap does not support \(String(describing: language))")
        }
    }

    /// Go: the files of the package an import path names, its test files
    /// left out; nil when no module of the unit holds such a package (the
    /// standard library, other modules), which leaves the import to Exact.
    func goPackageFiles(importPath: String) -> [PathID]? {
        go?.importable[importPath]
    }

    /// Go: the files of `file`'s own package (its directory and package
    /// clause, so an external `_test` package is another), the file included.
    func goPackageFiles(containing file: PathID) -> [PathID] {
        go.flatMap { go in go.packageKeyByFile[file].flatMap { go.filesByPackage[$0] } } ?? [file]
    }

    /// The `module` directive of a `go.mod`.
    static func goModulePath(inGoMod bytes: [UInt8]) -> String? {
        for line in String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isNewline) {
            var line = Substring(line)
            if let comment = line.range(of: "//") { line = line[..<comment.lowerBound] }
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count == 2, words[0] == "module" else { continue }
            let path = words[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
            return path.isEmpty ? nil : path
        }
        return nil
    }

    /// The name in a Go file's package clause: the first token after
    /// comments must be `package`.
    static func goPackageClause(_ bytes: [UInt8]) -> String? {
        var index = 0
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }
        while index < bytes.count {
            if isSpace(bytes[index]) {
                index += 1
            } else if bytes[index] == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                while index < bytes.count, bytes[index] != 0x0A { index += 1 }
            } else if bytes[index] == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == 0x2A && bytes[index + 1] == 0x2F) { index += 1 }
                index += 2
            } else if bytes[index] == 0xEF, index + 2 < bytes.count, bytes[index + 1] == 0xBB, bytes[index + 2] == 0xBF {
                index += 3
            } else {
                break
            }
        }
        let keyword = Array("package".utf8)
        guard index + keyword.count < bytes.count,
              bytes[index..<index + keyword.count].elementsEqual(keyword),
              isSpace(bytes[index + keyword.count])
        else { return nil }
        index += keyword.count
        while index < bytes.count, isSpace(bytes[index]) { index += 1 }
        let start = index
        while index < bytes.count,
              bytes[index] >= 0x80 || bytes[index] == 0x5F
                || (bytes[index] | 0x20 >= 0x61 && bytes[index] | 0x20 <= 0x7A)
                || (bytes[index] >= 0x30 && bytes[index] <= 0x39)
        { index += 1 }
        guard start < index else { return nil }
        return String(decoding: bytes[start..<index], as: UTF8.self)
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
            let isRoot = fileName == "main.rs" || fileName == "lib.rs" || Self.isBinaryRoot(path)
            if isRoot {
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
                let prefix = isRoot || fileName == "mod.rs"
                    ? (directory.isEmpty ? "" : "\(directory)/")
                    : "\(path.dropLast(3))/"
                let candidates = ["\(prefix)\(name).rs", "\(prefix)\(name)/mod.rs"]
                guard let child = candidates.lazy.compactMap({ pathIDsByString[$0] }).first
                else { continue }
                children[file.pathID, default: [:]][facet.nameID] = child
                parents[child] = file.pathID
            }
        }

        return (children, parents, roots)
    }

    /// `src/bin/name.rs` is a crate of its own.
    private static func isBinaryRoot(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        return components.count == 3 && components[0] == "src" && components[1] == "bin"
            && components[2].hasSuffix(".rs")
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
        case .go:
            // A Go import names a package of many files: `goPackageFiles`.
            return nil
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

    /// The Rust crate root (`main.rs`, `lib.rs`, `src/bin/*.rs`) whose
    /// `mod` tree reaches `file`; the file itself when it is one.
    public func crateRoot(of file: PathID) -> PathID? {
        language == .rust ? crateRoot(containing: file) : nil
    }

    /// The module a file declares, as names below its root. Rust walks
    /// `mod foo;` parents up to a crate root (`[]` for the root itself) and
    /// returns `nil` when no crate root reaches the file. Python is the
    /// dotted path under the unit root without `src/` (`__init__.py` is its
    /// package); TypeScript is the directories plus the file name.
    public func modulePath(of file: PathID, names: Interner<NameID>) -> [String]? {
        switch language {
        case .rust:
            var components: [String] = []
            var current = file
            var seen: Set<PathID> = []
            while seen.insert(current).inserted {
                if crateRoots.contains(current) { return components.reversed() }
                guard let parent = parentModules[current],
                      let name = moduleChildren[parent]?.first(where: { $0.value == current })?.key
                else { return nil }
                components.append(names.resolve(name))
                current = parent
            }
            return nil
        case .python:
            guard var path = pathsByID[file] else { return nil }
            if path.hasPrefix("src/") { path.removeFirst("src/".count) }
            var components = path.split(separator: "/").map(String.init)
            if let last = components.popLast() {
                let stem = last.split(separator: ".", maxSplits: 1).first.map(String.init) ?? last
                if stem != "__init__" { components.append(stem) }
            }
            return components
        case .typescript:
            return pathsByID[file].map { $0.split(separator: "/").map(String.init) }
        case .go:
            return go?.importPathByFile[file].map { $0.split(separator: "/").map(String.init) }
        case .javascript:
            return nil
        }
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

/// Go's "a directory is a package": files group by directory and package
/// clause; a package's import path is its nearest `go.mod`'s module path
/// plus the directory below it.
private struct GoPackages: Sendable {
    let packageKeyByFile: [PathID: String]
    let filesByPackage: [String: [PathID]]
    let importPathByFile: [PathID: String]
    /// Import path to the files an importer sees (no `_test.go` files).
    let importable: [String: [PathID]]

    init(files: [(PathID, String, String?)], modules: [String: String]) {
        var packageKeyByFile: [PathID: String] = [:]
        var filesByPackage: [String: [PathID]] = [:]
        var importPathByFile: [PathID: String] = [:]
        var importable: [String: [PathID]] = [:]
        for (pathID, path, packageName) in files {
            let components = path.split(separator: "/").dropLast().map(String.init)
            let directory = components.joined(separator: "/")
            let key = directory + "\0" + (packageName ?? "")
            packageKeyByFile[pathID] = key
            filesByPackage[key, default: []].append(pathID)
            // The nearest go.mod at or above the directory.
            var importPath = directory
            for depth in stride(from: components.count, through: 0, by: -1) {
                let candidate = depth == 0 ? "." : components[..<depth].joined(separator: "/")
                guard let module = modules[candidate] else { continue }
                importPath = ([module] + components[depth...]).joined(separator: "/")
                break
            }
            importPathByFile[pathID] = importPath
            if !path.hasSuffix("_test.go"), packageName?.hasSuffix("_test") != true {
                importable[importPath, default: []].append(pathID)
            }
        }
        self.packageKeyByFile = packageKeyByFile
        self.filesByPackage = filesByPackage
        self.importPathByFile = importPathByFile
        self.importable = importable
    }
}
