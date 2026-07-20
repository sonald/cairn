import CodeInsightCore

struct Resolver {
    let session: EngineSession

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
        if !sameFile.isEmpty { return sorted(sameFile, from: file) }

        let visibleScopes = Set(scopes.map(\.id))
        var imported: [ResolutionCandidate] = []
        var unresolved: [ResolutionCandidate] = []
        for (importIndex, binding) in index.imports.enumerated()
            where binding.localName == located.nameID
                && visibleScopes.contains(binding.scopeID)
        {
            guard let importIndex = UInt32(exactly: importIndex) else { continue }
            guard let targetFile = session.moduleMap.targetFile(
                for: binding,
                from: file,
                names: session.names,
                strings: session.strings
            ) else {
                // External crates are deliberately not resolved by the M0 engine.
                unresolved.append(candidate(
                    pathID: file,
                    localKind: .importBinding,
                    localIndex: importIndex,
                    certainty: .unresolved,
                    dispatch: dispatch(for: kind),
                    evidence: [.uniqueImport(importBindingIndex: importIndex)],
                    context: context
                ))
                continue
            }
            guard let importedName = binding.importedName,
                  let (_, targetIndex) = session.content(at: targetFile)
            else { continue }
            let matches = targetIndex.symbols.enumerated().filter {
                $0.element.parentFacetIndex == nil
                    && $0.element.nameID == importedName
            }
            guard matches.count == 1,
                  let facetIndex = UInt32(exactly: matches[0].offset)
            else { continue }
            imported.append(candidate(
                pathID: targetFile,
                localIndex: facetIndex,
                certainty: capped(.strong, for: kind),
                dispatch: dispatch(for: kind),
                evidence: [.uniqueImport(importBindingIndex: importIndex)],
                context: context
            ))
        }
        if !imported.isEmpty { return sorted(imported, from: file) }
        if !unresolved.isEmpty { return unresolved }

        let definitions = session.definitionOccurrences(named: located.nameID)
        let hasVisibleGlob = index.imports.contains {
            $0.flags.contains(.wildcard) && visibleScopes.contains($0.scopeID)
        }
        let hasVisibleNamedImport = index.imports.contains {
            $0.localName == located.nameID && visibleScopes.contains($0.scopeID)
        }
        let certainty: Certainty = definitions.count == 1
            && !hasVisibleGlob && !hasVisibleNamedImport
            ? .probable : .possible
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
    ) -> (nameID: NameID, call: UnresolvedCall?)? {
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
            return (match.nameID, match.call)
        }

        // TODO(M0): ASCII fallback only; persist local-reference ranges if
        // navigation expands beyond the M0 binding-shadowing check.
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
        guard index.bindings.contains(where: { $0.localNameID == nameID }) else {
            return nil
        }
        return (nameID, nil)
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
