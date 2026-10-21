import AppKit

enum CommandShortcutModifiers: String, Codable, CaseIterable, Sendable {
    case command, shift, commandShift

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .command: [.command]
        case .shift: [.shift]
        case .commandShift: [.command, .shift]
        }
    }
    var display: String {
        switch self {
        case .command: "⌘"
        case .shift: "⇧"
        case .commandShift: "⇧⌘"
        }
    }
}

/// Command bindings follow the character AppKit delivers for the active layout,
/// independently of the physical-position preference for review keys.
struct CommandShortcutBinding: Codable, Equatable, Hashable, Sendable {
    var character: String
    var keyCode: UInt16
    var modifiers: CommandShortcutModifiers

    private static let special: [UInt16: String] = [51: "⌫", 123: "←", 124: "→"]
    var isValid: Bool {
        if let label = Self.special[keyCode] { return character == label }
        return ReviewShortcutBinding.positionLabels[keyCode] != nil
            && character.count == 1 && character == character.lowercased()
            && !character.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
            }
    }
    var display: String {
        let label = character == "=" ? "+" : character == "-" ? "−" : character.uppercased()
        return modifiers.display + label
    }
    static func capture(_ event: NSEvent) -> Self? {
        var flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        // AppKit adds these flags to ordinary directional events.
        if (123...126).contains(event.keyCode) { flags.subtract([.numericPad, .function]) }
        guard let modifiers = CommandShortcutModifiers.allCases.first(where: { $0.flags == flags }) else { return nil }
        guard let character = Self.special[event.keyCode] ?? event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let binding = Self(character: character, keyCode: event.keyCode, modifiers: modifiers)
        return binding.isValid ? binding : nil
    }
    fileprivate func hasSameChord(as other: Self) -> Bool {
        guard modifiers == other.modifiers else { return false }
        if Self.special[keyCode] != nil || Self.special[other.keyCode] != nil {
            return keyCode == other.keyCode && character == other.character
        }
        return character == other.character
    }
    fileprivate var isEditableChord: Bool {
        isValid && modifiers != .shift && character.unicodeScalars.count == 1
            && character.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }
}

enum CommandShortcutAction: String, CaseIterable, Codable, Sendable {
    case export, commandPalette, rescan, openFolder, settings, undo, selectAll, closeWindow, quit
    case filterSearch, trash, zoomIn, zoomOut, slower, faster, selectFirst, selectLast, seekBackward, seekForward

    var title: String {
        switch self {
        case .export: L10n.text("Open Export")
        case .commandPalette: L10n.text("Command palette")
        case .rescan: L10n.text("Rescan folder")
        case .openFolder: L10n.text("Open folder")
        case .settings: L10n.text("Settings")
        case .undo: L10n.text("Undo")
        case .selectAll: L10n.text("Select all filtered items")
        case .closeWindow: L10n.text("Close")
        case .quit: L10n.text("Quit Louppe")
        case .filterSearch: L10n.text("Search filters")
        case .trash: L10n.text("Trash selected items")
        case .zoomIn: L10n.text("Zoom In")
        case .zoomOut: L10n.text("Zoom Out")
        case .slower: L10n.text("Slower playback")
        case .faster: L10n.text("Faster playback")
        case .selectFirst: L10n.text("Select to first item")
        case .selectLast: L10n.text("Select to last item")
        case .seekBackward: L10n.text("Seek backward")
        case .seekForward: L10n.text("Seek forward")
        }
    }
    var group: ReviewShortcutGroup {
        switch self {
        case .zoomIn, .zoomOut: .view
        case .slower, .faster, .seekBackward, .seekForward: .playback
        case .selectFirst, .selectLast: .navigation
        default: .review
        }
    }
    var reviewAction: ReviewShortcutAction? {
        switch self {
        case .export: .export
        case .undo: .undo
        case .seekBackward: .seekBackward
        case .seekForward: .seekForward
        default: nil
        }
    }
    var isEditable: Bool { [.export, .commandPalette, .rescan].contains(self) }
    var contexts: Set<ReviewShortcutContext> {
        switch self {
        case .zoomIn, .zoomOut: ReviewShortcutScope.grid.contexts
        case .seekBackward, .seekForward: ReviewShortcutScope.galleryVideo.contexts
        default: ReviewShortcutScope.all.contexts
        }
    }
    var contextLabel: String {
        switch self {
        case .zoomIn, .zoomOut: L10n.text("Grid")
        case .seekBackward, .seekForward: L10n.text("Gallery videos with seeking")
        case .slower, .faster: L10n.text("Playback speed; previous / next item for other media")
        default: L10n.text("All views and media")
        }
    }
}

struct CommandShortcutPreferences: Codable, Equatable, Sendable {
    static let preferenceKey = "app.commandShortcuts.v1"
    private var customBindings: [String: [CommandShortcutBinding]] = [:]
    init() {}

    private enum CodingKeys: String, CodingKey { case schemaVersion, customBindings }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "Unknown command shortcut schema")
        }
        customBindings = try container.decode([String: [CommandShortcutBinding]].self, forKey: .customBindings)
        guard hasValidBindings else {
            throw DecodingError.dataCorruptedError(forKey: .customBindings, in: container, debugDescription: "Unsafe command shortcuts")
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .schemaVersion)
        try container.encode(customBindings, forKey: .customBindings)
    }
    static func defaultBindings(for action: CommandShortcutAction) -> [CommandShortcutBinding] {
        cachedDefaults[action]!
    }
    private static let cachedDefaults = Dictionary(uniqueKeysWithValues:
        CommandShortcutAction.allCases.map { ($0, makeDefaultBindings(for: $0)) }
    )
    private static func makeDefaultBindings(for action: CommandShortcutAction) -> [CommandShortcutBinding] {
        let key: String
        let modifiers: CommandShortcutModifiers
        switch action {
        case .export: key = "e"; modifiers = .command
        case .commandPalette: key = "k"; modifiers = .command
        case .rescan: key = "r"; modifiers = .command
        case .openFolder: key = "o"; modifiers = .command
        case .settings: key = ","; modifiers = .command
        case .undo: key = "z"; modifiers = .command
        case .selectAll: key = "a"; modifiers = .command
        case .closeWindow: key = "w"; modifiers = .command
        case .quit: key = "q"; modifiers = .command
        case .filterSearch: key = "f"; modifiers = .command
        case .trash: key = "⌫"; modifiers = .command
        case .zoomIn: key = "="; modifiers = .command
        case .zoomOut: key = "-"; modifiers = .command
        case .slower: key = "←"; modifiers = .command
        case .faster: key = "→"; modifiers = .command
        case .selectFirst: key = "←"; modifiers = .commandShift
        case .selectLast: key = "→"; modifiers = .commandShift
        case .seekBackward: key = "←"; modifiers = .shift
        case .seekForward: key = "→"; modifiers = .shift
        }
        let special: [String: UInt16] = ["⌫": 51, "←": 123, "→": 124]
        let code = special[key] ?? ReviewShortcutBinding.positionLabels.first { $0.value == key }!.key
        let primary = CommandShortcutBinding(character: key, keyCode: code, modifiers: modifiers)
        if action == .zoomIn {
            return [primary, .init(character: "+", keyCode: 24, modifiers: .commandShift)]
        }
        return [primary]
    }
    func bindings(for action: CommandShortcutAction) -> [CommandShortcutBinding] {
        customBindings[action.rawValue] ?? Self.defaultBindings(for: action)
    }
    func hint(for action: CommandShortcutAction) -> String {
        // macOS convention writes Zoom In as ⌘+, including the shifted + key.
        if action == .zoomIn { return "⌘+" }
        return bindings(for: action).map(\.display).joined(separator: " / ")
    }

    /// Keep established system, clipboard, text editing, window and Help keys
    /// available to AppKit even when the session has ordinary control focus.
    private static let reservedLetters = Set(["a", "b", "c", "f", "g", "h", "i", "m", "n", "o", "p", "q", "s", "u", "v", "w", "x", "z"])
    func conflict(for binding: CommandShortcutBinding, action: CommandShortcutAction, excluding: CommandShortcutBinding? = nil) -> String? {
        guard action.isEditable, binding.isEditableChord,
              !Self.reservedLetters.contains(binding.character) else {
            return L10n.text("This shortcut is reserved by macOS.")
        }
        for other in CommandShortcutAction.allCases {
            for existing in bindings(for: other) {
                if other == action, existing == excluding { continue }
                if binding.hasSameChord(as: existing) {
                    return L10n.text("Already assigned to \(other.title).")
                }
            }
        }
        return nil
    }
    @discardableResult
    mutating func add(_ binding: CommandShortcutBinding, for action: CommandShortcutAction) -> Bool {
        guard bindings(for: action).count < 64, conflict(for: binding, action: action) == nil else { return false }
        customBindings[action.rawValue] = bindings(for: action) + [binding]
        return true
    }
    @discardableResult
    mutating func replace(_ binding: CommandShortcutBinding, with replacement: CommandShortcutBinding, for action: CommandShortcutAction) -> Bool {
        var values = bindings(for: action)
        guard let index = values.firstIndex(of: binding), conflict(for: replacement, action: action, excluding: binding) == nil else { return false }
        values[index] = replacement
        customBindings[action.rawValue] = values
        return true
    }
    @discardableResult
    mutating func remove(_ binding: CommandShortcutBinding, for action: CommandShortcutAction) -> Bool {
        guard action.isEditable, bindings(for: action).contains(binding) else { return false }
        customBindings[action.rawValue] = bindings(for: action).filter { $0 != binding }
        return true
    }
    @discardableResult
    mutating func reset(for action: CommandShortcutAction) -> Bool {
        guard action.isEditable else { return false }
        var proposal = self
        proposal.customBindings.removeValue(forKey: action.rawValue)
        guard proposal.hasValidBindings else { return false }
        self = proposal
        return true
    }
    mutating func resetAll() { customBindings = [:] }

    func match(for event: NSEvent, context: ReviewShortcutContext) -> CommandShortcutAction? {
        guard let candidate = CommandShortcutBinding.capture(event) else { return nil }
        if !context.isGallery, candidate.modifiers == .command,
           ["=", "+"].contains(candidate.character) { return .zoomIn }
        for action in CommandShortcutAction.allCases where action.contexts.contains(context) {
            if bindings(for: action).contains(where: { candidate.hasSameChord(as: $0) }) { return action }
        }
        // Both the unshifted = key and a shifted + activate native Grid zoom.
        if context.isGallery == false, candidate.modifiers == .commandShift, event.characters == "+" { return .zoomIn }
        return nil
    }
    private var hasValidBindings: Bool {
        guard customBindings.allSatisfy({ CommandShortcutAction(rawValue: $0.key)?.isEditable == true && $0.value.count <= 64 }) else { return false }
        for action in CommandShortcutAction.allCases where action.isEditable {
            for binding in bindings(for: action) {
                guard binding.isValid, conflict(for: binding, action: action, excluding: binding) == nil,
                      bindings(for: action).filter({ $0.hasSameChord(as: binding) }).count == 1 else { return false }
            }
        }
        return true
    }
    var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    private final class DecodedCache: @unchecked Sendable {
        let lock = NSLock()
        var raw: String?
        var value = CommandShortcutPreferences()
    }
    private static let decodedCache = DecodedCache()
    static func decode(_ value: String) -> Self {
        decodedCache.lock.lock()
        defer { decodedCache.lock.unlock() }
        if decodedCache.raw == value { return decodedCache.value }
        let decoded: Self
        if value.utf8.count < 100_000,
           let result = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)) { decoded = result }
        else { decoded = Self() }
        decodedCache.raw = value.utf8.count < 100_000 ? value : nil
        decodedCache.value = decoded
        return decoded
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        decode(defaults.string(forKey: preferenceKey) ?? "")
    }
    func save(to defaults: UserDefaults = .standard) { defaults.set(encoded, forKey: Self.preferenceKey) }
}
