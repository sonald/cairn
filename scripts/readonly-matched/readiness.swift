    package var matchedFirstDrawInstant: ContinuousClock.Instant?
    // HARNESS ONLY: identical read-only observation on baseline and candidate.
    package func matchedPerformanceGeometry(document: ReaderDocument, settings: ReaderSettings) -> [String: Any]? {
        guard let manager = view.textLayoutManager,
              let content = manager.textContentManager,
              let viewport = manager.textViewportLayoutController.viewportRange,
              let fragment = manager.textLayoutFragment(for: viewport.location),
              let line = fragment.textLineFragments.first,
              let scroll = view.enclosingScrollView,
              scroll.contentView.bounds.width > 1, scroll.contentView.bounds.height > 1 else { return nil }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        let fragmentStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        let local = line.characterRange.location
        let storageOffset = fragmentStart + local
        guard start != NSNotFound, end != NSNotFound,
              fragmentStart != NSNotFound, storageOffset >= 0,
              storageOffset < backingTextStorage.length, local < line.attributedString.length else { return nil }
        let attributesMatch = [NSAttributedString.Key.font, .ligature, .kern].allSatisfy { key in
            (line.attributedString.attribute(key, at: local, effectiveRange: nil) as? NSObject)
                == (backingTextStorage.attribute(key, at: storageOffset, effectiveRange: nil) as? NSObject)
        }
        let rect = fragment.layoutFragmentFrame
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite), rect.height > 0 else { return nil }
        return [
            "contentMatches": displayedDocument?.contentID == document.contentID,
            "settingsMatch": typographyKey == ReaderTypographyKey(settings: settings)
                && wrapLines == settings.wrapLines && lineNumbers == settings.lineNumbers
                && theme == ReaderTheme(settings: settings),
            "attributesMatch": attributesMatch,
            "effectiveAppearance": view.effectiveAppearance.name.rawValue,
            "pendingReflow": pendingViewportCorrection != nil || pendingWidthReflowGeneration != nil || hasScheduledWidthReflow,
            "limited": lastViewportRestoreWasLimited,
            "lastProductionAnchorErrorPt": lastViewportAnchorErrorPt as Any? ?? NSNull(),
            "freshAnchor": matchedAnchorObservation() as Any? ?? NSNull(),
            "viewportRange": [start, end], "fragment": [rect.minX, rect.minY, rect.width, rect.height],
            "clip": [scroll.contentView.bounds.minX, scroll.contentView.bounds.minY,
                     scroll.contentView.bounds.width, scroll.contentView.bounds.height],
            "containerWidth": view.textContainer?.size.width ?? 0,
            "selection": view.selectedRanges.map { [$0.rangeValue.location, $0.rangeValue.length] },
            "affinity": view.selectionAffinity.rawValue
        ]
    }
    // HARNESS ONLY: a fresh native reference target independent of production's
    // last reflow diagnostic. One target spans the consecutive settings sequence.
    private var matchedAnchorTarget: (id: UUID, content: ContentID, byte: UInt32, offset: CGFloat)?

    package func matchedCaptureAnchor() -> [String: Any]? {
        matchedAnchorTarget = nil
        guard let document = displayedDocument, let map = displayMap,
              view.visibleRect.width > 1, view.visibleRect.height > 1 else { return nil }
        let visible = view.visibleRect
        let location = view.characterIndexForInsertion(at: NSPoint(x: visible.midX, y: visible.minY + visible.height * 0.25))
        guard let row = matchedLaidOutRow(at: location) else { return nil }
        let byte: UInt32
        switch map.sourcePosition(ofDisplay: location) {
        case .source(let source): byte = source
        case .placeholder(let id):
            guard let body = document.foldRegions.first(where: { $0.id == id })?.bodyRange else { return nil }
            byte = body.lowerBound
        case nil: return nil
        }
        let target = (UUID(), document.contentID, byte, row.minY - visible.minY)
        matchedAnchorTarget = target
        return ["targetID": target.0.uuidString, "sourceByte": Int(byte), "offsetFromViewportTop": target.3,
                "captureDisplayOffset": location, "captureRow": [row.minX, row.minY, row.width, row.height]]
    }

    private func matchedLaidOutRow(at location: Int) -> NSRect? {
        guard location >= 0, location <= backingTextStorage.length,
              let manager = view.textLayoutManager, let content = manager.textContentManager,
              let position = content.location(content.documentRange.location, offsetBy: location) else { return nil }
        var fragment = manager.textLayoutFragment(for: position)
        if fragment == nil, location == backingTextStorage.length, location > 0,
           let previous = content.location(position, offsetBy: -1) {
            fragment = manager.textLayoutFragment(for: previous)
        }
        guard let fragment, fragment.state == .layoutAvailable else { return nil }
        let fragmentStart = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        guard fragmentStart != NSNotFound else { return nil }
        let local = location - fragmentStart
        let rows = fragment.textLineFragments
        let containing = rows.first(where: {
            NSLocationInRange(local, $0.characterRange)
                || ($0.characterRange.length == 0 && local == $0.characterRange.location)
        })
        let endRow = location == backingTextStorage.length
            && rows.last.map({ NSMaxRange($0.characterRange) == local }) == true ? rows.last : nil
        guard let line = containing ?? endRow else { return nil }
        let probe = line.characterRange.location
        let absolute = fragmentStart + probe
        if absolute < backingTextStorage.length {
            guard probe < line.attributedString.length,
                  [NSAttributedString.Key.font, .ligature, .kern].allSatisfy({ key in
                      (line.attributedString.attribute(key, at: probe, effectiveRange: nil) as? NSObject)
                          == (backingTextStorage.attribute(key, at: absolute, effectiveRange: nil) as? NSObject)
                  }) else { return nil }
        }
        let row = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX + view.textContainerOrigin.x,
                                                 dy: fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y)
        guard [row.minX, row.minY, row.width, row.height].allSatisfy(\.isFinite), row.height > 0 else { return nil }
        return row
    }

    private func matchedAnchorObservation() -> [String: Any]? {
        guard let target = matchedAnchorTarget, displayedDocument?.contentID == target.content,
              let scroll = view.enclosingScrollView, let map = displayMap else { return nil }
        let location: Int
        switch map.displayPosition(ofByte: target.byte) {
        case .visible(let offset): location = offset
        case .hidden(let id):
            guard let offset = map.placeholderOffset(for: id) else { return nil }
            location = offset
        case nil: return nil
        }
        guard let row = matchedLaidOutRow(at: location), row.intersects(view.visibleRect) else { return nil }
        let clip = scroll.contentView
        let requested = row.minY - target.offset
        let minimum = -clip.contentInsets.top
        let maximum = max(minimum, view.frame.height - clip.bounds.height + clip.contentInsets.bottom)
        let legal = min(max(requested, minimum), maximum)
        return ["targetID": target.id.uuidString, "sourceByte": Int(target.byte), "displayOffset": location,
                "offsetFromViewportTop": target.offset, "observedRow": [row.minX, row.minY, row.width, row.height],
                "requestedOriginY": requested, "legalOriginY": legal, "actualOriginY": clip.bounds.minY,
                "errorPt": Double(abs(clip.bounds.minY - legal)),
                "rawOffsetErrorPt": Double(abs(row.minY - clip.bounds.minY - target.offset)), "clamped": legal != requested]
    }
