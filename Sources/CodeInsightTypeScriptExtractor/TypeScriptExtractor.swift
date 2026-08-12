import CTreeSitterTypeScript
import CodeInsightCore
import Foundation
import TreeSitterKit

public struct TypeScriptExtractor: LanguageExtractor, Sendable {
    public static let grammarVersion: UInt32 = 1
    public static let extractorVersion: UInt32 = 1

    #if DEBUG
    @TaskLocal
    package static var parseObserver: (@Sendable () -> Void)?
    #endif

    public init() {}

    public var language: LanguageID { .typescript }
    public var grammarVersion: UInt32 { Self.grammarVersion }
    public var extractorVersion: UInt32 { Self.extractorVersion }

    public func extractWithDiagnostics(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner: ExtractionInterners
    ) throws -> (index: ContentIndex, containsErrorNodes: Bool) {
        try requireSupported(key.languageMode)
        try requireSupportedBytes(bytes)
        guard
            let language = grammar(for: key.languageMode),
            let parser = Parser(language: language),
            let tree = observedParse(parser, bytes: bytes)
        else {
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedFailureReasonErrorKey:
                    "TypeScript parser unavailable or parse failed"
            ])
        }
        return (
            buildIndex(
                bytes: bytes,
                key: key,
                root: tree.rootNode,
                names: interner.names,
                strings: interner.strings
            ),
            tree.rootNode.hasError
        )
    }

    public func identifierRanges(
        named name: String,
        in bytes: [UInt8],
        mode: LanguageMode
    ) throws -> [CodeInsightCore.ByteRange] {
        try requireSupported(mode)
        try requireSupportedBytes(bytes)
        guard
            let grammar = grammar(for: mode),
            let parser = Parser(language: grammar),
            let tree = parser.parse(bytes)
        else { return [] }
        let name = Array(name.utf8)
        var hits: [CodeInsightCore.ByteRange] = []
        func visit(_ node: Node) {
            if isIdentifierNode(node.kind),
               (node.byteRange.upperBound - node.byteRange.lowerBound) == UInt32(name.count),
               bytes[Int(node.byteRange.lowerBound)..<Int(node.byteRange.upperBound)]
                .elementsEqual(name)
            {
                hits.append(CodeInsightCore.ByteRange(
                    lowerBound: node.byteRange.lowerBound,
                    upperBound: node.byteRange.upperBound
                ))
            }
            for child in node.namedChildren {
                if ["jsx_opening_element", "jsx_self_closing_element", "jsx_closing_element"].contains(node.kind),
                   let name = childField(node, "name"),
                   child.byteRange == name.byteRange
                {
                    continue
                }
                visit(child)
            }
        }
        visit(tree.rootNode)
        return hits
    }

    #if DEBUG
    private func observedParse(
        _ parser: Parser,
        bytes: [UInt8]
    ) -> Tree? {
        Self.parseObserver?()
        return parser.parse(bytes)
    }
    #else
    private func observedParse(
        _ parser: Parser,
        bytes: [UInt8]
    ) -> Tree? {
        parser.parse(bytes)
    }
    #endif
}

private func grammar(for mode: LanguageMode) -> OpaquePointer? {
    mode.variant == "tsx" ? tree_sitter_tsx() : tree_sitter_typescript()
}

private func requireSupported(_ mode: LanguageMode) throws {
    guard mode.language == .typescript else {
        throw CocoaError(.featureUnsupported, userInfo: [
            NSLocalizedFailureReasonErrorKey:
                "TypeScriptExtractor only supports TypeScript; got \(String(describing: mode.language))"
        ])
    }
    guard mode.variant == nil || mode.variant == "tsx" else {
        throw CocoaError(.featureUnsupported, userInfo: [
            NSLocalizedFailureReasonErrorKey:
                "TypeScriptExtractor does not support variant '\(mode.variant ?? "")'"
        ])
    }
}

private func requireSupportedBytes(_ bytes: [UInt8]) throws {
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
        throw CocoaError(.fileReadCorruptFile, userInfo: [
            NSLocalizedFailureReasonErrorKey:
                "TypeScriptExtractor rejects UTF-8 BOM before parsing"
        ])
    }
    guard String(bytes: bytes, encoding: .utf8) != nil else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [
            NSLocalizedFailureReasonErrorKey:
                "TypeScriptExtractor rejected invalid UTF-8 before parsing"
        ])
    }
}

private func childField(_ node: Node, _ name: String) -> Node? {
    node.child(namedField: name)
}

private func directChildren(_ node: Node) -> [Node] {
    (0..<node.childCount).compactMap { node.child(at: $0) }
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
          range.upperBound <= UInt32(bytes.count)
    else { return nil }
    return ContentID.sha256(
        of: Array(bytes[Int(range.lowerBound)..<Int(range.upperBound)])
    )
}

private func isIdentifierNode(_ kind: String) -> Bool {
    kind == "identifier"
}

private func unquote(_ node: Node, in bytes: [UInt8]) -> String? {
    guard let raw = text(node, in: bytes) else { return nil }
    if raw.count >= 2,
       (raw.hasPrefix("\"") && raw.hasSuffix("\""))
        || (raw.hasPrefix("'") && raw.hasSuffix("'"))
    {
        return String(raw.dropFirst().dropLast())
    }
    return raw
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
    var exports: [ExportRecord] = []
    var facetStack: [UInt32] = []

    func pushScope(_ node: Node, kind: ScopeKind, parent: ScopeID?) -> ScopeID {
        let id = ScopeID(rawValue: UInt32(scopes.count))
        scopes.append(ScopeRecord(
            id: id,
            parent: parent,
            kind: kind,
            range: coreRange(node)
        ))
        scopeStack.append(id)
        return id
    }

    func popScope() {
        _ = scopeStack.popLast()
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

    func popRegion() {
        _ = regionStack.popLast()
    }

    func currentRegion() -> ExecutableRegionID? {
        regionStack.last
    }

    func appendBinding(_ nameNode: Node, scopeID: ScopeID, kind: BindingKind) {
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

    func declarationRange(_ node: Node, body: Node) -> CodeInsightCore.ByteRange {
        CodeInsightCore.ByteRange(
            lowerBound: node.byteRange.lowerBound,
            upperBound: body.byteRange.lowerBound
        )
    }

    func addParameterBindings(_ parameters: Node, scopeID: ScopeID) {
        if parameters.kind == "identifier" {
            appendBinding(parameters, scopeID: scopeID, kind: .param)
            return
        }
        for child in parameters.namedChildren {
            if let name = childField(child, "name"), name.kind == "identifier" {
                appendBinding(name, scopeID: scopeID, kind: .param)
            } else if let pattern = childField(child, "pattern"), pattern.kind == "identifier" {
                appendBinding(pattern, scopeID: scopeID, kind: .param)
            }
        }
    }

    func enterClosure(_ node: Node) -> Bool {
        guard let body = childField(node, "body") else { return false }
        let scopeID = pushScope(node, kind: .closure, parent: currentScope())
        let regionID = ExecutableRegionID(rawValue: UInt32(regions.count))
        regions.append(ExecutableRegionRecord(
            id: regionID,
            kind: .closure,
            range: coreRange(node),
            enclosingScopeID: scopeID,
            associatedFacetIndex: facetStack.last
        ))
        regionStack.append(regionID)
        if let parameters = childField(node, "parameters") ?? childField(node, "parameter") {
            addParameterBindings(parameters, scopeID: scopeID)
        }
        walkDirectBody(body)
        popRegion()
        popScope()
        return true
    }

    func enterBlock(_ node: Node) {
        guard let kind = blockScopeKind(node), let parent = currentScope() else { return }
        _ = pushScope(node, kind: kind, parent: parent)
        defer { popScope() }
        for child in node.namedChildren {
            walk(child)
        }
    }

    func enterBodyNode(_ node: Node, body: Node, closing: () -> Void) {
        walkDirectBody(body)
        for child in node.namedChildren where child.byteRange != body.byteRange {
            walk(child)
        }
        closing()
    }

    func walkDirectBody(_ body: Node) {
        if body.kind == "statement_block" {
            for child in body.namedChildren {
                walk(child)
            }
        } else {
            walk(body)
        }
    }

    func blockScopeKind(_ node: Node) -> ScopeKind? {
        if node.kind == "statement_block" { return .block }
        if ["internal_module", "module"].contains(node.kind) { return .module }
        return nil
    }

    func enterFunctionBody(_ node: Node, isMethod: Bool = false) -> Bool? {
        guard let name = childField(node, "name"),
              let nameString = text(name, in: bytes),
              let body = childField(node, "body")
        else { return nil }
        let emitted = shouldEmitFacetForFunction(isMethod: isMethod)
        if emitted {
            let index = UInt32(symbols.count)
            symbols.append(DeclarationFacet(
                symbolGroupID: SymbolGroupID(rawValue: index),
                space: .value,
                kind: .typescriptFunction,
                nameID: names.intern(nameString),
                range: coreRange(node),
                nameRange: coreRange(name),
                parentFacetIndex: facetStack.last,
                signatureFingerprint: fingerprint(declarationRange(node, body: body), bytes: bytes),
                bodyFingerprint: fingerprint(coreRange(body), bytes: bytes)
            ))
            facetStack.append(index)
        }
        let scopeID = pushScope(body, kind: .function, parent: currentScope())
        pushRegion(
            body,
            kind: isMethod ? .method : .function,
            scopeID: scopeID,
            facetIndex: emitted ? UInt32(symbols.count - 1) : nil
        )
        if let parameters = childField(node, "parameters") ?? childField(node, "parameter") {
            addParameterBindings(parameters, scopeID: scopeID)
        }
        return emitted
    }

    func exitFunctionBody() {
        popRegion()
        popScope()
    }

    func exitFunctionBody(afterEmit shouldPop: Bool) {
        if shouldPop {
            facetStack.removeLast()
        }
        exitFunctionBody()
    }

    func enterClassBody(_ node: Node) -> Bool? {
        guard let name = childField(node, "name"),
              let nameString = text(name, in: bytes),
              let body = childField(node, "body")
        else { return nil }
        let emitted = shouldEmitTopLevelFacet()
        if emitted {
            let index = UInt32(symbols.count)
            symbols.append(DeclarationFacet(
                symbolGroupID: SymbolGroupID(rawValue: index),
                space: .value,
                kind: .typescriptClass,
                nameID: names.intern(nameString),
                range: coreRange(node),
                nameRange: coreRange(name),
                parentFacetIndex: facetStack.last,
                signatureFingerprint: fingerprint(declarationRange(node, body: body), bytes: bytes),
                bodyFingerprint: fingerprint(coreRange(body), bytes: bytes)
            ))
            facetStack.append(index)
        }
        let scopeID = pushScope(body, kind: .class, parent: currentScope())
        pushRegion(
            body,
            kind: .classBody,
            scopeID: scopeID,
            facetIndex: emitted ? UInt32(symbols.count - 1) : nil
        )
        return emitted
    }

    func exitClassBody() {
        popRegion()
        popScope()
    }

    func exitClassBody(afterEmit shouldPop: Bool) {
        if shouldPop {
            facetStack.removeLast()
        }
        exitClassBody()
    }

    func shouldEmitTopLevelFacet() -> Bool {
        return currentScope() == moduleScopeID
    }

    func shouldEmitFacetForFunction(isMethod: Bool) -> Bool {
        if isMethod {
            guard let id = regionStack.last,
                  let region = regions.first(where: { $0.id == id })
            else { return false }
            return region.kind == .classBody
                && region.associatedFacetIndex != nil
        }
        return currentScope() == moduleScopeID
    }

    func enterVariableDeclaration(_ node: Node) {
        for child in node.namedChildren where child.kind == "variable_declarator" {
            guard let nameNode = childField(child, "name"),
                  nameNode.kind == "identifier",
                  let name = text(nameNode, in: bytes)
            else { continue }
            let scopeID = currentScope() ?? moduleScopeID
            appendBinding(nameNode, scopeID: scopeID, kind: .letBinding)
            if let value = childField(child, "value"),
               value.kind == "arrow_function" || value.kind == "function_expression"
            {
                if currentScope() != nil && currentScope() == moduleScopeID {
                    let facetIndex = UInt32(symbols.count)
                    let body = childField(value, "body")
                    let bodyFingerprint: ContentID?
                    if let body {
                        bodyFingerprint = fingerprint(coreRange(body), bytes: bytes)
                    } else {
                        bodyFingerprint = nil
                    }
                    let signatureRange = body.map {
                        declarationRange(value, body: $0)
                    } ?? coreRange(value)
                    symbols.append(DeclarationFacet(
                        symbolGroupID: SymbolGroupID(rawValue: facetIndex),
                        space: .value,
                        kind: .typescriptFunction,
                        nameID: names.intern(name),
                        range: coreRange(value),
                        nameRange: coreRange(nameNode),
                        parentFacetIndex: facetStack.last,
                        signatureFingerprint: fingerprint(signatureRange, bytes: bytes),
                        bodyFingerprint: bodyFingerprint
                    ))
                    facetStack.append(facetIndex)
                    walk(value)
                    _ = facetStack.popLast()
                } else {
                    walk(value)
                }
            } else if let value = childField(child, "value") {
                walk(value)
            }
        }
    }

    func recordCall(_ node: Node) {
        guard let regionID = currentRegion(),
              let function = childField(node, "function")
        else { return }
        let info = callInfo(function)
        guard !info.computed,
              let nameNode = info.name,
              let callName = text(nameNode, in: bytes)
        else { return }
        calls.append(UnresolvedCall(
            regionID: regionID,
            nameID: names.intern(callName),
            range: coreRange(node),
            nameRange: coreRange(nameNode),
            syntacticKind: info.kind,
            qualifierRange: info.qualifier.map { coreRange($0) },
            receiverRange: info.receiver.map { coreRange($0) },
            argumentCount: childField(node, "arguments").flatMap {
                UInt16(exactly: $0.namedChildren.count)
            }
        ))
    }

    func recordNew(_ node: Node) {
        guard let regionID = currentRegion(),
              let constructor = childField(node, "constructor"),
              let nameNode = directIdentifier(constructor),
              let callName = text(nameNode, in: bytes)
        else { return }
        calls.append(UnresolvedCall(
            regionID: regionID,
            nameID: names.intern(callName),
            range: coreRange(node),
            nameRange: coreRange(nameNode),
            syntacticKind: .directCall,
            qualifierRange: nil,
            receiverRange: nil,
            argumentCount: childField(node, "arguments").flatMap {
                UInt16(exactly: $0.namedChildren.count)
            }
        ))
    }

    func callInfo(_ node: Node) -> (
        name: Node?,
        kind: CallKind,
        qualifier: Node?,
        receiver: Node?,
        computed: Bool
    ) {
        switch node.kind {
        case "identifier":
            return (node, .directCall, nil, nil, false)
        case "member_expression":
            guard let property = childField(node, "property"),
                  property.kind != "computed_property_name"
            else { return (nil, .methodCall, nil, nil, true) }
            return (
                property,
                .methodCall,
                childField(node, "object"),
                childField(node, "object"),
                false
            )
        default:
            return (nil, .directCall, nil, nil, true)
        }
    }

    func directIdentifier(_ node: Node) -> Node? {
        if node.kind == "identifier" { return node }
        return nil
    }

    func addImport(
        _ importNode: Node,
        moduleScope: ScopeID
    ) {
        guard let source = childField(importNode, "source"),
              let specifier = unquote(source, in: bytes)
        else { return }
        let scopeID = currentScope() ?? moduleScope
        guard let clause = importClause(importNode) else {
            imports.append(ImportBinding(
                moduleSpecifier: strings.intern(specifier),
                importedName: nil,
                localName: nil,
                kind: .sideEffect,
                flags: directChildren(importNode).contains {
                    text($0, in: bytes) == "type"
                } ? [.typeOnly] : [],
                scopeID: scopeID,
                range: coreRange(importNode)
            ))
            return
        }

        let isTypeOnly = directChildren(importNode).contains {
            text($0, in: bytes) == "type"
        }
        for child in clause.namedChildren {
            if child.kind == "namespace_import" {
                if let alias = child.namedChildren.first,
                   let local = text(alias, in: bytes)
                {
                    imports.append(ImportBinding(
                        moduleSpecifier: strings.intern(specifier),
                        importedName: nil,
                        localName: names.intern(local),
                        kind: .namespace,
                        flags: isTypeOnly ? [.typeOnly, .wildcard] : [.wildcard],
                        scopeID: scopeID,
                        range: coreRange(child)
                    ))
                    appendBinding(alias, scopeID: scopeID, kind: .importBinding)
                }
            } else if child.kind == "named_imports" {
                for specifierNode in child.namedChildren
                    where specifierNode.kind == "import_specifier"
                {
                    guard let name = childField(specifierNode, "name"),
                          let imported = text(name, in: bytes)
                    else { continue }
                    let localNode = childField(specifierNode, "alias") ?? name
                    guard let local = text(localNode, in: bytes) else { continue }
                    var flags: ImportFlags = isTypeOnly ? [.typeOnly] : []
                    if directChildren(specifierNode).contains(where: { text($0, in: bytes) == "type" }) {
                        flags.insert(.typeOnly)
                    }
                    imports.append(ImportBinding(
                        moduleSpecifier: strings.intern(specifier),
                        importedName: names.intern(imported),
                        localName: names.intern(local),
                        kind: .named,
                        flags: flags,
                        scopeID: scopeID,
                        range: coreRange(specifierNode)
                    ))
                    appendBinding(localNode, scopeID: scopeID, kind: .importBinding)
                }
            } else if child.kind == "identifier" {
                guard let local = text(child, in: bytes) else { continue }
                imports.append(ImportBinding(
                    moduleSpecifier: strings.intern(specifier),
                    importedName: nil,
                    localName: names.intern(local),
                    kind: .default,
                    flags: isTypeOnly ? [.typeOnly] : [],
                    scopeID: scopeID,
                    range: coreRange(child)
                ))
                appendBinding(child, scopeID: scopeID, kind: .importBinding)
            }
        }
    }

    func importClause(_ node: Node) -> Node? {
        node.namedChildren.first(where: { $0.kind == "import_clause" })
    }

    func appendExport(_ name: String, sourceBinding: UInt32?, range: CodeInsightCore.ByteRange) {
        exports.append(ExportRecord(
            exportedName: names.intern(name),
            sourceBindingIndex: sourceBinding,
            range: range
        ))
    }

    func appendNamedExport(_ name: String, range: CodeInsightCore.ByteRange) {
        exports.append(ExportRecord(
            exportedName: names.intern(name),
            sourceBindingIndex: nil,
            range: range
        ))
    }

    func walkExport(_ node: Node) {
        if let declaration = childField(node, "declaration") {
            walk(declaration)
            if declaration.kind == "lexical_declaration"
                || declaration.kind == "variable_declaration"
            {
                for child in declaration.namedChildren
                    where child.kind == "variable_declarator"
                {
                    if let nameNode = childField(child, "name"),
                       let name = text(nameNode, in: bytes)
                    {
                        appendNamedExport(name, range: coreRange(child))
                    }
                }
            } else if let name = declarationFacetName(declaration) {
                appendNamedExport(name, range: coreRange(declaration))
            }
            return
        }
        if let source = childField(node, "source"),
           let specifier = unquote(source, in: bytes)
        {
            let scopeID = currentScope() ?? moduleScopeID
            let statementTypeOnly = directChildren(node).contains(where: { text($0, in: bytes) == "type" })
            if let clause = node.namedChildren.first(where: { $0.kind == "export_clause" }) {
                for child in clause.namedChildren where child.kind == "export_specifier" {
                    guard let nameNode = childField(child, "name"),
                          let name = text(nameNode, in: bytes)
                    else { continue }
                    let exported = text(childField(child, "alias") ?? nameNode, in: bytes) ?? name
                    var flags: ImportFlags = [.reexport]
                    if statementTypeOnly || directChildren(child).contains(where: { text($0, in: bytes) == "type" }) {
                        flags.insert(.typeOnly)
                    }
                    imports.append(ImportBinding(
                        moduleSpecifier: strings.intern(specifier),
                        importedName: names.intern(name),
                        localName: names.intern(exported),
                        kind: .named,
                        flags: flags,
                        scopeID: scopeID,
                        range: coreRange(child)
                    ))
                    appendExport(exported, sourceBinding: UInt32(imports.count - 1), range: coreRange(child))
                }
            } else {
                imports.append(ImportBinding(
                    moduleSpecifier: strings.intern(specifier),
                    importedName: nil,
                    localName: nil,
                    kind: .namespace,
                    flags: [.reexport, .wildcard],
                    scopeID: scopeID,
                    range: coreRange(node)
                ))
            }
            return
        }
        if let clause = node.namedChildren.first(where: { $0.kind == "export_clause" }) {
            for child in clause.namedChildren where child.kind == "export_specifier" {
                guard let nameNode = childField(child, "name"),
                      let name = text(nameNode, in: bytes)
                else { continue }
                let exported = text(childField(child, "alias") ?? nameNode, in: bytes) ?? name
                appendNamedExport(name, range: coreRange(child))
                if exported != name {
                    exports[exports.count - 1] = ExportRecord(
                        exportedName: names.intern(exported),
                        sourceBindingIndex: exports[exports.count - 1].sourceBindingIndex,
                        range: exports[exports.count - 1].range
                    )
                }
            }
        }
    }

    func walk(_ node: Node) {
        if bytes.isEmpty || node.byteRange.upperBound == node.byteRange.lowerBound {
            return
        }
        switch node.kind {
        case "function_declaration", "generator_function_declaration":
            if let emittedFunction = enterFunctionBody(node) {
                enterBodyNode(node, body: childField(node, "body")!) {
                    exitFunctionBody(afterEmit: emittedFunction)
                }
            } else if let body = childField(node, "body") {
                walk(body)
            }
            return
        case "class_declaration":
            if let emittedClass = enterClassBody(node) {
                enterBodyNode(node, body: childField(node, "body")!) {
                    exitClassBody(afterEmit: emittedClass)
                }
            } else if let body = childField(node, "body") {
                walk(body)
            }
            return
        case "method_definition":
            if let emittedMethod = enterFunctionBody(node, isMethod: true) {
                enterBodyNode(node, body: childField(node, "body")!) {
                    exitFunctionBody(afterEmit: emittedMethod)
                }
            } else if let body = childField(node, "body") {
                walk(body)
            }
            return
        case "lexical_declaration", "variable_declaration":
            enterVariableDeclaration(node)
            return
        case "call_expression":
            recordCall(node)
        case "new_expression":
            recordNew(node)
        case "import_statement":
            addImport(node, moduleScope: moduleScopeID)
            return
        case "export_statement":
            walkExport(node)
            return
        case "arrow_function", "function_expression":
            if enterClosure(node) {
                return
            }
        case "statement_block", "internal_module", "module":
            enterBlock(node)
            return
        default:
            break
        }
        for child in node.namedChildren {
            walk(child)
        }
    }

    func declarationFacetName(_ node: Node) -> String? {
        if let name = childField(node, "name") {
            return text(name, in: bytes)
        }
        if let declarator = node.namedChildren.first(where: { $0.kind == "variable_declarator" }),
           let name = childField(declarator, "name")
        {
            return text(name, in: bytes)
        }
        return nil
    }

    let moduleScopeID = pushScope(root, kind: .module, parent: nil)
    let moduleRegionID = ExecutableRegionID(rawValue: UInt32(regions.count))
    regions.append(ExecutableRegionRecord(
        id: moduleRegionID,
        kind: .moduleInitializer,
        range: coreRange(root),
        enclosingScopeID: moduleScopeID,
        associatedFacetIndex: nil
    ))
    regionStack.append(moduleRegionID)
    walk(root)
    popRegion()
    popScope()

    return ContentIndex(
        key: key,
        scopes: scopes,
        bindings: bindings,
        executableRegions: regions,
        symbols: symbols,
        calls: calls,
        imports: imports,
        exports: exports,
        lineTable: LineTable(bytes: bytes)
    )
}
