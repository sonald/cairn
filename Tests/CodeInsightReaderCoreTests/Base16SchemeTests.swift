@testable import CodeInsightReaderCore
import Foundation
import Testing

private let nordYAML = """
system: "base16"
name: "Nord"
author: "arcticicestudio"
variant: "dark"
palette:
  base00: "#2E3440"
  base01: "#3B4252"
  base02: "#434C5E"
  base03: "#4C566A"
  base04: "#D8DEE9"
  base05: "#E5E9F0"
  base06: "#ECEFF4"
  base07: "#8FBCBB"
  base08: "#BF616A"
  base09: "#D08770"
  base0A: "#EBCB8B"
  base0B: "#A3BE8C"
  base0C: "#88C0D0"
  base0D: "#81A1C1"
  base0E: "#B48EAD"
  base0F: "#5E81AC"
"""

/// A base24 scheme: same layout, colors up to base17.
private let base24YAML = nordYAML
    .replacingOccurrences(of: "system: \"base16\"", with: "system: \"base24\"")
    + "\n  base10: \"#000000\"\n  base17: \"#FFFFFF\"\n"

@Test
func base16SchemeReadsPublishedFilesWithAndWithoutTrailingComments() throws {
    let nord = try Base16Scheme(yaml: nordYAML)
    #expect(nord.name == "Nord")
    #expect(nord.variant == .dark)
    #expect(nord.base.count == 16)
    #expect(nord.base[0x00] == 0x2E3440)
    #expect(nord.base[0x0F] == 0x5E81AC)

    let latte = try Base16Scheme(yaml: """
    # A scheme as tinted-theming publishes it.
    system: "base16"
    name: "Catppuccin Latte"
    author: "https://github.com/catppuccin/catppuccin"
    variant: "light"
    palette:
      base00: "#eff1f5" # base
      base01: "#e6e9ef" # mantle
      base02: "#ccd0da" # surface0
      base03: "#bcc0cc" # surface1
      base04: "#acb0be" # surface2
      base05: "#4c4f69" # text
      base06: "#dc8a78" # rosewater
      base07: "#7287fd" # lavender
      base08: "#d20f39" # red
      base09: "#fe640b" # peach
      base0A: "#df8e1d" # yellow
      base0B: "#40a02b" # green
      base0C: "#179299" # teal
      base0D: "#1e66f5" # blue
      base0E: "#8839ef" # mauve
      base0F: "#dd7878" # flamingo
    """)
    #expect(latte.name == "Catppuccin Latte")
    #expect(latte.variant == .light)
    #expect(latte.base[0x00] == 0xEFF1F5)
    #expect(latte.base[0x0A] == 0xDF8E1D)
}

@Test
func base16SchemeInfersVariantAndRejectsIncompleteOrForeignFiles() throws {
    let noVariant = nordYAML.replacingOccurrences(of: "variant: \"dark\"\n", with: "")
    #expect(try Base16Scheme(yaml: noVariant).variant == .dark)
    let lightNoVariant = noVariant.replacingOccurrences(of: "#2E3440", with: "#FAFAFA")
    #expect(try Base16Scheme(yaml: lightNoVariant).variant == .light)

    let missing = nordYAML.replacingOccurrences(of: "  base0C: \"#88C0D0\"\n", with: "")
    #expect(throws: Base16Scheme.LoadError.missingColor("base0C")) {
        try Base16Scheme(yaml: missing)
    }
    #expect(throws: Base16Scheme.LoadError.notBase16) { try Base16Scheme(yaml: base24YAML) }
    #expect(throws: Base16Scheme.LoadError.notBase16) { try Base16Scheme(yaml: "\u{0}\u{1}::\n\"#") }
}

@Test
func userThemeFolderLoadsGoodFilesAndSkipsBadOnes() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("Base16SchemeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let good = "good-\(UUID().uuidString)"
    try nordYAML.write(to: folder.appendingPathComponent("\(good).yaml"), atomically: true, encoding: .utf8)
    let eightColors = nordYAML.split(separator: "\n").prefix(13).joined(separator: "\n")
    try eightColors.write(to: folder.appendingPathComponent("bad.yaml"), atomically: true, encoding: .utf8)
    try Data([0xFF, 0xFE, 0x00, 0x9F]).write(to: folder.appendingPathComponent("garbage.yaml"))
    try base24YAML.write(to: folder.appendingPathComponent("base24.yaml"), atomically: true, encoding: .utf8)

    ThemeCatalog.reloadUserThemes(in: folder)
    defer { ThemeCatalog.reloadUserThemes(in: folder.appendingPathComponent("missing")) }
    let user = ThemeCatalog.entries.filter { $0.source == .user }
    #expect(user.map(\.theme.id) == ["base16:\(good)"])
    #expect(user.first?.name == "Nord")
    #expect(user.first?.variant == .dark)
    #expect(ThemeCatalog.entry(for: .init(id: "base16:bad")) == nil)
}
