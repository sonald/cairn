// Real ReaderTextView timing for the card-animation question. Not part of the test suite:
// copy into Tests/CodeInsightReaderUITests/ and run
//   env CAIRN_CARD_PROBE=1 CAIRN_CARD_PROBE_OUT=<dir> swift test --filter zzCardCostProbe
import AppKit
import CodeInsightCore
import CodeInsightReaderCore
import Foundation
import Testing
@testable import CodeInsightReaderUI

@MainActor
private func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
}

@MainActor
private func ms(_ body: () -> Void) -> Double {
    let start = ContinuousClock.now
    body()
    let d = start.duration(to: .now).components
    return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
}

@MainActor
private func spin() {
    for _ in 0..<5 { RunLoop.main.run(mode: .default, before: Date()) }
}

@MainActor
@Test(arguments: [3_000, 50_001], [false, true])
func zzCardCostProbe(lineTarget: Int, wrap: Bool) async throws {
    guard ProcessInfo.processInfo.environment["CAIRN_CARD_PROBE"] == "1" else { return }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let all = try String(contentsOf: root.appendingPathComponent("fixtures/fold_perf.rs"), encoding: .utf8)
        .split(separator: "\n", omittingEmptySubsequences: false)
    // Cut at a module end so the prefix stays well-formed Rust.
    var cut = all.count
    if lineTarget < all.count, let end = all[lineTarget...].firstIndex(of: "}") { cut = end + 1 }
    let source = all[..<cut].joined(separator: "\n") + "\n"
    let fixture = "fold_perf.rs[..\(cut)]"
    let file = URL(fileURLWithPath: "/card-probe.rs")
    let plain = try DocumentLoader(source: { _ in Array(source.utf8) }).load(file: file).document
    let document = plain.foldRegions.isEmpty ? try DocumentLoader().loadSyntax(for: plain) : plain

    var settings = ReaderSettings()
    settings.wrapLines = wrap
    let reader = ReaderTextView(settings: settings)
    _ = NSApplication.shared
    let frame = NSRect(x: 80, y: 80, width: 1000, height: 800)
    let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let scroll = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
    scroll.hasVerticalScroller = true
    scroll.documentView = reader.view
    window.contentView = scroll
    reader.view.frame = scroll.contentView.bounds
    reader.configureGutter(in: scroll, lineNumbers: true)
    window.orderFront(nil)
    reader.display(document: document, fileURL: file)
    spin()

    // A medium block in the middle of the file, header revealed on screen.
    let lines = document.lineTable
    let middle = UInt32(document.bytes.count / 2)
    let fold = try #require(document.foldRegions
        .filter { $0.headerRange.lowerBound > middle }
        .first {
            let a = lines.lineColumn(at: $0.headerRange.lowerBound)?.line ?? 0
            let b = lines.lineColumn(at: $0.bodyRange.upperBound)?.line ?? 0
            return b - a >= 4 && b - a <= 80
        })
    reader.reveal(byteOffset: fold.headerRange.lowerBound)
    spin()
    window.displayIfNeeded()

    let manager = try #require(reader.view.textLayoutManager)
    // Fold toggle: one paragraph changes height, everything below shifts.
    var toggleSync: [Double] = []
    var toggleDeferred: [Double] = []
    for _ in 0..<20 {
        toggleSync.append(ms {
            _ = reader.toggleFold(id: fold.id)
            manager.textViewportLayoutController.layoutViewport()
            window.displayIfNeeded()
        })
        toggleDeferred.append(ms { spin(); window.displayIfNeeded() })
    }

    // Frame step: invalidate one mid-viewport fragment, relayout, redraw.
    var frameStep: [Double] = []
    for _ in 0..<60 {
        let controller = manager.textViewportLayoutController
        let viewport = try #require(controller.viewportRange)
        var fragments: [NSTextLayoutFragment] = []
        manager.enumerateTextLayoutFragments(from: viewport.location, options: []) {
            fragments.append($0)
            return fragments.count < 60
        }
        let target = try #require(fragments.dropFirst(fragments.count / 2).first)
        frameStep.append(ms {
            manager.invalidateLayout(for: target.rangeInElement)
            controller.layoutViewport()
            reader.view.needsDisplay = true
            window.displayIfNeeded()
        })
    }

    // Gap step: grow then shrink paragraph spacing under one mid-viewport
    // line in the real storage, 16pt per frame, and check the line below moves.
    let storage = try #require(reader.view.textStorage)
    let content = try #require(manager.textContentManager)
    var gapStep: [Double] = []
    var gapShiftErrors: [Double] = []
    do {
        let controller = manager.textViewportLayoutController
        let viewport = try #require(controller.viewportRange)
        var fragments: [NSTextLayoutFragment] = []
        manager.enumerateTextLayoutFragments(from: viewport.location, options: [.ensuresLayout]) {
            fragments.append($0)
            return fragments.count < 30
        }
        let target = fragments[fragments.count / 3]
        let start = content.offset(from: content.documentRange.location, to: target.rangeInElement.location)
        let range = (storage.string as NSString).paragraphRange(for: NSRange(location: start, length: 0))
        let below = NSMaxRange(range)
        func belowY() -> CGFloat? {
            guard let loc = content.location(content.documentRange.location, offsetBy: below) else { return nil }
            manager.ensureLayout(for: NSTextRange(location: loc))
            return manager.textLayoutFragment(for: loc)?.layoutFragmentFrame.minY
        }
        let base = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
            as? NSParagraphStyle) ?? NSParagraphStyle.default
        let y0 = try #require(belowY())
        let heights = Array(stride(from: 16.0, through: 240, by: 16)) + Array(stride(from: 224.0, through: 0, by: -16))
        for h in heights {
            let style = base.mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing = h
            gapStep.append(ms {
                storage.beginEditing()
                storage.addAttribute(.paragraphStyle, value: style, range: range)
                storage.endEditing()
                controller.layoutViewport()
                window.displayIfNeeded()
            })
            if let y = belowY() { gapShiftErrors.append(abs((y - y0) - (h - base.paragraphSpacing))) }
            if h == 240, let out = ProcessInfo.processInfo.environment["CAIRN_CARD_PROBE_OUT"],
               let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(out)/gap-\(cut)-wrap\(wrap).png"))
            }
        }
    }

    func summary(_ name: String, _ v: [Double]) -> String {
        String(format: "\"%@\":{\"median\":%.2f,\"p95\":%.2f,\"max\":%.2f,\"n\":%d}",
               name, percentile(v, 0.5), percentile(v, 0.95), v.max() ?? 0, v.count)
    }
    print("CARD-COST {\"fixture\":\"\(fixture)\",\"lines\":\(lines.lineStarts.count),\"wrap\":\(wrap),"
        + "\"foldLines\":\((lines.lineColumn(at: fold.bodyRange.upperBound)?.line ?? 0) - (lines.lineColumn(at: fold.headerRange.lowerBound)?.line ?? 0)),"
        + [summary("toggleSync", toggleSync), summary("toggleDeferred", toggleDeferred),
           summary("frameStep", frameStep), summary("gapStep", gapStep),
           summary("gapShiftErrorPt", gapShiftErrors)].joined(separator: ",") + "}")
}
