import CTreeSitterGo
import CodeInsightCore
import Foundation
import TreeSitterKit

public struct GoExtractor: LanguageExtractor, Sendable {
    public static let grammarVersion: UInt32 = 1
    public static let extractorVersion: UInt32 = 1

    public init() {}

    public var language: LanguageID { .go }
    public var grammarVersion: UInt32 { Self.grammarVersion }
    public var extractorVersion: UInt32 { Self.extractorVersion }

    public func extractWithDiagnostics(
        bytes: [UInt8],
        key: ContentIndexKey,
        interner: ExtractionInterners
    ) throws -> (index: ContentIndex, containsErrorNodes: Bool) {
        try requireSupported(key.languageMode)
        guard let tree = parse(bytes) else {
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedFailureReasonErrorKey: "Go parser unavailable or parse failed",
            ])
        }
        let index = GoIndexBuilder(
            bytes: bytes,
            names: interner.names,
            strings: interner.strings
        ).build(key: key, root: tree.rootNode)
        return (index, tree.rootNode.hasError)
    }

    /// Every `identifier`, `type_identifier`, `field_identifier` and
    /// `package_identifier` spelled `name`. Explicit stack: project search
    /// runs this on a cooperative thread.
    public func identifierRanges(
        named name: String,
        in bytes: [UInt8],
        mode: LanguageMode
    ) throws -> [CodeInsightCore.ByteRange] {
        try requireSupported(mode)
        guard let tree = parse(bytes) else { return [] }
        let name = Array(name.utf8)
        var hits: [CodeInsightCore.ByteRange] = []
        var pending = [tree.rootNode]
        while let node = pending.popLast() {
            let range = node.byteRange
            if Self.identifierKinds.contains(node.kind),
               range.upperBound - range.lowerBound == UInt32(name.count),
               bytes[Int(range.lowerBound)..<Int(range.upperBound)].elementsEqual(name)
            {
                hits.append(coreRange(node))
            }
            pending.append(contentsOf: node.namedChildren.reversed())
        }
        return hits
    }

    /// The grammar handle, so a link failure shows up in the first test.
    public static var grammarIsAvailable: Bool { tree_sitter_go() != nil }

    private static let identifierKinds: Set<String> = [
        "identifier", "type_identifier", "field_identifier", "package_identifier",
    ]

    private func parse(_ bytes: [UInt8]) -> Tree? {
        guard let grammar = tree_sitter_go(), let parser = Parser(language: grammar) else { return nil }
        return parser.parse(bytes)
    }

    private func requireSupported(_ mode: LanguageMode) throws {
        guard mode.language == .go, mode.variant == nil else {
            throw CocoaError(.featureUnsupported, userInfo: [
                NSLocalizedFailureReasonErrorKey:
                    "GoExtractor only supports Go; got \(mode.language) \(mode.variant ?? "")",
            ])
        }
    }
}

/// The package name `go` assumes for an import path when the import has no
/// alias (goimports' rule): the last element, the one before it when the
/// last is a major version (`v2`), without a `go-` prefix, up to the first
/// character that cannot be in an identifier (`yaml.v3` → `yaml`).
public func goAssumedPackageName(importPath: String) -> String {
    var elements = importPath.split(separator: "/").map(String.init)
    var base = elements.popLast() ?? importPath
    if base.hasPrefix("v"), Int(base.dropFirst()) != nil, let previous = elements.last {
        base = previous
    }
    if base.hasPrefix("go-") { base.removeFirst(3) }
    if let end = base.firstIndex(where: { !($0.isLetter || $0.isNumber || $0 == "_") }) {
        base = String(base[..<end])
    }
    return base
}

/// Predeclared types; they never hop.
let goPrimitiveNames: Set<String> = [
    "bool", "byte", "complex64", "complex128", "error", "float32", "float64",
    "int", "int8", "int16", "int32", "int64", "rune", "string",
    "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any", "comparable",
]

private func coreRange(_ node: Node) -> CodeInsightCore.ByteRange {
    CodeInsightCore.ByteRange(lowerBound: node.byteRange.lowerBound, upperBound: node.byteRange.upperBound)
}

private final class GoIndexBuilder {
    enum Work {
        case visit(Node)
        case popScope
        case popRegion
        case popFacet
        case run(() -> Void)
    }

    let bytes: [UInt8]
    let names: Interner<NameID>
    let strings: Interner<StringID>

    var scopes: [ScopeRecord] = []
    var scopeStack: [ScopeID] = []
    var bindings: [BindingRecord] = []
    var regions: [ExecutableRegionRecord] = []
    var regionStack: [ExecutableRegionID] = []
    var symbols: [DeclarationFacet] = []
    var implRelations: [ImplRelation] = []
    var supertypes: [SupertypeRelation] = []
    var calls: [UnresolvedCall] = []
    var imports: [ImportBinding] = []
    /// The facet whose body a closure belongs to.
    var facetStack: [UInt32] = []
    /// Names an unaliased or aliased import binds; `name.F()` is qualified.
    var importNames: Set<String> = []
    /// Type parameter names in force, innermost last.
    var typeParameterStack: [Set<String>] = []
    var work: [Work] = []

    init(bytes: [UInt8], names: Interner<NameID>, strings: Interner<StringID>) {
        self.bytes = bytes
        self.names = names
        self.strings = strings
    }

    func build(key: ContentIndexKey, root: Node) -> ContentIndex {
        let moduleScope = pushScope(root, kind: .module, parent: nil)
        pushRegion(root, kind: .moduleInitializer, scope: moduleScope, facet: nil)
        for child in root.namedChildren {
            topLevel(child)
        }
        drain()
        return ContentIndex(
            key: key,
            scopes: scopes,
            bindings: bindings,
            executableRegions: regions,
            symbols: symbols,
            implRelations: implRelations,
            supertypes: supertypes,
            calls: calls,
            imports: imports,
            exports: [],
            lineTable: LineTable(bytes: bytes),
            regions: contentRegions(in: root, language: .go)
        )
    }

    // MARK: Text

    func text(_ node: Node) -> String? {
        let lower = Int(node.byteRange.lowerBound)
        let upper = Int(node.byteRange.upperBound)
        guard lower <= upper, upper <= bytes.count else { return nil }
        return String(bytes: bytes[lower..<upper], encoding: .utf8)
    }

    func fingerprint(_ lower: UInt32, _ upper: UInt32) -> ContentID? {
        guard lower <= upper, upper <= bytes.count else { return nil }
        return ContentID.sha256(of: Array(bytes[Int(lower)..<Int(upper)]))
    }

    func visibility(_ name: String) -> DeclarationVisibility {
        name.first.map { $0.isUppercase } == true ? .public : .private
    }

    // MARK: Scopes and regions

    @discardableResult
    func pushScope(_ node: Node, kind: ScopeKind, parent: ScopeID?) -> ScopeID {
        let id = ScopeID(rawValue: UInt32(scopes.count))
        scopes.append(ScopeRecord(id: id, parent: parent, kind: kind, range: coreRange(node)))
        scopeStack.append(id)
        return id
    }

    func pushRegion(_ node: Node, kind: ExecutableRegionKind, scope: ScopeID, facet: UInt32?) {
        let id = ExecutableRegionID(rawValue: UInt32(regions.count))
        regions.append(ExecutableRegionRecord(
            id: id, kind: kind, range: coreRange(node), enclosingScopeID: scope, associatedFacetIndex: facet
        ))
        regionStack.append(id)
    }

    /// Runs queued work until the stack is empty. Nothing recurses through
    /// the tree, so deeply nested expressions cannot overflow the stack.
    func drain() {
        while let item = work.popLast() {
            switch item {
            case let .visit(node): visit(node)
            case .popScope: _ = scopeStack.popLast()
            case .popRegion: _ = regionStack.popLast()
            case .popFacet:
                _ = facetStack.popLast()
                _ = typeParameterStack.popLast()
            case let .run(action): action()
            }
        }
    }

    /// Queues `nodes` to be visited in order, then the closing work.
    func schedule(_ nodes: [Node], then closing: [Work] = []) {
        work.append(contentsOf: closing.reversed())
        work.append(contentsOf: nodes.reversed().map(Work.visit))
    }

    // MARK: Declarations

    func appendFacet(
        kind: DeclarationKind,
        space: SymbolSpace,
        name: Node,
        range: Node,
        body: Node?,
        parent: UInt32?,
        typeRef: TypeRef? = nil
    ) -> UInt32? {
        guard let nameString = text(name), nameString != "_" else { return nil }
        let index = UInt32(symbols.count)
        let signatureEnd = body?.byteRange.lowerBound ?? range.byteRange.upperBound
        symbols.append(DeclarationFacet(
            symbolGroupID: SymbolGroupID(rawValue: index),
            space: space,
            kind: kind,
            nameID: names.intern(nameString),
            range: coreRange(range),
            nameRange: coreRange(name),
            parentFacetIndex: parent,
            signatureFingerprint: fingerprint(range.byteRange.lowerBound, signatureEnd),
            bodyFingerprint: body.flatMap { fingerprint($0.byteRange.lowerBound, $0.byteRange.upperBound) },
            typeRef: typeRef,
            visibility: visibility(nameString)
        ))
        return index
    }

    func topLevel(_ node: Node) {
        switch node.kind {
        case "import_declaration":
            for child in node.namedChildren {
                if child.kind == "import_spec" {
                    recordImport(child)
                } else if child.kind == "import_spec_list" {
                    child.namedChildren.filter { $0.kind == "import_spec" }.forEach(recordImport)
                }
            }
        case "function_declaration", "method_declaration":
            enterFunction(node)
            drain()
        case "type_declaration":
            let specs = node.namedChildren.filter { $0.kind == "type_spec" || $0.kind == "type_alias" }
            for spec in specs {
                recordType(spec, range: specs.count == 1 ? node : spec)
            }
        case "var_declaration", "const_declaration":
            let specs = node.namedChildren.flatMap { child -> [Node] in
                child.kind == "var_spec_list" ? child.namedChildren.filter { $0.kind == "var_spec" } : [child]
            }.filter { $0.kind == "var_spec" || $0.kind == "const_spec" }
            for spec in specs {
                recordPackageValue(spec, range: specs.count == 1 ? node : spec, isConst: node.kind == "const_declaration")
            }
        case "package_clause", "comment":
            break
        default:
            // An ERROR node or a stray statement: its calls still count.
            schedule([node])
            drain()
        }
    }

    func recordImport(_ spec: Node) {
        guard let pathNode = spec.child(namedField: "path"), let raw = text(pathNode), raw.count >= 2 else { return }
        let path = String(raw.dropFirst().dropLast())
        let alias = spec.child(namedField: "name")
        let moduleScope = ScopeID(rawValue: 0)
        let kind: ImportKind
        var flags: ImportFlags = []
        var local: String?
        switch alias?.kind {
        case "dot":
            kind = .module
            flags = [.wildcard]
        case "blank_identifier":
            kind = .sideEffect
        default:
            kind = .module
            local = alias.flatMap(text) ?? goAssumedPackageName(importPath: path)
        }
        imports.append(ImportBinding(
            moduleSpecifier: strings.intern(path),
            importedName: nil,
            localName: local.map(names.intern),
            kind: kind,
            flags: flags,
            scopeID: moduleScope,
            range: coreRange(spec)
        ))
        if let local, !local.isEmpty {
            importNames.insert(local)
            bindings.append(BindingRecord(
                scopeID: moduleScope,
                localNameID: names.intern(local),
                space: .namespace,
                kind: .importBinding,
                declarationRange: coreRange(alias ?? pathNode),
                targetHint: nil
            ))
        }
    }

    func recordType(_ spec: Node, range: Node) {
        guard let name = spec.child(namedField: "name"), let type = spec.child(namedField: "type") else { return }
        let kind: DeclarationKind = switch (spec.kind, type.kind) {
        case ("type_spec", "struct_type"): .goStruct
        case ("type_spec", "interface_type"): .goInterface
        default: .goType
        }
        let body: Node? = kind == .goType ? nil : type
        guard let facet = appendFacet(kind: kind, space: .type, name: name, range: range, body: body, parent: nil)
        else { return }
        let typeParameters = typeParameterNames(spec.child(namedField: "type_parameters"))
        typeParameterStack.append(typeParameters)
        defer { typeParameterStack.removeLast() }
        if kind == .goStruct {
            let fields = type.namedChildren.first { $0.kind == "field_declaration_list" }?.namedChildren ?? []
            for field in fields where field.kind == "field_declaration" {
                recordField(field, parent: facet)
            }
        } else if kind == .goInterface {
            for element in type.namedChildren {
                if element.kind == "method_elem", let methodName = element.child(namedField: "name") {
                    _ = appendFacet(
                        kind: .goMethod, space: .value, name: methodName, range: element, body: nil, parent: facet
                    )
                } else if element.kind == "type_elem",
                          element.namedChildren.count == 1,
                          let head = typeHead(element.namedChildren[0])
                {
                    appendSupertype(head, facet: facet)
                }
            }
        }
    }

    func recordField(_ field: Node, parent: UInt32) {
        guard let type = field.child(namedField: "type") else { return }
        let head = typeHead(type)
        let names = namedChildren(of: field, field: "name")
        if names.isEmpty {
            // An embedded field is named after its type.
            guard let head else { return }
            _ = appendFacet(
                kind: .goField, space: .value, name: head, range: field, body: nil, parent: parent,
                typeRef: typeRef(head)
            )
            appendSupertype(head, facet: parent)
            return
        }
        for name in names {
            _ = appendFacet(
                kind: .goField, space: .value, name: name, range: field, body: nil, parent: parent,
                typeRef: head.map(typeRef)
            )
        }
    }

    func appendSupertype(_ head: Node, facet: UInt32) {
        guard let name = text(head) else { return }
        supertypes.append(SupertypeRelation(facetIndex: facet, nameID: names.intern(name), nameRange: coreRange(head)))
    }

    func recordPackageValue(_ spec: Node, range: Node, isConst: Bool) {
        let declared = namedChildren(of: spec, field: "name").filter { $0.kind == "identifier" }
        var facets: [UInt32] = []
        for name in declared {
            if let facet = appendFacet(
                kind: isConst ? .goConst : .goVar, space: .value, name: name, range: range, body: nil, parent: nil
            ) {
                facets.append(facet)
            }
        }
        guard let value = spec.child(namedField: "value") else { return }
        // A closure assigned to a single package variable belongs to it.
        if facets.count == 1 {
            facetStack.append(facets[0])
            typeParameterStack.append([])
            schedule([value], then: [.popFacet])
        } else {
            schedule([value])
        }
        drain()
    }

    // MARK: Functions

    func enterFunction(_ node: Node) {
        let isMethod = node.kind == "method_declaration"
        guard let name = node.child(namedField: "name") else { return }
        let body = node.child(namedField: "body")
        guard let facet = appendFacet(
            kind: isMethod ? .goMethod : .goFunction, space: .value, name: name, range: node, body: body, parent: nil
        ) else {
            if let body { schedule([body]) }
            return
        }
        var typeParameters = typeParameterNames(node.child(namedField: "type_parameters"))
        var receiverHead: Node?
        let receiver = node.child(namedField: "receiver")?.namedChildren
            .first { $0.kind == "parameter_declaration" }
        if isMethod, let receiverType = receiver?.child(namedField: "type") {
            // `(s *Stack[T])`: the receiver's type arguments are parameters here.
            var base = receiverType
            if base.kind == "pointer_type", let inner = base.namedChildren.first { base = inner }
            if base.kind == "generic_type" {
                for argument in base.child(namedField: "type_arguments")?.namedChildren ?? [] {
                    if let head = typeHead(argument), let name = text(head) { typeParameters.insert(name) }
                }
            }
            receiverHead = typeHead(receiverType)
            if let receiverHead, let typeName = text(receiverHead) {
                implRelations.append(ImplRelation(
                    implFacetIndex: facet, traitNameID: nil, traitNameRange: nil, typeNameID: names.intern(typeName)
                ))
            }
        }
        facetStack.append(facet)
        typeParameterStack.append(typeParameters)
        guard let body else {
            work.append(.popFacet)
            return
        }
        let scope = pushScope(body, kind: .function, parent: scopeStack.first)
        pushRegion(body, kind: isMethod ? .method : .function, scope: scope, facet: facet)
        if let receiver, let receiverName = receiver.child(namedField: "name"), let receiverHead,
           let typeName = text(receiverHead)
        {
            appendBinding(
                receiverName, scope: scope, kind: .param,
                typeRef: .selfType(coreRange(receiverHead)),
                hint: UnresolvedSymbolRef(nameID: names.intern(typeName), hintKind: .unqualified)
            )
        }
        bindParameters(node.child(namedField: "parameters"), scope: scope)
        bindParameters(node.child(namedField: "result"), scope: scope)
        schedule(body.namedChildren, then: [.popRegion, .popScope, .popFacet])
    }

    func enterFuncLiteral(_ node: Node) {
        let scope = pushScope(node, kind: .function, parent: scopeStack.last)
        pushRegion(node, kind: .closure, scope: scope, facet: facetStack.last)
        bindParameters(node.child(namedField: "parameters"), scope: scope)
        bindParameters(node.child(namedField: "result"), scope: scope)
        schedule(node.child(namedField: "body")?.namedChildren ?? [], then: [.popRegion, .popScope])
    }

    func bindParameters(_ list: Node?, scope: ScopeID) {
        guard let list, list.kind == "parameter_list" else { return }
        for parameter in list.namedChildren
            where parameter.kind == "parameter_declaration" || parameter.kind == "variadic_parameter_declaration"
        {
            let type = parameter.child(namedField: "type")
            // `...T` is a slice of T: no methods on the binding itself.
            let declared = parameter.kind == "parameter_declaration" ? type.map(declaredType) : nil
            for name in namedChildren(of: parameter, field: "name") {
                appendBinding(name, scope: scope, kind: .param, typeRef: declared?.typeRef, hint: declared?.hint)
            }
        }
    }

    func typeParameterNames(_ list: Node?) -> Set<String> {
        var result: Set<String> = []
        for declaration in list?.namedChildren ?? [] where declaration.kind == "type_parameter_declaration" {
            for name in namedChildren(of: declaration, field: "name") {
                if let name = text(name) { result.insert(name) }
            }
        }
        return result
    }

    // MARK: Types

    /// The named type a type expression is built on: `*pkg.T[U]` → `T`.
    /// Slices, maps, channels and function types have no head.
    func typeHead(_ node: Node) -> Node? {
        var node = node
        while true {
            switch node.kind {
            case "type_identifier", "identifier":
                return node
            case "qualified_type":
                return node.child(namedField: "name")
            case "selector_expression":
                return node.child(namedField: "field")
            case "pointer_type", "parenthesized_type", "type_elem":
                guard let inner = node.namedChildren.first else { return nil }
                node = inner
            case "generic_type":
                guard let inner = node.child(namedField: "type") else { return nil }
                node = inner
            default:
                return nil
            }
        }
    }

    func typeRef(_ head: Node) -> TypeRef {
        guard let name = text(head) else { return .named(coreRange(head)) }
        if typeParameterStack.contains(where: { $0.contains(name) }) {
            return .genericUnbounded(parameter: coreRange(head))
        }
        return goPrimitiveNames.contains(name) ? .primitive(coreRange(head)) : .named(coreRange(head))
    }

    /// A spelled type (`x T`, `var x *T`): its TypeRef and, for a project
    /// type name, the unqualified method-dispatch hint.
    func declaredType(_ type: Node) -> (typeRef: TypeRef?, hint: UnresolvedSymbolRef?) {
        guard let head = typeHead(type) else { return (nil, nil) }
        let ref = typeRef(head)
        guard case .named = ref, let name = text(head) else { return (ref, nil) }
        return (ref, UnresolvedSymbolRef(nameID: names.intern(name), hintKind: .unqualified))
    }

    /// A value whose type the syntax shows: `T{…}`, `&T{…}`, `new(T)`.
    func constructedType(_ value: Node) -> (typeRef: TypeRef?, hint: UnresolvedSymbolRef?) {
        var value = value
        if value.kind == "unary_expression", let operand = value.child(namedField: "operand"),
           value.child(at: 0).flatMap(text) == "&"
        {
            value = operand
        }
        let head: Node?
        if value.kind == "composite_literal" {
            head = value.child(namedField: "type").flatMap(typeHead)
        } else if value.kind == "call_expression",
                  value.child(namedField: "function").flatMap(text) == "new",
                  let argument = value.child(namedField: "arguments")?.namedChildren.first
        {
            head = typeHead(argument)
        } else {
            head = nil
        }
        guard let head, let name = text(head), !goPrimitiveNames.contains(name),
              !typeParameterStack.contains(where: { $0.contains(name) })
        else { return (nil, nil) }
        return (.constructed(coreRange(head)), UnresolvedSymbolRef(nameID: names.intern(name), hintKind: .member))
    }

    // MARK: Bindings

    func appendBinding(
        _ name: Node,
        scope: ScopeID,
        kind: BindingKind,
        typeRef: TypeRef? = nil,
        hint: UnresolvedSymbolRef? = nil
    ) {
        guard name.kind == "identifier", let string = text(name), string != "_" else { return }
        bindings.append(BindingRecord(
            scopeID: scope,
            localNameID: names.intern(string),
            space: .value,
            kind: kind,
            declarationRange: coreRange(name),
            targetHint: hint,
            typeRef: typeRef
        ))
    }

    /// `a, b := x, y` / `var a, b = x, y`: one value per name gives each its
    /// constructed type.
    func bindDeclared(_ left: [Node], values: [Node], declared: Node?) {
        guard let scope = scopeStack.last else { return }
        let spelled = declared.map(declaredType)
        for (offset, name) in left.enumerated() {
            let typed = spelled ?? (left.count == values.count ? constructedType(values[offset]) : (nil, nil))
            appendBinding(name, scope: scope, kind: .letBinding, typeRef: typed.typeRef, hint: typed.hint)
        }
    }

    func hasDefineToken(_ node: Node) -> Bool {
        (0..<node.childCount).contains { node.child(at: $0).flatMap(text) == ":=" }
    }

    // MARK: Walk

    func visit(_ node: Node) {
        switch node.kind {
        case "func_literal":
            enterFuncLiteral(node)
        case "block":
            pushScope(node, kind: .block, parent: scopeStack.last)
            schedule(node.namedChildren, then: [.popScope])
        case "if_statement", "for_statement", "expression_switch_statement", "type_switch_statement",
             "select_statement", "expression_case", "type_case", "default_case", "communication_case":
            pushScope(node, kind: .block, parent: scopeStack.last)
            if node.kind == "type_switch_statement", let alias = node.child(namedField: "alias") {
                bindDeclared(alias.namedChildren, values: [], declared: nil)
            }
            schedule(node.namedChildren.filter { $0.kind != "expression_list" || node.kind != "type_switch_statement" },
                     then: [.popScope])
        case "short_var_declaration":
            let left = node.child(namedField: "left")?.namedChildren ?? []
            let right = node.child(namedField: "right")?.namedChildren ?? []
            // The values run before the names exist.
            schedule(right, then: [.run { self.bindDeclared(left, values: right, declared: nil) }])
        case "var_spec", "const_spec":
            let values = node.child(namedField: "value")?.namedChildren ?? []
            let declared = namedChildren(of: node, field: "name")
            let type = node.child(namedField: "type")
            schedule(values, then: [.run { self.bindDeclared(declared, values: values, declared: type) }])
        case "range_clause", "receive_statement":
            let left = node.child(namedField: "left")?.namedChildren ?? []
            let right = node.child(namedField: "right").map { [$0] } ?? []
            if hasDefineToken(node) {
                schedule(right, then: [.run { self.bindDeclared(left, values: [], declared: nil) }])
            } else {
                schedule(left + right)
            }
        case "call_expression":
            recordCall(node)
            schedule(node.namedChildren)
        case "type_conversion_expression":
            // `F[int](x)` with one argument parses as a conversion.
            if node.child(namedField: "type")?.kind == "generic_type" { recordCall(node) }
            schedule(node.namedChildren)
        case "type_declaration":
            // Local types are not package declarations.
            break
        default:
            schedule(node.namedChildren)
        }
    }

    func recordCall(_ node: Node) {
        guard let region = regionStack.last,
              var function = node.child(namedField: "function") ?? node.child(namedField: "type")
        else { return }
        // `F[int](x)` names `F`.
        if function.kind == "index_expression", let operand = function.child(namedField: "operand") {
            function = operand
        } else if function.kind == "type_instantiation_expression" || function.kind == "generic_type",
                  let type = function.child(namedField: "type")
        {
            function = type
        }
        let name: Node
        var kind = CallKind.directCall
        var qualifier: Node?
        var receiver: Node?
        switch function.kind {
        case "identifier", "type_identifier":
            name = function
        case "qualified_type":
            // `pkg.F[int](x)` reads as an instantiated type.
            guard let field = function.child(namedField: "name"),
                  let package = function.child(namedField: "package")
            else { return }
            name = field
            kind = .qualifiedCall
            qualifier = package
        case "selector_expression":
            guard let field = function.child(namedField: "field"),
                  let operand = function.child(namedField: "operand")
            else { return }
            name = field
            if operand.kind == "identifier", let operandName = text(operand), importNames.contains(operandName) {
                kind = .qualifiedCall
                qualifier = operand
            } else {
                kind = .methodCall
                receiver = operand
            }
        default:
            return
        }
        guard let callName = text(name) else { return }
        calls.append(UnresolvedCall(
            regionID: region,
            nameID: names.intern(callName),
            range: coreRange(node),
            nameRange: coreRange(name),
            syntacticKind: kind,
            qualifierRange: qualifier.map(coreRange),
            receiverRange: receiver.map(coreRange),
            argumentCount: node.kind == "type_conversion_expression"
                ? 1 : node.child(namedField: "arguments").flatMap { UInt16(exactly: $0.namedChildren.count) }
        ))
    }

    /// The children a repeated field (`a, b int`) names.
    func namedChildren(of node: Node, field: String) -> [Node] {
        // ts_node_child_by_field_name returns only the first; walk the
        // children and keep the ones before the type that share the kind.
        guard let first = node.child(namedField: field) else { return [] }
        let type = node.child(namedField: "type")?.byteRange.lowerBound ?? UInt32.max
        let value = node.child(namedField: "value")?.byteRange.lowerBound ?? UInt32.max
        let end = min(type, value)
        return node.namedChildren.filter {
            $0.kind == first.kind && $0.byteRange.lowerBound >= first.byteRange.lowerBound
                && $0.byteRange.upperBound <= end
        }
    }
}
