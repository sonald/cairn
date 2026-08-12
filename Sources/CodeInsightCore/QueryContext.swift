import Foundation

package func pythonConfigIdentity(
    readBytes: (String) -> [UInt8]?
) -> (config: String, environment: String) {
    let config: (name: String, bytes: [UInt8])?
    if let bytes = readBytes("pyrightconfig.json") {
        config = ("pyrightconfig.json", bytes)
    } else if let bytes = readBytes("pyproject.toml") {
        config = ("pyproject.toml", bytes)
    } else {
        config = nil
    }

    let configFingerprint = config.map { item in
        ContentID.sha256(of: Array(item.name.utf8) + [0] + item.bytes)
            .bytes
            .map { String(format: "%02x", $0) }
            .joined()
    } ?? "ad63780a0cbd089b3305c2cf137e6b6bf21da9bd79e5c110172db574a847be12"
    let environmentFingerprint = readBytes("uv.lock").map { bytes in
        ContentID.sha256(of: Array("uv.lock".utf8) + [0] + bytes)
            .bytes
            .map { String(format: "%02x", $0) }
            .joined()
    } ?? ""
    return (configFingerprint, environmentFingerprint)
}

package func typescriptConfigIdentity(
    readBytes: (String) -> [UInt8]?
) -> (config: String, environment: String) {
    let candidates: [(String, [UInt8])] = [
        ("tsconfig.json", readBytes("tsconfig.json")),
        ("package.json", readBytes("package.json")),
    ].compactMap { name, bytes in
        bytes.map { (name, $0) }
    }

    var configBytes: [UInt8] = []
    for (name, bytes) in candidates {
        let nameBytes = Array(name.utf8)
        configBytes += Array(String(nameBytes.count).utf8)
        configBytes.append(UInt8(ascii: ":"))
        configBytes += nameBytes
        configBytes += Array(String(describing: bytes.count).utf8)
        configBytes.append(UInt8(ascii: ":"))
        configBytes += bytes
    }
    let configFingerprint = (candidates.isEmpty
        ? ContentID.sha256(of: Array("typescript-config\0none".utf8))
        : ContentID.sha256(of: configBytes)
    ).bytes.map { String(format: "%02x", $0) }.joined()

    let environmentFingerprint = readBytes("bun.lockb").map { bytes in
        ContentID.sha256(of: Array("bun.lockb".utf8) + [0] + bytes)
            .bytes
            .map { String(format: "%02x", $0) }
            .joined()
    } ?? ""
    return (configFingerprint, environmentFingerprint)
}

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

public enum FeatureSelection: String, CaseIterable, Hashable, Sendable {
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
