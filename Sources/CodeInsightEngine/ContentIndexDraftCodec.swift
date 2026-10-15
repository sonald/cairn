import CodeInsightCore
import CryptoKit
import Foundation

/// The persistent cache row for one extraction draft.
///
/// Layout: `CIDB`, a format byte, the body, then the SHA-256 of everything
/// before it. The body is little-endian LEB128 integers, length-prefixed
/// arrays and UTF-8 strings, in the field order `encode` writes. Optionals
/// are a 0/1 presence byte, or value+1 with 0 for absent; byte ranges are
/// lower bound plus length. The names and strings tables are the draft's
/// interner values, unique by construction. The line table is not stored:
/// decode used to accept only a stored table equal to `LineTable(bytes:)`,
/// so it now builds exactly that. Not compressed: on codex LZFSE saves
/// about 6 MB of 23 MB but makes encoding about 7 times slower.
///
/// Decoding treats the row as untrusted: every read is bounds-checked,
/// lengths may not exceed the bytes left, enum and flag values are checked,
/// and trailing bytes are rejected. Any failure throws `invalidPayload`,
/// and the caller drops the row and extracts again.
package enum ContentIndexDraftCodec {
    private static let formatVersion: UInt8 = 6
    private static let header: [UInt8] = [0x43, 0x49, 0x44, 0x42, formatVersion]
    private static let digestCount = SHA256.byteCount

    package static func encode(_ draft: ExtractionDraft) -> Data {
        var w = Writer()
        w.out.reserveCapacity(4096)
        w.out.append(contentsOf: header)
        let index = draft.index
        w.contentID(index.key.contentID)
        w.u8(index.key.languageMode.language.rawValue)
        w.optString(index.key.languageMode.variant)
        w.uint(index.key.grammarVersion)
        w.uint(index.key.extractorVersion)
        w.flag(draft.containsErrorNodes)
        w.strings(draft.names.values)
        w.strings(draft.strings.values)

        w.count(index.scopes.count)
        for s in index.scopes {
            w.uint(s.id.rawValue); w.opt(s.parent?.rawValue)
            w.u8(s.kind.rawValue); w.range(s.range)
        }
        w.count(index.bindings.count)
        for b in index.bindings {
            w.uint(b.scopeID.rawValue); w.uint(b.localNameID.rawValue)
            w.u8(b.space.rawValue); w.u8(b.kind.rawValue); w.range(b.declarationRange)
            if let hint = b.targetHint {
                w.u8(hint.hintKind.rawValue + 1); w.uint(hint.nameID.rawValue)
            } else {
                w.u8(0)
            }
            w.typeRef(b.typeRef)
        }
        w.count(index.executableRegions.count)
        for r in index.executableRegions {
            w.uint(r.id.rawValue); w.u8(r.kind.rawValue); w.range(r.range)
            w.uint(r.enclosingScopeID.rawValue); w.opt(r.associatedFacetIndex)
        }
        w.count(index.symbols.count)
        for s in index.symbols {
            w.uint(s.symbolGroupID.rawValue); w.u8(s.space.rawValue); w.u8(s.kind.rawValue)
            w.uint(s.nameID.rawValue); w.range(s.range); w.range(s.nameRange)
            w.opt(s.parentFacetIndex); w.optContentID(s.signatureFingerprint)
            w.optContentID(s.bodyFingerprint); w.typeRef(s.typeRef)
            w.u8(s.visibility.map { $0.rawValue + 1 } ?? 0)
        }
        w.count(index.implRelations.count)
        for r in index.implRelations {
            w.uint(r.implFacetIndex); w.opt(r.traitNameID?.rawValue)
            w.optRange(r.traitNameRange); w.uint(r.typeNameID.rawValue)
        }
        w.count(index.calls.count)
        for c in index.calls {
            w.uint(c.regionID.rawValue); w.uint(c.nameID.rawValue); w.range(c.range)
            w.range(c.nameRange); w.u8(c.syntacticKind.rawValue); w.optRange(c.qualifierRange)
            w.optRange(c.receiverRange); w.opt(c.argumentCount.map(UInt32.init))
        }
        w.count(index.imports.count)
        for i in index.imports {
            w.uint(i.moduleSpecifier.rawValue); w.opt(i.importedName?.rawValue)
            w.opt(i.localName?.rawValue); w.u8(i.kind.rawValue); w.u8(i.flags.rawValue)
            w.uint(i.scopeID.rawValue); w.range(i.range)
        }
        w.count(index.exports.count)
        for e in index.exports {
            w.uint(e.exportedName.rawValue); w.opt(e.sourceBindingIndex); w.range(e.range)
        }
        w.count(index.regions.count)
        for r in index.regions {
            w.range(r.range); w.u8(r.kind.rawValue)
        }
        return Data(sealed(w.out))
    }

    /// Appends the digest of `body`, which must already start with the header.
    static func sealed(_ body: [UInt8]) -> [UInt8] {
        body + Array(SHA256.hash(data: body))
    }

    package static func decode(
        _ data: Data,
        order: Int,
        bytes: [UInt8],
        expectedKey: ContentIndexKey
    ) throws -> ExtractionDraft {
        let invalid = DraftCodecError.invalidPayload
        let (index, names, strings, containsErrorNodes) = try data.withUnsafeBytes { raw in
            guard raw.count >= header.count + digestCount,
                  raw.prefix(header.count).elementsEqual(header)
            else { throw invalid }
            let bodyEnd = raw.count - digestCount
            guard SHA256.hash(data: UnsafeRawBufferPointer(rebasing: raw[..<bodyEnd]))
                .elementsEqual(raw[bodyEnd...])
            else { throw invalid }
            var r = Reader(base: UnsafeRawBufferPointer(rebasing: raw[..<bodyEnd]))
            r.position = header.count

            let key = ContentIndexKey(
                contentID: try r.contentID(),
                languageMode: LanguageMode(language: try r.enumValue(), variant: try r.optString()),
                grammarVersion: try r.uint(),
                extractorVersion: try r.uint()
            )
            guard key == expectedKey,
                  ContentID.sha256(of: bytes) == expectedKey.contentID
            else { throw invalid }
            let containsErrorNodes = try r.flag()
            let names = try r.strings()
            let strings = try r.strings()

            let scopes = try r.array {
                ScopeRecord(
                    id: ScopeID(rawValue: try $0.uint()),
                    parent: try $0.opt().map(ScopeID.init(rawValue:)),
                    kind: try $0.enumValue(),
                    range: try $0.range()
                )
            }
            let bindings = try r.array { r in
                BindingRecord(
                    scopeID: ScopeID(rawValue: try r.uint()),
                    localNameID: NameID(rawValue: try r.uint()),
                    space: try r.enumValue(),
                    kind: try r.enumValue(),
                    declarationRange: try r.range(),
                    targetHint: try r.optEnum().map { (kind: UnresolvedSymbolHintKind) in
                        UnresolvedSymbolRef(nameID: NameID(rawValue: try r.uint()), hintKind: kind)
                    },
                    typeRef: try r.typeRef()
                )
            }
            let executableRegions = try r.array {
                ExecutableRegionRecord(
                    id: ExecutableRegionID(rawValue: try $0.uint()),
                    kind: try $0.enumValue(),
                    range: try $0.range(),
                    enclosingScopeID: ScopeID(rawValue: try $0.uint()),
                    associatedFacetIndex: try $0.opt()
                )
            }
            let symbols = try r.array { r in
                DeclarationFacet(
                    symbolGroupID: SymbolGroupID(rawValue: try r.uint()),
                    space: try r.enumValue(),
                    kind: try r.enumValue(),
                    nameID: NameID(rawValue: try r.uint()),
                    range: try r.range(),
                    nameRange: try r.range(),
                    parentFacetIndex: try r.opt(),
                    signatureFingerprint: try r.optContentID(),
                    bodyFingerprint: try r.optContentID(),
                    typeRef: try r.typeRef(),
                    visibility: try r.optEnum()
                )
            }
            let implRelations = try r.array {
                ImplRelation(
                    implFacetIndex: try $0.uint(),
                    traitNameID: try $0.opt().map(NameID.init(rawValue:)),
                    traitNameRange: try $0.optRange(),
                    typeNameID: NameID(rawValue: try $0.uint())
                )
            }
            let calls = try r.array { r in
                UnresolvedCall(
                    regionID: ExecutableRegionID(rawValue: try r.uint()),
                    nameID: NameID(rawValue: try r.uint()),
                    range: try r.range(),
                    nameRange: try r.range(),
                    syntacticKind: try r.enumValue(),
                    qualifierRange: try r.optRange(),
                    receiverRange: try r.optRange(),
                    argumentCount: try r.opt().map {
                        guard let value = UInt16(exactly: $0) else { throw invalid }
                        return value
                    }
                )
            }
            let imports = try r.array {
                ImportBinding(
                    moduleSpecifier: StringID(rawValue: try $0.uint()),
                    importedName: try $0.opt().map(NameID.init(rawValue:)),
                    localName: try $0.opt().map(NameID.init(rawValue:)),
                    kind: try $0.enumValue(),
                    flags: try $0.importFlags(),
                    scopeID: ScopeID(rawValue: try $0.uint()),
                    range: try $0.range()
                )
            }
            let exports = try r.array {
                ExportRecord(
                    exportedName: NameID(rawValue: try $0.uint()),
                    sourceBindingIndex: try $0.opt(),
                    range: try $0.range()
                )
            }
            let regions = try r.array {
                ContentRegion(range: try $0.range(), kind: try $0.enumValue())
            }
            guard r.position == r.base.count else { throw invalid }
            let index = ContentIndex(
                key: key,
                scopes: scopes,
                bindings: bindings,
                executableRegions: executableRegions,
                symbols: symbols,
                implRelations: implRelations,
                calls: calls,
                imports: imports,
                exports: exports,
                lineTable: LineTable(bytes: bytes),
                regions: regions
            )
            return (index, names, strings, containsErrorNodes)
        }
        guard isValid(
            index,
            nameCount: names.count,
            stringCount: strings.count,
            byteCount: bytes.count
        ) else { throw invalid }

        return ExtractionDraft(
            order: order,
            bytes: bytes,
            index: index,
            names: try interner(names, as: NameID.self),
            strings: try interner(strings, as: StringID.self),
            containsErrorNodes: containsErrorNodes
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

    private static func isValid(
        _ index: ContentIndex,
        nameCount: Int,
        stringCount: Int,
        byteCount: Int
    ) -> Bool {
        let scopes = Set(index.scopes.map(\.id))
        let regions = Set(index.executableRegions.map(\.id))

        var previousEnd: UInt32 = 0
        for region in index.regions {
            guard region.range.lowerBound >= previousEnd,
                  region.range.lowerBound < region.range.upperBound,
                  valid(region.range, byteCount: byteCount) else { return false }
            previousEnd = region.range.upperBound
        }

        guard index.scopes.allSatisfy({
            valid($0.range, byteCount: byteCount)
                && $0.parent.map(scopes.contains) != false
        }), index.bindings.allSatisfy({
            scopes.contains($0.scopeID)
                && valid($0.localNameID, count: nameCount)
                && valid($0.declarationRange, byteCount: byteCount)
                && $0.targetHint.map { valid($0.nameID, count: nameCount) } != false
                && $0.typeRef.map { typeRef in
                    typeRef.ranges.allSatisfy { valid($0, byteCount: byteCount) }
                } != false
        }), index.executableRegions.allSatisfy({
            valid($0.range, byteCount: byteCount)
                && scopes.contains($0.enclosingScopeID)
                && valid($0.associatedFacetIndex, count: index.symbols.count)
        }), index.symbols.allSatisfy({
            valid($0.nameID, count: nameCount)
                && valid($0.range, byteCount: byteCount)
                && valid($0.nameRange, byteCount: byteCount)
                && valid($0.parentFacetIndex, count: index.symbols.count)
                && $0.typeRef.map { typeRef in
                    typeRef.ranges.allSatisfy { valid($0, byteCount: byteCount) }
                } != false
        }), index.implRelations.allSatisfy({
            valid($0.implFacetIndex, count: index.symbols.count)
                && $0.traitNameID.map { valid($0, count: nameCount) } != false
                && $0.traitNameRange.map { valid($0, byteCount: byteCount) } != false
                && valid($0.typeNameID, count: nameCount)
        }), index.calls.allSatisfy({
            regions.contains($0.regionID)
                && valid($0.nameID, count: nameCount)
                && valid($0.range, byteCount: byteCount)
                && valid($0.nameRange, byteCount: byteCount)
                && $0.range.lowerBound <= $0.nameRange.lowerBound
                && $0.nameRange.upperBound <= $0.range.upperBound
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

    private struct Writer {
        var out: [UInt8] = []

        mutating func u8(_ value: UInt8) { out.append(value) }

        mutating func flag(_ value: Bool) { out.append(value ? 1 : 0) }

        mutating func varint(_ value: UInt64) {
            var value = value
            while value >= 0x80 {
                out.append(UInt8(truncatingIfNeeded: value) | 0x80)
                value >>= 7
            }
            out.append(UInt8(value))
        }

        mutating func uint(_ value: UInt32) { varint(UInt64(value)) }

        mutating func count(_ value: Int) { varint(UInt64(value)) }

        mutating func opt(_ value: UInt32?) { varint(value.map { UInt64($0) + 1 } ?? 0) }

        mutating func range(_ range: ByteRange) {
            uint(range.lowerBound)
            uint(range.upperBound - range.lowerBound)
        }

        mutating func optRange(_ range: ByteRange?) {
            flag(range != nil)
            if let range { self.range(range) }
        }

        mutating func bytes(_ value: some Collection<UInt8>) {
            count(value.count)
            out.append(contentsOf: value)
        }

        mutating func optString(_ value: String?) {
            flag(value != nil)
            if let value { bytes(value.utf8) }
        }

        mutating func strings(_ values: [String]) {
            count(values.count)
            for value in values { bytes(value.utf8) }
        }

        mutating func contentID(_ id: ContentID) {
            u8(id.algorithm)
            bytes(id.bytes)
        }

        mutating func optContentID(_ id: ContentID?) {
            flag(id != nil)
            if let id { contentID(id) }
        }

        mutating func typeRef(_ ref: TypeRef?) {
            switch ref {
            case nil: u8(0)
            case let .named(r)?: u8(1); range(r)
            case let .primitive(r)?: u8(2); range(r)
            case let .selfType(r)?: u8(3); range(r)
            case let .constructed(r)?: u8(4); range(r)
            case let .genericBound(p, b)?: u8(5); range(p); range(b)
            case let .genericUnbounded(p)?: u8(6); range(p)
            }
        }
    }

    private struct Reader {
        let base: UnsafeRawBufferPointer
        var position = 0

        private var invalid: DraftCodecError { .invalidPayload }

        mutating func u8() throws -> UInt8 {
            guard position < base.count else { throw invalid }
            defer { position += 1 }
            return base[position]
        }

        mutating func flag() throws -> Bool {
            switch try u8() {
            case 0: false
            case 1: true
            default: throw invalid
            }
        }

        /// At most ten bytes, and the tenth may only carry the top bit.
        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: UInt64(0), through: 63, by: 7) {
                let byte = try u8()
                guard shift < 63 || byte <= 1 else { throw invalid }
                result |= UInt64(byte & 0x7F) << shift
                if byte < 0x80 { return result }
            }
            throw invalid
        }

        mutating func uint() throws -> UInt32 {
            guard let value = UInt32(exactly: try varint()) else { throw invalid }
            return value
        }

        mutating func opt() throws -> UInt32? {
            let value = try varint()
            guard value != 0 else { return nil }
            guard let result = UInt32(exactly: value - 1) else { throw invalid }
            return result
        }

        /// Every element takes at least one byte, so a count larger than
        /// what is left is corrupt and must not size an allocation.
        mutating func count() throws -> Int {
            let value = try varint()
            guard value <= UInt64(base.count - position) else { throw invalid }
            return Int(value)
        }

        mutating func array<T>(_ element: (inout Reader) throws -> T) throws -> [T] {
            let n = try count()
            var result: [T] = []
            result.reserveCapacity(n)
            for _ in 0..<n { result.append(try element(&self)) }
            return result
        }

        mutating func enumValue<T: RawRepresentable>() throws -> T where T.RawValue == UInt8 {
            guard let value = T(rawValue: try u8()) else { throw invalid }
            return value
        }

        /// 0 is absent, otherwise the raw value plus one.
        mutating func optEnum<T: RawRepresentable>() throws -> T? where T.RawValue == UInt8 {
            let tag = try u8()
            guard tag != 0 else { return nil }
            guard let value = T(rawValue: tag - 1) else { throw invalid }
            return value
        }

        mutating func importFlags() throws -> ImportFlags {
            // Every flag in Imports.swift. A flag added there but not here
            // fails every row that carries it, so those files re-extract.
            let known: ImportFlags = [.wildcard, .reexport, .typeOnly, .conditional, .dynamic]
            let flags = ImportFlags(rawValue: try u8())
            guard known.isSuperset(of: flags) else { throw invalid }
            return flags
        }

        mutating func range() throws -> ByteRange {
            let lower = try uint()
            let (upper, overflow) = lower.addingReportingOverflow(try uint())
            guard !overflow else { throw invalid }
            return ByteRange(lowerBound: lower, upperBound: upper)
        }

        mutating func optRange() throws -> ByteRange? {
            try flag() ? try range() : nil
        }

        mutating func rawBytes() throws -> UnsafeRawBufferPointer {
            let n = try count()
            defer { position += n }
            return UnsafeRawBufferPointer(rebasing: base[position..<position + n])
        }

        mutating func string() throws -> String {
            let raw = try rawBytes()
            // `String(validating:as:)` needs macOS 15. Decoding replaces each
            // ill-formed sequence with U+FFFD, so the result spells the input
            // back exactly when the input was valid UTF-8.
            let value = String(decoding: raw, as: UTF8.self)
            guard value.utf8.elementsEqual(raw) else { throw invalid }
            return value
        }

        mutating func optString() throws -> String? {
            try flag() ? try string() : nil
        }

        mutating func strings() throws -> [String] {
            try array { try $0.string() }
        }

        mutating func contentID() throws -> ContentID {
            ContentID(algorithm: try u8(), bytes: Array(try rawBytes()))
        }

        mutating func optContentID() throws -> ContentID? {
            try flag() ? try contentID() : nil
        }

        mutating func typeRef() throws -> TypeRef? {
            switch try u8() {
            case 0: nil
            case 1: .named(try range())
            case 2: .primitive(try range())
            case 3: .selfType(try range())
            case 4: .constructed(try range())
            case 5: .genericBound(parameter: try range(), bound: try range())
            case 6: .genericUnbounded(parameter: try range())
            default: throw invalid
            }
        }
    }
}

package enum DraftCodecError: Error {
    case invalidPayload
}
