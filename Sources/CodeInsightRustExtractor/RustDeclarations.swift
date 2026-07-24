import CodeInsightCore
import TreeSitterKit

struct RustDeclarationSite {
    let facetIndex: UInt32?
    let initializerRange: CodeInsightCore.ByteRange?
    let implTypeNameID: NameID?

    static let none = RustDeclarationSite(
        facetIndex: nil,
        initializerRange: nil,
        implTypeNameID: nil
    )
}

struct RustDeclarations {
    private struct Container {
        let owner: RustNodeKey
        let facetIndex: UInt32
        let kind: DeclarationKind
    }

    let bytes: [UInt8]
    let names: Interner<NameID>
    private(set) var facets: [DeclarationFacet] = []
    private(set) var implRelations: [ImplRelation] = []
    private var containers: [Container] = []

    init(bytes: [UInt8], names: Interner<NameID>) {
        self.bytes = bytes
        self.names = names
    }

    mutating func enter(
        _ node: Node,
        parent: Node?,
        ancestors: [Node],
        byteOffset: UInt32
    ) -> RustDeclarationSite {
        _ = ancestors

        let declaration: (DeclarationKind, SymbolSpace, Node)?
        switch node.kind {
        case "function_item":
            let kind: DeclarationKind = isMember(parent: parent)
                ? .rustMethod
                : .rustFn
            declaration = nameChild(of: node).map { (kind, .value, $0) }
        case "function_signature_item" where containers.last?.kind == .rustTrait:
            declaration = nameChild(of: node).map { (.rustMethod, .value, $0) }
        case "struct_item":
            declaration = directChild(of: node, kinds: ["type_identifier"])
                .map { (.rustStruct, .type, $0) }
        case "enum_item":
            declaration = directChild(of: node, kinds: ["type_identifier"])
                .map { (.rustEnum, .type, $0) }
        case "trait_item":
            declaration = directChild(of: node, kinds: ["type_identifier"])
                .map { (.rustTrait, .type, $0) }
        case "impl_item":
            declaration = implementedTypeName(in: node)
                .map { (.rustImpl, .type, $0) }
        case "mod_item":
            declaration = directChild(of: node, kinds: ["identifier"])
                .map { (.rustMod, .module, $0) }
        case "const_item":
            declaration = directChild(of: node, kinds: ["identifier"])
                .map { (.rustConst, .value, $0) }
        case "static_item":
            declaration = directChild(of: node, kinds: ["identifier"])
                .map { (.rustStatic, .value, $0) }
        case "type_item":
            declaration = directChild(of: node, kinds: ["type_identifier"])
                .map { (.rustTypeAlias, .type, $0) }
        case "field_declaration" where containers.last?.kind == .rustStruct:
            declaration = directChild(of: node, kinds: ["field_identifier"])
                .map { (.rustField, .value, $0) }
        default:
            declaration = nil
        }

        guard let (kind, space, nameNode) = declaration,
              let name = nameNode.text(in: bytes, byteOffset: byteOffset),
              let facetIndex = UInt32(exactly: facets.count)
        else {
            return .none
        }

        let fingerprints = fingerprints(
            for: node,
            kind: kind,
            byteOffset: byteOffset
        )
        facets.append(DeclarationFacet(
            symbolGroupID: SymbolGroupID(rawValue: facetIndex),
            space: space,
            kind: kind,
            nameID: names.intern(name),
            range: node.coreByteRange(byteOffset: byteOffset),
            nameRange: nameNode.coreByteRange(byteOffset: byteOffset),
            parentFacetIndex: parentFacetIndex(for: kind),
            signatureFingerprint: fingerprints.signature,
            bodyFingerprint: fingerprints.body
        ))

        var implTypeNameID: NameID?
        if kind == .rustImpl,
           let implementation = implementationNames(in: node),
           let typeName = implementation.type.text(
               in: bytes,
               byteOffset: byteOffset
           )
        {
            let traitName = implementation.trait.flatMap {
                $0.text(in: bytes, byteOffset: byteOffset)
            }
            if implementation.trait == nil || traitName != nil {
                let typeNameID = names.intern(typeName)
                implRelations.append(ImplRelation(
                    implFacetIndex: facetIndex,
                    traitNameID: traitName.map(names.intern),
                    traitNameRange: implementation.trait?.coreByteRange(
                        byteOffset: byteOffset
                    ),
                    typeNameID: typeNameID
                ))
                implTypeNameID = typeNameID
            }
        }

        if isContainer(node: node, kind: kind) {
            containers.append(Container(
                owner: RustNodeKey(node, byteOffset: byteOffset),
                facetIndex: facetIndex,
                kind: kind
            ))
        }

        return RustDeclarationSite(
            facetIndex: facetIndex,
            initializerRange: initializer(in: node)?.coreByteRange(
                byteOffset: byteOffset
            ),
            implTypeNameID: implTypeNameID
        )
    }

    mutating func exit(_ node: Node, byteOffset: UInt32) {
        if containers.last?.owner == RustNodeKey(node, byteOffset: byteOffset) {
            containers.removeLast()
        }
    }

    private func isMember(parent: Node?) -> Bool {
        guard parent?.kind == "declaration_list" else { return false }
        return containers.last?.kind == .rustImpl
            || containers.last?.kind == .rustTrait
    }

    private func parentFacetIndex(for kind: DeclarationKind) -> UInt32? {
        if kind == .rustField {
            return containers.last(where: { $0.kind == .rustStruct })?.facetIndex
        }
        return containers.last?.facetIndex
    }

    private func isContainer(node: Node, kind: DeclarationKind) -> Bool {
        switch kind {
        case .rustStruct, .rustTrait, .rustImpl:
            return true
        case .rustMod:
            return node.namedChildren.contains { $0.kind == "declaration_list" }
        default:
            return false
        }
    }

    private func nameChild(of node: Node) -> Node? {
        directChild(of: node, kinds: ["identifier", "metavariable"])
    }

    private func directChild(of node: Node, kinds: Set<String>) -> Node? {
        node.directNamedChild { kinds.contains($0.kind) }
    }

    private func implementedTypeName(in node: Node) -> Node? {
        implementationCandidates(in: node).last.flatMap(typeName)
    }

    private func implementationNames(in node: Node) -> (trait: Node?, type: Node)? {
        let candidates = implementationCandidates(in: node)
        guard let type = candidates.last.flatMap(typeName) else { return nil }
        let trait = candidates.count > 1 ? candidates.first.flatMap(typeName) : nil
        return (trait, type)
    }

    private func implementationCandidates(in node: Node) -> [Node] {
        node.namedChildren.filter {
            $0.kind != "type_parameters"
                && $0.kind != "where_clause"
                && $0.kind != "declaration_list"
        }
    }

    private func typeName(in node: Node) -> Node? {
        switch node.kind {
        case "identifier", "type_identifier", "primitive_type":
            return node
        case "scoped_type_identifier":
            for child in node.namedChildren.reversed() {
                if let name = typeName(in: child) { return name }
            }
        default:
            for child in node.namedChildren {
                if let name = typeName(in: child) { return name }
            }
        }
        return nil
    }

    private func initializer(in node: Node) -> Node? {
        guard node.kind == "const_item" || node.kind == "static_item" else {
            return nil
        }

        var followsEquals = false
        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            if child.kind == "=" {
                followsEquals = true
            } else if followsEquals && child.isNamed {
                return child
            }
        }
        return nil
    }

    private func fingerprints(
        for node: Node,
        kind: DeclarationKind,
        byteOffset: UInt32
    ) -> (signature: ContentID?, body: ContentID?) {
        guard kind == .rustFn || kind == .rustMethod else { return (nil, nil) }
        let declarationRange = node.coreByteRange(byteOffset: byteOffset)
        let bodyRange = node.directNamedChild { $0.kind == "block" }?
            .coreByteRange(byteOffset: byteOffset)
        let signatureRange = CodeInsightCore.ByteRange(
            lowerBound: declarationRange.lowerBound,
            upperBound: bodyRange?.lowerBound ?? declarationRange.upperBound
        )
        return (
            fingerprint(signatureRange),
            bodyRange.map(fingerprint)
        )
    }

    private func fingerprint(_ range: CodeInsightCore.ByteRange) -> ContentID {
        ContentID.sha256(of: Array(bytes[Int(range.lowerBound)..<Int(range.upperBound)]))
    }
}
