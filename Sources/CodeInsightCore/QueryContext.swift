import Foundation

public struct AnalysisProfileID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public static func derived(
        language: LanguageID,
        projectUnitName: String,
        configFingerprint: String,
        environmentFingerprint: String,
        featureSelection: FeatureSelection
    ) -> AnalysisProfileID {
        // Cross-language contract: TS/Python must copy this exact v1 framing.
        // Changing it changes profile identity for every supported language.
        let fields = [
            "codeinsight.analysis-profile.v1",
            language.profileIdentityName,
            projectUnitName,
            configFingerprint.lowercased(),
            environmentFingerprint.lowercased(),
            featureSelection.rawValue,
        ]
        var canonical: [UInt8] = []
        for field in fields {
            let value = Array(
                field.precomposedStringWithCanonicalMapping.utf8
            )
            canonical += Array(String(value.count).utf8)
            canonical.append(UInt8(ascii: ":"))
            canonical += value
            canonical.append(UInt8(ascii: "\n"))
        }
        let bytes = ContentID.sha256(of: canonical).bytes
        return AnalysisProfileID(rawValue: UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )))
    }
}

public enum TrustMode: Sendable {
    case safe
    case trusted
}

public enum FeatureSelection: String, Hashable, Sendable {
    case defaultFeatures
    case allFeatures
    case noDefaultFeatures
}

public struct AnalysisProfile: Sendable {
    public let id: AnalysisProfileID
    public let language: LanguageID
    public let projectRoot: PathID
    /// Rust package/workspace name; TS uses a tsconfig path and Python a venv ID.
    public let projectUnitName: String
    public let configFingerprint: String
    public let environmentFingerprint: String
    public let featureSelection: FeatureSelection
    public let featureNames: [String]
    public let edition: String?
    public let trustMode: TrustMode

    public init(
        language: LanguageID,
        projectRoot: PathID,
        projectUnitName: String,
        configFingerprint: String,
        environmentFingerprint: String,
        featureSelection: FeatureSelection,
        featureNames: [String],
        edition: String?,
        trustMode: TrustMode
    ) {
        self.language = language
        self.projectRoot = projectRoot
        self.projectUnitName = projectUnitName
            .precomposedStringWithCanonicalMapping
        self.configFingerprint = configFingerprint.lowercased()
        self.environmentFingerprint = environmentFingerprint.lowercased()
        self.featureSelection = featureSelection
        self.featureNames = Array(Set(featureNames.map {
            $0.precomposedStringWithCanonicalMapping
        })).sorted()
        self.edition = edition
        self.trustMode = trustMode
        id = AnalysisProfileID.derived(
            language: language,
            projectUnitName: self.projectUnitName,
            configFingerprint: self.configFingerprint,
            environmentFingerprint: self.environmentFingerprint,
            featureSelection: featureSelection
        )
    }

    public static func placeholder(
        language: LanguageID,
        root: PathID
    ) -> AnalysisProfile {
        AnalysisProfile(
            language: language,
            projectRoot: root,
            projectUnitName: ".",
            configFingerprint: "",
            environmentFingerprint: "",
            featureSelection: .defaultFeatures,
            featureNames: [],
            edition: nil,
            trustMode: .safe
        )
    }
}

private extension LanguageID {
    var profileIdentityName: String {
        switch self {
        case .rust: "rust"
        case .python: "python"
        case .typescript: "typescript"
        case .javascript: "javascript"
        }
    }
}

public struct QueryContext: Sendable {
    public let snapshotID: SnapshotID
    public let analysisProfileID: AnalysisProfileID
    public let generation: UInt64

    public init(
        snapshotID: SnapshotID,
        analysisProfileID: AnalysisProfileID,
        generation: UInt64
    ) {
        self.snapshotID = snapshotID
        self.analysisProfileID = analysisProfileID
        self.generation = generation
    }
}
