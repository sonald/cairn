import CodeInsightCore
import TreeSitterKit

struct RustScopeBuilder {
    private struct ActiveScope {
        let owner: RustNodeKey
        let id: ScopeID
        let genericTypeNames: Set<NameID>
        let implTypeNameID: NameID?
    }

    private struct PatternPlan {
        let root: RustNodeKey
        let scopeID: ScopeID
        let bindingKind: BindingKind
        let targetHint: UnresolvedSymbolRef?
    }

    private struct ActiveRegion {
        let owner: RustNodeKey
        let id: ExecutableRegionID
    }

    let bytes: [UInt8]
    let names: Interner<NameID>
    private(set) var scopes: [ScopeRecord] = []
    private(set) var bindings: [BindingRecord] = []
    private(set) var executableRegions: [ExecutableRegionRecord] = []

    private var activeScopes: [ActiveScope] = []
    private var pendingPatterns: [RustNodeKey: PatternPlan] = [:]
    private var activePatterns: [PatternPlan] = []
    private var activeRegions: [ActiveRegion] = []

    init(bytes: [UInt8], names: Interner<NameID>) {
        self.bytes = bytes
        self.names = names
    }

    mutating func enter(
        _ node: Node,
        parent: Node?,
        ancestors: [Node],
        declaration: RustDeclarationSite,
        byteOffset: UInt32
    ) {
        if let kind = scopeKind(for: node) {
            pushScope(
                owner: node,
                kind: kind,
                range: bindingBody(in: node)?.coreByteRange(
                    byteOffset: byteOffset
                ) ?? node.coreByteRange(byteOffset: byteOffset),
                implTypeNameID: declaration.implTypeNameID,
                byteOffset: byteOffset
            )
        }

        let key = RustNodeKey(node, byteOffset: byteOffset)
        if let plan = pendingPatterns.removeValue(forKey: key) {
            activePatterns.append(plan)
        }
        if let plan = activePatterns.last,
           isBindingIdentifier(
               node,
               parent: parent,
               plan: plan,
               byteOffset: byteOffset
           ),
           let name = node.text(in: bytes, byteOffset: byteOffset)
        {
            bindings.append(BindingRecord(
                scopeID: plan.scopeID,
                localNameID: names.intern(name),
                space: .value,
                kind: plan.bindingKind,
                declarationRange: node.coreByteRange(byteOffset: byteOffset),
                targetHint: plan.targetHint
            ))
        }

        registerPatterns(from: node, byteOffset: byteOffset)
        pushRegionIfNeeded(
            for: node,
            parent: parent,
            ancestors: ancestors,
            declaration: declaration,
            byteOffset: byteOffset
        )
    }

    mutating func exit(_ node: Node, byteOffset: UInt32) {
        let key = RustNodeKey(node, byteOffset: byteOffset)
        if activePatterns.last?.root == key {
            activePatterns.removeLast()
        }
        if activeRegions.last?.owner == key {
            activeRegions.removeLast()
        }
        if activeScopes.last?.owner == key {
            activeScopes.removeLast()
        }
    }

    var currentScopeID: ScopeID? {
        activeScopes.last?.id
    }

    var currentRegionID: ExecutableRegionID? {
        activeRegions.last?.id
    }

    var currentImportScopeID: ScopeID? {
        guard activeScopes.count >= 2,
              activeScopes.last?.owner.kind == "block",
              activeScopes[activeScopes.count - 2].owner.kind == "function_item"
        else { return currentScopeID }
        return activeScopes[activeScopes.count - 2].id
    }

    private mutating func pushScope(
        owner: Node,
        kind: ScopeKind,
        range: CodeInsightCore.ByteRange,
        implTypeNameID: NameID?,
        byteOffset: UInt32
    ) {
        guard let rawID = UInt32(exactly: scopes.count) else {
            preconditionFailure("Scope count exceeds UInt32")
        }
        let id = ScopeID(rawValue: rawID)
        scopes.append(ScopeRecord(
            id: id,
            parent: currentScopeID,
            kind: kind,
            range: range
        ))
        var genericTypeNames = activeScopes.last?.genericTypeNames ?? []
        genericTypeNames.formUnion(genericTypeParameterNames(
            in: owner,
            byteOffset: byteOffset
        ))
        activeScopes.append(ActiveScope(
            owner: RustNodeKey(owner, byteOffset: byteOffset),
            id: id,
            genericTypeNames: genericTypeNames,
            implTypeNameID: implTypeNameID
                ?? activeScopes.last?.implTypeNameID
        ))
    }

    private func scopeKind(for node: Node) -> ScopeKind? {
        switch node.kind {
        case "source_file":
            return .module
        case "block":
            return .block
        case "function_item":
            return .function
        case "closure_expression":
            return .closure
        case "impl_item":
            return .impl
        case "mod_item" where node.namedChildren.contains(where: {
            $0.kind == "declaration_list"
        }):
            return .module
        case "match_arm":
            return .matchArm
        case "for_expression":
            return .block
        case "if_expression" where node.namedChildren.contains(where: {
            $0.kind == "let_condition" || $0.kind == "let_chain"
        }):
            return .block
        case "while_expression" where node.namedChildren.contains(where: {
            $0.kind == "let_condition" || $0.kind == "let_chain"
        }):
            return .block
        default:
            return nil
        }
    }

    private func bindingBody(in node: Node) -> Node? {
        switch node.kind {
        case "if_expression", "while_expression", "for_expression":
            return node.directNamedChild { $0.kind == "block" }
        default:
            return nil
        }
    }

    private mutating func registerPatterns(
        from node: Node,
        byteOffset: UInt32
    ) {
        guard let scopeID = currentScopeID else { return }

        switch node.kind {
        case "parameter":
            register(
                node.namedChildren.first,
                scopeID: scopeID,
                kind: .param,
                targetHint: annotatedTargetHint(
                    in: node,
                    byteOffset: byteOffset
                ),
                byteOffset: byteOffset
            )
        case "self_parameter":
            register(
                node.directNamedChild { $0.kind == "self" },
                scopeID: scopeID,
                kind: .param,
                targetHint: activeScopes.last?.implTypeNameID.map {
                    UnresolvedSymbolRef(nameID: $0, hintKind: .unqualified)
                },
                byteOffset: byteOffset
            )
        case "closure_parameters":
            for child in node.namedChildren
                where child.kind != "parameter"
                    && child.kind != "self_parameter"
            {
                register(
                    child,
                    scopeID: scopeID,
                    kind: .param,
                    targetHint: nil,
                    byteOffset: byteOffset
                )
            }
        case "let_declaration":
            register(
                node.directNamedChild { $0.kind != "mutable_specifier" },
                scopeID: scopeID,
                kind: .letBinding,
                targetHint: annotatedTargetHint(
                    in: node,
                    byteOffset: byteOffset
                ) ?? constructedTargetHint(
                    in: node,
                    byteOffset: byteOffset
                ),
                byteOffset: byteOffset
            )
        case "match_arm":
            let matchPattern = node.directNamedChild {
                $0.kind == "match_pattern"
            }
            register(
                matchPattern?.namedChildren.first,
                scopeID: scopeID,
                kind: .patternBinding,
                targetHint: nil,
                byteOffset: byteOffset
            )
        case "let_condition":
            register(
                node.namedChildren.first,
                scopeID: scopeID,
                kind: .patternBinding,
                targetHint: nil,
                byteOffset: byteOffset
            )
        case "for_expression":
            register(
                node.directNamedChild { $0.kind != "label" },
                scopeID: scopeID,
                kind: .patternBinding,
                targetHint: nil,
                byteOffset: byteOffset
            )
        default:
            break
        }
    }

    private mutating func register(
        _ node: Node?,
        scopeID: ScopeID,
        kind: BindingKind,
        targetHint: UnresolvedSymbolRef?,
        byteOffset: UInt32
    ) {
        guard let node else { return }
        let key = RustNodeKey(node, byteOffset: byteOffset)
        pendingPatterns[key] = PatternPlan(
            root: key,
            scopeID: scopeID,
            bindingKind: kind,
            targetHint: isSimpleBindingPattern(node) ? targetHint : nil
        )
    }

    private func isSimpleBindingPattern(_ node: Node) -> Bool {
        node.kind == "identifier" || node.kind == "self"
    }

    private func annotatedTargetHint(
        in node: Node,
        byteOffset: UInt32
    ) -> UnresolvedSymbolRef? {
        guard let type = annotatedType(in: node),
              !contains(nodeKind: "dynamic_type", in: type),
              let name = supportedTypeName(in: type),
              let text = name.text(in: bytes, byteOffset: byteOffset)
        else { return nil }
        let nameID = names.intern(text)
        guard activeScopes.last?.genericTypeNames.contains(nameID) != true else {
            return nil
        }
        return UnresolvedSymbolRef(nameID: nameID, hintKind: .unqualified)
    }

    private func constructedTargetHint(
        in node: Node,
        byteOffset: UInt32
    ) -> UnresolvedSymbolRef? {
        guard let value = initializer(in: node) else { return nil }
        let name: Node?
        switch value.kind {
        case "call_expression":
            guard let callee = value.namedChildren.first,
                  callee.kind == "scoped_identifier",
                  callee.namedChildren.last?.text(
                      in: bytes,
                      byteOffset: byteOffset
                  ) == "new"
            else { return nil }
            name = callee.namedChildren.first.flatMap(supportedTypeName)
        case "struct_expression":
            name = value.namedChildren.first.flatMap(supportedTypeName)
        default:
            return nil
        }
        guard let name,
              let text = name.text(in: bytes, byteOffset: byteOffset)
        else { return nil }
        let nameID = names.intern(text)
        guard activeScopes.last?.genericTypeNames.contains(nameID) != true else {
            return nil
        }
        return UnresolvedSymbolRef(nameID: nameID, hintKind: .member)
    }

    private func annotatedType(in node: Node) -> Node? {
        var followsColon = false
        for index in 0..<node.childCount {
            guard let child = node.child(at: index) else { continue }
            if child.kind == ":" {
                followsColon = true
            } else if followsColon && child.isNamed {
                return child
            }
        }
        return nil
    }

    private func initializer(in node: Node) -> Node? {
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

    private func supportedTypeName(in node: Node) -> Node? {
        switch node.kind {
        case "identifier", "type_identifier", "primitive_type":
            return node
        case "generic_type":
            return node.namedChildren.first.flatMap(supportedTypeName)
        case "reference_type":
            for child in node.namedChildren.reversed() {
                if let name = supportedTypeName(in: child) { return name }
            }
            return nil
        case "scoped_type_identifier":
            for child in node.namedChildren.reversed() {
                if let name = supportedTypeName(in: child) { return name }
            }
            return nil
        default:
            return nil
        }
    }

    private func contains(nodeKind: String, in node: Node) -> Bool {
        if node.kind == nodeKind { return true }
        return node.namedChildren.contains {
            contains(nodeKind: nodeKind, in: $0)
        }
    }

    private func genericTypeParameterNames(
        in node: Node,
        byteOffset: UInt32
    ) -> Set<NameID> {
        guard let parameters = node.directNamedChild(where: {
            $0.kind == "type_parameters"
        }) else { return [] }
        return Set(parameters.namedChildren.compactMap { parameter in
            guard parameter.kind == "type_parameter",
                  let name = parameter.directNamedChild(where: {
                      $0.kind == "type_identifier"
                  })?.text(in: bytes, byteOffset: byteOffset)
            else { return nil }
            return names.intern(name)
        })
    }

    private func isBindingIdentifier(
        _ node: Node,
        parent: Node?,
        plan: PatternPlan,
        byteOffset: UInt32
    ) -> Bool {
        if node.kind == "shorthand_field_identifier" {
            return true
        }
        if node.kind == "self" {
            return plan.bindingKind == .param
        }
        guard node.kind == "identifier", let parent else { return false }

        switch parent.kind {
        case "scoped_identifier", "scoped_type_identifier", "generic_pattern",
             "range_pattern", "struct_pattern":
            return false
        case "tuple_struct_pattern":
            return parent.namedChildren.first.map {
                RustNodeKey($0, byteOffset: byteOffset)
            } != RustNodeKey(node, byteOffset: byteOffset)
        default:
            return true
        }
    }

    private mutating func pushRegionIfNeeded(
        for node: Node,
        parent: Node?,
        ancestors: [Node],
        declaration: RustDeclarationSite,
        byteOffset: UInt32
    ) {
        let kind: ExecutableRegionKind
        let range: CodeInsightCore.ByteRange

        switch node.kind {
        case "function_item":
            kind = isMethod(parent: parent, ancestors: ancestors)
                ? .method
                : .function
            range = node.coreByteRange(byteOffset: byteOffset)
        case "closure_expression":
            kind = .closure
            range = node.coreByteRange(byteOffset: byteOffset)
        case "const_item", "static_item":
            guard let initializerRange = declaration.initializerRange else {
                return
            }
            kind = .constantInitializer
            range = initializerRange
        default:
            return
        }

        guard let scopeID = currentScopeID,
              let rawID = UInt32(exactly: executableRegions.count)
        else {
            preconditionFailure("Executable region has no scope or exceeds UInt32")
        }
        let id = ExecutableRegionID(rawValue: rawID)
        executableRegions.append(ExecutableRegionRecord(
            id: id,
            kind: kind,
            range: range,
            enclosingScopeID: scopeID,
            associatedFacetIndex: declaration.facetIndex
        ))
        activeRegions.append(ActiveRegion(
            owner: RustNodeKey(node, byteOffset: byteOffset),
            id: id
        ))
    }

    private func isMethod(parent: Node?, ancestors: [Node]) -> Bool {
        guard parent?.kind == "declaration_list" else { return false }
        for ancestor in ancestors.reversed() {
            if ancestor.kind == "impl_item" || ancestor.kind == "trait_item" {
                return true
            }
            if ancestor.kind == "mod_item" || ancestor.kind == "source_file" {
                return false
            }
        }
        return false
    }
}
