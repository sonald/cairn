import CodeInsightReaderCore
import Foundation

/// The composed decoration of one display run. Every field is a style that
/// does not change layout; typography changes go through the reader's
/// typography transaction instead.
struct DecorationRun: Equatable {
    var range: NSRange
    var syntax: HighlightKind?
    var occurrence = false
    /// Highlighted-name color slot (1...6); its background wins over `occurrence`.
    var highlightSlot: UInt8?
    /// nil when the run is not a local reference; true for a parameter.
    var parameterReference: Bool?
}

/// One source of decoration. `ranges` are sorted by location and do not
/// overlap within the layer; `apply` writes the layer's value for the range
/// at the given index into a run it covers.
struct DecorationLayer {
    let ranges: [NSRange]
    let apply: (Int, inout DecorationRun) -> Void
}

enum DecorationComposer {
    /// Sweeps all layers once, splitting runs at every layer boundary and
    /// emitting only runs that at least one layer covers.
    static func compose(_ layers: [DecorationLayer]) -> [DecorationRun] {
        var indices = Array(repeating: 0, count: layers.count)
        var location = layers.compactMap { $0.ranges.first?.location }.min() ?? Int.max
        var runs: [DecorationRun] = []
        runs.reserveCapacity(layers.reduce(0) { $0 + $1.ranges.count })
        while location != Int.max {
            var run = DecorationRun(range: NSRange(location: location, length: 0))
            var covered = false
            var next = Int.max
            for (layerIndex, layer) in layers.enumerated() {
                while indices[layerIndex] < layer.ranges.count,
                      NSMaxRange(layer.ranges[indices[layerIndex]]) <= location
                {
                    indices[layerIndex] += 1
                }
                guard indices[layerIndex] < layer.ranges.count else { continue }
                let range = layer.ranges[indices[layerIndex]]
                if range.location <= location {
                    layer.apply(indices[layerIndex], &run)
                    covered = true
                    next = min(next, NSMaxRange(range))
                } else {
                    next = min(next, range.location)
                }
            }
            guard next > location else { break }
            if covered {
                run.range.length = next - location
                runs.append(run)
            }
            location = next
        }
        return runs
    }
}
