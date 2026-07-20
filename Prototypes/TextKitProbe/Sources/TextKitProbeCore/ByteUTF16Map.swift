import Foundation

public struct ByteUTF16Map: Sendable {
    public struct Checkpoint: Sendable {
        public let byteOffset: Int
        public let utf16Offset: Int
    }

    public let bytes: [UInt8]
    public let checkpoints: [Checkpoint]
    public let utf16Count: Int

    public init(validUTF8 bytes: [UInt8], stride: Int = 256) {
        precondition(stride > 0)
        self.bytes = bytes

        var checkpoints = [Checkpoint(byteOffset: 0, utf16Offset: 0)]
        var byte = 0
        var utf16 = 0
        var nextCheckpoint = stride
        while byte < bytes.count {
            if byte >= nextCheckpoint {
                checkpoints.append(Checkpoint(byteOffset: byte, utf16Offset: utf16))
                nextCheckpoint += stride
            }
            let width = Self.scalarWidth(firstByte: bytes[byte])
            precondition(width > 0 && byte + width <= bytes.count, "invalid UTF-8")
            utf16 += width == 4 ? 2 : 1
            byte += width
        }
        if checkpoints.last?.byteOffset != bytes.count {
            checkpoints.append(Checkpoint(byteOffset: bytes.count, utf16Offset: utf16))
        }
        self.checkpoints = checkpoints
        utf16Count = utf16
    }

    public func utf16Offset(forByte byteOffset: Int) -> Int? {
        guard byteOffset >= 0 && byteOffset <= bytes.count else { return nil }
        let checkpoint = checkpoints[lastCheckpoint(atMost: byteOffset, key: \.byteOffset)]
        var byte = checkpoint.byteOffset
        var utf16 = checkpoint.utf16Offset
        while byte < byteOffset {
            let width = Self.scalarWidth(firstByte: bytes[byte])
            guard byte + width <= byteOffset else { return nil }
            utf16 += width == 4 ? 2 : 1
            byte += width
        }
        return utf16
    }

    public func byteOffset(forUTF16 utf16Offset: Int) -> Int? {
        guard utf16Offset >= 0 && utf16Offset <= utf16Count else { return nil }
        let checkpoint = checkpoints[lastCheckpoint(atMost: utf16Offset, key: \.utf16Offset)]
        var byte = checkpoint.byteOffset
        var utf16 = checkpoint.utf16Offset
        while utf16 < utf16Offset {
            let width = Self.scalarWidth(firstByte: bytes[byte])
            let units = width == 4 ? 2 : 1
            guard utf16 + units <= utf16Offset else { return nil }
            byte += width
            utf16 += units
        }
        return byte
    }

    public func nsRange(byteLowerBound: Int, byteUpperBound: Int) -> NSRange? {
        guard
            let lower = utf16Offset(forByte: byteLowerBound),
            let upper = utf16Offset(forByte: byteUpperBound),
            lower <= upper
        else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    private func lastCheckpoint(
        atMost value: Int,
        key: KeyPath<Checkpoint, Int>
    ) -> Int {
        var low = 0
        var high = checkpoints.count
        while low < high {
            let middle = (low + high) / 2
            if checkpoints[middle][keyPath: key] <= value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low - 1
    }

    private static func scalarWidth(firstByte: UInt8) -> Int {
        switch firstByte {
        case 0x00...0x7f: 1
        case 0xc2...0xdf: 2
        case 0xe0...0xef: 3
        case 0xf0...0xf4: 4
        default: 0
        }
    }
}
