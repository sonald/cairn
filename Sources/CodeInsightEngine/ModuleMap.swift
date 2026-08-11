import CodeInsightCore
import Foundation

public struct ModuleMap: Sendable {
    public let moduleChildren: [PathID: [NameID: PathID]]

    private let parentModules: [PathID: PathID]
    private let crateRoots: Set<PathID>

    init(
        manifest: SnapshotManifest,
        language: LanguageID,
        indexes: [ContentIndexKey: ContentIndex],
        bytesByContent: [ContentID: [UInt8]],
        names: Interner<NameID>,
        paths: Interner<PathID>
    ) {
        precondition(language == .rust)
        let files = manifest.files.filter {
            LanguageMode.classify(
                path: paths.resolve($0.pathID),
                language: language
            ) != nil
        }
        let pathIDsByString = Dictionary(uniqueKeysWithValues: files.map {
            (paths.resolve($0.pathID), $0.pathID)
        })
        var indexesByContent: [ContentID: ContentIndex] = [:]
        for (key, index) in indexes where indexesByContent[key.contentID] == nil {
            indexesByContent[key.contentID] = index
        }
        var children: [PathID: [NameID: PathID]] = [:]
        var parents: [PathID: PathID] = [:]
        var roots: Set<PathID> = []

        for file in files {
            let path = paths.resolve(file.pathID)
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

        moduleChildren = children
        parentModules = parents
        crateRoots = roots
    }

    func targetFile(
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
