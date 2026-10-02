import AppKit
import CodeInsightAppModel
import SwiftUI

/// One active recorder (K-R3.3). A local event monitor swallows key events
/// while recording, so menu key equivalents (⌘R …) never fire mid-recording;
/// Esc cancels, ⌫ clears the edited binding, modifier-only presses are
/// ignored, and gesture rows record the first click's modifier set.
@MainActor
final class KeyChordRecordingSession {
    struct Decision: Equatable {
        var swallow = false
        var recorded: KeyBinding?
        var cancelled = false
        var cleared = false

        static let ignore = Decision()
    }

    /// What the recorder did with the latest event — the self-test and the
    /// settings model both read it.
    private(set) var captured: Decision = .ignore
    private let isGesture: Bool
    private let onDecision: @MainActor (Decision) -> Void
    private var monitor: Any?
    /// The window the recording belongs to. The local monitor sees every
    /// window's events; one from another window (Settings closed or left
    /// mid-recording) ends the recording and passes through untouched, so
    /// it can never be captured as a binding. Nil accepts any window.
    private let windowNumber: Int?

    init(
        isGesture: Bool,
        windowNumber: Int? = nil,
        onDecision: @escaping @MainActor (Decision) -> Void
    ) {
        self.isGesture = isGesture
        self.windowNumber = windowNumber
        self.onDecision = onDecision
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) {
            [weak self] event in
            let swallowed = MainActor.assumeIsolated {
                self?.consume(event) ?? false
            }
            return swallowed ? nil : event
        }
    }

    /// Consumes an event while recording; true means the event was swallowed
    /// before it could reach menus or the responder chain.
    private func consume(_ event: NSEvent) -> Bool {
        if let windowNumber, event.windowNumber != windowNumber {
            onDecision(Decision(cancelled: true))
            return false
        }
        let decision = evaluate(event)
        guard decision.swallow else { return false }
        captured = decision
        onDecision(decision)
        return true
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

        /// Pure event → decision mapping (unit tested); swallow means the event
    /// never reaches menus or the responder chain.
    func evaluate(_ event: NSEvent) -> Decision {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 { // Esc
                return Decision(swallow: true, cancelled: true)
            }
            guard let chord = KeyChord(event: event) else {
                // Modifier-only press: ignore and keep recording (K-R3.3).
                return Decision(swallow: true)
            }
            if case .special(.delete) = chord.key {
                return Decision(swallow: true, cleared: true)
            }
            if isGesture {
                // Gesture rows ignore plain typing.
                return Decision(swallow: false)
            }
            return Decision(swallow: true, recorded: .keyboard(chord))
        case .leftMouseDown:
            guard isGesture else { return .ignore }
            let modifiers = Set<KeyChord.Modifier>(event.modifierFlags)
            return Decision(swallow: true, recorded: .click(modifiers))
        default:
            return .ignore
        }
    }
}

/// Settings-page state (K0b): the effective table plus search, filter, and
/// recording state. Every mutation goes through `commit`, which hands the
/// new table to the application (persist + rebuild every surface) and gets
/// the authoritative table back via `applyCommitted`.
@MainActor
@Observable
final class KeyBindingSettingsModel {
    enum Tab: String {
        case reader
        case exact
        case keybindings
    }

    struct PendingConflict: Equatable {
        let command: CommandID
        let slot: Int?
        let binding: KeyBinding
        let other: CommandID
    }

    struct RowError: Equatable {
        let command: CommandID
        let message: String
    }

    private(set) var table: KeyBindingTable
    var selectedTab: Tab = .reader {
        didSet {
            if selectedTab != .keybindings { endRecording() }
        }
    }
    private(set) var recording: (command: CommandID, slot: Int?)?
    private(set) var pendingConflict: PendingConflict?
    private(set) var rowError: RowError?
    var query = ""
    var keySearchChord: KeyChord?
    var filterModifiedOnly = false
    private let onCommit: @MainActor (KeyBindingTable) -> Void
    private var recordingSession: KeyChordRecordingSession?

    init(table: KeyBindingTable, onCommit: @escaping @MainActor (KeyBindingTable) -> Void) {
        self.table = table
        self.onCommit = onCommit
    }

    // MARK: Read points (self-test / tests)

    var visibleCommandCount: Int {
        visibleCommands.values.reduce(0) { $0 + $1.count }
    }

    func keycapTexts(commandID: String) -> [String] {
        guard let id = table.commands.first(where: { $0.id.rawValue == commandID })?.id else {
            return []
        }
        return table.bindings(for: id).map { table.displayString($0) }
    }

    func isModified(_ id: CommandID) -> Bool {
        table.modifiedCommands.contains(id)
    }

    var modifiedCount: Int { table.modifiedCommands.count }

    func isLocked(_ id: CommandID) -> Bool {
        table.bindings(for: id).contains { table.isLocked($0) }
    }

    /// Commands added by the lens type-follow work (P1 / P3) carry the
    /// "新增" tag until the next release (K-R3.2).
    static let newCommands: Set<CommandID> = [
        .navigateTypeDefinition, .readerGestureTypeDefinition,
        .lensTrackSymbol, .lensTrackEnclosing, .lensTogglePin,
    ]

    func isNew(_ id: CommandID) -> Bool { Self.newCommands.contains(id) }

    // MARK: Search & filter (K-R3.4)

    var visibleCommands: [CodeInsightAppModel.CommandGroup: [CommandDefinition]] {
        var result: [CodeInsightAppModel.CommandGroup: [CommandDefinition]] = [:]
        let queryKey = query.trimmingCharacters(in: .whitespaces).lowercased()
        for definition in table.commands {
            if filterModifiedOnly && !isModified(definition.id) { continue }
            if let chord = keySearchChord,
               !table.bindings(for: definition.id).contains(.keyboard(chord))
            {
                continue
            }
            if !queryKey.isEmpty {
                let title = localized(definition.titleKey).lowercased()
                let group = Self.groupTitle(definition.group).lowercased()
                let shortcuts = table.bindings(for: definition.id)
                    .map { table.displayString($0) }.joined(separator: " ")
                    .lowercased()
                let idMatch = definition.id.rawValue.lowercased().contains(queryKey)
                if !title.contains(queryKey), !group.contains(queryKey),
                   !shortcuts.contains(queryKey), !idMatch
                {
                    continue
                }
            }
            result[definition.group, default: []].append(definition)
        }
        return result
    }

    static func groupTitle(_ group: CodeInsightAppModel.CommandGroup) -> String {
        localized("keybinding.group.\(group.rawValue)")
    }

    // MARK: Mutations

    /// Begins recording for a command; `slot` nil means "add a new binding".
    func beginRecording(command: CommandID, slot: Int?, in window: NSWindow? = nil) {
        guard pendingConflict == nil else { return }
        endRecording()
        rowError = nil
        recording = (command, slot)
        let commandID = command
        let slotValue = slot
        let session = KeyChordRecordingSession(
            isGesture: isGestureCommand(commandID),
            windowNumber: window?.windowNumber
        ) { [weak self] decision in
            self?.handle(decision, command: commandID, slot: slotValue)
        }
        recordingSession = session
        session.start()
    }

    private func isGestureCommand(_ id: CommandID) -> Bool {
        table.definition(for: id)?.group == .readerGestures
    }

    func endRecording() {
        recordingSession?.stop()
        recordingSession = nil
        recording = nil
    }

    private func handle(
        _ decision: KeyChordRecordingSession.Decision, command: CommandID, slot: Int?
    ) {
        if decision.cancelled {
            endRecording()
            return
        }
        if decision.cleared {
            commit { table in
                var bindings = table.bindings(for: command)
                if let slot, bindings.indices.contains(slot) {
                    bindings.remove(at: slot)
                }
                table.setBindings(bindings, for: command)
            }
            endRecording()
            return
        }
        guard let binding = decision.recorded else { return }
        record(binding, for: command, slot: slot)
    }

    /// Applies a recorded binding: validates (K-R2), then either applies,
    /// surfaces the conflict bar, or shows the red error under the row.
    func record(_ binding: KeyBinding, for command: CommandID, slot: Int?) {
        switch table.validate(binding, for: command) {
        case .ok:
            commit { table in
                var bindings = table.bindings(for: command)
                if let slot, bindings.indices.contains(slot) {
                    bindings[slot] = binding
                } else {
                    bindings.append(binding)
                }
                table.setBindings(bindings, for: command)
            }
            endRecording()
        case let .conflict(other):
            pendingConflict = PendingConflict(
                command: command, slot: slot, binding: binding, other: other
            )
            endRecording()
        case .locked:
            rowError = RowError(
                command: command, message: localized("keybinding.error.locked")
            )
            endRecording()
        case .needsModifier:
            rowError = RowError(
                command: command, message: localized("keybinding.error.needsModifier")
            )
            endRecording()
        case .duplicateOnSameCommand:
            rowError = RowError(
                command: command, message: localized("keybinding.error.duplicate")
            )
            endRecording()
        }
    }

    func cancelConflict() {
        pendingConflict = nil
    }

    /// K-R2.3: the conflict bar's "替换". Removes the edited slot (when the
    /// recording started on an existing keycap), takes the binding from the
    /// other command, and applies both as one commit.
    func replaceConflict() {
        guard let pending = pendingConflict else { return }
        commit { table in
            var bindings = table.bindings(for: pending.command)
            if let slot = pending.slot, bindings.indices.contains(slot) {
                bindings.remove(at: slot)
            }
            table.setBindings(bindings, for: pending.command)
            table.replace(pending.binding, for: pending.command, takingFrom: pending.other)
        }
        pendingConflict = nil
    }

    func reset(_ id: CommandID) {
        commit { $0.reset(id) }
        rowError = nil
    }

    func resetAll() {
        commit { $0.resetAll() }
        endRecording()
        rowError = nil
    }

    func clearKeySearch() {
        keySearchChord = nil
    }

    /// The one-shot recorder behind "按键搜索" (K-R3.4): the first chord,
    /// Esc, or a key from another window ends it — it must never keep
    /// swallowing the application's keys.
    func makeKeySearchSession(in window: NSWindow?) -> KeyChordRecordingSession {
        var session: KeyChordRecordingSession?
        let created = KeyChordRecordingSession(
            isGesture: false,
            windowNumber: window?.windowNumber
        ) { [weak self] decision in
            guard decision.recorded != nil || decision.cancelled || decision.cleared
            else { return }
            session?.stop()
            session = nil
            guard let self, let binding = decision.recorded,
                  case let .keyboard(chord) = binding
            else { return }
            self.keySearchChord = chord
        }
        session = created
        return created
    }

    private func commit(_ mutate: (inout KeyBindingTable) -> Void) {
        var table = self.table
        mutate(&table)
        onCommit(table)
    }

    /// Called back by the application after a commit was applied and
    /// persisted; also the path for external table updates.
    func applyCommitted(_ table: KeyBindingTable) {
        self.table = table
    }
}

/// The "快捷键" settings page (K-R3): grouped single-column list with
/// sticky section headers, recording keycaps, inline conflicts, and search.
struct KeybindingsSettingsView: View {
    @Bindable var model: KeyBindingSettingsModel
    @State private var confirmsResetAll = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(12)
            Divider()
            listBody
            Divider()
            footer.padding(12)
        }
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(
                    localized("keybinding.search"), text: $model.query
                )
                .textFieldStyle(.plain)
                .accessibilityIdentifier("keybinding.search")
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                keySearchButton
            }
            HStack(spacing: 8) {
                filterChip(
                    title: localized("keybinding.filter.all"),
                    active: !model.filterModifiedOnly,
                    identifier: "keybinding.filter.all"
                ) {
                    model.filterModifiedOnly = false
                }
                filterChip(
                    title: localizedFormat(
                        "keybinding.filter.modified", model.modifiedCount
                    ),
                    active: model.filterModifiedOnly,
                    identifier: "keybinding.filter.modified"
                ) {
                    model.filterModifiedOnly = true
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var keySearchButton: some View {
        if let chord = model.keySearchChord {
            Button {
                model.clearKeySearch()
            } label: {
                KeyCap(text: model.table.displayString(.keyboard(chord)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("keybinding.keySearch.clear")
            .help(localized("keybinding.keySearch.clear.hint"))
        } else {
            Button {
                startKeySearch()
            } label: {
                Image(systemName: "keyboard")
            }
            .accessibilityIdentifier("keybinding.keySearch")
            .help(localized("keybinding.keySearch.hint"))
        }
    }

    @State private var keySearchSession: KeyChordRecordingSession?

    private func startKeySearch() {
        keySearchSession?.stop()
        keySearchSession = model.makeKeySearchSession(in: NSApp.keyWindow)
        keySearchSession?.start()
    }

    private func filterChip(
        title: String, active: Bool, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(active ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .overlay(Capsule().stroke(Color.secondary.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var listBody: some View {
        let visible = model.visibleCommands
        if visible.isEmpty {
            VStack(spacing: 6) {
                Text(localized("keybinding.empty.title"))
                    .font(.headline)
                Text(localized("keybinding.empty.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(CodeInsightAppModel.CommandGroup.allCases, id: \.self) { group in
                        if let commands = visible[group], !commands.isEmpty {
                            Section {
                                ForEach(commands, id: \.id) { definition in
                                    KeyBindingRow(model: model, definition: definition)
                                    Divider()
                                }
                            } header: {
                                HStack {
                                    Text(KeyBindingSettingsModel.groupTitle(group))
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(.bar)
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("keybinding.list")
        }
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(localized("keybinding.footer"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(localized("keybinding.resetAll")) {
                confirmsResetAll = true
            }
            .accessibilityIdentifier("keybinding.resetAll")
            .confirmationDialog(
                localized("keybinding.resetAll.confirm"),
                isPresented: $confirmsResetAll,
                titleVisibility: .visible
            ) {
                Button(localized("keybinding.resetAll"), role: .destructive) {
                    model.resetAll()
                }
                Button(localized("settings.cancel"), role: .cancel) {}
            }
        }
    }
}

private struct KeyBindingRow: View {
    @Bindable var model: KeyBindingSettingsModel
    let definition: CommandDefinition
    @State private var hovering = false

    private var bindings: [KeyBinding] {
        model.table.bindings(for: definition.id)
    }

    private var isLockedRow: Bool { model.isLocked(definition.id) }
    private var isFixedRow: Bool { definition.group == .panels }
    private var isGestureRow: Bool { definition.group == .readerGestures }
    private var isRecording: Bool {
        model.recording?.command == definition.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.isModified(definition.id) ? Color.accentColor : Color.clear)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(localized(definition.titleKey))
                    .lineLimit(1)
                if model.isNew(definition.id) {
                    Text(localized("keybinding.newTag"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Spacer()
                keycaps
                if model.isModified(definition.id) {
                    Button(localized("keybinding.reset")) {
                        model.reset(definition.id)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .accessibilityIdentifier("keybinding.reset.\(definition.id.rawValue)")
                }
                if isLockedRow {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(localized("keybinding.error.locked"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            if isRecording {
                recordingHint
            }
            if let error = model.rowError, error.command == definition.id {
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("keybinding.error.\(definition.id.rawValue)")
            }
            if let pending = model.pendingConflict, pending.command == definition.id {
                conflictBar(pending)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("keybinding.row.\(definition.id.rawValue)")
    }

    @ViewBuilder
    private var keycaps: some View {
        if isRecording {
            if model.recording?.slot == nil, !bindings.isEmpty {
                KeyCap(text: localized("keybinding.recording.keyboard"), isPlaceholder: true)
            } else {
                KeyCap(
                    text: localized(
                        isGestureRow ? "keybinding.recording.gesture" : "keybinding.recording.keyboard"
                    ),
                    isPlaceholder: true
                )
            }
        } else if bindings.isEmpty {
            KeyCap(text: localized("keybinding.none"), isPlaceholder: true)
        } else {
            HStack(spacing: 4) {
                ForEach(bindings, id: \.self) { binding in
                    KeyCap(
                        text: model.table.displayString(binding),
                        isFixed: isFixedRow,
                        isLocked: model.table.isLocked(binding)
                    )
                    .accessibilityIdentifier(keycapIdentifier(binding))
                    .onTapGesture {
                        guard !isFixedRow, !isLockedRow,
                              let slot = bindings.firstIndex(of: binding)
                        else { return }
                        model.beginRecording(command: definition.id, slot: slot, in: NSApp.keyWindow)
                    }
                }
                if hovering, !isFixedRow, !isLockedRow {
                    Button {
                        model.beginRecording(command: definition.id, slot: nil, in: NSApp.keyWindow)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("keybinding.add.\(definition.id.rawValue)")
                    .help(localized("keybinding.add.hint"))
                }
            }
        }
    }

    private var recordingHint: some View {
        Text(localized(
            isGestureRow ? "keybinding.recording.gesture.hint" : "keybinding.recording.hint"
        ))
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
    }

    private func conflictBar(_ pending: KeyBindingSettingsModel.PendingConflict) -> some View {
        HStack(spacing: 8) {
            Text(localizedFormat(
                "keybinding.conflict.format",
                model.table.displayString(pending.binding),
                localized(
                    model.table.titleKey(for: pending.other) ?? pending.other.rawValue
                )
            ))
            .font(.caption)
            .lineLimit(2)
            Spacer()
            Button(localized("keybinding.conflict.replace")) {
                model.replaceConflict()
            }
            .accessibilityIdentifier("keybinding.conflict.replace")
            Button(localized("keybinding.conflict.cancel")) {
                model.cancelConflict()
            }
            .accessibilityIdentifier("keybinding.conflict.cancel")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yellow.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.yellow.opacity(0.55), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .accessibilityIdentifier("keybinding.conflict")
    }

    private func keycapIdentifier(_ binding: KeyBinding) -> String {
        "keybinding.keycap.\(definition.id.rawValue)."
            + model.table.displayString(binding)
    }
}

/// A keycap: bordered monospaced capsule. Fixed panel keys render filled and
/// read-only; placeholders ("按下组合键…", "未设置") render dashed.
struct KeyCap: View {
    let text: String
    var isPlaceholder = false
    var isFixed = false
    var isLocked = false

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isFixed ? Color.secondary.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        isPlaceholder ? Color.secondary.opacity(0.4) : Color.secondary.opacity(0.7),
                        style: StrokeStyle(lineWidth: 1, dash: isPlaceholder ? [3] : [])
                    )
            )
            .foregroundStyle(isPlaceholder ? .secondary : .primary)
    }
}
