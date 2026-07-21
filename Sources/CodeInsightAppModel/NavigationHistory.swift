import CodeInsightCore

public struct JumpRecord: Equatable, Sendable {
    public let path: String
    public let contentID: ContentID?
    public let byteOffset: UInt32
    public let line: UInt32
    public let column: UInt32
    public let symbolAnchor: String?
    public let snapshotID: SnapshotID?

    public init(
        path: String,
        contentID: ContentID?,
        byteOffset: UInt32,
        line: UInt32,
        column: UInt32,
        symbolAnchor: String?,
        snapshotID: SnapshotID?
    ) {
        self.path = path
        self.contentID = contentID
        self.byteOffset = byteOffset
        self.line = line
        self.column = column
        self.symbolAnchor = symbolAnchor
        self.snapshotID = snapshotID
    }
}

@MainActor
public final class NavigationHistory {
    public private(set) var records: [JumpRecord] = []
    public private(set) var cursor = 0

    private static let limit = 200
    private var forwardRecord: JumpRecord?

    public init() {}

    public var canGoBack: Bool {
        cursor > 0
    }

    public var canGoForward: Bool {
        cursor + 1 < records.count
            || (cursor + 1 == records.count && forwardRecord != nil)
    }

    public func push(_ record: JumpRecord) {
        if cursor < records.count {
            records.removeSubrange((cursor + 1)..<records.count)
            if records.indices.contains(cursor), records[cursor].path == record.path {
                records[cursor] = record
                forwardRecord = nil
                cursor = records.count
                return
            }
        }
        forwardRecord = nil
        if records.last != record {
            records.append(record)
        }
        if records.count > Self.limit {
            records.removeFirst(records.count - Self.limit)
        }
        cursor = records.count
    }

    public func goBack(from current: JumpRecord) -> JumpRecord? {
        guard canGoBack else { return nil }
        if cursor == records.count {
            forwardRecord = current
        }
        cursor -= 1
        return records[cursor]
    }

    public func goForward() -> JumpRecord? {
        guard canGoForward else { return nil }
        if cursor + 1 < records.count {
            cursor += 1
            return records[cursor]
        }
        cursor += 1
        return forwardRecord
    }

    public func reset() {
        records.removeAll(keepingCapacity: true)
        cursor = 0
        forwardRecord = nil
    }
}
