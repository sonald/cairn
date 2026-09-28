/// Language-neutral shape of a declaration. Every place that groups, labels
/// or filters declarations reads it here instead of switching over
/// language-specific kinds.
public enum DeclarationShape: Sendable, CaseIterable {
    case function
    case `struct`
    case `enum`
    case `class`
    case typeAlias
    case trait
    case impl
    case module
    case value

    public var family: DeclarationFamily {
        switch self {
        case .function: .function
        case .struct, .enum, .class, .typeAlias: .type
        case .trait: .trait
        case .impl, .module: .container
        case .value: .value
        }
    }
}

public enum DeclarationFamily: Sendable {
    case function
    case type
    case trait
    case container
    case value
}

public extension DeclarationKind {
    var shape: DeclarationShape {
        switch self {
        case .rustFn, .rustMethod, .pythonFunction, .typescriptFunction: .function
        case .rustStruct: .struct
        case .rustEnum: .enum
        case .pythonClass, .typescriptClass: .class
        case .rustTypeAlias: .typeAlias
        case .rustTrait: .trait
        case .rustImpl: .impl
        case .rustMod: .module
        case .rustConst, .rustStatic, .rustField: .value
        }
    }

    var language: LanguageID {
        switch self {
        case .rustFn, .rustStruct, .rustEnum, .rustTrait, .rustImpl, .rustMod,
             .rustConst, .rustStatic, .rustTypeAlias, .rustMethod, .rustField:
            .rust
        case .pythonFunction, .pythonClass: .python
        case .typescriptFunction, .typescriptClass: .typescript
        }
    }

    /// Separator between the names of a qualified declaration path.
    var qualifiedNameSeparator: String {
        language == .rust ? "::" : "."
    }
}
