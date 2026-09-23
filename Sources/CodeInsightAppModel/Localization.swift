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

package var modelDisplayLanguage: String {
    Bundle.module.preferredLocalizations.first ?? "en"
}

func localized(_ key: String, language: String?) -> String {
    guard let language,
          let resources = Bundle.module.resourceURL,
          let bundle = Bundle(path: resources.appendingPathComponent("\(language).lproj").path)
    else { return localized(key) }
    return NSLocalizedString(key, bundle: bundle, comment: "")
}

func localizedFormat(_ key: String, language: String?, _ arguments: CVarArg...) -> String {
    let locale = language.map {
        Locale(identifier: $0 + "_" + (Locale.current.region?.identifier ?? "US"))
    } ?? localizationLocale
    return String(format: localized(key, language: language), locale: locale, arguments: arguments)
}
