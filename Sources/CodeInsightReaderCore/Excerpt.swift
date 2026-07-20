import CodeInsightCore
import Foundation

public func excerpt(
    for target: ByteRange,
    in document: ReaderDocument,
    binding: Bool = false
) -> String {
    guard let targetStart = document.lineTable.lineColumn(at: target.lowerBound) else {
        return ""
    }
    let lastLine = max(0, document.lineTable.lineStarts.count - 1)
    let targetLine = Int(targetStart.line - 1)

    if binding {
        return lines(
            from: max(0, targetLine - 2),
            through: min(lastLine, targetLine + 2),
            in: document
        ).joined(separator: "\n")
    }

    let endOffset = target.upperBound > target.lowerBound
        ? target.upperBound - 1
        : target.lowerBound
    let targetEndLine = min(
        lastLine,
        Int(document.lineTable.lineColumn(at: endOffset)?.line ?? targetStart.line) - 1
    )
    var firstLine = targetLine
    while firstLine > 0, isDocComment(line(firstLine - 1, in: document)) {
        firstLine -= 1
    }
    let includedEnd = min(targetEndLine, targetLine + 23)
    var result = lines(from: firstLine, through: includedEnd, in: document)
    let remaining = targetEndLine - includedEnd
    if remaining > 0 {
        result.append("… \(remaining) more lines")
    }
    return result.joined(separator: "\n")
}

private func isDocComment(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("///") || trimmed.hasPrefix("//!")
}

private func lines(
    from lower: Int,
    through upper: Int,
    in document: ReaderDocument
) -> [String] {
    guard lower <= upper else { return [] }
    return (lower...upper).map { line($0, in: document) }
}

private func line(_ index: Int, in document: ReaderDocument) -> String {
    let starts = document.lineTable.lineStarts
    guard starts.indices.contains(index) else { return "" }
    let lower = Int(starts[index])
    var upper = index + 1 < starts.count
        ? Int(starts[index + 1])
        : document.bytes.count
    if upper > lower, document.bytes[upper - 1] == 0x0A { upper -= 1 }
    if upper > lower, document.bytes[upper - 1] == 0x0D { upper -= 1 }
    return String(decoding: document.bytes[lower..<upper], as: UTF8.self)
}
