import CodeInsightCore

public struct NamePosting: Sendable {
    public private(set) var definitions: [
        NameID: [(key: ContentIndexKey, facetIndex: UInt32)]
    ] = [:]
    public private(set) var calls: [
        NameID: [(key: ContentIndexKey, callIndex: UInt32)]
    ] = [:]

    public init(indexes: [ContentIndexKey: ContentIndex]) {
        for (key, index) in indexes {
            add(index, for: key)
        }
    }

    mutating func add(_ index: ContentIndex, for key: ContentIndexKey) {
        for (facetIndex, facet) in index.symbols.enumerated() {
            guard let facetIndex = UInt32(exactly: facetIndex) else {
                preconditionFailure("Facet count exceeds UInt32")
            }
            definitions[facet.nameID, default: []].append((key, facetIndex))
        }
        for (callIndex, call) in index.calls.enumerated() {
            guard let callIndex = UInt32(exactly: callIndex) else {
                preconditionFailure("Call count exceeds UInt32")
            }
            calls[call.nameID, default: []].append((key, callIndex))
        }
    }
}
