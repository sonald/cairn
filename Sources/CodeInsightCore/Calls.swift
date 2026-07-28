public enum CallKind: UInt8, Codable, Sendable {
    case directCall
    case methodCall
    case qualifiedCall
    case indirectCall
    case macroInvocation
    case decoratorApply
}

public struct UnresolvedCall: Codable, Sendable {
    public let regionID: ExecutableRegionID
    public let nameID: NameID
    public let range: ByteRange
    public let nameRange: ByteRange
    public let syntacticKind: CallKind
    public let qualifierRange: ByteRange?
    public let receiverRange: ByteRange?
    public let argumentCount: UInt16?

    public init(
        regionID: ExecutableRegionID,
        nameID: NameID,
        range: ByteRange,
        nameRange: ByteRange,
        syntacticKind: CallKind,
        qualifierRange: ByteRange?,
        receiverRange: ByteRange?,
        argumentCount: UInt16?
    ) {
        self.regionID = regionID
        self.nameID = nameID
        self.range = range
        self.nameRange = nameRange
        self.syntacticKind = syntacticKind
        self.qualifierRange = qualifierRange
        self.receiverRange = receiverRange
        self.argumentCount = argumentCount
    }
}
