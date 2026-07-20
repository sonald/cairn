public struct ByteRange: Comparable, Sendable {
    public let lowerBound: UInt32
    public let upperBound: UInt32

    public init(lowerBound: UInt32, upperBound: UInt32) {
        precondition(lowerBound <= upperBound, "ByteRange bounds are reversed")
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public var length: UInt32 {
        upperBound - lowerBound
    }

    public func contains(_ offset: UInt32) -> Bool {
        lowerBound <= offset && offset < upperBound
    }

    public func overlaps(_ other: ByteRange) -> Bool {
        !isEmpty && !other.isEmpty
            && lowerBound < other.upperBound
            && other.lowerBound < upperBound
    }

    public static func < (lhs: ByteRange, rhs: ByteRange) -> Bool {
        lhs.lowerBound < rhs.lowerBound
    }

    private var isEmpty: Bool {
        lowerBound == upperBound
    }
}

public struct LineTable: Sendable {
    public let lineStarts: [UInt32]

    private let byteCount: UInt32

    public init(bytes: [UInt8]) {
        guard let byteCount = UInt32(exactly: bytes.count) else {
            preconditionFailure("LineTable supports at most UInt32.max bytes")
        }

        var starts: [UInt32] = [0]
        starts.reserveCapacity(bytes.count / 28 + 1)
        bytes.withUnsafeBufferPointer { buffer in
            guard let pointer = buffer.baseAddress else { return }
            var index = 0
            while index < buffer.count {
                if pointer[index] == 0x0A {
                    starts.append(UInt32(index + 1))
                }
                index += 1
            }
        }

        self.lineStarts = starts
        self.byteCount = byteCount
    }

    /// Engine-internal coordinates are 1-based UTF-8 byte positions. UI
    /// UTF-16 coordinate conversion belongs in the rendering layer.
    public func byteOffset(line: UInt32, column: UInt32) -> UInt32? {
        guard line > 0, column > 0 else { return nil }
        let lineIndex = Int(line - 1)
        guard lineIndex < lineStarts.count else { return nil }

        let offset = UInt64(lineStarts[lineIndex]) + UInt64(column - 1)
        guard let offset = UInt32(exactly: offset) else { return nil }

        if lineIndex + 1 < lineStarts.count {
            guard offset < lineStarts[lineIndex + 1] else { return nil }
        } else {
            guard offset <= byteCount else { return nil }
        }
        return offset
    }

    /// CRLF is treated as one line break because only LF creates the next line;
    /// both CR and LF still occupy byte columns in the preceding line.
    public func lineColumn(
        at offset: UInt32
    ) -> (line: UInt32, column: UInt32)? {
        guard offset <= byteCount else { return nil }

        var lower = 0
        var upper = lineStarts.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lineStarts[middle] <= offset {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        let lineIndex = lower - 1
        return (
            line: UInt32(lineIndex + 1),
            column: offset - lineStarts[lineIndex] + 1
        )
    }
}
