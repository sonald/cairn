import Foundation
import CodeInsightAppModel

/// Resolve text in this target's SwiftPM resource bundle, including in Cairn.app.
func localized(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "")
}

// Plural rules follow the UI language; regional number conventions stay local.
private let localizationLocale = Locale(identifier:
    (Bundle.module.preferredLocalizations.first ?? "en")
        + "_" + (Locale.current.region?.identifier ?? "US"))

func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key), locale: localizationLocale, arguments: arguments)
}

/// Captured role/reason identifiers stay stable across language changes.
func localizedReadingSetText(_ stored: String) -> String {
    switch stored {
    case "CALL": localized("relation.role.call")
    case "DEFINITION": localized("relation.role.definition")
    case "IMPLEMENTATION": localized("relation.role.implementation")
    case "INFERRED CALLER": localized("relation.role.inferredCaller")
    case "REFERENCE": localized("relation.role.reference")
    case "VERIFIED CALLER": localized("relation.role.verifiedCaller")
    case "display cap (50 excerpts)": localized("relation.skip.cap")
    case "recorded excerpt could not be frozen": localized("relation.skip.freeze")
    case "recorded source is unreadable": localized("relation.skip.source")
    case "recorded source language is unsupported": localized("relation.skip.language")
    case "relation evidence is unavailable": localized("relation.skip.evidence")
    default: readingSetDisplayText(stored)
    }
}
