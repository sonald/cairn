// Prototype: base16 (16 colors) -> Cairn ReaderTheme roles, checked against the
// contrast pairs in ReaderSettingsTests.readerThemePaletteMeetsRequiredContrastRatios.
// Usage: swift mapping-proto.swift base16/*.yaml
import Foundation

struct Scheme {
    var name = "", variant = ""
    var base: [String: UInt32] = [:]
    subscript(_ k: String) -> UInt32 { base[k]! }
}

func parse(_ path: String) -> Scheme {
    var s = Scheme()
    for raw in try! String(contentsOfFile: path, encoding: .utf8).split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") || line.isEmpty { continue }
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        // Value is either a quoted scalar (take the quoted part, drop any trailing comment)
        // or a bare scalar up to the first ` #`.
        if value.hasPrefix("\"") {
            let inner = value.dropFirst()
            value = String(inner[..<(inner.firstIndex(of: "\"") ?? inner.endIndex)])
        } else if let hash = value.range(of: " #") {
            value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if key == "name" { s.name = value }
        else if key == "variant" { s.variant = value }
        else if key.hasPrefix("base"), let v = UInt32(value.replacingOccurrences(of: "#", with: ""), radix: 16) { s.base[key] = v }
    }
    if s.variant.isEmpty { s.variant = lum(s["base00"]) < 0.5 ? "dark" : "light" }
    return s
}

func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
func lum(_ rgb: UInt32) -> Double {
    0.2126 * lin(Double((rgb >> 16) & 0xff) / 255) + 0.7152 * lin(Double((rgb >> 8) & 0xff) / 255) + 0.0722 * lin(Double(rgb & 0xff) / 255)
}
func contrast(_ a: UInt32, _ b: UInt32) -> Double { let l = max(lum(a), lum(b)), d = min(lum(a), lum(b)); return (l + 0.05) / (d + 0.05) }
func blend(_ fg: UInt32, over bg: UInt32, _ alpha: Double) -> UInt32 {
    func ch(_ s: Int) -> UInt32 { let f = Double((fg >> s) & 0xff), b = Double((bg >> s) & 0xff); return UInt32((f * alpha + b * (1 - alpha)).rounded()) }
    return ch(16) << 16 | ch(8) << 8 | ch(0)
}
func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }

/// Blend `color` toward `target` (the text color of the variant) just enough to
/// reach `min` contrast against `bg`. Keeps hue, shifts tone; this is what the
/// hand-tuned Cairn palettes do by eye.
func ensureContrast(_ color: UInt32, against bg: UInt32, min: Double, toward target: UInt32) -> UInt32 {
    if contrast(color, bg) >= min { return color }
    var lo = 0.0, hi = 1.0
    for _ in 0..<16 { let mid = (lo + hi) / 2; if contrast(blend(target, over: color, mid), bg) >= min { hi = mid } else { lo = mid } }
    return blend(target, over: color, hi)
}
var adjustments: [String] = []
func text(_ name: String, _ color: UInt32, on bg: UInt32, min: Double, fg: UInt32) -> UInt32 {
    let out = ensureContrast(color, against: bg, min: min, toward: fg)
    if out != color { adjustments.append("\(name) \(hex(color))→\(hex(out))") }
    return out
}

/// The mapping under test. `quiet` only changes syntax roles.
struct Palette { var roles: [(String, UInt32)] = []; mutating func set(_ n: String, _ v: UInt32) { roles.append((n, v)) }; subscript(_ n: String) -> UInt32 { roles.first { $0.0 == n }!.1 } }

func map(_ s: Scheme, quiet: Bool) -> Palette {
    let dark = s.variant == "dark"
    let bg = s["base00"], fg = s["base05"], chrome = s["base01"]
    // Toning target: the strongest text color the scheme offers (Solarized's
    // base05 is only 4.4:1 on its own chrome; Nord's base07 is a cyan).
    let strong = ["base05", "base06", "base07"].map { s[$0] }.max { contrast($0, bg) < contrast($1, bg) }!
    let soft = dark ? 0.16 : 0.14          // accent-over-background fills
    var p = Palette()
    p.set("background", bg)
    p.set("foreground", fg)
    // Grayscale roles derived from fg/bg, not from base01–04: those steps are
    // not monotonic in every scheme (Nord base04 is light).
    p.set("lineNumber", text("lineNumber", blend(fg, over: bg, 0.55), on: bg, min: 3.0, fg: strong))
    p.set("currentLine", blend(fg, over: bg, dark ? 0.06 : 0.05))
    p.set("chrome", chrome)
    p.set("chromeHeader", s["base02"])
    p.set("chromeDivider", blend(fg, over: chrome, 0.18))
    p.set("chromeSelection", blend(s["base0D"], over: chrome, soft + 0.06))
    p.set("chromeSecondary", text("chromeSecondary", fg, on: chrome, min: 4.5, fg: dark ? 0xFFFFFF : 0x000000))
    p.set("chromeTertiary", text("chromeTertiary", blend(fg, over: chrome, 0.7), on: chrome, min: 3.0, fg: strong))
    p.set("chipBackground", s["base02"])
    p.set("chipForeground", fg)
    p.set("accent", s["base0D"])
    // Semantic text roles: an accent, toned toward the text color until it reads
    // on chrome and on its own soft fill (both 4.5:1, as the built-ins promise).
    func semantic(_ name: String, _ key: String, soft softName: String) {
        var c = text(name, s[key], on: chrome, min: 4.5, fg: strong)
        let fill = blend(c, over: bg, soft)
        c = text(name, c, on: fill, min: 4.5, fg: strong)
        p.set(name, c); p.set(softName, fill)
    }
    semantic("verified", "base0B", soft: "mossSoft")
    semantic("inferred", "base0D", soft: "slateSoft")
    semantic("unresolved", "base08", soft: "rustSoft")
    semantic("warning", "base0A", soft: "amberSoft")
    semantic("hist", "base09", soft: "histSoft")
    p.set("warningBorder", s["base09"]); p.set("amberMark", s["base09"])
    p.set("occurrence", blend(s["base0A"], over: bg, soft + 0.06)); p.set("overviewOccurrence", s["base0A"])
    p.set("histReader", blend(s["base09"], over: bg, 0.05))
    // Highlight slots: stronger fills than the semantic softs so six of them stay
    // apart; a scheme that reuses one accent for two sources (Rosé Pine 09 == 0E)
    // gets base0F for the later slot.
    var slotSources: [UInt32] = []
    for k in ["base0C", "base0E", "base0B", "base08", "base0D", "base09"] {
        slotSources.append(slotSources.contains(s[k]) ? s["base0F"] : s[k])
    }
    for (i, c) in slotSources.enumerated() {
        p.set("slot\(i + 1)", blend(c, over: bg, dark ? 0.40 : 0.30)); p.set("overview\(i + 1)", c)
    }
    for (i, k) in ["base0D", "base0E", "base0C", "base09"].enumerated() { p.set("query\(i)", s[k]) }
    p.set("diffAdded", s["base0B"]); p.set("diffRemoved", s["base08"]); p.set("diffChanged", s["base0A"])
    // Syntax: every text color reads at 3:1 on the background.
    func syn(_ name: String, _ c: UInt32) { p.set(name, text(name, c, on: bg, min: 3.0, fg: strong)) }
    syn("comment", contrast(s["base03"], bg) >= 3.0 ? s["base03"] : blend(fg, over: bg, 0.6))
    syn("keyword", s["base0E"]); syn("string", s["base0B"]); syn("number", s["base09"]); syn("macro", s["base0E"])
    if quiet {
        syn("functionName", s["base06"]); p.set("functionCall", fg); p.set("property", fg); p.set("parameter", fg); p.set("localBinding", fg)
        syn("typeName", s["base0D"]); syn("declarationTitle", s["base0D"]); syn("enumMember", s["base0D"]); p.set("declarationEmphasis", fg)
    } else {
        syn("functionName", s["base0D"]); syn("functionCall", s["base0D"]); syn("property", s["base08"]); syn("parameter", s["base08"]); p.set("localBinding", fg)
        syn("typeName", s["base0A"]); syn("declarationTitle", s["base0A"]); syn("enumMember", s["base0A"]); p.set("declarationEmphasis", fg)
    }
    return p
}

let checks: [(String, String, Double)] = [
    ("foreground", "background", 4.5), ("chromeSecondary", "chrome", 4.5), ("verified", "chrome", 4.5), ("verified", "mossSoft", 4.5),
    ("inferred", "chrome", 4.5), ("inferred", "slateSoft", 4.5), ("unresolved", "chrome", 4.5), ("unresolved", "rustSoft", 4.5),
    ("warning", "chrome", 4.5), ("warning", "amberSoft", 4.5), ("hist", "histSoft", 4.5), ("lineNumber", "background", 3.0), ("chromeTertiary", "chrome", 3.0),
]
let syntax = ["comment", "keyword", "string", "number", "functionName", "typeName", "property", "macro"]

var failures = 0
for path in CommandLine.arguments.dropFirst() {
    let s = parse(path)
    for quiet in [true, false] {
        let p = map(s, quiet: quiet)
        var bad: [String] = []
        for (f, b, min) in checks { let r = contrast(p[f], p[b]); if r < min { bad.append("\(f)/\(b)=\(String(format: "%.2f", r))<\(min)") } }
        for n in syntax { let r = contrast(p[n], p["background"]); if r < 3.0 { bad.append("\(n)/bg=\(String(format: "%.2f", r))<3.0") } }
        // Slot fills must stay visibly different from background and from each other.
        for i in 1...6 { let r = contrast(p["slot\(i)"], p["background"]); if r < 1.15 { bad.append("slot\(i)/bg=\(String(format: "%.2f", r))<1.15") } }
        let tag = quiet ? "quiet" : "full "
        if quiet, !adjustments.isEmpty { print("  toned: " + adjustments.joined(separator: ", ")) }
        if quiet {
            // Slot fills must be distinguishable from each other: report the closest pair (RGB distance, 0–441).
            func dist(_ a: UInt32, _ b: UInt32) -> Double {
                let d = [16, 8, 0].map { Double(Int((a >> $0) & 0xff) - Int((b >> $0) & 0xff)) }
                return (d[0] * d[0] + d[1] * d[1] + d[2] * d[2]).squareRoot()
            }
            var closest = (999.0, "")
            for i in 1...6 { for j in i..<6 { let d = dist(p["slot\(i)"], p["slot\(j + 1)"]); if d < closest.0 { closest = (d, "slot\(i)/slot\(j + 1)") } } }
            print("  slots: closest \(closest.1) dist=\(Int(closest.0)); base0F=\(hex(s["base0F"])) base09=\(hex(s["base09"]))")
        }
        adjustments = []
        if bad.isEmpty { print("PASS \(tag) \(s.name) (\(s.variant))") } else { failures += bad.count; print("FAIL \(tag) \(s.name) (\(s.variant)): " + bad.joined(separator: ", ")) }
    }
}
print(failures == 0 ? "ALL PASS" : "\(failures) failing pairs")
