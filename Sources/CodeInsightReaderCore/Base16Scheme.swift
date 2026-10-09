import Foundation

/// A tinted-theming base16 scheme read from its YAML file as published.
///
/// Only the flat subset those files use is understood: top-level
/// `key: "value"` lines and the indented `baseXX: "#rrggbb"` lines under
/// `palette:`. Values may be quoted and may carry a trailing `# comment`.
public struct Base16Scheme: Equatable, Sendable {
    public enum LoadError: Error, Equatable {
        case notBase16
        case missingColor(String)
    }

    public let name: String
    public let variant: ThemePalette.Variant
    /// base00 ... base0F.
    let base: [UInt32]

    public static func load(contentsOf url: URL) throws -> Base16Scheme {
        try Base16Scheme(yaml: String(contentsOf: url, encoding: .utf8))
    }

    public init(yaml: String) throws {
        var fields: [String: String] = [:]
        var colors = [UInt32?](repeating: nil, count: 16)
        for raw in yaml.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                let inner = value.dropFirst()
                value = String(inner[..<(inner.firstIndex(of: "\"") ?? inner.endIndex)])
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            if key.count == 6, key.lowercased().hasPrefix("base"),
               let index = Int(key.dropFirst(4), radix: 16) {
                let hex = value.hasPrefix("#") ? value.dropFirst() : Substring(value)
                if hex.count == 6, let rgb = UInt32(hex, radix: 16) { colors[index] = rgb }
            } else {
                fields[key] = value
            }
        }
        guard fields["system"] == "base16" else { throw LoadError.notBase16 }
        if let missing = colors.firstIndex(of: nil) {
            throw LoadError.missingColor(String(format: "base%02X", missing))
        }
        base = colors.map { $0! }
        name = fields["name"] ?? ""
        variant = ThemePalette.Variant(rawValue: fields["variant"]?.lowercased() ?? "")
            ?? (relativeLuminance(base[0x00]) < 0.5 ? .dark : .light)
    }
}

// MARK: - Mapping

extension ThemePalette {
    /// Maps the 16 scheme colors onto every Cairn role. Text roles are toned
    /// toward the scheme's strongest text color until they reach the contrast
    /// the built-in themes promise. `quiet` changes syntax roles only.
    public init(scheme: Base16Scheme, quiet: Bool) {
        let b = scheme.base
        let dark = scheme.variant == .dark
        let bg = b[0x00], fg = b[0x05], chrome = b[0x01]
        // Solarized's base05 is only 4.4:1 on its own chrome; Nord's base07 is cyan.
        let strong = [b[0x05], b[0x06], b[0x07]].max { contrast($0, bg) < contrast($1, bg) }!
        let soft = dark ? 0.16 : 0.14
        func text(_ color: UInt32, on background: UInt32, _ minimum: Double) -> UInt32 {
            tone(color, on: background, minimum: minimum, toward: strong)
        }
        func syntax(_ color: UInt32) -> UInt32 { text(color, on: bg, 3.0) }
        /// A status color that reads on chrome and on its own soft fill.
        func semantic(_ accent: UInt32) -> (text: UInt32, fill: UInt32) {
            let onChrome = text(accent, on: chrome, 4.5)
            let fill = blend(onChrome, over: bg, soft)
            return (text(onChrome, on: fill, 4.5), fill)
        }
        let verified = semantic(b[0x0B])
        let inferred = semantic(b[0x0D])
        let unresolved = semantic(b[0x08])
        let warning = semantic(b[0x0A])
        // base0F is unstable across schemes (blue in Nord, gray in Rosé Pine).
        let hist = semantic(b[0x09])
        // A scheme that reuses one accent for two slots gets base0F for the later one.
        var slotSources: [UInt32] = []
        for index in [0x0C, 0x0E, 0x0B, 0x08, 0x0D, 0x09] {
            slotSources.append(slotSources.contains(b[index]) ? b[0x0F] : b[index])
        }
        let builtIn: ThemePalette = dark ? .dark : .light
        let commentSource = contrast(b[0x03], bg) >= 3.0 ? b[0x03] : blend(fg, over: bg, 0.6)
        self.init(
            variant: scheme.variant,
            background: bg,
            foreground: fg,
            lineNumber: text(blend(fg, over: bg, 0.55), on: bg, 3.0),
            currentLine: blend(fg, over: bg, dark ? 0.06 : 0.05),
            occurrence: blend(b[0x0A], over: bg, soft + 0.06),
            keyword: syntax(b[0x0E]),
            comment: syntax(commentSource),
            string: syntax(b[0x0B]),
            number: syntax(b[0x09]),
            functionName: syntax(quiet ? b[0x06] : b[0x0D]),
            declarationTitle: syntax(quiet ? b[0x0D] : b[0x0A]),
            functionCall: quiet ? fg : syntax(b[0x0D]),
            declarationEmphasis: fg,
            typeName: syntax(quiet ? b[0x0D] : b[0x0A]),
            property: quiet ? fg : syntax(b[0x08]),
            parameter: quiet ? fg : syntax(b[0x08]),
            macro: syntax(b[0x0E]),
            enumMember: syntax(quiet ? b[0x0D] : b[0x0A]),
            localBinding: fg,
            diffAdded: b[0x0B],
            diffRemoved: b[0x08],
            diffChanged: b[0x0A],
            highlights: slotSources.map { blend($0, over: bg, dark ? 0.40 : 0.30) },
            overviewHighlights: slotSources,
            overviewOccurrence: b[0x0A],
            queryConditions: [b[0x0D], b[0x0E], b[0x0C], b[0x09]],
            chrome: chrome,
            chromeHeader: b[0x02],
            chromeDivider: blend(fg, over: chrome, 0.18),
            chromeSelection: blend(b[0x0D], over: chrome, soft + 0.06),
            accent: b[0x0D],
            chromeSecondary: tone(fg, on: chrome, minimum: 4.5, toward: dark ? 0xFFFFFF : 0x000000),
            chromeTertiary: text(blend(fg, over: chrome, 0.7), on: chrome, 3.0),
            chipBackground: b[0x02],
            chipForeground: fg,
            verified: verified.text,
            inferred: inferred.text,
            unresolved: unresolved.text,
            unresolvedBorder: unresolved.text,
            warning: warning.text,
            warningBorder: b[0x09],
            amberMark: b[0x09],
            amberSoft: warning.fill,
            hist: hist.text,
            histSoft: hist.fill,
            histReader: blend(b[0x09], over: bg, 0.05),
            mossSoft: verified.fill,
            slateSoft: inferred.fill,
            rustSoft: unresolved.fill,
            warningFillAlpha: builtIn.warningFillAlpha,
            primarySelectionFillAlpha: builtIn.primarySelectionFillAlpha,
            verifiedFillAlpha: builtIn.verifiedFillAlpha,
            inferredFillAlpha: builtIn.inferredFillAlpha
        )
    }
}

// MARK: - Color math (sRGB, WCAG relative luminance)

func relativeLuminance(_ rgb: UInt32) -> Double {
    func linear(_ shift: UInt32) -> Double {
        let value = Double((rgb >> shift) & 0xff) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
}

func contrast(_ first: UInt32, _ second: UInt32) -> Double {
    let a = relativeLuminance(first), b = relativeLuminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// `color` at `alpha` over `background`, interpolated per sRGB channel.
func blend(_ color: UInt32, over background: UInt32, _ alpha: Double) -> UInt32 {
    func channel(_ shift: UInt32) -> UInt32 {
        let top = Double((color >> shift) & 0xff), bottom = Double((background >> shift) & 0xff)
        return UInt32((top * alpha + bottom * (1 - alpha)).rounded())
    }
    return channel(16) << 16 | channel(8) << 8 | channel(0)
}

/// Blends `color` toward `target` just enough to reach `minimum` contrast on
/// `background`; keeps the hue as far as the contrast allows.
func tone(_ color: UInt32, on background: UInt32, minimum: Double, toward target: UInt32) -> UInt32 {
    if contrast(color, background) >= minimum { return color }
    var low = 0.0, high = 1.0
    for _ in 0..<16 {
        let mid = (low + high) / 2
        if contrast(blend(target, over: color, mid), background) >= minimum { high = mid } else { low = mid }
    }
    return blend(target, over: color, high)
}
