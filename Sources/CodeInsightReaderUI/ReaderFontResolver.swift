import AppKit
import CodeInsightReaderCore
import CoreText

extension Notification.Name {
    package static let readerFontEnvironmentDidChange = Notification.Name(
        "ReaderFontEnvironmentDidChange"
    )
}

package struct ResolvedFontKey: Hashable {
    package let postScriptName: String
    package let size: CGFloat
    package let weight: Double
    package let variations: [Int: Double]
    package let featureRequests: [String: Int]
    package let fontEnvironmentRevision: UInt64
}

package struct ResolvedCodeFont {
    package let font: NSFont
    package let key: ResolvedFontKey
    package let requestedPostScriptName: String?
    package let fallbackReason: String?
    package let attributes: [NSAttributedString.Key: Any]
    package var actualPostScriptName: String { key.postScriptName }
    package var featureRequests: [String: Int] { key.featureRequests }
}

/// Shared by code reading surfaces; stores fonts only, never documents or views.
@MainActor
package final class ReaderFontResolver {
    package static let shared = ReaderFontResolver()
    package let cacheLimit = 128
    package private(set) var fontEnvironmentRevision: UInt64 = 0
    package private(set) var fontResolutionMilliseconds = 0.0
    package private(set) var fontResolutionCount = 0
    package private(set) var fontCacheHitCount = 0
    package var cacheCount: Int { cache.count }

    private struct Request: Hashable {
        let selection: CodeFontSelection
        let mode: CodeLigatureMode
        let size: CGFloat
        let weight: CGFloat
    }

    private var cache: [Request: ResolvedCodeFont] = [:]
    private var insertionOrder: [Request] = []
    private var availableNames: Set<String>

    package init() {
        availableNames = Self.installedNames()
    }

    /// Force a refresh for explicit requests and font-registration notifications,
    /// including replacements whose PostScript names have not changed.
    package func refresh() {
        availableNames = Self.installedNames()
        cache.removeAll(keepingCapacity: true)
        insertionOrder.removeAll(keepingCapacity: true)
        fontEnvironmentRevision &+= 1
        NotificationCenter.default.post(name: .readerFontEnvironmentDidChange, object: self)
    }

    package func refreshIfNeeded() {
        if Self.installedNames() != availableNames { refresh() }
    }

    package func resolve(
        theme: ReaderTheme,
        size: CGFloat? = nil,
        weight: NSFont.Weight = .regular
    ) -> ResolvedCodeFont {
        resolve(
            selection: theme.codeFont, mode: theme.codeLigatures,
            size: size ?? theme.fontSize, weight: weight
        )
    }

    package func resolve(
        selection: CodeFontSelection,
        mode: CodeLigatureMode,
        size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> ResolvedCodeFont {
        let size = size.isFinite && size > 0 ? max(1.0 / 64, (size * 64).rounded() / 64) : 13
        let weight = NSFont.Weight(rawValue: weight.rawValue.isFinite
            ? min(1, max(-1, weight.rawValue)) : 0)
        let request = Request(selection: selection, mode: mode, size: size, weight: weight.rawValue)
        if let result = cache[request] {
            fontCacheHitCount += 1
            return result
        }
        let started = ContinuousClock.now
        defer {
            let duration = started.duration(to: .now).components
            fontResolutionMilliseconds += Double(duration.seconds) * 1000
                + Double(duration.attoseconds) / 1e15
        }
        fontResolutionCount += 1

        var requestedName: String?
        var fallback: String?
        var base: NSFont
        switch selection {
        case .systemMonospaced:
            base = .monospacedSystemFont(ofSize: size, weight: weight)
        case .postScriptName(let name):
            requestedName = name
            if let selected = NSFont(name: name, size: size) {
                base = selected
                if weight != .regular, let family = selected.familyName {
                    var attributes = selected.fontDescriptor.fontAttributes
                    attributes.removeValue(forKey: .name)
                    attributes.removeValue(forKey: .visibleName)
                    attributes[.family] = family
                    var traits = attributes[.traits] as? [NSFontDescriptor.TraitKey: Any] ?? [:]
                    traits[.weight] = weight.rawValue
                    attributes[.traits] = traits
                    if let derived = NSFont(descriptor: NSFontDescriptor(fontAttributes: attributes), size: size),
                       derived.familyName == family {
                        base = derived
                        let actual = (CTFontCopyTraits(derived) as NSDictionary)[kCTFontWeightTrait] as? NSNumber
                        if abs((actual?.doubleValue ?? 0) - Double(weight.rawValue)) > 0.01 {
                            fallback = "Using the nearest available weight in \(family)."
                        }
                    } else {
                        fallback = "Requested weight unavailable; using \(selected.fontName)."
                    }
                }
            } else {
                base = .monospacedSystemFont(ofSize: size, weight: weight)
                fallback = "Requested font \(name) is unavailable; using the system monospaced font."
            }
        }

        let features: [String: Int]
        switch mode {
        case .fontDefault: features = [:]
        case .enabled: features = ["calt": 1, "liga": 1, "clig": 1]
        case .disabled: features = ["calt": 0, "liga": 0, "clig": 0, "dlig": 0, "hlig": 0]
        }
        if !features.isEmpty {
            let descriptor = CTFontCopyFontDescriptor(base)
            var settings = CTFontDescriptorCopyAttribute(descriptor, kCTFontFeatureSettingsAttribute)
                as? [[String: Any]] ?? []
            settings.removeAll { item in
                guard let tag = item[kCTFontOpenTypeFeatureTag as String] as? String else { return false }
                return features[tag] != nil
            }
            settings += features.keys.sorted().map {
                [kCTFontOpenTypeFeatureTag as String: $0,
                 kCTFontOpenTypeFeatureValue as String: features[$0]!]
            }
            let configured = CTFontDescriptorCreateCopyWithAttributes(
                descriptor, [kCTFontFeatureSettingsAttribute: settings] as CFDictionary
            )
            base = CTFontCreateWithFontDescriptor(configured, size, nil) as NSFont
        }
        let variations = CTFontCopyVariation(base) as? [NSNumber: NSNumber] ?? [:]
        let traits = CTFontCopyTraits(base) as NSDictionary
        let key = ResolvedFontKey(
            postScriptName: base.fontName, size: base.pointSize,
            weight: (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0,
            variations: Dictionary(uniqueKeysWithValues: variations.map { ($0.key.intValue, $0.value.doubleValue) }),
            featureRequests: features, fontEnvironmentRevision: fontEnvironmentRevision
        )
        var attributes: [NSAttributedString.Key: Any] = [.font: base]
        if mode != .fontDefault { attributes[.ligature] = mode == .enabled ? 1 : 0 }
        let result = ResolvedCodeFont(
            font: base, key: key, requestedPostScriptName: requestedName,
            fallbackReason: fallback, attributes: attributes
        )
        if cache.count == cacheLimit { cache.removeValue(forKey: insertionOrder.removeFirst()) }
        insertionOrder.append(request)
        cache[request] = result
        return result
    }

    private static func installedNames() -> Set<String> {
        Set(CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? [])
    }
}
