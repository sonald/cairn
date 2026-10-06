import CodeInsightCore

/// Shared by indexing and the reader, including template interpolation boundaries.
public func contentRegionKind(nodeKind: String, language: LanguageID) -> ContentRegionKind? {
    switch language {
    case .rust:
        switch nodeKind {
        case "line_comment", "block_comment": return .comment
        case "string_literal", "raw_string_literal", "char_literal": return .string
        default: return nil
        }
    case .python:
        switch nodeKind {
        case "comment": return .comment
        case "string", "concatenated_string": return .string
        default: return nil
        }
    case .typescript, .javascript:
        switch nodeKind {
        case "comment": return .comment
        case "string", "regex", "string_fragment", "escape_sequence", "`": return .string
        default: return nil
        }
    }
}

public func contentRegions(in root: Node, language: LanguageID) -> [ContentRegion] {
    root.contentRegions(language: language)
}
