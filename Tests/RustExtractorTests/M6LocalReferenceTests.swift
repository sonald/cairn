import CTreeSitterRust
import CodeInsightRustExtractor
import Darwin
import Foundation
import os
import Testing
import TreeSitterKit

private let m6RepositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

#if DEBUG
@Test
func localReferenceWalkUsesTheExistingTreeAndSkipsMacroReparse() throws {
    let source = """
        item_wrapper! {
            fn generated(hidden: i32) {
                hidden;
            }
        }
        fn visible(visible: i32) {
            visible;
        }
        """
    let bytes = Array(source.utf8)
    let parser = try #require(m6LocalReferenceParser())
    let tree = try #require(parser.parse(bytes))
    let extraParseCount = OSAllocatedUnfairLock(initialState: 0)

    let result = RustExtractor.$parseObserver.withValue({
        extraParseCount.withLock { $0 += 1 }
    }) {
        RustExtractor().localReferences(tree: tree, bytes: bytes)
    }

    #expect(extraParseCount.withLock { $0 } == 0)
    #expect(result.bindings.count == 1)
    #expect(result.referencesByBinding.count == 1)
    #expect(result.referencesByBinding[0].count == 1)
    let visible = try #require(source.range(of: "fn visible"))
    #expect(result.bindings[0].declarationRange.lowerBound
        > UInt32(source[..<visible.lowerBound].utf8.count))
}
#endif

@Test
func m6FixtureLocalReferenceIndexMetrics() throws {
    let fixture = m6RepositoryRoot.appendingPathComponent(
        "Tests/Fixtures/m6_reference_density.rust"
    )
    let bytes = [UInt8](try Data(contentsOf: fixture))
    let parser = try #require(m6LocalReferenceParser())
    let parseStarted = ContinuousClock.now
    let tree = try #require(parser.parse(bytes))
    let parseMS = m6Milliseconds(since: parseStarted)
    let baselineBytes = m6PhysicalFootprintBytes()
    let buildStarted = ContinuousClock.now

    let result = RustExtractor().localReferences(tree: tree, bytes: bytes)

    let buildMS = m6Milliseconds(since: buildStarted)
    let afterBytes = m6PhysicalFootprintBytes()
    let bindingCount = result.bindings.count
    let referenceCount = result.referencesByBinding.lazy.map(\.count).reduce(0, +)
    let indexedTokenCount = bindingCount + referenceCount
    let baselineMB = baselineBytes.map { Double($0) / 1_048_576 } ?? -1
    let afterMB = afterBytes.map { Double($0) / 1_048_576 } ?? -1

    #expect(bindingCount == 20_000)
    #expect(referenceCount == 35_000)
    print(String(
        format: "M6_LOCAL_REFERENCE_INDEX parseMS=%.3f buildMS=%.3f "
            + "baselineMB=%.3f afterMB=%.3f deltaMB=%.3f "
            + "bindings=%d references=%d tokens=%d",
        parseMS,
        buildMS,
        baselineMB,
        afterMB,
        afterMB - baselineMB,
        bindingCount,
        referenceCount,
        indexedTokenCount
    ))
}

private func m6LocalReferenceParser() -> Parser? {
    guard let language = tree_sitter_rust() else { return nil }
    return Parser(language: language)
}

private func m6Milliseconds(
    since start: ContinuousClock.Instant
) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

private func m6PhysicalFootprintBytes() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
}
