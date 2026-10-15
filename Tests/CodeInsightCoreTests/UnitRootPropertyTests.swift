import Testing
@testable import CodeInsightCore

/// Deterministic generator so a failing seed reproduces.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// The pre-optimization scan over every root, kept as an independent oracle.
private func scannedDeepestUnitRoot(containing path: String, among roots: [String]) -> String? {
    func depth(_ root: String) -> Int {
        root == "." || root.isEmpty ? 0 : root.split(separator: "/").count
    }
    return roots.filter { root in
        root == "." || root.isEmpty || path == root || path.hasPrefix(root + "/")
    }
    .max { depth($0) < depth($1) }
}

/// Paths are normalized project-relative paths (no empty, `.` or `..`
/// components), as manifests and `ProfileDetector` produce; roots may be
/// anything, including malformed ones that can never hold a path.
@Test
func unitRootLookupMatchesScanOnGeneratedPathsAndRoots() {
    // `b`/`bc`/`b.rs` share string prefixes; the accented pair is the same
    // name in two canonically equivalent spellings.
    let names = ["a", "b", "bc", "b.rs", "src", "源", "caf\u{E9}", "cafe\u{301}", "x y", ".hidden"]
    let oddRoots = [".", "", "a/", "/a", "a//b", "./a", "src/"]
    var nestedHits = 0
    var nearMisses = 0
    var rootFallbacks = 0
    for seed in UInt64(1)...500 {
        var random = SplitMix64(state: seed)
        let paths = (0..<Int.random(in: 1...30, using: &random)).map { _ in
            (0..<Int.random(in: 1...8, using: &random))
                .map { _ in names.randomElement(using: &random)! }
                .joined(separator: "/")
        }
        var roots: [String] = []
        for _ in 0..<Int.random(in: 0...10, using: &random) {
            let path = paths.randomElement(using: &random)!
            let parts = path.split(separator: "/")
            switch Int.random(in: 0..<5, using: &random) {
            case 0, 1: // An ancestor directory, or the path itself.
                roots.append(parts.prefix(Int.random(in: 1...parts.count, using: &random))
                    .joined(separator: "/"))
            case 2: // A string prefix that stops inside a component.
                let cut = Int.random(in: 1...path.count, using: &random)
                roots.append(String(path.prefix(cut)))
            case 3:
                roots.append(oddRoots.randomElement(using: &random)!)
            default: // Unrelated to any path.
                roots.append((0..<Int.random(in: 1...4, using: &random))
                    .map { _ in names.randomElement(using: &random)! }
                    .joined(separator: "/"))
            }
        }
        roots.shuffle(using: &random)
        let lookup = deepestUnitRootLookup(among: roots)
        for path in paths {
            let expected = scannedDeepestUnitRoot(containing: path, among: roots)
            let actual = lookup(path)
            // Compare bytes: canonically equivalent spellings are `==`.
            #expect(
                actual.map { Array($0.utf8) } == expected.map { Array($0.utf8) },
                "seed \(seed): \(path) among \(roots) gave \(String(describing: actual)), expected \(String(describing: expected))"
            )
            #expect(deepestUnitRoot(containing: path, among: roots) == actual)
            if let expected, expected != ".", !expected.isEmpty { nestedHits += 1 }
            if expected == "." || expected == "" { rootFallbacks += 1 }
            if roots.contains(where: { $0 != path && $0 != "." && !$0.isEmpty
                && path.hasPrefix($0) && !path.hasPrefix($0 + "/") }) {
                nearMisses += 1
            }
        }
    }
    // The generator must reach every branch, or the agreement means little.
    print("unit roots: \(nestedHits) nested, \(nearMisses) near misses, \(rootFallbacks) project root")
    #expect(nestedHits > 1_000)
    #expect(nearMisses > 500)
    #expect(rootFallbacks > 500)
}
