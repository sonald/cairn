import CodeInsightCore

struct Resolver {
    let session: EngineSession

    func tokenRange(file: PathID, offset: UInt32) -> ByteRange? {
        guard let (_, index) = session.content(at: file) else { return nil }
        return locatedName(
            at: offset,
            in: index,
            bytes: session.sourceBytes(at: file)
        )?.range
    }

    func resolve(
        file: PathID,
        offset: UInt32,
        context: QueryContext
    ) -> [ResolutionCandidate] {
        guard let (_, index) = session.content(at: file),
              let located = locatedName(
                at: offset,
                in: index,
                bytes: session.sourceBytes(at: file)
              )
        else { return [] }

        let kind = located.call?.syntacticKind
        if let importIndex = located.importIndex {
            guard index.imports.indices.contains(Int(importIndex)) else { return [] }
            return importCandidates(
                index: importIndex,
                binding: index.imports[Int(importIndex)],
                from: file,
                kind: kind,
                context: context
            )
        }
        if case .methodCall? = kind {
            return globalCandidates(
                nameID: located.nameID,
                from: file,
                certainty: .possible,
                dispatch: .dynamicDispatch,
                evidence: [.methodNameOnly(nameID: located.nameID)],
                context: context,
                kinds: [.rustMethod, .rustFn]
            )
        }
        if case .macroInvocation? = kind {
            return globalCandidates(
                nameID: located.nameID,
                from: file,
                certainty: .possible,
                dispatch: .macroGenerated,
                evidence: [.nameOnly(nameID: located.nameID)],
                context: context,
                space: .macro
            )
        }

        let scopes = scopeChain(at: offset, in: index)
        if let lexical = lexicalBinding(
            named: located.nameID,
            at: offset,
            scopes: scopes,
            in: index
        ) {
            let dispatch: DispatchKind
            if isDirectCall(kind)
                && (lexical.binding.kind == .letBinding
                    || lexical.binding.kind == .patternBinding)
            {
                dispatch = .callback
            } else {
                dispatch = .direct
            }
            return [candidate(
                pathID: file,
                localIndex: lexical.index,
                certainty: capped(.strong, for: kind),
                dispatch: dispatch,
                evidence: [.lexicalBinding(bindingIndex: lexical.index)],
                context: context
            )]
        }

        let sameFile = index.symbols.enumerated().compactMap {
            facetIndex, facet -> ResolutionCandidate? in
            guard facet.parentFacetIndex == nil,
                  facet.nameID == located.nameID,
                  let facetIndex = UInt32(exactly: facetIndex)
            else { return nil }
            return candidate(
                pathID: file,
                localIndex: facetIndex,
                certainty: capped(.strong, for: kind),
                dispatch: dispatch(for: kind),
                evidence: [.sameFile(pathID: file)],
                context: context
            )
        }
        if !sameFile.isEmpty && !located.identifierFallback {
            return sorted(sameFile, from: file)
        }

        let visibleScopes = Set(scopes.map(\.id))
        var imported: [ResolutionCandidate] = []
        var unresolved: [ResolutionCandidate] = []
        for (importIndex, binding) in index.imports.enumerated()
            where binding.localName == located.nameID
                && visibleScopes.contains(binding.scopeID)
        {
            guard let importIndex = UInt32(exactly: importIndex) else { continue }
            let resolved = importCandidates(
                index: importIndex,
                binding: binding,
                from: file,
                kind: kind,
                context: context
            )
            for candidate in resolved {
                if candidate.certainty == .unresolved {
                    unresolved.append(candidate)
                } else {
                    imported.append(candidate)
                }
            }
        }
        if !imported.isEmpty { return sorted(imported, from: file) }
        if !unresolved.isEmpty { return unresolved }

        let definitions = session.definitionOccurrences(named: located.nameID).filter {
            guard located.identifierFallback else { return true }
            switch $0.1.space {
            case .type, .value: return true
            default: return false
            }
        }
        let hasVisibleGlob = index.imports.contains {
            $0.flags.contains(.wildcard) && visibleScopes.contains($0.scopeID)
        }
        let hasVisibleNamedImport = index.imports.contains {
            $0.localName == located.nameID && visibleScopes.contains($0.scopeID)
        }
        let certainty: Certainty = definitions.count == 1
            && !hasVisibleGlob && !hasVisibleNamedImport
            ? .probable : .possible
        if located.identifierFallback {
            return [SymbolSpace.type, .value].flatMap { space in
                globalCandidates(
                    nameID: located.nameID,
                    from: file,
                    certainty: certainty,
                    dispatch: dispatch(for: kind),
                    evidence: [.nameOnly(nameID: located.nameID)],
                    context: context,
                    space: space
                )
            }
        }
        return globalCandidates(
            nameID: located.nameID,
            from: file,
            certainty: certainty,
            dispatch: dispatch(for: kind),
            evidence: [.nameOnly(nameID: located.nameID)],
            context: context
        )
    }

    private func locatedName(
        at offset: UInt32,
        in index: ContentIndex,
        bytes: [UInt8]?
    ) -> (
        range: ByteRange,
        nameID: NameID,
        call: UnresolvedCall?,
        importIndex: UInt32?,
        identifierFallback: Bool
    )? {
        var matches: [(range: ByteRange, nameID: NameID, call: UnresolvedCall?)] = []
        matches += index.calls.compactMap { call in
            call.range.contains(offset) ? (call.range, call.nameID, call) : nil
        }
        matches += index.bindings.compactMap { binding in
            binding.declarationRange.contains(offset)
                ? (binding.declarationRange, binding.localNameID, nil) : nil
        }
        matches += index.symbols.compactMap { facet in
            facet.nameRange.contains(offset) ? (facet.nameRange, facet.nameID, nil) : nil
        }
        if let match = matches.min(by: { $0.range.length < $1.range.length }) {
            return (match.range, match.nameID, match.call, nil, false)
        }

        // M0 identifier fallback is ASCII-only.
        guard let bytes, Int(offset) < bytes.count,
              isIdentifierByte(bytes[Int(offset)])
        else { return nil }
        var lower = Int(offset)
        var upper = Int(offset) + 1
        while lower > 0 && isIdentifierByte(bytes[lower - 1]) { lower -= 1 }
        while upper < bytes.count && isIdentifierByte(bytes[upper]) { upper += 1 }
        let nameID = session.names.intern(
            String(decoding: bytes[lower..<upper], as: UTF8.self)
        )
        let range = ByteRange(
            lowerBound: UInt32(lower),
            upperBound: UInt32(upper)
        )
        if let item = index.imports.enumerated().first(where: {
            $0.element.range.contains(offset)
                && ($0.element.localName == nameID
                    || $0.element.importedName == nameID)
        }), let importIndex = UInt32(exactly: item.offset) {
            return (range, nameID, nil, importIndex, false)
        }
        let hasLocalBinding = index.bindings.contains {
            $0.localNameID == nameID
        }
        let hasGlobalDefinition = session.definitionOccurrences(named: nameID).contains {
            switch $0.1.space {
            case .type, .value: return true
            default: return false
            }
        }
        guard hasLocalBinding || hasGlobalDefinition else { return nil }
        return (range, nameID, nil, nil, !hasLocalBinding)
    }

    private func importCandidates(
        index importIndex: UInt32,
        binding: ImportBinding,
        from source: PathID,
        kind: CallKind?,
        context: QueryContext
    ) -> [ResolutionCandidate] {
        var visited: Set<SymbolOccurrenceID> = []
        if let resolved = importCandidate(
            index: importIndex,
            binding: binding,
            from: source,
            kind: kind,
            context: context,
            evidenceIndex: importIndex,
            reexportHops: 0,
            visited: &visited
        ) {
            return [resolved]
        }
        guard let importedName = binding.importedName else { return [] }
        return globalCandidates(
            nameID: importedName,
            from: source,
            certainty: .possible,
            dispatch: dispatch(for: kind),
            evidence: [.nameOnly(nameID: importedName)],
            context: context
        )
    }

    private func importCandidate(
        index importIndex: UInt32,
        binding: ImportBinding,
        from source: PathID,
        kind: CallKind?,
        context: QueryContext,
        evidenceIndex: UInt32,
        reexportHops: Int,
        requestedName: NameID? = nil,
        visited: inout Set<SymbolOccurrenceID>
    ) -> ResolutionCandidate? {
        let occurrence = SymbolOccurrenceID(
            snapshotID: context.snapshotID,
            pathID: source,
            localKind: .importBinding,
            localIndex: importIndex
        )
        guard visited.insert(occurrence).inserted else { return nil }
        guard let targetFile = session.moduleMap.targetFile(
            for: binding,
            from: source,
            names: session.names,
            strings: session.strings
        ) else {
            // External crates are deliberately not resolved by the M0 engine.
            return candidate(
                pathID: source,
                localKind: .importBinding,
                localIndex: importIndex,
                certainty: .unresolved,
                dispatch: dispatch(for: kind),
                evidence: [.uniqueImport(importBindingIndex: evidenceIndex)],
                context: context
            )
        }
        guard let importedName = requestedName ?? binding.importedName,
              let (_, targetIndex) = session.content(at: targetFile)
        else { return nil }
        let matches = targetIndex.symbols.enumerated().filter {
            $0.element.parentFacetIndex == nil
                && $0.element.nameID == importedName
                && $0.element.kind != .rustImpl
        }
        if matches.count == 1,
           let facetIndex = UInt32(exactly: matches[0].offset)
        {
            return candidate(
                pathID: targetFile,
                localIndex: facetIndex,
                certainty: capped(.strong, for: kind),
                dispatch: dispatch(for: kind),
                evidence: [.uniqueImport(importBindingIndex: evidenceIndex)],
                context: context
            )
        }

        guard matches.isEmpty,
              reexportHops < 4
        else { return nil }

        var reexports: [(UInt32, ImportBinding, NameID?)] = []
        for export in targetIndex.exports where export.exportedName == importedName {
            guard let index = export.sourceBindingIndex,
                  targetIndex.imports.indices.contains(Int(index))
            else { continue }
            reexports.append((index, targetIndex.imports[Int(index)], nil))
        }
        for (index, binding) in targetIndex.imports.enumerated()
            where binding.flags.contains(.reexport)
                && binding.flags.contains(.wildcard)
        {
            guard let index = UInt32(exactly: index) else { continue }
            reexports.append((index, binding, importedName))
        }

        let resolved = reexports.compactMap { index, binding, requestedName in
            var branchVisited = visited
            return importCandidate(
                index: index,
                binding: binding,
                from: targetFile,
                kind: kind,
                context: context,
                evidenceIndex: evidenceIndex,
                reexportHops: reexportHops + 1,
                requestedName: requestedName,
                visited: &branchVisited
            )
        }
        return resolved.count == 1 ? resolved[0] : nil
    }

    private func isIdentifierByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x5F
    }

    private func scopeChain(
        at offset: UInt32,
        in index: ContentIndex
    ) -> [ScopeRecord] {
        guard let innermost = index.scopes.filter({ $0.range.contains(offset) })
            .min(by: { $0.range.length < $1.range.length })
        else { return [] }
        let scopesByID = Dictionary(uniqueKeysWithValues: index.scopes.map { ($0.id, $0) })
        var result: [ScopeRecord] = []
        var current: ScopeRecord? = innermost
        while let scope = current {
            result.append(scope)
            current = scope.parent.flatMap { scopesByID[$0] }
        }
        return result
    }

    private func lexicalBinding(
        named nameID: NameID,
        at offset: UInt32,
        scopes: [ScopeRecord],
        in index: ContentIndex
    ) -> (index: UInt32, binding: BindingRecord)? {
        for scope in scopes {
            let matches = index.bindings.enumerated().filter { _, binding in
                guard binding.scopeID == scope.id,
                      binding.localNameID == nameID
                else { return false }
                return binding.kind == .param
                    || binding.declarationRange.lowerBound < offset
            }.sorted {
                $0.element.declarationRange.lowerBound
                    > $1.element.declarationRange.lowerBound
            }
            if let match = matches.first,
               let bindingIndex = UInt32(exactly: match.offset)
            {
                return (bindingIndex, match.element)
            }
        }
        return nil
    }

    private func globalCandidates(
        nameID: NameID,
        from source: PathID,
        certainty: Certainty,
        dispatch: DispatchKind,
        evidence: [ResolutionEvidence],
        context: QueryContext,
        kinds: Set<DeclarationKind>? = nil,
        space: SymbolSpace? = nil
    ) -> [ResolutionCandidate] {
        let results = session.definitionOccurrences(named: nameID).compactMap {
            occurrence, facet, _ -> ResolutionCandidate? in
            if let kinds, !kinds.contains(facet.kind) { return nil }
            if let space, facet.space != space { return nil }
            return candidate(
                pathID: occurrence.pathID,
                localIndex: occurrence.localIndex,
                certainty: certainty,
                dispatch: dispatch,
                evidence: evidence,
                context: context
            )
        }
        return sorted(results, from: source)
    }

    private func candidate(
        pathID: PathID,
        localKind: LocalOccurrenceKind = .declarationFacet,
        localIndex: UInt32,
        certainty: Certainty,
        dispatch: DispatchKind,
        evidence: [ResolutionEvidence],
        context: QueryContext
    ) -> ResolutionCandidate {
        // Design red line: this heuristic engine may emit Strong, never Exact.
        ResolutionCandidate(
            target: SymbolOccurrenceID(
                snapshotID: context.snapshotID,
                pathID: pathID,
                localKind: localKind,
                localIndex: localIndex
            ),
            certainty: min(certainty, .strong),
            dispatch: dispatch,
            provenance: .fuzzyResolver,
            completeness: .complete,
            evidence: evidence
        )
    }

    private func capped(_ certainty: Certainty, for kind: CallKind?) -> Certainty {
        if case .macroInvocation? = kind { return min(certainty, .possible) }
        return min(certainty, .strong)
    }

    private func dispatch(for kind: CallKind?) -> DispatchKind {
        switch kind {
        case .methodCall?: .dynamicDispatch
        case .macroInvocation?: .macroGenerated
        default: .direct
        }
    }

    private func isDirectCall(_ kind: CallKind?) -> Bool {
        if case .directCall? = kind { return true }
        return false
    }

    private func sorted(
        _ candidates: [ResolutionCandidate],
        from source: PathID
    ) -> [ResolutionCandidate] {
        let sourceDirectory = session.directory(of: source)
        return candidates.sorted {
            if $0.certainty != $1.certainty { return $0.certainty > $1.certainty }
            let lhsNearby = session.directory(of: $0.target.pathID) == sourceDirectory
            let rhsNearby = session.directory(of: $1.target.pathID) == sourceDirectory
            if lhsNearby != rhsNearby { return lhsNearby }
            let lhsPath = session.paths.resolve($0.target.pathID)
            let rhsPath = session.paths.resolve($1.target.pathID)
            if lhsPath != rhsPath { return lhsPath < rhsPath }
            return $0.target.localIndex < $1.target.localIndex
        }
    }
}
