        // MATCHED_PERFORMANCE_ADDON: intentionally identical on both measured versions.
        if arguments.contains("--matched-perf") {
            ReaderWorkCounters.setEnabled(true)
            ReaderWorkCounters.reset()
            var samples: [[String: Any]] = []
            var phaseSetups: [[String: Any]] = []
            var anchorCapture: [String: Any]?
            let clock = ContinuousClock()
            let stageLimit = Double(option("--stage-deadline-seconds") ?? "60") ?? 60
            func ms(_ start: ContinuousClock.Instant) -> Double {
                let value = start.duration(to: clock.now).components
                return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
            }
            // Identical conservative source-cost classification on S0 and candidate.
            // A generic runtime "limited" flag is not evidence of a policy exclusion.
            let costMetadataStart = clock.now
            let sourceLineStarts = document.lineTable.lineStarts
            var maximumSourceLineBytes = 0
            for index in sourceLineStarts.indices {
                let end = index + 1 < sourceLineStarts.count
                    ? Int(sourceLineStarts[index + 1]) : document.bytes.count
                maximumSourceLineBytes = max(maximumSourceLineBytes, end - Int(sourceLineStarts[index]))
            }
            var knownPolicyLimitReasons: [String] = []
            if sourceLineStarts.count > 8_000 { knownPolicyLimitReasons.append("logical-line-count-over-8000") }
            if maximumSourceLineBytes > 64 * 1024 { knownPolicyLimitReasons.append("source-line-bytes-over-65536") }
            let sourceCost: [String: Any] = [
                "byteCount": document.bytes.count, "logicalLineCount": sourceLineStarts.count,
                "maximumSourceLineBytes": maximumSourceLineBytes,
                "lineCountLimit": 8_000, "sourceLineByteLimit": 64 * 1024,
                "knownPolicyLimitReasons": knownPolicyLimitReasons
            ]
            let costMetadataMs = ms(costMetadataStart)
            func identifiersReady() -> Bool { __IDENTIFIER_READY__ }
            func awaitStable(_ start: ContinuousClock.Instant, drawBefore: Int,
                             requireAnchor: Bool, selection: [NSValue]) throws -> [String: Any] {
                var previous: Data?
                var unchangedTurns = 0
                var turns = 0
                var last: [String: Any] = [:]
                while ms(start) < stageLimit * 1000 {
                    // Same native event processing on both builds. A delay alone never passes readiness.
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
                    turns += 1
                    if var geometry = reader.matchedPerformanceGeometry(document: document, settings: settings) {
                        let identifierReady = identifiersReady()
                        let selectionMatches = reader.view.selectedRanges == selection
                        geometry["identifierReady"] = identifierReady
                        geometry["selectionMatches"] = selectionMatches
                        geometry["expectedSelection"] = selection.map { [$0.rangeValue.location, $0.rangeValue.length] }
                        last = geometry
                        let qualified = identifierReady
                            && geometry["contentMatches"] as? Bool == true
                            && geometry["settingsMatch"] as? Bool == true
                            && geometry["attributesMatch"] as? Bool == true
                            && geometry["pendingReflow"] as? Bool == false
                            && reader.backgroundDrawCount > drawBefore
                            && selectionMatches
                        let signature = try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys])
                        unchangedTurns = qualified && signature == previous ? unchangedTurns + 1 : 0
                        previous = signature
                        if qualified && unchangedTurns >= 3 {
                            if geometry["limited"] as? Bool == true, knownPolicyLimitReasons.isEmpty {
                                return ["status": "fail", "policyLimited": false,
                                        "reason": "unexpected-limited-recovery-for-supported-source", "deterministicFailure": true,
                                        "sourceCost": sourceCost, "nativeTurns": turns, "geometry": geometry]
                            }
                            if requireAnchor, !knownPolicyLimitReasons.isEmpty {
                                return ["status": "not_run", "policyLimited": true, "reason": "known-source-cost-limits-anchor-recovery",
                                        "policyLimitReasons": knownPolicyLimitReasons, "sourceCost": sourceCost,
                                        "viewportSettledMs": ms(start), "nativeTurns": turns, "geometry": geometry]
                            }
                            if requireAnchor {
                                guard let observed = geometry["freshAnchor"] as? [String: Any],
                                      let error = observed["errorPt"] as? Double,
                                      observed["targetID"] as? String == anchorCapture?["targetID"] as? String else {
                                    return ["status": "fail", "reason": "fresh-anchor-measurement-missing",
                                            "deterministicFailure": true, "nativeTurns": turns, "geometry": geometry]
                                }
                                guard error <= 1 else {
                                    return ["status": "fail", "reason": "fresh-anchor-displacement",
                                            "deterministicFailure": true, "nativeTurns": turns, "geometry": geometry]
                                }
                            }
                            return ["status": "pass", "stableLayoutMs": ms(start), "nativeTurns": turns, "geometry": geometry]

                        }
                    }
                }
                let reason = requireAnchor && knownPolicyLimitReasons.isEmpty && last["freshAnchor"] is NSNull
                    ? "fresh-anchor-measurement-missing" : "target-viewport-readiness-deadline"
                return ["status": "fail", "reason": reason,
                        "nativeTurns": turns, "geometry": last]
            }
            func measured(_ name: String, requireAnchor: Bool = false, _ operation: () throws -> Void) throws {
                try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "status": "not_run",
                    "pendingScenario": name, "events": samples], options: [.prettyPrinted, .sortedKeys])
                    .write(to: output, options: .atomic)
                let before = try counters()
                let drawBefore = reader.backgroundDrawCount
                reader.matchedFirstDrawInstant = nil
                let start = clock.now
                try operation()
                let operationMs = ms(start)
                let operationAfter = try counters()
                let selectionAfterOperation = reader.view.selectedRanges
                let selection = selectionAfterOperation
                draw()
                let operationAndDrawMs = ms(start)
                let firstDrawMs = reader.matchedFirstDrawInstant.map { instant -> Double in
                    let value = start.duration(to: instant).components
                    return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
                }
                let coldLoadToDrawMs = reader.matchedFirstDrawInstant.map { instant -> Double in
                    let value = preparationStart.duration(to: instant).components
                    return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
                }
                let drew = reader.backgroundDrawCount > drawBefore
                let ready = try awaitStable(start, drawBefore: drawBefore, requireAnchor: requireAnchor, selection: selection)
                let after = try counters()
                samples.append([
                    "scenario": name, "status": ready["status"] as? String == "fail" ? "fail" : "pass",
                    "operationStatus": "pass", "drawStatus": drew ? "pass" : "fail",
                    "settings": ["fontSize": settings.fontSize, "wrapLines": settings.wrapLines,
                                 "theme": settings.theme.rawValue, "lineNumbers": settings.lineNumbers],
                    "operationOnlyMs": operationMs,
                    "firstActualDrawMs": drew ? firstDrawMs as Any? ?? NSNull() : NSNull(),
                    "operationAndSynchronousDrawMs": operationAndDrawMs,
                    "coldLoadToFirstDrawMs": name == "cold-display" ? coldLoadToDrawMs as Any? ?? NSNull() : NSNull(),
                    "coldLoadToStableMs": name == "cold-display" && ready["status"] as? String == "pass"
                        ? ms(preparationStart) as Any : NSNull(),
                    "stable": ready,
                    "before": before, "operationAfter": operationAfter, "after": after,
                    "operationDelta": Dictionary(uniqueKeysWithValues: operationAfter.map { ($0.key, $0.value - before[$0.key, default: 0]) }),
                    "interactionDelta": Dictionary(uniqueKeysWithValues: after.map { ($0.key, $0.value - before[$0.key, default: 0]) }),
                    "drawBefore": drawBefore, "drawAfter": reader.backgroundDrawCount,
                    "occurrenceCount": reader.occurrenceCount,
                    "selectionAfterOperation": selectionAfterOperation.map { [$0.rangeValue.location, $0.rangeValue.length] },
                    "expectedStableSelection": selection.map { [$0.rangeValue.location, $0.rangeValue.length] },
                    "selection": reader.view.selectedRanges.map { [$0.rangeValue.location, $0.rangeValue.length] },
                    "affinity": reader.view.selectionAffinity.rawValue,
                    "physicalFootprintBytes": physicalFootprintBytes() as Any? ?? NSNull()
                ])
            }
            func resetSelectionBeforePhase(_ name: String) throws {
                let before = try counters()
                let original = reader.view.selectedRanges.map { [$0.rangeValue.location, $0.rangeValue.length] }
                let start = clock.now
                let drawBefore = reader.backgroundDrawCount
                reader.clearOccurrences()
                let canonical = [NSValue(range: NSRange(location: 0, length: 0))]
                reader.view.setSelectedRanges(canonical, affinity: .downstream, stillSelecting: false)
                draw()
                let ready = try awaitStable(start, drawBefore: drawBefore, requireAnchor: false, selection: canonical)
                let after = try counters()
                phaseSetups.append(["phase": name, "reason": "remove-identifier-selection-before-cross-version-projection-settings",
                    "outsideMeasuredPhase": true, "beforeSelection": original, "afterSelection": [[0, 0]],
                    "occurrenceCount": reader.occurrenceCount, "elapsedMs": ms(start), "readiness": ready,
                    "workDelta": Dictionary(uniqueKeysWithValues: after.map { ($0.key, $0.value - before[$0.key, default: 0]) })])
            }
            try measured("cold-display") {
                reader.display(document: document, fileURL: url)
                // Match the host's explicit initial caret intent on both versions.
                // This protocol setup is included in the cold operation cost.
                reader.view.setSelectedRanges([NSValue(range: NSRange(location: 0, length: 0))],
                                              affinity: .downstream, stillSelecting: false)
            }
            let source = String(decoding: data, as: UTF8.self)
            let offset = source.range(of: "repeated").map { UInt32(source[..<$0.lowerBound].utf8.count) } ?? 0
            // Explicit warm-up is reported, never hidden in the hot measurement.
            try measured("identifier-warmup") { _ = reader.activate(atByteOffset: offset) }
            try measured("hot-identifier") { for _ in 0..<10 { _ = reader.activate(atByteOffset: offset) } }
            let scenario = option("--matched-scenario") ?? "all"
            if scenario == "all" || scenario == "gutter" {
                try measured("stable-scroll") {
                    for y in stride(from: 0, through: 200, by: 20) {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); draw()
                    }
                }
            }
            if scenario == "all" || scenario == "projection" {
                try resetSelectionBeforePhase("projection")
                if let fold = document.foldRegions.first(where: { $0.summary.hiddenLineCount >= 2 }),
                   let position = document.lineTable.lineColumn(at: fold.headerRange.lowerBound) {
                    for phase in ["single-fold", "single-unfold"] {
                        try measured(phase) {
                            guard reader.canToggleFold(atLine: Int(position.line)),
                                  reader.toggleFold(atLine: Int(position.line)) else {
                                throw NSError(domain: "ReadonlyMatchedPerformance", code: 1, userInfo: [
                                    NSLocalizedDescriptionKey: "Eligible fixture fold did not toggle in \(phase)"
                                ])
                            }
                        }
                    }
                } else {
                    for phase in ["single-fold", "single-unfold"] {
                        samples.append(["scenario": phase, "status": "not_run", "applicable": false,
                                        "reason": "fixture-has-no-visible-fold-with-two-hidden-lines"])
                    }
                }
            }
            if scenario == "all" || scenario == "reflow" {
                try resetSelectionBeforePhase("reflow")
                let captureStarted = clock.now
                // Capture once before this uninterrupted sequence. Re-sampling
                // after a font change would select a different character at x.
                if knownPolicyLimitReasons.isEmpty { anchorCapture = reader.matchedCaptureAnchor() }
                phaseSetups.append(["phase": "reflow-anchor", "outsideMeasuredPhase": true,
                    "captureMs": ms(captureStarted), "target": anchorCapture as Any? ?? NSNull(),
                    "skipReasons": knownPolicyLimitReasons])
                try measured("color-only", requireAnchor: true) { settings.theme = .dark; reader.apply(settings: settings) }
                try measured("font-only", requireAnchor: true) { settings.fontSize = 15; reader.apply(settings: settings) }
                try measured("color-font-wrap", requireAnchor: true) {
                    settings.theme = .light; settings.fontSize = 14; settings.wrapLines = false; reader.apply(settings: settings)
                }
            }
            // Identical post-readiness memory observation. Not part of stable-layout proof/latency.
            let memoryStart = clock.now
            repeat {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005))
                sampleMemory()
            } while ms(memoryStart) < 100
            let font = ReaderFontResolver.shared.resolve(selection: settings.codeFont, mode: settings.codeLigatures,
                                                        size: CGFloat(settings.fontSize))
            let valid = samples.allSatisfy {
                $0["status"] as? String == "pass" || $0["applicable"] as? Bool == false
            } && !phaseSetups.contains {
                ($0["readiness"] as? [String: Any])?["status"] as? String == "fail"
            }
            finish([
                "schemaVersion": 1, "status": valid ? "pass" : "fail", "matchedProtocol": "s7-v2",
                "fixtureSHA256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                "codeSHA": "__MEASURED_SOURCE_SHA__", "sampleID": option("--sample-id") ?? "unknown",
                "coldInputPreparationMs": preparationMs, "events": samples, "phaseSetups": phaseSetups,
                "coldProtocolSetup": ["caret": 0, "affinity": "downstream", "afterDisplay": true, "includedInOperation": true],
                "sourceCost": sourceCost, "sourceCostClassificationMs": costMetadataMs,
                "initialTheme": ReaderSettings.Theme.light.rawValue,
                "windowAppearance": window.effectiveAppearance.name.rawValue,
                "resolvedFontName": font.actualPostScriptName, "fontFeatureRequests": font.featureRequests,
                "effectiveFontFeatures": CTFontCopyFeatureSettings(font.font) as? [[String: Any]] ?? [],
                "fontFallbackReason": font.fallbackReason as Any? ?? NSNull(),
                "settings": ["fontSize": settings.fontSize, "wrapLines": settings.wrapLines,
                             "theme": settings.theme.rawValue, "lineNumbers": settings.lineNumbers,
                             "ligatures": settings.codeLigatures.rawValue],
                "readonlyFlags": ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("CAIRN_READONLY_") },
                "windowPt": [window.frame.width, window.frame.height],
                "viewportPt": [scroll.contentView.bounds.width, scroll.contentView.bounds.height],
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "physicalMemorySamplesBytes": memorySamples.withLock { $0 },
                "peakPhysBytes": memorySamples.withLock { $0.max() } as Any? ?? NSNull(),
                "memoryObservationMs": ms(memoryStart),
                "limitations": ["First actual draw timestamps native drawBackground entry, not compositor presentation",
                    "Stable means observed unchanged target viewport geometry/attributes/selection across native turns; not full-document extent convergence",
                    "Fresh anchor proof is a native source-byte/row observation, never the production last diagnostic",
                    "No sleep alone establishes readiness; known source-cost precision is NOT_RUN, never an anchor PASS"]
            ], code: valid ? 0 : 1)
        }
