import CodeInsightCore
import TreeSitterKit

struct RustScopeBuilder {
    private struct ActiveScope {
        let owner: RustNodeKey
        let id: ScopeID
    }

    private struct PatternPlan {
        let root: RustNodeKey
        let scopeID: ScopeID
        let bindingKind: BindingKind
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
        declaration: RustDeclarationSite
    ) {
        if let kind = scopeKind(for: node) {
            pushScope(
                owner: node,
                kind: kind,
                range: bindingBody(in: node)?.coreByteRange
                    ?? node.coreByteRange
            )
        }

        let key = RustNodeKey(node)
        if let plan = pendingPatterns.removeValue(forKey: key) {
            activePatterns.append(plan)
        }
        if let plan = activePatterns.last,
           isBindingIdentifier(node, parent: parent, plan: plan),
           let name = node.text(in: bytes)
        {
            bindings.append(BindingRecord(
                scopeID: plan.scopeID,
                localNameID: names.intern(name),
                space: .value,
                kind: plan.bindingKind,
                declarationRange: node.coreByteRange,
                targetHint: nil
            ))
        }

        registerPatterns(from: node)
        pushRegionIfNeeded(
            for: node,
            parent: parent,
            ancestors: ancestors,
            declaration: declaration
        )
    }

    mutating func exit(_ node: Node) {
        let key = RustNodeKey(node)
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
        range: CodeInsightCore.ByteRange
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
        activeScopes.append(ActiveScope(owner: RustNodeKey(owner), id: id))
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

    private mutating func registerPatterns(from node: Node) {
        guard let scopeID = currentScopeID else { return }

        switch node.kind {
        case "parameter":
            register(
                node.namedChildren.first,
                scopeID: scopeID,
                kind: .param
            )
        case "self_parameter":
            register(
                node.directNamedChild { $0.kind == "self" },
                scopeID: scopeID,
                kind: .param
            )
        case "closure_parameters":
            for child in node.namedChildren
                where child.kind != "parameter"
                    && child.kind != "self_parameter"
            {
                register(child, scopeID: scopeID, kind: .param)
            }
        case "let_declaration":
            register(
                node.directNamedChild { $0.kind != "mutable_specifier" },
                scopeID: scopeID,
                kind: .letBinding
            )
        case "match_arm":
            let matchPattern = node.directNamedChild {
                $0.kind == "match_pattern"
            }
            register(
                matchPattern?.namedChildren.first,
                scopeID: scopeID,
                kind: .patternBinding
            )
        case "let_condition":
            register(
                node.namedChildren.first,
                scopeID: scopeID,
                kind: .patternBinding
            )
        case "for_expression":
            register(
                node.directNamedChild { $0.kind != "label" },
                scopeID: scopeID,
                kind: .patternBinding
            )
        default:
            break
        }
    }

    private mutating func register(
        _ node: Node?,
        scopeID: ScopeID,
        kind: BindingKind
    ) {
        guard let node else { return }
        let key = RustNodeKey(node)
        pendingPatterns[key] = PatternPlan(
            root: key,
            scopeID: scopeID,
            bindingKind: kind
        )
    }

    private func isBindingIdentifier(
        _ node: Node,
        parent: Node?,
        plan: PatternPlan
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
            return parent.namedChildren.first.map(RustNodeKey.init)
                != RustNodeKey(node)
        default:
            return true
        }
    }

    private mutating func pushRegionIfNeeded(
        for node: Node,
        parent: Node?,
        ancestors: [Node],
        declaration: RustDeclarationSite
    ) {
        let kind: ExecutableRegionKind
        let range: CodeInsightCore.ByteRange

        switch node.kind {
        case "function_item":
            kind = isMethod(parent: parent, ancestors: ancestors)
                ? .method
                : .function
            range = node.coreByteRange
        case "closure_expression":
            kind = .closure
            range = node.coreByteRange
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
        activeRegions.append(ActiveRegion(owner: RustNodeKey(node), id: id))
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
