import AppKit
import CodeInsightAppModel
import CodeInsightCore
import CodeInsightEngine
import CodeInsightExact
import CodeInsightGit
import CodeInsightReaderCore
import CodeInsightReaderUI
import CoreText
import Darwin
import os
import PDFKit
import SwiftUI
import WebKit

extension AppDelegate {
    func measureRelationTiming(
        model: AppModel,
        controller: MainWindowController,
        offset: UInt32,
        direction: RelationTreeModel.Direction,
        timeout: TimeInterval
    ) -> (
        relationFirstActionableMS: Double,
        relationAllResultsMS: Double,
        relationFirstActionableKind: String,
        relationFirstActionableTitle: String,
        relationCandidateEdgeCount: Int
    ) {
        let previousGeneration = model.relationTree.generation
        let startedAt = ContinuousClock.now
        controller.selfTestReaderRelation(offset: offset, direction: direction)
        let deadline = ContinuousClock.now + .seconds(timeout)
        var firstMS = 0.0
        var firstKind = ""
        var firstTitle = ""
        var allResultsMS = 0.0
        while ContinuousClock.now < deadline {
            if model.relationTree.generation > previousGeneration {
                if firstMS == 0,
                   let first = firstActionableRelation(
                       model: model,
                       controller: controller
                   )
                {
                    firstMS = milliseconds(since: startedAt)
                    firstKind = first.kind
                    firstTitle = first.title
                }
                if firstMS > 0,
                   let children = model.relationTree.root?.children,
                   !children.contains(where: { $0.kind == .loading })
                {
                    allResultsMS = milliseconds(since: startedAt)
                    break
                }
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return (
            firstMS,
            allResultsMS,
            firstKind,
            firstTitle,
            model.relationTree.heuristicCandidateCount
        )
    }

    func exactRelationEdges(
        in model: AppModel
    ) -> [RelationTreeModel.Node] {
        guard let root = model.relationTree.root else { return [] }
        return relationEdgeNodes(in: root).filter { $0.badge == "Verified" }
    }

    func relationEdgeNodes(
        in root: RelationTreeModel.Node
    ) -> [RelationTreeModel.Node] {
        let children = root.children ?? []
        var rows: [RelationTreeModel.Node] = []
        for child in children {
            if child.kind == .edge {
                rows.append(child)
            } else {
                rows += (child.children ?? []).filter { $0.kind == .edge }
            }
        }
        return rows
    }

    private func firstActionableRelation(
        model: AppModel,
        controller: MainWindowController
    ) -> (kind: String, title: String)? {
        guard controller.selfTestRelationsTreeVisible,
              let root = model.relationTree.root
        else { return nil }
        let visibleRect = controller.selfTestRelationsVisibleRect
        let titles = controller.selfTestVisibleRelationEdgeTitles(inGroup: "")
        let frames = controller.selfTestVisibleRelationEdgeFrames(inGroup: "")
        let rows = root.children?.flatMap { child in
            child.kind == .edge
                ? [child]
                : (child.children ?? []).filter { $0.kind == .edge }
        } ?? []
        for (title, frame) in zip(titles, frames) {
            let visibleFrame = visibleRect.intersection(frame)
            guard frame.width > 0,
                  frame.height > 0,
                  visibleFrame.width > 0,
                  visibleFrame.height > 0,
                  let row = rows.first(where: {
                      $0.title == title && $0.target != nil
                  })
            else { continue }
            return (
                row.badge == "Verified" ? "exact" : "heuristic",
                title
            )
        }
        return nil
    }

    static func writeJSON(_ object: [String: Any]) {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
        }
    }

    static func exitSelfTest(
        channel: String,
        status: Int32
    ) -> Never {
        let marker = "SELF_TEST_FINISH"
            + " timestamp=\(Date().timeIntervalSince1970)"
            + " pid=\(getpid()) channel=\(channel) exit=\(status)\n"
        FileHandle.standardError.write(Data(marker.utf8))
        Darwin.exit(status)
    }
}

enum SelfTestBudgets {
    static let idleFootprintMB = 100.0
    // Current F0 control measured 48.7 MiB process-wide delta. 56 keeps
    // the old ~13% headroom and the historical 64 MiB injection is rejected.
    static let largeReferenceDeltaFootprintMB = 56.0
    static let regularFirstVisibleMS = 100.0
    static let hugeFirstVisibleMS = 2_500.0
    static let hugeStyledFragments = 500
    static let projectTreeVisibleMS = 1_000.0
    static let projectIndexReadyMS = 2_500.0
    static let snapshotFirstPaintMS = 1_000.0
}

func exactSelfTestGit(_ root: URL, _ arguments: String...) throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ExactSelfTestError.git(
            String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "git failed"
        )
    }
}

enum ExactSelfTestError: Error, LocalizedError {
    case fixture(String)
    case git(String)

    var errorDescription: String? {
        switch self {
        case .fixture(let detail): detail
        case .git(let detail): detail
        }
    }
}

func physicalFootprintBytes() -> UInt64? {
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

func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

@MainActor
func waitUntil(
    timeout: TimeInterval,
    condition: () -> Bool
) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return condition()
}

@MainActor
func pumpRunLoop() {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
}

func rustFiles(in nodes: [FileTreeNode]) -> [URL] {
    nodes.flatMap { node in
        if node.isDirectory { return rustFiles(in: node.children) }
        return LanguageMode.classify(path: node.url.path, language: .rust) != nil
            ? [node.url] : []
    }
}

@MainActor
func cachedBitmap(of view: NSView?) -> NSBitmapImageRep? {
    guard let view else { return nil }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return nil }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
}

@MainActor
func cachedPNG(of view: NSView?, path: String) -> (
    path: String, width: Int, height: Int, visiblePixels: Bool
)? {
    guard let bitmap = cachedBitmap(of: view) else { return nil }
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        return nil
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        return (
            path,
            bitmap.pixelsWide,
            bitmap.pixelsHigh,
            bookmarkBitmapHasVisiblePixels(bitmap)
        )
    } catch {
        return nil
    }
}

func bookmarkBitmapHasVisiblePixels(_ bitmap: NSBitmapImageRep) -> Bool {
    guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return false }
    let stepX = max(1, bitmap.pixelsWide / 64)
    let stepY = max(1, bitmap.pixelsHigh / 64)
    var reference: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)?
    for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            else { continue }
            let sample = (
                red: color.redComponent,
                green: color.greenComponent,
                blue: color.blueComponent,
                alpha: color.alphaComponent
            )
            if let reference {
                let delta = max(
                    abs(sample.red - reference.red),
                    abs(sample.green - reference.green),
                    abs(sample.blue - reference.blue),
                    abs(sample.alpha - reference.alpha)
                )
                if delta >= 0.05 { return true }
            } else {
                reference = sample
            }
        }
    }
    return false
}
