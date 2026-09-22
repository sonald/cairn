import AppKit
import CoreText
import CryptoKit

// Run: swift scripts/ligature-font-probe.swift > .build/ligature-font-probe.json
// Independent Core Text evidence; actual Reader interaction is a separate gate.
let samples = ["!=", "->", "=>", "<=", ">=", "!==", "===", "::", "..", "...", "office ffi", "中文 👩🏽‍💻 e\u{301}\t!="]
let requests = CommandLine.arguments.dropFirst().isEmpty
    ? ["FiraCodeRoman-Regular", "JetBrainsMono-Regular", "__missing_ligature_font__"]
    : Array(CommandLine.arguments.dropFirst())
var reports: [[String: Any]] = []
for requested in requests {
    let base = NSFont(name: requested, size: 16) ?? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    let ctBase = CTFontCreateWithName(base.fontName as CFString, 16, nil)
    let url = CTFontCopyAttribute(ctBase, kCTFontURLAttribute) as? URL
    let bytes = url.flatMap { try? Data(contentsOf: $0) }
    var modes: [[String: Any]] = []
    for mode in ["default", "on", "off", "ligature-only-on", "ligature-only-off", "on-kern-zero", "on-kern-positive"] {
        let enabled = mode.hasPrefix("on")
        let tags = enabled ? ["calt", "liga", "clig"] : (mode == "off" ? ["calt", "liga", "clig", "dlig", "hlig"] : [])
        let features: [[String: Any]] = tags.map {
            [kCTFontOpenTypeFeatureTag as String: $0, kCTFontOpenTypeFeatureValue as String: enabled ? 1 : 0]
        }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(ctBase),
            [kCTFontFeatureSettingsAttribute: features] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 16, nil)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if mode != "default" { attributes[.ligature] = (enabled || mode == "ligature-only-on") ? 1 : 0 }
        if mode == "on-kern-zero" { attributes[.kern] = 0 }
        if mode == "on-kern-positive" { attributes[.kern] = 0.3 }
        var shapes: [[String: Any]] = []
        for sample in samples {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: sample, attributes: attributes))
            var runs: [[String: Any]] = []
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var advances = [CGSize](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                let actual = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                runs.append(["font": CTFontCopyPostScriptName(actual), "glyphs": glyphs,
                             "positions": positions.map { [$0.x, $0.y] }, "advances": advances.map { [$0.width, $0.height] }, "utf16Indices": indices])
            }
            shapes.append(["text": sample, "runs": runs])
        }
        modes.append(["mode": mode, "features": features, "shapes": shapes])
    }
    reports.append(["requested": requested, "actual": base.fontName, "fallback": base.fontName != requested,
                    "version": CTFontCopyName(ctBase, kCTFontVersionNameKey) as String? ?? "unknown",
                    "path": url?.path ?? "unavailable", "sha256": bytes.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "unavailable", "modes": modes])
}
let result: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString, "fontSize": 16, "reports": reports]
// A missing requested test font is BLOCKED, never a successful shaping test.
let blocked = reports.contains { ($0["fallback"] as? Bool == true) && ($0["requested"] as? String != "__missing_ligature_font__") }
for report in reports where report["fallback"] as? Bool == false {
    let modes = report["modes"] as! [[String: Any]]
    let shapes = modes.map { $0["shapes"] as! [[String: Any]] }
    // Same glyph count can still mean different forms: compare the complete run data.
    assert(NSDictionary(dictionary: shapes[0][0]) == NSDictionary(dictionary: shapes[1][0]))
    assert(NSDictionary(dictionary: shapes[1][0]) != NSDictionary(dictionary: shapes[2][0]))
}
let output = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(output)

if blocked { exit(2) }
