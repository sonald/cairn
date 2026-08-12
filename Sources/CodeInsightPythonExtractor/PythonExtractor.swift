import CTreeSitterPython
import CodeInsightCore
import Foundation
import TreeSitterKit

public struct PythonExtractor: LanguageExtractor, Sendable {
    public static let grammarVersion: UInt32 = 1
    public static let extractorVersion: UInt32 = 1

    public init() {}

    public var language: LanguageID { .python }
    public var grammarVersion: UInt32 { Self.grammarVersion }
    public var extractorVersion: UInt32 { Self.extractorVersion }

    public func extractWithDiagnostics(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner: ExtractionInterners
    ) throws -> (index: ContentIndex, containsErrorNodes: Bool) {
        try requireSupported(key.languageMode)
        guard
            let grammar = tree_sitter_python(),
            let parser = Parser(language: grammar),
            let tree = parser.parse(bytes)
        else {
            throw CocoaError(
                .featureUnsupported,
                userInfo: [
                    NSLocalizedFailureReasonErrorKey:
                        "Python parser unavailable or parse failed"
                ]
            )
        }
        let index = buildIndex(
            bytes: bytes,
            key: key,
            root: tree.rootNode,
            names: interner.names,
            strings: interner.strings
        )
        return (index, tree.rootNode.hasError)
    }

    public func identifierRanges(
        named name: String,
        in bytes: [UInt8],
        mode: LanguageMode
    ) throws -> [CodeInsightCore.ByteRange] {
        try requireSupported(mode)
        guard
            let grammar = tree_sitter_python(),
            let parser = Parser(language: grammar),
            let tree = parser.parse(bytes)
        else { return [] }
        let name = Array(name.utf8)
        return tree.rootNode.depthFirst().compactMap { node in
            guard node.kind.contains("identifier"),
                  (node.byteRange.upperBound - node.byteRange.lowerBound) == UInt32(name.count),
                  bytes[Int(node.byteRange.lowerBound)..<Int(node.byteRange.upperBound)]
                    .elementsEqual(name)
            else { return nil }
            return CodeInsightCore.ByteRange(
                lowerBound: node.byteRange.lowerBound,
                upperBound: node.byteRange.upperBound
            )
        }
    }

    public func identifierRanges(
        named name: String,
        in bytes: [UInt8]
    ) throws -> [CodeInsightCore.ByteRange] {
        try identifierRanges(
            named: name,
            in: bytes,
            mode: LanguageMode(language: .python)
        )
    }

    private func requireSupported(_ mode: LanguageMode) throws {
        guard mode.language == .python, mode.variant == nil else {
            throw CocoaError(
                .featureUnsupported,
                userInfo: [
                    NSLocalizedFailureReasonErrorKey:
                        "PythonExtractor only supports Python; got \(mode.language) \(mode.variant ?? "")"
                ]
            )
        }
    }
}

private func childField(_ node: Node, _ name: String) -> Node? {
    node.child(namedField: name)
}

private func text(_ node: Node, in bytes: [UInt8]) -> String? {
    let lower = Int(node.byteRange.lowerBound)
    let upper = Int(node.byteRange.upperBound)
    guard lower <= upper, upper <= bytes.count else { return nil }
    return String(bytes: bytes[lower..<upper], encoding: .utf8)
}

private func coreRange(_ node: Node) -> CodeInsightCore.ByteRange {
    CodeInsightCore.ByteRange(
        lowerBound: node.byteRange.lowerBound,
        upperBound: node.byteRange.upperBound
    )
}

private func fingerprint(
    _ range: CodeInsightCore.ByteRange,
    bytes: [UInt8]
) -> ContentID? {
    guard range.lowerBound <= range.upperBound,
          range.upperBound <= bytes.count
    else { return nil }
    return ContentID.sha256(
        of: Array(bytes[Int(range.lowerBound)..<Int(range.upperBound)])
    )
}

private func buildIndex(
    bytes: [UInt8],
    key: ContentIndexKey,
    root: Node,
    names: Interner<NameID>,
    strings: Interner<StringID>
) -> ContentIndex {
    var scopes: [ScopeRecord] = []
    var scopeStack: [ScopeID] = []
    var bindings: [BindingRecord] = []
    var regions: [ExecutableRegionRecord] = []
    var regionStack: [ExecutableRegionID] = []
    var symbols: [DeclarationFacet] = []
    var calls: [UnresolvedCall] = []
    var imports: [ImportBinding] = []
    var functionScopes: [ScopeID] = []
    var classScopes: [ScopeID] = []
    var facetStack: [UInt32] = []

    func pushScope(
        _ node: Node,
        kind: ScopeKind,
        parent: ScopeID?
    ) -> ScopeID {
        let id = ScopeID(rawValue: UInt32(scopes.count))
        scopes.append(ScopeRecord(
            id: id,
            parent: parent,
            kind: kind,
            range: coreRange(node)
        ))
        scopeStack.append(id)
        if kind == .function || kind == .closure {
            functionScopes.append(id)
        } else if kind == .class {
            classScopes.append(id)
        }
        return id
    }

    func popScope(_ id: ScopeID) {
        _ = scopeStack.popLast()
        if functionScopes.last == id { functionScopes.removeLast() }
        if classScopes.last == id { classScopes.removeLast() }
    }

    func currentScope() -> ScopeID? {
        scopeStack.last
    }

    func pushRegion(
        _ node: Node,
        kind: ExecutableRegionKind,
        scopeID: ScopeID,
        facetIndex: UInt32?
    ) {
        let id = ExecutableRegionID(rawValue: UInt32(regions.count))
        regions.append(ExecutableRegionRecord(
            id: id,
            kind: kind,
            range: coreRange(node),
            enclosingScopeID: scopeID,
            associatedFacetIndex: facetIndex
        ))
        regionStack.append(id)
    }

    func popRegion(_ id: ExecutableRegionID) {
        if regionStack.last == id {
            regionStack.removeLast()
        }
    }

    func currentRegion() -> ExecutableRegionID? {
        regionStack.last
    }

    func appendBinding(
        _ nameNode: Node,
        scopeID: ScopeID,
        kind: BindingKind
    ) {
        guard let name = text(nameNode, in: bytes) else { return }
        bindings.append(BindingRecord(
            scopeID: scopeID,
            localNameID: names.intern(name),
            space: .value,
            kind: kind,
            declarationRange: coreRange(nameNode),
            targetHint: nil
        ))
    }

    func appendImport(
        specifier: String,
        imported: String?,
        local: String?,
        kind: ImportKind,
        flags: ImportFlags,
        scopeID: ScopeID,
        range: CodeInsightCore.ByteRange
    ) {
        imports.append(ImportBinding(
            moduleSpecifier: strings.intern(specifier),
            importedName: imported.map(names.intern),
            localName: local.map(names.intern),
            kind: kind,
            flags: flags,
            scopeID: scopeID,
            range: range
        ))
    }

    func enterFunction(
        _ node: Node,
        wrapper: Node,
        isMethod: Bool
    ) -> Bool {
        guard let name = childField(node, "name"),
              let nameString = text(name, in: bytes),
              let body = childField(node, "body")
        else { return false }
        let range = coreRange(wrapper)
        let bodyRange = coreRange(body)
        let facetIndex = UInt32(symbols.count)
        let parentFacet: UInt32?
        if isMethod, !classScopes.isEmpty {
            parentFacet = facetStack.last
        } else if functionScopes.isEmpty {
            parentFacet = nil
        } else {
            parentFacet = facetStack.last
        }
        symbols.append(DeclarationFacet(
            symbolGroupID: SymbolGroupID(rawValue: facetIndex),
            space: .value,
            kind: .pythonFunction,
            nameID: names.intern(nameString),
            range: range,
            nameRange: coreRange(name),
            parentFacetIndex: parentFacet,
            signatureFingerprint: fingerprint(
                CodeInsightCore.ByteRange(
                    lowerBound: range.lowerBound,
                    upperBound: bodyRange.lowerBound
                ),
                bytes: bytes
            ),
            bodyFingerprint: fingerprint(bodyRange, bytes: bytes)
        ))
        facetStack.append(facetIndex)
        let parentScope = scopeStack.last(where: {
            scopes[Int($0.rawValue)].kind != .class
        })
        let scopeID = pushScope(body, kind: .function, parent: parentScope)
        pushRegion(body, kind: isMethod ? .method : .function, scopeID: scopeID, facetIndex: facetIndex)
        return true
    }

    func enterClass(_ node: Node, wrapper: Node?) -> Bool {
        guard let name = childField(node, "name"),
              let nameString = text(name, in: bytes),
              let body = childField(node, "body")
        else { return false }
        let range = coreRange(wrapper ?? node)
        let bodyRange = coreRange(body)
        let facetIndex = UInt32(symbols.count)
        symbols.append(DeclarationFacet(
            symbolGroupID: SymbolGroupID(rawValue: facetIndex),
            space: .value,
            kind: .pythonClass,
            nameID: names.intern(nameString),
            range: range,
            nameRange: coreRange(name),
            parentFacetIndex: facetStack.last,
            signatureFingerprint: fingerprint(
                CodeInsightCore.ByteRange(
                    lowerBound: range.lowerBound,
                    upperBound: bodyRange.lowerBound
                ),
                bytes: bytes
            ),
            bodyFingerprint: fingerprint(bodyRange, bytes: bytes)
        ))
        facetStack.append(facetIndex)
        let scopeID = pushScope(body, kind: .class, parent: currentScope())
        pushRegion(body, kind: .classBody, scopeID: scopeID, facetIndex: facetIndex)
        return true
    }

    func walk(
        _ node: Node,
        directClassMember: Bool,
        moduleScope: ScopeID,
        parentIsClassBody: Bool = false
    ) {
        switch node.kind {
        case "decorated_definition":
            guard let definition = childField(node, "definition") else { return }
            if definition.kind == "function_definition" {
                if enterFunction(definition, wrapper: node, isMethod: directClassMember) {
                    let scopeID = scopeStack.last
                    walkChildren(definition, directClassMember: false, moduleScope: moduleScope)
                    if let regionID = regionStack.last { popRegion(regionID) }
                    if let scopeID { popScope(scopeID) }
                    _ = facetStack.popLast()
                }
            } else {
                if enterClass(definition, wrapper: node) {
                    let scopeID = scopeStack.last
                    walkChildren(definition, directClassMember: true, moduleScope: moduleScope, parentClassBody: true)
                    if let regionID = regionStack.last { popRegion(regionID) }
                    if let scopeID { popScope(scopeID) }
                    _ = facetStack.popLast()
                }
            }
            return
        case "function_definition":
            if enterFunction(node, wrapper: node, isMethod: directClassMember) {
                let scopeID = scopeStack.last
                walkChildren(node, directClassMember: false, moduleScope: moduleScope)
                if let regionID = regionStack.last { popRegion(regionID) }
                if let scopeID { popScope(scopeID) }
                _ = facetStack.popLast()
            }
            return
        case "class_definition":
            if enterClass(node, wrapper: nil) {
                let scopeID = scopeStack.last
                walkChildren(node, directClassMember: true, moduleScope: moduleScope, parentClassBody: true)
                if let regionID = regionStack.last { popRegion(regionID) }
                if let scopeID { popScope(scopeID) }
                _ = facetStack.popLast()
            }
            return
        case "lambda":
            enterLambda(node)
            return
        case "parameters", "lambda_parameters":
            if let scopeID = functionScopes.last {
                for child in node.namedChildren {
                    appendBinding(parameterName(child) ?? child, scopeID: scopeID, kind: .param)
                }
            } else if let scopeID = currentScope() {
                for child in node.namedChildren {
                    appendBinding(parameterName(child) ?? child, scopeID: scopeID, kind: .param)
                }
            }
        default:
            break
        }

        if node.kind == "assignment" {
            if let right = childField(node, "right") {
                walk(right, directClassMember: false, moduleScope: moduleScope)
            }
            if let currentScopeID = currentScope(),
               let left = childField(node, "left"),
               let name = simpleIdentifier(left)
            {
                appendBinding(name, scopeID: currentScopeID, kind: .assignment)
            }
            return
        }

        if node.kind == "call" {
            if let function = childField(node, "function"),
               let regionID = currentRegion(),
               let info = callInfo(function),
               info.computed == false,
               let nameNode = info.name,
               let callName = text(nameNode, in: bytes)
            {
                calls.append(UnresolvedCall(
                    regionID: regionID,
                    nameID: names.intern(callName),
                    range: coreRange(node),
                    nameRange: coreRange(nameNode),
                    syntacticKind: info.kind,
                    qualifierRange: info.qualifier.map(coreRange),
                    receiverRange: info.receiver.map(coreRange),
                    argumentCount: childField(node, "arguments").flatMap {
                        UInt16(exactly: $0.namedChildren.count)
                    }
                ))
            }
        } else if node.kind == "import_statement" {
            enterImport(node, moduleScope: moduleScope)
        } else if node.kind == "import_from_statement" {
            enterFromImport(node, moduleScope: moduleScope)
        }

        walkChildren(
            node,
            directClassMember: directClassMember,
            moduleScope: moduleScope,
            parentClassBody: node.kind == "block"
        )
    }

    func enterLambda(_ node: Node) {
        let scopeID = pushScope(node, kind: .closure, parent: currentScope())
        let regionID = ExecutableRegionID(rawValue: UInt32(regions.count))
        regions.append(ExecutableRegionRecord(
            id: regionID,
            kind: .closure,
            range: coreRange(node),
            enclosingScopeID: scopeID,
            associatedFacetIndex: nil
        ))
        regionStack.append(regionID)
        if let parameters = childField(node, "parameters") {
            bindParameters(parameters, scopeID: scopeID)
        }
        if let body = childField(node, "body") {
            walk(body, directClassMember: false, moduleScope: moduleScope)
        }
        popRegion(regionID)
        popScope(scopeID)
    }

    func bindParameters(_ parameters: Node, scopeID: ScopeID) {
        for child in parameters.namedChildren {
            if let name = parameterName(child) {
                appendBinding(name, scopeID: scopeID, kind: .param)
            }
        }
    }

    func enterImport(_ node: Node, moduleScope: ScopeID) {
        let scopeID = currentScope() ?? moduleScope
        for child in node.namedChildren {
            recordModuleImport(child, scopeID: scopeID)
        }
    }

    func recordModuleImport(_ child: Node, scopeID: ScopeID) {
        if child.kind == "dotted_name" {
            appendImport(
                specifier: text(child, in: bytes) ?? "",
                imported: nil,
                local: dottedPath(text(child, in: bytes) ?? ""),
                kind: .module,
                flags: [],
                scopeID: scopeID,
                range: coreRange(child)
            )
        } else if child.kind == "aliased_import" {
            guard let name = childField(child, "name"),
                  let local = childField(child, "alias").flatMap({ text($0, in: bytes) })
            else { return }
            let specifier = text(name, in: bytes) ?? ""
            appendImport(
                specifier: specifier,
                imported: nil,
                local: local,
                kind: .module,
                flags: [],
                scopeID: scopeID,
                range: coreRange(child)
            )
        }
    }

    func enterFromImport(_ node: Node, moduleScope: ScopeID) {
        guard let module = childField(node, "module_name"),
              let specifier = text(module, in: bytes)
        else { return }
        let scopeID = currentScope() ?? moduleScope
        for child in node.namedChildren {
            if child.byteRange == module.byteRange
                || child.kind == "relative_import"
                || child.kind == "import_prefix"
            {
                continue
            }
            if child.kind == "wildcard_import" {
                appendImport(
                    specifier: specifier,
                    imported: nil,
                    local: nil,
                    kind: .namespace,
                    flags: [.wildcard],
                    scopeID: scopeID,
                    range: coreRange(child)
                )
            } else if child.kind == "aliased_import" {
                guard let name = childField(child, "name"),
                      let imported = text(name, in: bytes)
                else { continue }
                let alias = (childField(child, "alias")).flatMap { text($0, in: bytes) }
                appendImport(
                    specifier: specifier,
                    imported: imported,
                    local: alias ?? imported,
                    kind: .named,
                    flags: [],
                    scopeID: scopeID,
                    range: coreRange(child)
                )
            } else if child.kind == "dotted_name" {
                let imported = text(child, in: bytes) ?? ""
                appendImport(
                    specifier: specifier,
                    imported: imported,
                    local: imported,
                    kind: .named,
                    flags: [],
                    scopeID: scopeID,
                    range: coreRange(child)
                )
            }
        }
    }

    func walkChildren(
        _ node: Node,
        directClassMember: Bool,
        moduleScope: ScopeID,
        parentClassBody: Bool = false
    ) {
        for child in node.namedChildren {
            walk(
                child,
                directClassMember: directClassMember && parentClassBody,
                moduleScope: moduleScope
            )
        }
    }

    let moduleScope = pushScope(root, kind: .module, parent: nil)
    let moduleRegionID = ExecutableRegionID(rawValue: UInt32(regions.count))
    regions.append(ExecutableRegionRecord(
        id: moduleRegionID,
        kind: .moduleInitializer,
        range: coreRange(root),
        enclosingScopeID: moduleScope,
        associatedFacetIndex: nil
    ))
    regionStack.append(moduleRegionID)
    walk(root, directClassMember: false, moduleScope: moduleScope)
    popRegion(moduleRegionID)
    popScope(moduleScope)

    return ContentIndex(
        key: key,
        scopes: scopes,
        bindings: bindings,
        executableRegions: regions,
        symbols: symbols,
        calls: calls,
        imports: imports,
        exports: [],
        lineTable: LineTable(bytes: bytes)
    )
}

private func parameterName(_ node: Node) -> Node? {
    if node.kind == "identifier" { return node }
    if node.kind == "list_splat_pattern" || node.kind == "dictionary_splat_pattern" {
        return node.namedChildren.first
    }
    if let name = childField(node, "name") { return name }
    if let pattern = childField(node, "pattern") { return parameterName(pattern) }
    let child = node.namedChildren.first
    return child.flatMap { parameterName($0) } ?? child
}

private func simpleIdentifier(_ node: Node) -> Node? {
    if node.kind == "identifier" { return node }
    if node.kind == "pattern" {
        return node.namedChildren.first.flatMap(simpleIdentifier)
    }
    return nil
}

private func callInfo(_ node: Node) -> (
    name: Node?,
    kind: CallKind,
    qualifier: Node?,
    receiver: Node?,
    computed: Bool
)? {
    switch node.kind {
    case "identifier":
        return (node, .directCall, nil, nil, false)
    case "attribute":
        return (
            childField(node, "attribute"),
            .methodCall,
            nil,
            childField(node, "object"),
            false
        )
    case "dotted_name":
        guard let last = node.namedChildren.last else {
            return (nil, .methodCall, nil, nil, true)
        }
        let receiver = node.namedChildren.count > 1
            ? node.namedChildren[node.namedChildren.count - 2]
            : nil
        return (last, .methodCall, nil, receiver, false)
    default:
        return nil
    }
}

private func dottedPath(_ value: String) -> String? {
    value.split(separator: ".").first.map(String.init)
}

package func pythonLocalReferences(
    in tree: Tree,
    bytes: [UInt8]
) -> (
    bindings: [BindingRecord],
    referencesByBinding: [[CodeInsightCore.ByteRange]]
) {
    let names = Interner<NameID>()
    var bindings: [BindingRecord] = []
    var referencesByBinding: [[CodeInsightCore.ByteRange]] = []
    var scopeStack: [Int] = []
    var scopeKinds: [ScopeKind] = []
    var scopeParents: [Int?] = []
    var scopeBindings: [[String: Int]] = []

    func enterScope(_ kind: ScopeKind) -> Int {
        let parent: Int?
        switch kind {
        case .function, .closure:
            parent = scopeStack.last(where: { scopeKinds[$0] != .class })
        default:
            parent = scopeStack.last
        }
        let id = scopeKinds.count
        scopeKinds.append(kind)
        scopeParents.append(parent)
        scopeBindings.append([:])
        scopeStack.append(id)
        return id
    }

    func leaveScope(_ id: Int) {
        if scopeStack.last == id {
            scopeStack.removeLast()
        }
    }

    func appendBinding(_ nameNode: Node, kind: BindingKind) {
        guard let scopeID = scopeStack.last,
              let name = text(nameNode, in: bytes)
        else { return }
        let index = bindings.count
        bindings.append(BindingRecord(
            scopeID: ScopeID(rawValue: UInt32(scopeID)),
            localNameID: names.intern(name),
            space: .value,
            kind: kind,
            declarationRange: coreRange(nameNode),
            targetHint: nil
        ))
        referencesByBinding.append([])
        scopeBindings[scopeID][name] = index
    }

    func bindingIndex(_ name: String) -> Int? {
        var id = scopeStack.last
        while let current = id {
            if let index = scopeBindings[current][name] {
                return index
            }
            id = scopeParents[current]
        }
        return nil
    }

    func recordReference(_ node: Node) {
        guard node.kind == "identifier",
              let name = text(node, in: bytes),
              let index = bindingIndex(name)
        else { return }
        referencesByBinding[index].append(coreRange(node))
    }

    func walkParameter(_ node: Node) {
        if let type = childField(node, "type") {
            walk(type)
        }
        if let value = childField(node, "value") {
            walk(value)
        }
        if let nameNode = parameterName(node)
            ?? (node.kind == "identifier" ? node : nil)
        {
            appendBinding(nameNode, kind: .param)
        }
    }

    func walk(_ node: Node) {
        switch node.kind {
        case "decorated_definition":
            if let definition = childField(node, "definition") {
                for child in node.namedChildren where child.byteRange != definition.byteRange {
                    walk(child)
                }
                walk(definition)
            }
            return
        case "function_definition":
            guard let name = childField(node, "name"),
                  let parameters = childField(node, "parameters"),
                  let body = childField(node, "body")
            else { return }
            appendBinding(name, kind: .letBinding)
            let scopeID = enterScope(.function)
            for parameter in parameters.namedChildren {
                walkParameter(parameter)
            }
            for child in node.namedChildren where child.byteRange != name.byteRange
                && child.byteRange != parameters.byteRange
                && child.byteRange != body.byteRange
            {
                walk(child)
            }
            walk(body)
            leaveScope(scopeID)
            return
        case "class_definition":
            guard let name = childField(node, "name"),
                  let body = childField(node, "body")
            else { return }
            appendBinding(name, kind: .letBinding)
            let scopeID = enterScope(.class)
            for child in node.namedChildren where child.byteRange != name.byteRange
                && child.byteRange != body.byteRange
            {
                walk(child)
            }
            walk(body)
            leaveScope(scopeID)
            return
        case "lambda":
            let scopeID = enterScope(.closure)
            if let parameters = childField(node, "parameters") {
                for parameter in parameters.namedChildren {
                    walkParameter(parameter)
                }
            }
            if let body = childField(node, "body") {
                walk(body)
            }
            leaveScope(scopeID)
            return
        case "assignment":
            if let right = childField(node, "right") {
                walk(right)
            }
            if let left = childField(node, "left"),
               let name = simpleIdentifier(left)
            {
                appendBinding(name, kind: .assignment)
            }
            return
        case "import_statement", "import_from_statement",
             "global_statement", "nonlocal_statement",
             "string", "concatenated_string", "comment":
            return
        case "attribute":
            if let object = childField(node, "object") {
                walk(object)
            }
            return
        case "keyword_argument":
            if let value = childField(node, "value") {
                walk(value)
            }
            return
        default:
            recordReference(node)
        }
        for child in node.namedChildren {
            walk(child)
        }
    }

    let moduleScope = enterScope(.module)
    walk(tree.rootNode)
    leaveScope(moduleScope)
    return (bindings, referencesByBinding)
}
