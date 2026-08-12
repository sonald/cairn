import CodeInsightCore
import Foundation
import Testing
@testable import CodeInsightAppModel

@Test
func sessionCodecPersistsLanguageAndMigratesMissingLanguageToRust() throws {
    let snapshot = SessionCodec.Snapshot(
        projectRoot: "/tmp/project",
        language: .python,
        revision: nil,
        activeTabOrdinal: nil,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: []
    )
    let data = try SessionCodec.encode(
        snapshot,
        maximumTabCount: 10,
        dependencyAllowed: { _ in false }
    )
    var object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object["language"] as? Int == Int(LanguageID.python.rawValue))
    #expect(try SessionCodec.decode(
        data,
        maximumTabCount: 10,
        dependencyAllowed: { _ in false }
    ).language == .python)

    object.removeValue(forKey: "language")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    #expect(try SessionCodec.decode(
        legacy,
        maximumTabCount: 10,
        dependencyAllowed: { _ in false }
    ).language == .rust)
}

@Test
func sessionCodecRoundTripsTypeScriptRawValueTwo() throws {
    let snapshot = SessionCodec.Snapshot(
        projectRoot: "/tmp/ts-project",
        language: .typescript,
        revision: nil,
        activeTabOrdinal: nil,
        panelPreset: PanelPresetModel.reading.rawValue,
        tabs: []
    )
    let data = try SessionCodec.encode(
        snapshot,
        maximumTabCount: 10,
        dependencyAllowed: { _ in false }
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object["language"] as? Int == 2)
    #expect(try SessionCodec.decode(
        data,
        maximumTabCount: 10,
        dependencyAllowed: { _ in false }
    ).language == .typescript)
}

@Test
func sessionCodecRoundTripsTaggedTabsAndEveryFrozenInspectorField() throws {
    let capturedAt = Date(timeIntervalSince1970: 1_786_270_000.125)
    let excerpt = sessionExcerpt(capturedAt: capturedAt)
    let contentID = excerpt.contentID
    let snapshot = SessionCodec.Snapshot(
        projectRoot: "/tmp/project",
        language: .rust,
        revision: "abc123",
        activeTabOrdinal: 1,
        panelPreset: PanelPresetModel.relations.rawValue,
        tabs: [
            .file(.init(
                path: "src/main.rs",
                anchorContentID: contentID,
                scrollAnchor: .init(
                    byteOffset: 7,
                    line: 2,
                    column: 3,
                    symbolAnchor: "render"
                ),
                selectionAnchor: .init(
                    byteOffset: 9,
                    line: 2,
                    column: 5,
                    symbolAnchor: "value"
                )
            )),
            .readingSet(.init(
                title: "spawn trace",
                excerpts: [excerpt],
                scrollOffset: 144.5,
                skippedReasons: ["recorded source is unreadable"]
            )),
        ]
    )

    let data = try SessionCodec.encode(
        snapshot,
        maximumTabCount: 10,
        dependencyAllowed: { _ in false }
    )
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"kind\":\"file\""))
    #expect(json.contains("\"kind\":\"readingSet\""))
    #expect(!json.contains("SnapshotID"))
    #expect(!json.contains("ResolutionExplanationID"))

    let decoded = try SessionCodec.decode(
        data,
        maximumTabCount: 10,
        dependencyAllowed: { _ in false }
    )
    #expect(decoded.projectRoot == "/tmp/project")
    #expect(decoded.revision == "abc123")
    #expect(decoded.activeTabOrdinal == 1)
    #expect(decoded.panelPreset == "relations")
    #expect(decoded.tabs.count == 2)
    guard case .file(let file) = decoded.tabs[0],
          case .readingSet(let readingSet) = decoded.tabs[1]
    else {
        Issue.record("tagged tabs changed kind")
        return
    }
    #expect(file.path == "src/main.rs")
    #expect(file.anchorContentID == contentID)
    #expect(file.scrollAnchor?.byteOffset == 7)
    #expect(file.selectionAnchor?.byteOffset == 9)
    #expect(readingSet.title == "spawn trace")
    #expect(readingSet.scrollOffset == 144.5)
    #expect(readingSet.skippedReasons == ["recorded source is unreadable"])

    let restored = try #require(readingSet.excerpts.first)
    #expect(restored.role == excerpt.role)
    #expect(restored.symbol == excerpt.symbol)
    #expect(restored.path == excerpt.path)
    #expect(restored.line == excerpt.line)
    #expect(restored.column == excerpt.column)
    #expect(restored.firstLine == excerpt.firstLine)
    #expect(restored.byteRange == excerpt.byteRange)
    #expect(restored.sourceText == excerpt.sourceText)
    #expect(restored.contentID == excerpt.contentID)
    #expect(restored.revision == excerpt.revision)
    #expect(restored.capturedAt == capturedAt)
    #expect(restored.caveat == excerpt.caveat)
    #expect(restored.partialLine == excerpt.partialLine)
    #expect(restored.inspector.nodeTitle == excerpt.inspector.nodeTitle)
    #expect(restored.inspector.badge.rawValue == excerpt.inspector.badge.rawValue)
    #expect(restored.inspector.why == excerpt.inspector.why)
    #expect(restored.inspector.sourceBody == excerpt.inspector.sourceBody)
    #expect(restored.inspector.verificationTitle
        == excerpt.inspector.verificationTitle)
    #expect(restored.inspector.verificationBody
        == excerpt.inspector.verificationBody)
    #expect(restored.inspector.correctionBody == excerpt.inspector.correctionBody)
    #expect(restored.inspector.availabilityBody
        == excerpt.inspector.availabilityBody)
    #expect(restored.inspector.environmentBody == excerpt.inspector.environmentBody)
    #expect(restored.inspector.auditRows.map(\.label)
        == excerpt.inspector.auditRows.map(\.label))
    #expect(restored.inspector.auditRows.map(\.value)
        == excerpt.inspector.auditRows.map(\.value))
    #expect(restored.inspector.accessibilityValue
        == excerpt.inspector.accessibilityValue)
    #expect(restored.inspector.capturedAt == capturedAt)
    #expect(restored.inspector.formerCandidateAvailable)
}

@Test
func sessionCodecRejectsUnknownVersionsCountsSizesAndProjectPathEscape() throws {
    let excerpt = sessionExcerpt()
    let valid = SessionCodec.Snapshot(
        projectRoot: "/tmp/project",
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: "reading",
        tabs: [.readingSet(.init(
            title: "trace",
            excerpts: [excerpt],
            scrollOffset: 0
        ))]
    )
    let data = try SessionCodec.encode(
        valid,
        maximumTabCount: 10,
        dependencyAllowed: { _ in false }
    )
    let json = try #require(String(data: data, encoding: .utf8))
    let unknown = try #require(
        json.replacingOccurrences(
            of: "\"schemaVersion\":1",
            with: "\"schemaVersion\":2"
        ).data(using: .utf8)
    )
    #expect(sessionCodecFails {
        _ = try SessionCodec.decode(
            unknown,
            maximumTabCount: 10,
            dependencyAllowed: { _ in false }
        )
    })

    var missingRootObject = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    missingRootObject.removeValue(forKey: "projectRoot")
    let missingRoot = try JSONSerialization.data(withJSONObject: missingRootObject)
    #expect(sessionCodecFails {
        _ = try SessionCodec.decode(
            missingRoot,
            maximumTabCount: 10,
            dependencyAllowed: { _ in false }
        )
    })

    let tooMany = SessionCodec.Snapshot(
        projectRoot: "/tmp/project",
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: "reading",
        tabs: Array(repeating: valid.tabs[0], count: 11)
    )
    #expect(sessionCodecFails {
        _ = try SessionCodec.encode(
            tooMany,
            maximumTabCount: 10,
            dependencyAllowed: { _ in false }
        )
    })

    let tooManyExcerpts = SessionCodec.Snapshot(
        projectRoot: "/tmp/project",
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: "reading",
        tabs: [.readingSet(.init(
            title: "trace",
            excerpts: Array(repeating: excerpt, count: 51),
            scrollOffset: nil
        ))]
    )
    #expect(sessionCodecFails {
        _ = try SessionCodec.encode(
            tooManyExcerpts,
            maximumTabCount: 10,
            dependencyAllowed: { _ in false }
        )
    })

    let escaping = SessionCodec.Snapshot(
        projectRoot: "/tmp/project",
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: "reading",
        tabs: [.file(.init(
            path: "../outside.rs",
            anchorContentID: nil,
            scrollAnchor: nil,
            selectionAnchor: nil
        ))]
    )
    #expect(sessionCodecFails {
        _ = try SessionCodec.encode(
            escaping,
            maximumTabCount: 10,
            dependencyAllowed: { _ in false }
        )
    })

    let oversized = SessionCodec.Snapshot(
        projectRoot: "/tmp/project",
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: "reading",
        tabs: [.readingSet(.init(
            title: "trace",
            excerpts: [sessionExcerpt(sourceText: String(repeating: "x", count: 16_385))],
            scrollOffset: nil
        ))]
    )
    #expect(sessionCodecFails {
        _ = try SessionCodec.encode(
            oversized,
            maximumTabCount: 10,
            dependencyAllowed: { _ in false }
        )
    })

    let tooManyAuditRows = SessionCodec.Snapshot(
        projectRoot: "/tmp/project",
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: "reading",
        tabs: [.readingSet(.init(
            title: "trace",
            excerpts: [sessionExcerpt(auditRowCount: 33)],
            scrollOffset: nil
        ))]
    )
    #expect(sessionCodecFails {
        _ = try SessionCodec.encode(
            tooManyAuditRows,
            maximumTabCount: 10,
            dependencyAllowed: { _ in false }
        )
    })

    let oversizedDisplay = SessionCodec.Snapshot(
        projectRoot: "/tmp/project",
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: "reading",
        tabs: [.readingSet(.init(
            title: "trace",
            excerpts: [sessionExcerpt(
                displayBody: String(repeating: "x", count: 16_385)
            )],
            scrollOffset: nil
        ))]
    )
    #expect(sessionCodecFails {
        _ = try SessionCodec.encode(
            oversizedDisplay,
            maximumTabCount: 10,
            dependencyAllowed: { _ in false }
        )
    })
}

@Test
func sessionCodecAppliesDependencyPredicateToFileTabsButKeepsFrozenExcerpts() throws {
    let path = "/tmp/dependency/src/lib.rs"
    let file = SessionCodec.Snapshot(
        projectRoot: "/tmp/project",
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: "reading",
        tabs: [.file(.init(
            path: path,
            anchorContentID: nil,
            scrollAnchor: nil,
            selectionAnchor: nil
        ))]
    )
    #expect(sessionCodecFails {
        _ = try SessionCodec.encode(
            file,
            maximumTabCount: 10,
            dependencyAllowed: { _ in false }
        )
    })
    _ = try SessionCodec.encode(
        file,
        maximumTabCount: 10,
        dependencyAllowed: { $0 == path }
    )

    let frozen = SessionCodec.Snapshot(
        projectRoot: "/tmp/project",
        language: .rust,
        revision: nil,
        activeTabOrdinal: 0,
        panelPreset: "reading",
        tabs: [.readingSet(.init(
            title: "dependency evidence",
            excerpts: [sessionExcerpt(
                path: path,
                sourceKind: .dependencyCaptured
            )],
            scrollOffset: nil
        ))]
    )
    let data = try SessionCodec.encode(
        frozen,
        maximumTabCount: 10,
        dependencyAllowed: { _ in false }
    )
    let decoded = try SessionCodec.decode(
        data,
        maximumTabCount: 10,
        dependencyAllowed: { _ in false }
    )
    guard case .readingSet(let restored) = decoded.tabs[0] else {
        Issue.record("frozen dependency tab changed kind")
        return
    }
    #expect(restored.excerpts.first?.sourceText == "fn captured() {}\n")
}

private func sessionExcerpt(
    path: String = "src/lib.rs",
    sourceText: String = "fn captured() {}\n",
    sourceKind: ReadingSetExcerpt.SourceKind = .worktreeCaptured,
    capturedAt: Date = Date(timeIntervalSince1970: 1_786_270_000.125),
    auditRowCount: Int = 3,
    displayBody: String = "src/lib.rs:1"
) -> ReadingSetExcerpt {
    let contentID = ContentID.sha256(of: Array(sourceText.utf8))
    let auditRows: [ReadingSetExcerpt.FrozenInspectorDisplay.AuditRow] =
        if auditRowCount == 3 {
            [
                .init(label: "Source", value: "worktree captured"),
                .init(label: "Content", value: "0123456789ab"),
                .init(label: "Captured at", value: "2026-08-09T18:00:00Z"),
            ]
        } else {
            (0..<auditRowCount).map {
                .init(label: "Row \($0)", value: "value")
            }
        }
    let inspector = ReadingSetExcerpt.FrozenInspectorDisplay(
        nodeTitle: "captured",
        badge: .verified,
        why: "Exact target matched",
        sourceBody: displayBody,
        verificationTitle: "Verified target",
        verificationBody: "same target",
        correctionBody: "No correction",
        availabilityBody: "Available at capture",
        environmentBody: "Safe at capture",
        auditRows: auditRows,
        accessibilityValue: "VERIFIED captured",
        capturedAt: capturedAt,
        formerCandidateAvailable: true
    )
    return ReadingSetExcerpt(
        role: "VERIFIED CALLER",
        symbol: "captured",
        path: path,
        line: 1,
        column: 4,
        firstLine: 1,
        byteRange: ByteRange(
            lowerBound: 0,
            upperBound: UInt32(sourceText.utf8.count)
        ),
        sourceText: sourceText,
        contentID: contentID,
        revision: sourceKind == .projectCommit ? "abc123" : nil,
        capturedAt: capturedAt,
        sourceKind: sourceKind,
        inspector: inspector,
        caveat: "name match only",
        partialLine: true
    )
}

private func sessionCodecFails(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch {
        return true
    }
}
