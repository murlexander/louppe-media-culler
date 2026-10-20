import AppKit
import Carbon
import SwiftUI

struct ReviewShortcutsSettingsView: View {
    @AppStorage(ReviewShortcutPreferences.preferenceKey) private var savedShortcuts = ""
    @AppStorage(CommandShortcutPreferences.preferenceKey) private var savedCommands = ""
    @State private var preferences = ReviewShortcutPreferences.load()
    @State private var commandPreferences = CommandShortcutPreferences.load()
    @State private var layers = ReviewKeyboardLayerState()
    @State private var search = ""
    @State private var expandedGroups: Set<String> = ["review", "navigation"]
    @State private var draftAction: ReviewShortcutAction?
    @State private var addChoiceAction: ReviewShortcutAction?
    @State private var pendingAddChoice: (action: ReviewShortcutAction, command: Bool)?
    @State private var draftCommand: CommandShortcutAction?
    @State private var commandErrorAction: CommandShortcutAction?
    @State private var commandError: String?
    @State private var draftScope: ReviewShortcutScope = .all
    @State private var errorAction: ReviewShortcutAction?
    @State private var error: String?
    @State private var selectedKey: UInt16?
    @State private var layoutCharacters = ReviewKeyboardMap.currentLayoutCharacters()
    @State private var modifiedCharacters: [ReviewKeyboardLayer: [UInt16: String]] = Dictionary(uniqueKeysWithValues:
        ReviewKeyboardLayer.allCases.filter { $0 != .base }.map { ($0, ReviewKeyboardMap.currentLayoutCharacters(layer: $0)) })

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section {
            Picker(L10n.text("Match shortcuts by"), selection: Binding(
                get: { preferences.interpretation },
                set: { value in
                    var updated = preferences
                    updated.interpretation = value
                    save(updated)
                    selectedKey = nil
                    cancelDraft()
                    clearError()
                }
            )) {
                ForEach(ReviewShortcutInterpretation.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .help(matchingModeHelp)
            .accessibilityHint(matchingModeHelp)
            ReviewKeyboardView(map: keyboardMap, preferences: preferences, commandPreferences: commandPreferences,
                               toggleCommand: { layers.toggleCommand() }, toggleShift: { layers.toggleShift() }, selectedKey: $selectedKey)
                .padding(.vertical, 5)
            if let selectedKey {
                HStack {
                    Text(layers.displayed.prefix + keyboardMap.label(for: selectedKey))
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Button {
                        self.selectedKey = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("Clear selection"))
                    .accessibilityLabel(L10n.text("Clear selection"))
                }
            }
            TextField(text: $search, prompt: Text(L10n.text("Find a shortcut"))) {
                Text(L10n.text("Find a shortcut"))
            }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("louppe.shortcutSearch")

            ForEach(ReviewShortcutGroup.allCases, id: \.self) { group in
                let actions = matchingActions(in: group)
                let commands = matchingCommands(in: group)
                if !actions.isEmpty || !commands.isEmpty {
                    DisclosureGroup(isExpanded: groupExpansion(group)) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(actions, id: \.self) { action in
                                actionEditor(action)
                                if action != actions.last || !commands.isEmpty { Divider() }
                            }
                            ForEach(commands, id: \.self) { action in
                                commandEditor(action)
                                if action != commands.last { Divider() }
                            }
                        }
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                    } label: {
                        Text(group.title)
                    }
                }
            }
            if !ReviewShortcutAction.allCases.contains(where: matchesEditor)
                && !CommandShortcutAction.allCases.contains(where: matchesCommandEditor) {
                Text(L10n.text("No matching shortcuts."))
                    .foregroundStyle(.secondary)
            }
            Button(L10n.text("Restore shortcut defaults")) {
                var updated = preferences
                updated.resetCurrentMode()
                save(updated)
                cancelDraft()
                clearError()
                var commands = commandPreferences
                commands.resetAll()
                saveCommands(commands)
            }
            .help(L10n.text("Restore review shortcuts for this mode and all Command shortcuts."))
        } header: {
            Text(L10n.text("Keyboard shortcuts"))
        }
        .disclosureGroupStyle(ShortcutDisclosureStyle())
        .background(ShortcutModifierObserver { layers.held = $0 })
        .onAppear {
            preferences = ReviewShortcutPreferences.decode(savedShortcuts)
            commandPreferences = CommandShortcutPreferences.decode(savedCommands)
        }
        .onChange(of: savedShortcuts) { _, value in
            preferences = ReviewShortcutPreferences.decode(value)
        }
        .onChange(of: savedCommands) { _, value in commandPreferences = CommandShortcutPreferences.decode(value) }
        .onChange(of: search) { _, _ in
            if !query.isEmpty { selectedKey = nil }
            cancelDraft()
            clearError()
        }
        .onChange(of: selectedKey) { _, key in
            if key != nil { search = "" }
            cancelDraft()
            clearError()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))) { _ in
            layoutCharacters = ReviewKeyboardMap.currentLayoutCharacters()
            modifiedCharacters = Dictionary(uniqueKeysWithValues: ReviewKeyboardLayer.allCases.filter { $0 != .base }
                .map { ($0, ReviewKeyboardMap.currentLayoutCharacters(layer: $0)) })
        }
    }

    @ViewBuilder
    private func actionEditor(_ action: ReviewShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(action.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(action.contextLabel)
                    .accessibilityHint(action.contextLabel)
                addShortcutControl(for: action)
                .help(L10n.text("Add several keys to an action. A key can be shared only when its view and media contexts do not overlap."))
                .accessibilityLabel(L10n.text("Add shortcut for \(action.title)"))
                .accessibilityHint(L10n.text("Add several keys to an action. A key can be shared only when its view and media contexts do not overlap."))
                ShortcutAccessoryButton(symbol: "arrow.counterclockwise", title: L10n.text("Restore defaults for \(action.title)")) {
                    var updated = preferences
                    if updated.reset(for: action) {
                        if let command = linkedCommand(for: action), command.isEditable {
                            var commands = commandPreferences
                            guard commands.reset(for: command) else {
                                showCommandError(L10n.text("A default shortcut is already assigned to another action."), for: command)
                                return
                            }
                            saveCommands(commands)
                        }
                        save(updated)
                        if draftAction == action || draftCommand == linkedCommand(for: action) { cancelDraft() }
                        clearError()
                    } else if let conflict = updated.resetConflict(for: action) {
                        showConflict(conflict, for: action)
                    }
                }
                .help(L10n.text("Restore defaults for this action"))
                .accessibilityLabel(L10n.text("Restore defaults for \(action.title)"))
            }
            ForEach(preferences.assignments(for: action)) { assignment in
                HStack(spacing: 8) {
                    ReviewShortcutRecorder(
                        title: preferences.display(for: assignment.binding),
                        actionTitle: action.title,
                        onCapture: { binding in
                            replace(assignment, with: binding, action: action, scope: assignment.scope)
                        },
                        onInvalid: { invalidKey(for: action) }
                    )
                    .frame(width: 132, height: 26)
                    scopePicker(for: action, selection: Binding(
                        get: { assignment.scope },
                        set: { _ = replace(assignment, with: assignment.binding, action: action, scope: $0) }
                    ))
                    ShortcutAccessoryButton(symbol: "minus", title: L10n.text("Remove \(preferences.display(for: assignment.binding)) from \(action.title)")) {
                        var updated = preferences
                        guard updated.remove(assignment.id, for: action) else { return }
                        save(updated)
                        clearError()
                    }
                    .help(L10n.text("Remove shortcut"))
                    .accessibilityLabel(L10n.text("Remove \(preferences.display(for: assignment.binding)) from \(action.title)"))
                }
            }
            if draftAction == action {
                HStack(spacing: 8) {
                    ReviewShortcutRecorder(
                        title: L10n.text("Record key…"),
                        actionTitle: action.title,
                        automaticallyRecord: true,
                        onCapture: { binding in add(binding, for: action) },
                        onInvalid: { invalidKey(for: action) },
                        onCancel: cancelDraft
                    )
                    .frame(width: 132, height: 26)
                    scopePicker(for: action, selection: $draftScope)
                    ShortcutAccessoryButton(symbol: "xmark", title: L10n.text("Cancel new shortcut"), action: cancelDraft)
                    .help(L10n.text("Cancel new shortcut"))
                    .accessibilityLabel(L10n.text("Cancel new shortcut"))
                }
            } else if preferences.assignments(for: action).isEmpty {
                Text(L10n.text("No shortcut assigned"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let command = linkedCommand(for: action) { commandBindingsEditor(command) }
            if errorAction == action, let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("louppe.shortcutError")
            }
        }
    }

    @ViewBuilder
    private func addShortcutControl(for action: ReviewShortcutAction) -> some View {
        if let command = linkedCommand(for: action), command.isEditable {
            ShortcutAccessoryButton(symbol: "plus", title: L10n.text("Add shortcut for \(action.title)")) {
                addChoiceAction = action
            }
            .popover(isPresented: Binding(
                get: { addChoiceAction == action },
                set: { if !$0 { addChoiceAction = nil } }
            ), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    addChoiceButton("Single key", action: action, command: false)
                    addChoiceButton("Command shortcut", action: action, command: true)
                }
                .padding(8)
                .background(Color.appBackground)
                .onDisappear {
                    guard let choice = pendingAddChoice else { return }
                    pendingAddChoice = nil
                    // Return focus after the chooser's window has dismissed.
                    Task { @MainActor in
                        await Task.yield()
                        if choice.command { beginCommandDraft(command) }
                        else { beginDraft(choice.action) }
                    }
                }
            }
        } else {
            ShortcutAccessoryButton(symbol: "plus", title: L10n.text("Add shortcut for \(action.title)")) { beginDraft(action) }
        }
    }

    private func addChoiceButton(_ title: L10n.Message, action: ReviewShortcutAction, command: Bool) -> some View {
        Button {
            pendingAddChoice = (action, command)
            addChoiceAction = nil
        } label: {
            Text(L10n.text(title))
                .frame(width: 160, height: 26, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func beginDraft(_ action: ReviewShortcutAction) {
        cancelDraft()
        draftAction = action
        draftScope = action.defaultScope
        clearError()
    }

    private func beginCommandDraft(_ action: CommandShortcutAction) {
        cancelDraft()
        draftCommand = action
        clearError()
    }

    private func commandEditor(_ action: CommandShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(action.title).frame(maxWidth: .infinity, alignment: .leading)
                    .help(action.contextLabel).accessibilityHint(action.contextLabel)
                if action.isEditable {
                    ShortcutAccessoryButton(symbol: "plus", title: L10n.text("Add shortcut for \(action.title)")) {
                        beginCommandDraft(action)
                    }
                    ShortcutAccessoryButton(symbol: "arrow.counterclockwise", title: L10n.text("Restore defaults for \(action.title)")) {
                        var updated = commandPreferences
                        if updated.reset(for: action) { saveCommands(updated); cancelDraft(); clearError() }
                        else { showCommandError(L10n.text("A default shortcut is already assigned to another action."), for: action) }
                    }
                }
            }
            commandBindingsEditor(action)
        }
    }

    @ViewBuilder
    private func commandBindingsEditor(_ action: CommandShortcutAction) -> some View {
        ForEach(commandPreferences.bindings(for: action), id: \.self) { binding in
            HStack(spacing: 8) {
                if action.isEditable {
                    CommandShortcutRecorder(title: binding.display, actionTitle: action.title,
                        onCapture: { replacement in updateCommand(binding, with: replacement, for: action) },
                        onInvalid: { invalidCommand(for: action) })
                        .frame(width: 132, height: 26)
                } else {
                    Text(binding.display).font(.system(.body, design: .monospaced))
                        .frame(width: 132, height: 26)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.18)))
                        .accessibilityLabel(L10n.text("\(action.title): \(binding.display)"))
                        .help((action == .seekBackward || action == .seekForward)
                              ? L10n.text("Seek video by five seconds in Gallery") : L10n.text("Standard Mac shortcut"))
                }
                Spacer(minLength: 0)
                if action.contexts != ReviewShortcutScope.all.contexts || action == .slower || action == .faster {
                    Text((action == .seekBackward || action == .seekForward)
                         ? L10n.text("Seek video by five seconds in Gallery") : action.contextLabel)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if action.isEditable {
                    ShortcutAccessoryButton(symbol: "minus", title: L10n.text("Remove \(binding.display) from \(action.title)")) {
                        var updated = commandPreferences
                        if updated.remove(binding, for: action) { saveCommands(updated); clearError() }
                    }.help(L10n.text("Remove shortcut"))
                }
            }
        }
        if draftCommand == action {
            HStack(spacing: 8) {
                CommandShortcutRecorder(title: L10n.text("Record key…"), actionTitle: action.title,
                    automaticallyRecord: true, onCapture: { updateCommand(nil, with: $0, for: action) },
                    onInvalid: { invalidCommand(for: action) }, onCancel: cancelDraft)
                    .frame(width: 132, height: 26)
                Spacer(minLength: 0)
                ShortcutAccessoryButton(symbol: "xmark", title: L10n.text("Cancel new shortcut"), action: cancelDraft)
            }
        } else if commandPreferences.bindings(for: action).isEmpty {
            Text(L10n.text("No shortcut assigned")).font(.caption).foregroundStyle(.secondary)
        }
        if commandErrorAction == action, let commandError {
            Text(commandError).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("louppe.commandShortcutError")
        }
    }

    private func updateCommand(_ original: CommandShortcutBinding?, with replacement: CommandShortcutBinding,
                               for action: CommandShortcutAction) -> Bool {
        var updated = commandPreferences
        if let conflict = updated.conflict(for: replacement, action: action, excluding: original) {
            showCommandError(conflict, for: action)
            return false
        }
        let accepted = original.map { updated.replace($0, with: replacement, for: action) }
            ?? updated.add(replacement, for: action)
        guard accepted else { invalidCommand(for: action); return false }
        saveCommands(updated)
        if selectedKey != nil {
            layers.latched = .init(command: true, shift: replacement.modifiers == .commandShift)
            selectedKey = replacement.keyCode
        }
        cancelDraft()
        clearError()
        return true
    }

    private func invalidCommand(for action: CommandShortcutAction) {
        showCommandError(L10n.text("Press Command and a letter. Add Shift if needed."), for: action)
    }

    private func showCommandError(_ message: String, for action: CommandShortcutAction) {
        commandErrorAction = action
        commandError = message
    }

    private func saveCommands(_ updated: CommandShortcutPreferences) {
        commandPreferences = updated
        savedCommands = updated.encoded
    }

    private var matchingModeHelp: String {
        [L10n.text("Physical positions keep the same finger movements on Dvorak and other layouts. Position names refer to a QWERTY keyboard."),
         L10n.text("Bindings are saved separately for each matching mode.")]
            .joined(separator: " ")
    }

    private func scopePicker(for action: ReviewShortcutAction, selection: Binding<ReviewShortcutScope>) -> some View {
        Picker(selection.wrappedValue.title, selection: selection) {
            ForEach(distinctScopes(for: action, current: selection.wrappedValue), id: \.self) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .accessibilityLabel(L10n.text("When \(action.title) applies"))
        .accessibilityValue(selection.wrappedValue.title)
        .help(selection.wrappedValue.title)
        .disabled(distinctScopes(for: action, current: selection.wrappedValue).count == 1)
    }

    /// Different scope names can mean the same thing for a limited action.
    /// Compare the model's effective contexts and keep the saved label selected.
    private func distinctScopes(for action: ReviewShortcutAction, current: ReviewShortcutScope) -> [ReviewShortcutScope] {
        var scopes: [ReviewShortcutScope] = []
        var contexts: [Set<ReviewShortcutContext>] = []
        let candidates = [action.defaultScope] + action.allowedScopes.filter { $0 != action.defaultScope }
        for scope in candidates {
            let effective = preferences.effectiveContexts(for: action, scope: scope)
            if let index = contexts.firstIndex(of: effective) {
                if scope == current { scopes[index] = scope }
            } else {
                contexts.append(effective)
                scopes.append(scope)
            }
        }
        return scopes
    }

    private func matchingActions(in group: ReviewShortcutGroup) -> [ReviewShortcutAction] {
        ReviewShortcutAction.allCases.filter { $0.group == group && matchesEditor($0) }
    }

    private var keyboardMap: ReviewKeyboardMap {
        ReviewKeyboardMap(interpretation: preferences.interpretation, layoutCharacters: layoutCharacters,
                          layer: layers.displayed, modifiedCharacters: modifiedCharacters[layers.displayed] ?? [:])
    }

    private func linkedCommand(for action: ReviewShortcutAction) -> CommandShortcutAction? {
        CommandShortcutAction.allCases.first { $0.reviewAction == action }
    }

    private func matchingCommands(in group: ReviewShortcutGroup) -> [CommandShortcutAction] {
        CommandShortcutAction.allCases.filter { $0.reviewAction == nil && $0.group == group && matchesCommandEditor($0) }
    }

    private func matchesCommandEditor(_ action: CommandShortcutAction) -> Bool {
        if let selectedKey, !keyboardMap.commandActions(for: selectedKey, preferences: commandPreferences).contains(action) { return false }
        guard !query.isEmpty else { return true }
        return ([action.title, action.group.title, action.contextLabel] + commandPreferences.bindings(for: action).map(\.display))
            .joined(separator: " ").localizedStandardContains(query)
    }

    private func matchesEditor(_ action: ReviewShortcutAction) -> Bool {
        if let selectedKey {
            let baseMatch = keyboardMap.actions(for: selectedKey, preferences: preferences).contains(action)
            let commandMatch = linkedCommand(for: action).map {
                keyboardMap.commandActions(for: selectedKey, preferences: commandPreferences).contains($0)
            } ?? false
            if !baseMatch && !commandMatch { return false }
        }
        return matchesSearch(action)
    }

    private func matchesSearch(_ action: ReviewShortcutAction) -> Bool {
        guard !query.isEmpty else { return true }
        let commandHints = linkedCommand(for: action).map { commandPreferences.bindings(for: $0).map(\.display) } ?? []
        let text = ([action.title, action.group.title, action.contextLabel] + commandHints
            + preferences.assignments(for: action).flatMap { [preferences.display(for: $0.binding), $0.scope.title] })
            .joined(separator: " ")
        return text.localizedStandardContains(query)
    }

    private func groupExpansion(_ group: ReviewShortcutGroup) -> Binding<Bool> {
        Binding(
            get: { selectedKey != nil || !query.isEmpty || expandedGroups.contains(group.rawValue) },
            set: { expanded in
                if expanded { expandedGroups.insert(group.rawValue) }
                else {
                    expandedGroups.remove(group.rawValue)
                    if draftAction?.group == group || draftCommand?.group == group {
                        cancelDraft()
                        clearError()
                    }
                }
            }
        )
    }

    private func add(_ binding: ReviewShortcutBinding, for action: ReviewShortcutAction) -> Bool {
        var updated = preferences
        if let conflict = updated.conflict(for: binding, action: action, scope: draftScope) {
            showConflict(conflict, for: action)
            return false
        }
        guard updated.add(binding, for: action, scope: draftScope) else { invalidKey(for: action); return false }
        save(updated)
        cancelDraft()
        clearError()
        return true
    }

    private func replace(_ assignment: ReviewShortcutAssignment, with binding: ReviewShortcutBinding,
                         action: ReviewShortcutAction, scope: ReviewShortcutScope) -> Bool {
        var updated = preferences
        if let conflict = updated.conflict(for: binding, action: action, scope: scope, excludingID: assignment.id) {
            showConflict(conflict, for: action)
            return false
        }
        guard updated.replace(assignment.id, with: binding, for: action, scope: scope) else {
            invalidKey(for: action)
            return false
        }
        save(updated)
        if selectedKey != nil, binding != assignment.binding {
            layers.latched = .base
            selectedKey = binding.keyCode
        }
        clearError()
        return true
    }

    private func showConflict(_ conflict: ReviewShortcutConflict, for action: ReviewShortcutAction) {
        showError(L10n.text("Already used for \(conflict.action.title) in \(conflict.contextLabel). Choose another key or a separate context."), for: action)
    }

    private func invalidKey(for action: ReviewShortcutAction) {
        showError(L10n.text("Press one letter, number, punctuation key, arrow, Tab, or Space without modifiers."), for: action)
    }

    private func save(_ updated: ReviewShortcutPreferences) {
        preferences = updated
        savedShortcuts = updated.encoded
    }

    private func showError(_ message: String, for action: ReviewShortcutAction) {
        errorAction = action
        error = message
    }

    private func clearError() {
        errorAction = nil
        error = nil
        commandErrorAction = nil
        commandError = nil
    }

    private func cancelDraft() {
        draftAction = nil
        draftCommand = nil
        addChoiceAction = nil
    }
}

/// Only this focused control receives recording events. It never installs a
/// monitor or routes keys through the session's shortcut handler.
/// Keep the header's entire layout rectangle interactive without allowing
/// clicks on the expanded editor to toggle its parent section.
struct ShortcutDisclosureStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .accessibilityHidden(true)
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: configuration.isExpanded)
                        .frame(width: 12)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? L10n.text("Expanded") : L10n.text("Collapsed"))

            if configuration.isExpanded { configuration.content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Fixed symbol bounds keep every native accessory button the same size.
struct ShortcutAccessoryButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .accessibilityLabel(title)
    }
}

/// A window-owned observer previews modifier layers without consuming input.
/// Recording controls retain their own keys; another app or Settings window
/// never changes this view's preview.
struct ShortcutModifierObserver: NSViewRepresentable {
    var onChange: (ReviewKeyboardLayer) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onChange = onChange
        return view
    }
    func updateNSView(_ view: MonitorView, context: Context) {
        view.onChange = onChange
        view.installIfNeeded()
    }
    static func dismantleNSView(_ view: MonitorView, coordinator: Void) { view.removeMonitor() }

    final class MonitorView: NSView {
        var onChange: (ReviewKeyboardLayer) -> Void = { _ in }
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        var isInstalled: Bool { monitor != nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { removeMonitor() } else { installIfNeeded() }
        }
        func installIfNeeded() {
            guard let window, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.preview(event)
                return event
            }
            for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
                                   (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange(.base) }
                })
            }
        }
        func preview(_ event: NSEvent) {
            guard let window, window.isKeyWindow, NSApp.isActive, event.window == nil || event.window === window else { return }
            if let recorder = window.firstResponder as? ReviewShortcutRecorderButton, recorder.isRecording { onChange(.base); return }
            if let recorder = window.firstResponder as? CommandShortcutRecorderButton, recorder.isRecording { onChange(.base); return }
            let flags = event.modifierFlags
            guard !(NSWorkspace.shared.isVoiceOverEnabled && flags.contains(.capsLock)) else { onChange(.base); return }
            guard flags.intersection([.control, .option, .function, .help]).isEmpty else { onChange(.base); return }
            onChange(.init(command: flags.contains(.command), shift: flags.contains(.shift)))
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            onChange(.base)
        }
    }
}

struct CommandShortcutRecorder: NSViewRepresentable {
    var title: String
    var actionTitle: String
    var automaticallyRecord = false
    var onCapture: (CommandShortcutBinding) -> Bool
    var onInvalid: () -> Void
    var onCancel: () -> Void = {}

    func makeNSView(context: Context) -> CommandShortcutRecorderButton {
        let button = CommandShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(CommandShortcutRecorderButton.startRecording)
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: CommandShortcutRecorderButton, context: Context) {
        button.shortcutTitle = title
        button.actionTitle = actionTitle
        button.onCapture = onCapture
        button.onInvalid = onInvalid
        button.onCancel = onCancel
        button.automaticallyRecord = automaticallyRecord
        button.refreshTitle()
        button.startAutomaticallyIfNeeded()
    }
}

final class CommandShortcutRecorderButton: NSButton {
    var shortcutTitle = ""
    var actionTitle = ""
    var onCapture: ((CommandShortcutBinding) -> Bool)?
    var onInvalid: (() -> Void)?
    var onCancel: (() -> Void)?
    var automaticallyRecord = false
    private var didAutomaticallyRecord = false
    private(set) var isRecording = false
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); startAutomaticallyIfNeeded() }
    func startAutomaticallyIfNeeded() {
        guard automaticallyRecord, !didAutomaticallyRecord, window != nil else { return }
        didAutomaticallyRecord = true
        startRecording()
    }
    @objc func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        refreshTitle()
    }
    func refreshTitle() {
        title = isRecording ? L10n.text("Press a shortcut…") : shortcutTitle
        setAccessibilityLabel(L10n.text("\(actionTitle): \(title)"))
        setAccessibilityHelp(L10n.text("Click to record a shortcut. Escape cancels."))
    }
    override func resignFirstResponder() -> Bool { cancelRecording(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        guard acceptsRecording(event) else { cancelRecording(); return false }
        record(event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        guard acceptsRecording(event) else { cancelRecording(); return super.keyDown(with: event) }
        record(event)
    }
    private func acceptsRecording(_ event: NSEvent) -> Bool {
        if event.keyCode == 48, !event.modifierFlags.contains(.command) { return false }
        var flags = event.modifierFlags
        if 123...126 ~= event.keyCode { flags.subtract([.numericPad, .function]) }
        return flags.intersection([.control, .option, .function, .help]).isEmpty
            && !(NSWorkspace.shared.isVoiceOverEnabled && flags.contains(.capsLock))
    }
    private func cancelRecording() { isRecording = false; refreshTitle() }
    private func record(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { cancelRecording(); onCancel?(); return }
        guard let binding = CommandShortcutBinding.capture(event) else { onInvalid?(); return }
        if onCapture?(binding) == true { cancelRecording() }
    }
}

struct ReviewShortcutRecorder: NSViewRepresentable {
    var title: String
    var actionTitle: String
    var automaticallyRecord = false
    var onCapture: (ReviewShortcutBinding) -> Bool
    var onInvalid: () -> Void
    var onCancel: () -> Void = {}

    func makeNSView(context: Context) -> ReviewShortcutRecorderButton {
        let button = ReviewShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.target = button
        button.action = #selector(ReviewShortcutRecorderButton.startRecording)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: ReviewShortcutRecorderButton, context: Context) {
        button.shortcutTitle = title
        button.actionTitle = actionTitle
        button.onCapture = onCapture
        button.onInvalid = onInvalid
        button.onCancel = onCancel
        button.automaticallyRecord = automaticallyRecord
        button.refreshTitle()
        button.startAutomaticallyIfNeeded()
    }
}

final class ReviewShortcutRecorderButton: NSButton {
    var shortcutTitle = ""
    var actionTitle = ""
    var onCapture: ((ReviewShortcutBinding) -> Bool)?
    var onInvalid: (() -> Void)?
    var onCancel: (() -> Void)?
    var automaticallyRecord = false
    private var didAutomaticallyRecord = false
    private(set) var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startAutomaticallyIfNeeded()
    }

    func startAutomaticallyIfNeeded() {
        guard automaticallyRecord, !didAutomaticallyRecord, window != nil else { return }
        didAutomaticallyRecord = true
        startRecording()
    }

    @objc func startRecording() {
        isRecording = true
        window?.makeFirstResponder(self)
        refreshTitle()
    }

    func refreshTitle() {
        title = isRecording ? L10n.text("Press a key…") : shortcutTitle
        setAccessibilityLabel(L10n.text("\(actionTitle): \(title)"))
        setAccessibilityHelp(L10n.text("Click to record a shortcut. Escape cancels."))
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        if preservesNativeOwnership(of: event) {
            cancelRecording()
            return false
        }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        if preservesNativeOwnership(of: event) {
            cancelRecording()
            return super.keyDown(with: event)
        }
        record(event)
    }

    private func preservesNativeOwnership(of event: NSEvent) -> Bool {
        var modifiers = event.modifierFlags
        // AppKit attaches these flags to ordinary arrows. Match the session
        // router's normalization while preserving real modified/native chords.
        if 123...126 ~= event.keyCode { modifiers.subtract([.numericPad, .function]) }
        let nativeModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .function, .help]
        return !modifiers.intersection(nativeModifiers).isEmpty
            || (NSWorkspace.shared.isVoiceOverEnabled && modifiers.contains(.capsLock))
    }

    private func cancelRecording() {
        isRecording = false
        refreshTitle()
    }

    private func record(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 {
            cancelRecording()
            onCancel?()
            return
        }
        guard let binding = ReviewShortcutBinding.capture(event) else {
            onInvalid?()
            return
        }
        if onCapture?(binding) == true {
            cancelRecording()
        }
    }
}
