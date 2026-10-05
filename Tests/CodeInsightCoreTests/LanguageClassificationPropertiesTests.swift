import Foundation
import Testing
@testable import CodeInsightCore

// The pre-optimization implementation is deliberately kept as an independent oracle.
private func originalClassification(path: String, language: LanguageID) -> LanguageMode? {
    switch language {
    case .rust:
        guard URL(fileURLWithPath: path).pathExtension == "rs" else {
            return nil
        }
        return LanguageMode(language: .rust)
    case .python:
        guard URL(fileURLWithPath: path).pathExtension == "py" else {
            return nil
        }
        return LanguageMode(language: .python)
    case .typescript, .javascript:
        guard language == .typescript else { return nil }
        if path.hasSuffix(".ts")
            && !path.hasSuffix(".d.ts")
            && !path.hasSuffix(".mts")
            && !path.hasSuffix(".cts")
        {
            return LanguageMode(language: .typescript)
        }
        if path.hasSuffix(".tsx") {
            return LanguageMode(language: .typescript, variant: "tsx")
        }
        return nil
    }
}

@Test
func languageClassificationMatchesOriginalOnGeneratedPaths() {
    let languages: [LanguageID] = [.rust, .python, .typescript, .javascript]
    let stems = ["file", "file.test", ".hidden", "", "..", "源", "cafe\u{301}", "a b", "a%2Eb", "a#b"]
    let extensions = ["", ".", ".rs", ".RS", ".py", ".PY", ".pyi", ".ts", ".TS", ".tsx", ".d.ts", ".mts", ".cts", ".js"]
    let prefixes = ["", "/", "./", "../", "src/", "src/../", "src.rs/", "src.py/../nested/", "a//b/"]
    let suffixes = ["", "/", "//", "/.", "/.."]
    for stem in stems {
        for ext in extensions {
            for prefix in prefixes {
                for suffix in suffixes {
                    let path = prefix + stem + ext + suffix
                    for language in languages {
                        #expect(
                            LanguageMode.classify(path: path, language: language)
                                == originalClassification(path: path, language: language),
                            "path: \(path), language: \(language)"
                        )
                    }
                }
            }
        }
    }

    // Local deterministic generator keeps failures reproducible without adding a test-only type.
    var state: UInt64 = 0xC1A5_51F1_ED05
    func pick(_ values: [String]) -> String {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return values[Int(state >> 32) % values.count]
    }
    for sample in 0..<1_000 {
        let path = pick(prefixes) + pick(stems) + pick(extensions) + "/"
            + pick(prefixes) + pick(stems) + pick(extensions) + pick(suffixes)
        for language in languages {
            #expect(
                LanguageMode.classify(path: path, language: language)
                    == originalClassification(path: path, language: language),
                "seed C1A551F1ED05, sample \(sample), path: \(path), language: \(language)"
            )
        }
    }
}
