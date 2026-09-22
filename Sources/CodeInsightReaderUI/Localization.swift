import Foundation

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
