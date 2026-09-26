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
    for span in document.highlightSpans.reversed()
        where (span.kind == .comment || span.kind == .commentFigure)
            && span.range.upperBound <= document.lineTable.lineStarts[firstLine]
    {
        guard span.range.upperBound > span.range.lowerBound,
              let start = document.lineTable.lineColumn(at: span.range.lowerBound),
              let end = document.lineTable.lineColumn(at: span.range.upperBound - 1),
              Int(end.line) == firstLine
        else { break }
        let commentLine = Int(start.line) - 1
        let prefix = document.bytes[
            Int(document.lineTable.lineStarts[commentLine])..<Int(span.range.lowerBound)
        ]
        let suffix = document.bytes[
            Int(span.range.upperBound)..<Int(document.lineTable.lineStarts[firstLine])
        ]
        guard prefix.allSatisfy({ $0 == 0x20 || $0 == 0x09 }),
              suffix.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A })
        else { break }
        firstLine = commentLine
    }
    if document.highlightSpans.isEmpty {
        while firstLine > 0 {
            let previous = line(firstLine - 1, in: document)
                .trimmingCharacters(in: .whitespaces)
            guard previous.hasPrefix("///") || previous.hasPrefix("//!") else { break }
            firstLine -= 1
        }
    }
    return lines(from: firstLine, through: targetEndLine, in: document)
        .joined(separator: "\n")
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
