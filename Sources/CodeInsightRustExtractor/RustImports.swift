import CodeInsightCore
import TreeSitterKit

struct RustImports {
    let bytes: [UInt8]
    let names: Interner<NameID>
    let strings: Interner<StringID>
    private(set) var imports: [ImportBinding] = []
    private(set) var exports: [ExportRecord] = []

    mutating func enter(_ node: Node, scopeID: ScopeID?) {
        guard let scopeID else { return }

        switch node.kind {
        case "use_declaration":
            let reexport = node.namedChildren.contains {
                $0.kind == "visibility_modifier"
            }
            guard let argument = node.directNamedChild(where: {
                $0.kind != "visibility_modifier"
            }) else { return }
            expand(
                argument,
                prefix: "",
                scopeID: scopeID,
                reexport: reexport
            )
        case "extern_crate_declaration":
            addExternCrate(node, scopeID: scopeID)
        default:
            break
        }
    }

    private mutating func expand(
        _ node: Node,
        prefix: String,
        scopeID: ScopeID,
        reexport: Bool
    ) {
        switch node.kind {
        case "use_list":
            for child in node.namedChildren {
                expand(
                    child,
                    prefix: prefix,
                    scopeID: scopeID,
                    reexport: reexport
                )
            }
        case "scoped_use_list":
            let children = node.namedChildren
            guard let path = children.first?.text(in: bytes),
                  let list = children.last,
                  list.kind == "use_list"
            else { return }
            expand(
                list,
                prefix: joined(prefix, path),
                scopeID: scopeID,
                reexport: reexport
            )
        case "use_as_clause":
            let children = node.namedChildren
            guard children.count >= 2,
                  let path = children.first?.text(in: bytes),
                  let alias = children.last?.text(in: bytes)
            else { return }
            let specifier = path == "self" ? prefix : joined(prefix, path)
            let imported = path == "self"
                ? lastComponent(of: prefix)
                : lastComponent(of: path)
            add(
                specifier: specifier,
                importedName: imported,
                localName: alias,
                kind: .named,
                flags: reexport ? [.reexport] : [],
                scopeID: scopeID,
                range: node.coreByteRange
            )
        case "use_wildcard":
            let path = node.namedChildren.first?.text(in: bytes)
            add(
                specifier: path.map { joined(prefix, $0) } ?? prefix,
                importedName: nil,
                localName: nil,
                kind: .namespace,
                flags: reexport ? [.wildcard, .reexport] : [.wildcard],
                scopeID: scopeID,
                range: node.coreByteRange
            )
        case "self" where !prefix.isEmpty:
            let name = lastComponent(of: prefix)
            add(
                specifier: prefix,
                importedName: name,
                localName: name,
                kind: .named,
                flags: reexport ? [.reexport] : [],
                scopeID: scopeID,
                range: node.coreByteRange
            )
        case "identifier", "scoped_identifier", "crate", "self", "super",
             "metavariable":
            guard let path = node.text(in: bytes) else { return }
            let name = lastComponent(of: path)
            add(
                specifier: joined(prefix, path),
                importedName: name,
                localName: name,
                kind: .named,
                flags: reexport ? [.reexport] : [],
                scopeID: scopeID,
                range: node.coreByteRange
            )
        default:
            break
        }
    }

    private mutating func addExternCrate(_ node: Node, scopeID: ScopeID) {
        let identifiers = node.namedChildren.filter { $0.kind == "identifier" }
        guard let nameNode = identifiers.first,
              let name = nameNode.text(in: bytes)
        else { return }
        let localName = identifiers.last?.text(in: bytes) ?? name
        add(
            specifier: name,
            importedName: name,
            localName: localName,
            kind: .module,
            flags: [],
            scopeID: scopeID,
            range: node.coreByteRange
        )
    }

    private mutating func add(
        specifier: String,
        importedName: String?,
        localName: String?,
        kind: ImportKind,
        flags: ImportFlags,
        scopeID: ScopeID,
        range: CodeInsightCore.ByteRange
    ) {
        guard !specifier.isEmpty,
              let bindingIndex = UInt32(exactly: imports.count)
        else { return }
        let importedNameID = importedName.map(names.intern)
        let localNameID = localName.map(names.intern)
        imports.append(ImportBinding(
            moduleSpecifier: strings.intern(specifier),
            importedName: importedNameID,
            localName: localNameID,
            kind: kind,
            flags: flags,
            scopeID: scopeID,
            range: range
        ))
        if flags.contains(.reexport), let exportedName = localNameID {
            exports.append(ExportRecord(
                exportedName: exportedName,
                sourceBindingIndex: bindingIndex,
                range: range
            ))
        }
    }

    private func joined(_ prefix: String, _ path: String) -> String {
        prefix.isEmpty ? path : "\(prefix)::\(path)"
    }

    private func lastComponent(of path: String) -> String {
        path.split(separator: "::").last.map(String.init) ?? path
    }
}
