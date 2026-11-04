import AppKit
import Carbon
import SwiftUI

enum ReviewKeyboardLayer: String, CaseIterable, Hashable {
    case base, shift, command, commandShift

    var modifiers: CommandShortcutModifiers? {
        switch self {
        case .base: nil
        case .shift: .shift
        case .command: .command
        case .commandShift: .commandShift
        }
    }
    var command: Bool { self == .command || self == .commandShift }
    var shift: Bool { self == .shift || self == .commandShift }
    var prefix: String { modifiers?.display ?? "" }
    init(command: Bool, shift: Bool) {
        self = command ? (shift ? .commandShift : .command) : (shift ? .shift : .base)
    }
}

struct ReviewKeyboardLayerState {
    var latched = ReviewKeyboardLayer.base
    var held = ReviewKeyboardLayer.base
    var displayed: ReviewKeyboardLayer {
        .init(command: latched.command || held.command, shift: latched.shift || held.shift)
    }

    mutating func toggleCommand() { latched = .init(command: !latched.command, shift: latched.shift) }
    mutating func toggleShift() { latched = .init(command: latched.command, shift: !latched.shift) }
}

/// A visual index into the shortcut editor. Selecting a key never changes a binding.
struct ReviewKeyboardMap {
    let interpretation: ReviewShortcutInterpretation
    let layoutCharacters: [UInt16: String]
    var layer: ReviewKeyboardLayer = .base
    var modifiedCharacters: [UInt16: String] = [:]
    var modifiedCharactersByLayer: [ReviewKeyboardLayer: [UInt16: String]] = [:]

    static let rows: [[UInt16]] = [
        [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24],
        [48, 12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30, 42],
        [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39],
        [6, 7, 8, 9, 11, 45, 46, 43, 47, 44],
    ]

    func character(for keyCode: UInt16) -> String? {
        if let special = ReviewShortcutBinding.specialLabels[keyCode] { return special }
        if keyCode == 51 { return "⌫" }
        if layer != .base { return modifiedCharacters[keyCode] }
        return interpretation == .physicalPosition
            ? ReviewShortcutBinding.positionLabels[keyCode] : layoutCharacters[keyCode]
    }

    func label(for keyCode: UInt16) -> String {
        switch keyCode {
        case 48: return "⇥"
        case 49: return L10n.text("Space")
        default: return character(for: keyCode)?.uppercased() ?? "–"
        }
    }

    func actions(for keyCode: UInt16, preferences: ReviewShortcutPreferences) -> [ReviewShortcutAction] {
        guard layer == .base || layer == .shift else { return [] }
        return ReviewShortcutAction.allCases.filter { action in
            preferences.assignments(for: action).contains { assignment in
                if layer == .shift {
                    // Match the router's Shift allowance: review letters keep
                    // working, but arrows/Space/Tab and punctuation do not.
                    let meaning = interpretation == .physicalPosition
                        ? ReviewShortcutBinding.positionLabels[assignment.binding.keyCode, default: ""]
                        : assignment.binding.character
                    guard !assignment.binding.isSpecial, !meaning.isEmpty,
                          meaning.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else { return false }
                }
                if interpretation == .physicalPosition || assignment.binding.isSpecial {
                    return assignment.binding.keyCode == keyCode
                }
                return assignment.binding.character == character(for: keyCode)?.lowercased()
            }
        }
    }

    func commandActions(for keyCode: UInt16, preferences: CommandShortcutPreferences) -> [CommandShortcutAction] {
        let matches = commandBindings(for: keyCode, preferences: preferences)
        return CommandShortcutAction.allCases.filter { action in matches.contains { $0.action == action } }
    }

    /// The base keyboard is an overview of every used key. Modifier layers
    /// narrow that overview using their actual input-source translations.
    func commandBindings(for keyCode: UInt16, preferences: CommandShortcutPreferences)
        -> [(action: CommandShortcutAction, binding: CommandShortcutBinding)] {
        CommandShortcutAction.allCases.flatMap { action in
            preferences.bindings(for: action).compactMap { binding in
                guard layer == .base || binding.modifiers == layer.modifiers else { return nil }
                if ReviewShortcutBinding.specialLabels[keyCode] != nil || keyCode == 51 {
                    return binding.keyCode == keyCode ? (action, binding) : nil
                }
                let bindingLayer = ReviewKeyboardLayer(command: binding.modifiers != .shift,
                                                       shift: binding.modifiers != .command)
                let characters = layer == .base ? modifiedCharactersByLayer[bindingLayer] ?? [:] : modifiedCharacters
                return binding.character == characters[keyCode] ? (action, binding) : nil
            }
        }
    }

    @MainActor
    static func currentLayoutCharacters(layer: ReviewKeyboardLayer = .base) -> [UInt16: String] {
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return [:] }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        return withExtendedLifetime(data) {
            var result: [UInt16: String] = [:]
            for keyCode in ReviewShortcutBinding.positionLabels.keys {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let carbonModifiers = (layer.command ? UInt32(cmdKey) : 0) | (layer.shift ? UInt32(shiftKey) : 0)
                let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), carbonModifiers >> 8,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKeyState, characters.count, &length, &characters)
                guard status == noErr, length > 0 else { continue }
                let character = String(utf16CodeUnits: characters, count: length).lowercased()
                let binding = ReviewShortcutBinding(character: character, keyCode: keyCode)
                if binding.isValid { result[keyCode] = character }
            }
            return result
        }
    }
}

struct ReviewKeyboardView: View {
    private static let rowHeight: CGFloat = 27
    let map: ReviewKeyboardMap
    let preferences: ReviewShortcutPreferences
    var commandPreferences = CommandShortcutPreferences()
    var toggleCommand: () -> Void = {}
    var toggleShift: () -> Void = {}
    @Binding var selectedKey: UInt16?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            // Compact ANSI Mac proportions: every row spans 14½ key pitches.
            // Fixed hardware keys complete the silhouette without becoming
            // editable controls or additional accessibility stops.
            let unit = max(0, (geometry.size.width - 13.5 * 3) / 14.5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    fixedKey("esc", units: 1.5, unit: unit)
                    ForEach(Array(functionSymbols.enumerated()), id: \.offset) { index, symbol in
                        VStack(spacing: 1) {
                            Image(systemName: symbol).font(.system(size: 8))
                            Text("F\(index + 1)").font(.system(size: 6))
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: unit, height: Self.rowHeight)
                        .overlay(keyOutline())
                        .accessibilityHidden(true)
                    }
                    fixedKey("⏻", units: 1, unit: unit)
                }
                HStack(spacing: 3) {
                    ForEach(ReviewKeyboardMap.rows[0], id: \.self) { code in
                        key(code).frame(width: unit)
                    }
                    key(51).frame(width: width(1.5, unit: unit))
                }
                HStack(spacing: 3) {
                    ForEach(ReviewKeyboardMap.rows[1], id: \.self) { code in
                        key(code).frame(width: width(code == 48 ? 1.5 : 1, unit: unit))
                    }
                }
                HStack(spacing: 3) {
                    fixedKey("⇪", units: 1.75, unit: unit)
                    ForEach(ReviewKeyboardMap.rows[2], id: \.self) { code in
                        key(code).frame(width: unit)
                    }
                    fixedKey("↩", units: 1.75, unit: unit)
                }
                HStack(spacing: 3) {
                    modifierKey("⇧", title: L10n.text("Shift"), active: map.layer.shift, action: toggleShift)
                        .frame(width: width(2.25, unit: unit))
                    ForEach(ReviewKeyboardMap.rows[3], id: \.self) { code in
                        key(code).frame(width: unit)
                    }
                    modifierKey("⇧", title: L10n.text("Shift"), active: map.layer.shift, action: toggleShift)
                        .frame(width: width(2.25, unit: unit))
                }
                HStack(spacing: 3) {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: unit, height: Self.rowHeight)
                        .overlay(keyOutline())
                        .accessibilityHidden(true)
                    fixedKey("⌃", units: 1, unit: unit)
                    fixedKey("⌥", units: 1, unit: unit)
                    modifierKey("⌘", title: L10n.text("Command"), active: map.layer.command, action: toggleCommand)
                        .frame(width: width(1.25, unit: unit))
                    key(49).frame(width: width(5, unit: unit))
                    modifierKey("⌘", title: L10n.text("Command"), active: map.layer.command, action: toggleCommand)
                        .frame(width: width(1.25, unit: unit))
                    fixedKey("⌥", units: 1, unit: unit)
                    key(123).frame(width: unit)
                    VStack(spacing: 3) {
                        key(126, height: 12)
                        key(125, height: 12)
                    }
                    .frame(width: unit)
                    key(124).frame(width: unit)
                }
            }
        }
        .padding(6)
        .frame(height: 6 * Self.rowHeight + 5 * 3 + 12)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.text("Keyboard shortcuts"))
    }

    private func width(_ units: CGFloat, unit: CGFloat) -> CGFloat {
        unit * units + 3 * (units - 1)
    }

    private let functionSymbols = [
        "sun.min", "sun.max", "rectangle.on.rectangle", "magnifyingglass",
        "mic", "moon", "backward.end", "playpause", "forward.end",
        "speaker.slash", "speaker.wave.1", "speaker.wave.3",
    ]

    private var selectedForeground: Color {
        colorScheme == .dark || contrast == .increased ? .appBackground : .white
    }

    private func keyOutline() -> some View {
        RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.22), lineWidth: 1)
    }

    private func fixedKey(_ label: String, units: CGFloat, unit: CGFloat) -> some View {
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: width(units, unit: unit), height: Self.rowHeight)
            .overlay(keyOutline())
            .accessibilityHidden(true)
    }

    private func key(_ code: UInt16, height: CGFloat = ReviewKeyboardView.rowHeight) -> some View {
        let actions = map.actions(for: code, preferences: preferences)
        let commands = map.commandBindings(for: code, preferences: commandPreferences)
        let titles = actions.map(\.title) + commands.map { $0.binding.display + " — " + $0.action.title }
        let label = map.label(for: code)
        let selected = selectedKey == code
        let assigned = !titles.isEmpty
        return Button {
            selectedKey = selected ? nil : code
        } label: {
            Text(label)
                .font(.system(size: 11, weight: assigned ? .medium : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .foregroundStyle(selected ? selectedForeground : Color.primary)
                .background(selected ? Color.louppeAccent : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(assigned ? Color.louppeAccent : Color.primary.opacity(0.22), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(map.character(for: code) == nil && !assigned)
        .accessibilityLabel(map.layer.prefix + (code == 48 ? L10n.text("Tab") : label))
        .accessibilityValue(titles.isEmpty ? L10n.text("No shortcut assigned") : titles.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(titles.isEmpty ? L10n.text("No shortcut assigned") : map.layer.prefix + label + " — " + titles.joined(separator: ", "))
        .accessibilityIdentifier("louppe.shortcutKey.\(code)")
    }

    private func modifierKey(_ symbol: String, title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol).font(.system(size: 12))
                .frame(maxWidth: .infinity).frame(height: Self.rowHeight)
                .foregroundStyle(active ? selectedForeground : Color.primary)
                .background(active ? Color.louppeAccent : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
                    modifierIsAssigned(symbol) ? Color.louppeAccent : Color.primary.opacity(0.22), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(active ? L10n.text("On") : L10n.text("Off"))
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .help(title)
        .accessibilityIdentifier("louppe.shortcutModifier.\(symbol)")
    }

    private func modifierIsAssigned(_ symbol: String) -> Bool {
        if CommandShortcutAction.allCases.contains(where: { action in
            commandPreferences.bindings(for: action).contains {
                symbol == "⌘" ? $0.modifiers != .shift : $0.modifiers != .command
            }
        }) { return true }
        guard symbol == "⇧" else { return false }
        var shiftedMap = map
        shiftedMap.layer = .shift
        shiftedMap.modifiedCharacters = map.modifiedCharactersByLayer[.shift] ?? [:]
        return ReviewKeyboardMap.rows.flatMap { $0 }.contains {
            !shiftedMap.actions(for: $0, preferences: preferences).isEmpty
        }
    }
}
