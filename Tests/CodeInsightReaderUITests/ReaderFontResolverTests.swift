import AppKit
import CodeInsightReaderCore
import CoreText
import Testing
@testable import CodeInsightReaderUI

@MainActor @Test
func readerFontResolverRestoresDefaultFeaturesAfterOff() {
    let resolver = ReaderFontResolver()
    let on = resolver.resolve(selection: .systemMonospaced, mode: .enabled, size: 13)
    let off = resolver.resolve(selection: .systemMonospaced, mode: .disabled, size: 13)
    let restored = resolver.resolve(selection: .systemMonospaced, mode: .fontDefault, size: 13)
    let onAgain = resolver.resolve(selection: .systemMonospaced, mode: .enabled, size: 13)
    #expect(on.featureRequests == ["calt": 1, "liga": 1, "clig": 1])
    #expect(off.featureRequests == ["calt": 0, "liga": 0, "clig": 0, "dlig": 0, "hlig": 0])
    #expect(off.attributes[.ligature] as? Int == 0)
    #expect(restored.attributes[.ligature] == nil)
    #expect(restored.featureRequests.isEmpty)
    #expect(restored.font == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
    #expect(onAgain.key == on.key)
    #expect(on.key != off.key)
    #expect(resolver.fontResolutionCount == 3)
    #expect(resolver.fontCacheHitCount == 1)
}

@MainActor @Test
func readerFontResolverPreservesUnavailableRequestAndReportsFallback() {
    let name = "Cairn-Deliberately-Missing-Font-81F345"
    let resolved = ReaderFontResolver().resolve(
        selection: .postScriptName(name), mode: .disabled, size: 15
    )
    #expect(resolved.requestedPostScriptName == name)
    #expect(resolved.actualPostScriptName != name)
    #expect(resolved.fallbackReason?.contains(name) == true)
    #expect(resolved.font.pointSize == 15)
    #expect(resolved.featureRequests["calt"] == 0)
}

@MainActor @Test
func readerFontResolverDerivesSameFamilyBeforeApplyingFeatures() throws {
    let selected = try #require(NSFont(name: "Menlo-Regular", size: 13))
    let resolved = ReaderFontResolver().resolve(
        selection: .postScriptName(selected.fontName), mode: .enabled,
        size: 16, weight: .semibold
    )
    #expect(resolved.font.familyName == selected.familyName)
    #expect(resolved.font.pointSize == 16)
    #expect(resolved.key.weight > 0)
    let settings = CTFontCopyFeatureSettings(resolved.font) as? [[String: Any]] ?? []
    // Core Text drops unsupported feature requests: Menlo has liga, but no calt.
    // Verify both our request and a supported feature retained by the derived font.
    #expect(resolved.featureRequests["calt"] == 1)
    #expect(settings.contains { ($0[kCTFontOpenTypeFeatureTag as String] as? String) == "liga"
        && ($0[kCTFontOpenTypeFeatureValue as String] as? Int) == 1 })
    let italic = try #require(NSFont(name: "Menlo-Italic", size: 13))
    let derivedItalic = ReaderFontResolver().resolve(
        selection: .postScriptName(italic.fontName), mode: .enabled,
        size: 16, weight: .semibold
    )
    #expect(derivedItalic.font.familyName == italic.familyName)
    #expect(derivedItalic.font.fontDescriptor.symbolicTraits.contains(.italic))
    #expect(derivedItalic.key.weight > 0)
    #expect(derivedItalic.featureRequests["calt"] == 1)
}

@MainActor @Test
func readerFontResolverBoundsCacheAndInvalidatesUnchangedRequests() {
    let resolver = ReaderFontResolver()
    let initial = resolver.resolve(selection: .systemMonospaced, mode: .enabled, size: 13)
    for index in 0..<300 {
        _ = resolver.resolve(
            selection: .systemMonospaced, mode: .enabled,
            size: 10 + CGFloat(index) / 64, weight: .regular
        )
    }
    #expect(resolver.cacheCount == resolver.cacheLimit)
    let resolutionCount = resolver.fontResolutionCount
    resolver.refresh()
    #expect(resolver.cacheCount == 0)
    let refreshed = resolver.resolve(selection: .systemMonospaced, mode: .enabled, size: 13)
    #expect(refreshed.key != initial.key)
    #expect(refreshed.key.fontEnvironmentRevision == initial.key.fontEnvironmentRevision + 1)
    #expect(resolver.fontResolutionCount == resolutionCount + 1)
    #expect(refreshed.font == initial.font)
}
