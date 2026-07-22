public enum RustExtractorInfo {
    /// Bump grammarVersion when tree-sitter-rust changes and extractorVersion
    /// when extraction semantics change. Both values are part of ContentIndexKey.
    public static let grammarVersion: UInt32 = 1 // tree-sitter-rust v0.24.0
    public static let extractorVersion: UInt32 = 5
}
