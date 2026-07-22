import CodeInsightCore
import Foundation

enum ContentIndexDraftCodec {
    private static let formatVersion: UInt32 = 1
    private static let magic = Data([0x43, 0x49, 0x44, 0x58, 0x01])

    private struct Payload: Codable {
        let formatVersion: UInt32
        let index: ContentIndex
        let names: [String]
        let strings: [String]
        let containsErrorNodes: Bool
    }

    static func encode(_ draft: ExtractionDraft) throws -> Data {
        let encoded = try JSONEncoder().encode(Payload(
            formatVersion: formatVersion,
            index: draft.index,
            names: draft.names.values,
            strings: draft.strings.values,
            containsErrorNodes: draft.containsErrorNodes
        ))
        var result = magic
        result.append(try (encoded as NSData).compressed(using: .lzfse) as Data)
        return result
    }

    static func decode(
        _ data: Data,
        order: Int,
        bytes: [UInt8],
        expectedKey: ContentIndexKey
    ) throws -> ExtractionDraft {
        guard data.starts(with: magic) else { throw DraftCodecError.invalidPayload }
        let encoded = try (Data(data.dropFirst(magic.count)) as NSData)
            .decompressed(using: .lzfse) as Data
        let payload = try JSONDecoder().decode(Payload.self, from: encoded)
        guard payload.formatVersion == formatVersion,
              payload.index.key == expectedKey,
              ContentID.sha256(of: bytes) == expectedKey.contentID,
              payload.index.lineTable == LineTable(bytes: bytes),
              isValid(payload, byteCount: bytes.count)
        else { throw DraftCodecError.invalidPayload }

        let names = try interner(payload.names, as: NameID.self)
        let strings = try interner(payload.strings, as: StringID.self)
        return ExtractionDraft(
            order: order,
            bytes: bytes,
            index: payload.index,
            names: names,
            strings: strings,
            containsErrorNodes: payload.containsErrorNodes
        )
    }

    private static func interner<ID>(
        _ values: [String],
        as _: ID.Type
    ) throws -> Interner<ID>
    where ID: RawRepresentable & Hashable & Sendable, ID.RawValue == UInt32 {
        let result = Interner<ID>()
        for (offset, value) in values.enumerated() {
            guard result.intern(value).rawValue == UInt32(exactly: offset) else {
                throw DraftCodecError.invalidPayload
            }
        }
        return result
    }

    private static func isValid(_ payload: Payload, byteCount: Int) -> Bool {
        let index = payload.index
        let nameCount = payload.names.count
        let stringCount = payload.strings.count
        let scopes = Set(index.scopes.map(\.id))
        let regions = Set(index.executableRegions.map(\.id))

        guard index.scopes.allSatisfy({
            valid($0.range, byteCount: byteCount)
                && $0.parent.map(scopes.contains) != false
        }), index.bindings.allSatisfy({
            scopes.contains($0.scopeID)
                && valid($0.localNameID, count: nameCount)
                && valid($0.declarationRange, byteCount: byteCount)
                && $0.targetHint.map { valid($0.nameID, count: nameCount) } != false
        }), index.executableRegions.allSatisfy({
            valid($0.range, byteCount: byteCount)
                && scopes.contains($0.enclosingScopeID)
                && valid($0.associatedFacetIndex, count: index.symbols.count)
        }), index.symbols.allSatisfy({
            valid($0.nameID, count: nameCount)
                && valid($0.range, byteCount: byteCount)
                && valid($0.nameRange, byteCount: byteCount)
                && valid($0.parentFacetIndex, count: index.symbols.count)
        }), index.implRelations.allSatisfy({
            valid($0.implFacetIndex, count: index.symbols.count)
                && $0.traitNameID.map { valid($0, count: nameCount) } != false
                && $0.traitNameRange.map { valid($0, byteCount: byteCount) } != false
                && valid($0.typeNameID, count: nameCount)
        }), index.calls.allSatisfy({
            regions.contains($0.regionID)
                && valid($0.nameID, count: nameCount)
                && valid($0.range, byteCount: byteCount)
                && $0.qualifierRange.map { valid($0, byteCount: byteCount) } != false
                && $0.receiverRange.map { valid($0, byteCount: byteCount) } != false
        }), index.imports.allSatisfy({
            valid($0.moduleSpecifier, count: stringCount)
                && $0.importedName.map { valid($0, count: nameCount) } != false
                && $0.localName.map { valid($0, count: nameCount) } != false
                && scopes.contains($0.scopeID)
                && valid($0.range, byteCount: byteCount)
        }), index.exports.allSatisfy({
            valid($0.exportedName, count: nameCount)
                && valid($0.sourceBindingIndex, count: index.imports.count)
                && valid($0.range, byteCount: byteCount)
        }) else { return false }
        return scopes.count == index.scopes.count
            && regions.count == index.executableRegions.count
    }

    private static func valid(_ id: NameID, count: Int) -> Bool {
        Int(id.rawValue) < count
    }

    private static func valid(_ id: StringID, count: Int) -> Bool {
        Int(id.rawValue) < count
    }

    private static func valid(_ index: UInt32?, count: Int) -> Bool {
        index.map { Int($0) < count } != false
    }

    private static func valid(_ range: ByteRange, byteCount: Int) -> Bool {
        Int(range.upperBound) <= byteCount
    }
}

private enum DraftCodecError: Error {
    case invalidPayload
}
