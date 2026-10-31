import AppKit

/// Exclusive runtime states make shortcut reuse a set-intersection decision,
/// rather than a priority rule that could silently choose the wrong action.
enum ReviewShortcutContext: String, CaseIterable, Codable, Sendable {
    case galleryPhoto, galleryPlayableVideo, galleryOtherVideo
    case galleryPlayableAudio, galleryOtherAudio, galleryText, galleryEmpty
    case gridPhoto, gridPlayableVideo, gridOtherVideo
    case gridPlayableAudio, gridOtherAudio, gridText, gridEmpty

    init(viewMode: ViewMode, mediaKind: MediaKind?, isPlayable: Bool, canSeekVideo: Bool) {
        let gallery = viewMode == .gallery
        switch mediaKind {
        case .photo: self = gallery ? .galleryPhoto : .gridPhoto
        case .video:
            if isPlayable { self = gallery ? .galleryPlayableVideo : .gridPlayableVideo }
            else { self = gallery ? .galleryOtherVideo : .gridOtherVideo }
        case .audio: self = isPlayable ? (gallery ? .galleryPlayableAudio : .gridPlayableAudio) : (gallery ? .galleryOtherAudio : .gridOtherAudio)
        case .text: self = gallery ? .galleryText : .gridText
        case nil: self = gallery ? .galleryEmpty : .gridEmpty
        }
    }

    var isGallery: Bool { rawValue.hasPrefix("gallery") }
    var isPhoto: Bool { self == .galleryPhoto || self == .gridPhoto }
    var isVideo: Bool { rawValue.hasSuffix("Video") }
    var isAudio: Bool { rawValue.hasSuffix("Audio") }
    var isText: Bool { self == .galleryText || self == .gridText }
    var isEmpty: Bool { self == .galleryEmpty || self == .gridEmpty }
    var isPlayable: Bool {
        [.galleryPlayableVideo, .galleryPlayableAudio, .gridPlayableVideo, .gridPlayableAudio].contains(self)
    }
    var canSeekVideo: Bool { self == .galleryPlayableVideo }
    var title: String {
        let media: String
        if isPhoto { media = L10n.text("Photos") }
        else if isVideo { media = L10n.text("Videos") }
        else if isAudio { media = L10n.text("Audio") }
        else if isText { media = L10n.text("Text") }
        else { media = L10n.text("No current item") }
        return L10n.text("\(isGallery ? L10n.text("Gallery") : L10n.text("Grid")) · \(media)")
    }
}

enum ReviewShortcutScope: String, CaseIterable, Codable, Sendable {
    case all, gallery, grid, photos, videos, audio, text, playable, nonPlayable, galleryPhotos, galleryVideo
    /// Preserves the native Left/Right behavior without stealing video seeking.
    case outsideGalleryVideo

    var title: String {
        switch self {
        case .all: L10n.text("Where available")
        case .gallery: L10n.text("Gallery")
        case .grid: L10n.text("Grid")
        case .photos: L10n.text("Photos")
        case .videos: L10n.text("Videos")
        case .audio: L10n.text("Audio")
        case .text: L10n.text("Text")
        case .playable: L10n.text("Playable video and audio")
        case .nonPlayable: L10n.text("Media without playback")
        case .galleryPhotos: L10n.text("Gallery photos")
        case .galleryVideo: L10n.text("Gallery videos with seeking")
        case .outsideGalleryVideo: L10n.text("Outside Gallery video seeking")
        }
    }

    var contexts: Set<ReviewShortcutContext> { Self.cachedContexts[self]! }
    private static let cachedContexts = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.uncachedContexts) })
    private var uncachedContexts: Set<ReviewShortcutContext> {
        Set(ReviewShortcutContext.allCases.filter { context in
            switch self {
            case .all: true
            case .gallery: context.isGallery
            case .grid: !context.isGallery
            case .photos: context.isPhoto
            case .videos: context.isVideo
            case .audio: context.isAudio
            case .text: context.isText
            case .playable: context.isPlayable
            case .nonPlayable: !context.isPlayable
            case .galleryPhotos: context.isGallery && context.isPhoto
            case .galleryVideo: context.canSeekVideo
            case .outsideGalleryVideo: !context.canSeekVideo
            }
        })
    }
}

enum ReviewShortcutGroup: String, CaseIterable, Sendable {
    case review, navigation, playback, view, stars
    var title: String {
        switch self {
        case .review: L10n.text("Review")
        case .navigation: L10n.text("Navigation")
        case .playback: L10n.text("Playback")
        case .view: L10n.text("View")
        case .stars: L10n.text("Stars")
        }
    }
}

enum ReviewShortcutAction: String, CaseIterable, Codable, Sendable {
    case yes, no, previous, next, previousRow, nextRow, playPause, seekBackward, seekForward
    case browser, info, clipping, grid, export, clear, undo, actualSize, phoneSize
    case clearStars, oneStar, twoStars, threeStars, fourStars, fiveStars
    // Append only: default assignment IDs depend on case order.
    case folders, previousFolder, nextFolder

    var title: String {
        switch self {
        case .yes: L10n.text("Mark Yes")
        case .no: L10n.text("Mark No")
        case .previous: L10n.text("Previous item")
        case .next: L10n.text("Next item")
        case .previousRow: L10n.text("Previous row")
        case .nextRow: L10n.text("Next row")
        case .playPause: L10n.text("Play / Pause")
        case .seekBackward: L10n.text("Seek backward")
        case .seekForward: L10n.text("Seek forward")
        case .browser: L10n.text("Show / Hide Browser")
        case .folders: L10n.text("Show / Hide Folders")
        case .previousFolder: L10n.text("Previous Folder")
        case .nextFolder: L10n.text("Next Folder")
        case .info: L10n.text("Show / Hide Info")
        case .clipping: L10n.text("Toggle clipping overlay")
        case .grid: L10n.text("Switch Gallery / Grid")
        case .export: L10n.text("Open Export")
        case .clear: L10n.text("Clear all Yes / No decisions")
        case .undo: L10n.text("Undo")
        case .actualSize: L10n.text("Toggle 100% photo view")
        case .phoneSize: L10n.text("Toggle phone-sized photo view")
        case .clearStars: L10n.text("Clear stars")
        case .oneStar: L10n.text("1 star")
        case .twoStars: L10n.text("2 stars")
        case .threeStars: L10n.text("3 stars")
        case .fourStars: L10n.text("4 stars")
        case .fiveStars: L10n.text("5 stars")
        }
    }
    var group: ReviewShortcutGroup {
        switch self {
        case .yes, .no, .export, .clear, .undo: .review
        case .previous, .next, .previousRow, .nextRow, .previousFolder, .nextFolder: .navigation
        case .playPause, .seekBackward, .seekForward: .playback
        case .browser, .folders, .info, .clipping, .grid, .actualSize, .phoneSize: .view
        case .clearStars, .oneStar, .twoStars, .threeStars, .fourStars, .fiveStars: .stars
        }
    }
    var defaultCharacter: String {
        switch self {
        case .yes: "f"
        case .no: "d"
        case .previous: "j"
        case .next: "l"
        case .previousRow: "↑"
        case .nextRow: "↓"
        case .playPause: "k"
        case .seekBackward: "←"
        case .seekForward: "→"
        case .browser: "q"
        case .folders: "t"
        case .previousFolder: "["
        case .nextFolder: "]"
        case .info: "w"
        case .clipping: "x"
        case .grid: "g"
        case .export: "e"
        case .clear: "r"
        case .undo: "z"
        case .actualSize: "s"
        case .phoneSize: "a"
        case .clearStars: "0"
        case .oneStar: "1"
        case .twoStars: "2"
        case .threeStars: "3"
        case .fourStars: "4"
        case .fiveStars: "5"
        }
    }
    var defaultScope: ReviewShortcutScope {
        switch self {
        case .previousRow, .nextRow: .grid
        case .playPause: .playable
        case .seekBackward, .seekForward: .galleryVideo
        case .browser: .gallery
        case .clipping, .actualSize, .phoneSize: .galleryPhotos
        default: .all
        }
    }
    var contexts: Set<ReviewShortcutContext> { Self.cachedContexts[self]! }
    private static let cachedContexts = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.uncachedContexts) })
    private var uncachedContexts: Set<ReviewShortcutContext> {
        // Item-dependent actions are unavailable when filtering leaves no item.
        if [.yes, .no, .clearStars, .oneStar, .twoStars, .threeStars, .fourStars, .fiveStars].contains(self) {
            return Set(ReviewShortcutContext.allCases.filter { !$0.isEmpty })
        }
        return defaultScope.contexts
    }
    var contextLabel: String {
        defaultScope == .all ? L10n.text("All views and media") : defaultScope.title
    }
    var allowedScopes: [ReviewShortcutScope] {
        ReviewShortcutScope.allCases.filter { !$0.contexts.intersection(contexts).isEmpty }
    }
    var isSafeDuringFileOperation: Bool { [.browser, .folders, .info, .clipping, .grid].contains(self) }
}

enum ReviewShortcutInterpretation: String, CaseIterable, Codable, Sendable {
    case keyboardLayout, physicalPosition
    var title: String {
        switch self {
        case .keyboardLayout: L10n.text("Follow keyboard layout")
        case .physicalPosition: L10n.text("Physical key positions")
        }
    }
}

struct ReviewShortcutBinding: Codable, Equatable, Sendable {
    var character: String
    var keyCode: UInt16

    static let specialLabels: [UInt16: String] = [48: "⇥", 49: "Space", 123: "←", 124: "→", 125: "↓", 126: "↑"]
    static let positionLabels: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
    ]
    var isSpecial: Bool { Self.specialLabels[keyCode] != nil }
    var isValid: Bool {
        if let special = Self.specialLabels[keyCode] { return character == special }
        return Self.positionLabels[keyCode] != nil && character.count == 1
            && !character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }
            && character == character.lowercased()
    }
    static func capture(_ event: NSEvent) -> Self? {
        var modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        // AppKit marks arrow events numericPad even on keyboards without one.
        if (123...126).contains(event.keyCode) { modifiers.subtract([.numericPad, .function]) }
        guard modifiers.isEmpty else { return nil }
        if let special = specialLabels[event.keyCode] { return Self(character: special, keyCode: event.keyCode) }
        guard let character = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let binding = Self(character: character, keyCode: event.keyCode)
        return binding.isValid ? binding : nil
    }
}

struct ReviewShortcutAssignment: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var binding: ReviewShortcutBinding
    var scope: ReviewShortcutScope
    init(id: UUID = UUID(), binding: ReviewShortcutBinding, scope: ReviewShortcutScope = .all) {
        self.id = id; self.binding = binding; self.scope = scope
    }
}
struct ReviewShortcutConflict: Equatable, Sendable {
    var action: ReviewShortcutAction
    var contextLabel: String
}
struct ReviewShortcutMatch: Equatable, Sendable {
    var action: ReviewShortcutAction
    var requiresNavigationFocus: Bool
}

/// Each matching mode has its own ordered aliases. Switching mode never edits
/// the other map. Folder sidecars and ordinary macOS Command keys are unrelated.
struct ReviewShortcutPreferences: Codable, Equatable, Sendable {
    static let preferenceKey = "review.shortcuts.v1"
    var interpretation: ReviewShortcutInterpretation
    private var layoutBindings: [String: [ReviewShortcutAssignment]] = [:]
    private var physicalBindings: [String: [ReviewShortcutAssignment]] = [:]

    // New setups preserve the review keys' physical arrangement on every
    // layout. Decoding always restores the user's explicitly saved mode.
    init(interpretation: ReviewShortcutInterpretation = .physicalPosition) {
        self.interpretation = interpretation
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, interpretation, layoutBindings, physicalBindings, customBindings }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interpretation = try container.decode(ReviewShortcutInterpretation.self, forKey: .interpretation)
        if container.contains(.schemaVersion) {
            guard try container.decode(Int.self, forKey: .schemaVersion) == 2 else {
                throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container, debugDescription: "Unknown shortcut schema")
            }
            layoutBindings = try container.decode([String: [ReviewShortcutAssignment]].self, forKey: .layoutBindings)
            physicalBindings = try container.decode([String: [ReviewShortcutAssignment]].self, forKey: .physicalBindings)
        } else {
            let legacy = try container.decode([String: ReviewShortcutBinding].self, forKey: .customBindings)
            // Old files only supported ordinary keys. Validate both meanings
            // before migrating so corrupt data cannot turn into an active key.
            guard legacy.allSatisfy({ ReviewShortcutAction(rawValue: $0.key) != nil && $0.value.isValid && !$0.value.isSpecial }) else {
                throw DecodingError.dataCorruptedError(forKey: .customBindings, in: container, debugDescription: "Invalid legacy shortcuts")
            }
            for mode in ReviewShortcutInterpretation.allCases {
                interpretation = mode
                for (key, binding) in legacy {
                    guard let action = ReviewShortcutAction(rawValue: key) else { continue }
                    var values = assignments(for: action)
                    let primary = values.firstIndex { $0.binding.character == action.defaultCharacter } ?? 0
                    values[primary].binding = binding
                    store(values, for: action)
                }
            }
            interpretation = try container.decode(ReviewShortcutInterpretation.self, forKey: .interpretation)
        }
        yieldNewDefaultsToSavedBindings()
        guard hasValidBindings else {
            throw DecodingError.dataCorruptedError(forKey: .layoutBindings, in: container, debugDescription: "Ambiguous shortcuts")
        }
    }
    /// A newly introduced default must never discard established customizations.
    /// Explicit entries (including empty ones) remain authoritative in each mode.
    private mutating func yieldNewDefaultsToSavedBindings() {
        let originalMode = interpretation
        defer { interpretation = originalMode }
        for mode in ReviewShortcutInterpretation.allCases {
            interpretation = mode
            let saved = mode == .keyboardLayout ? layoutBindings : physicalBindings
            for action in [ReviewShortcutAction.folders, .previousFolder, .nextFolder] where saved[action.rawValue] == nil {
                let defaults = Self.defaultAssignments(for: action)
                let retained = defaults.filter { candidate in
                    !ReviewShortcutAction.allCases.contains { other in
                        (saved[other.rawValue] ?? []).contains { existing in
                            sameKey(candidate.binding, existing.binding)
                                && !effectiveContexts(for: action, scope: candidate.scope)
                                    .isDisjoint(with: effectiveContexts(for: other, scope: existing.scope))
                        }
                    }
                }
                if retained != defaults { store(retained, for: action) }
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(2, forKey: .schemaVersion)
        try container.encode(interpretation, forKey: .interpretation)
        try container.encode(layoutBindings, forKey: .layoutBindings)
        try container.encode(physicalBindings, forKey: .physicalBindings)
    }
    func assignments(for action: ReviewShortcutAction) -> [ReviewShortcutAssignment] {
        let map = interpretation == .keyboardLayout ? layoutBindings : physicalBindings
        return map[action.rawValue] ?? Self.defaultAssignments(for: action)
    }
    private mutating func store(_ values: [ReviewShortcutAssignment], for action: ReviewShortcutAction) {
        if interpretation == .keyboardLayout { layoutBindings[action.rawValue] = values }
        else { physicalBindings[action.rawValue] = values }
    }
    static func defaultBinding(for action: ReviewShortcutAction) -> ReviewShortcutBinding {
        makeBinding(action.defaultCharacter)
    }
    private static func makeBinding(_ character: String) -> ReviewShortcutBinding {
        let code = ReviewShortcutBinding.specialLabels.first { $0.value == character }?.key
            ?? ReviewShortcutBinding.positionLabels.first { $0.value == character }!.key
        return .init(character: character, keyCode: code)
    }
    static func defaultAssignments(for action: ReviewShortcutAction) -> [ReviewShortcutAssignment] { cachedDefaults[action]! }
    private static let cachedDefaults = Dictionary(uniqueKeysWithValues: ReviewShortcutAction.allCases.map { ($0, makeDefaultAssignments(for: $0)) })
    private static func makeDefaultAssignments(for action: ReviewShortcutAction) -> [ReviewShortcutAssignment] {
        var values: [(String, ReviewShortcutScope)] = [(action.defaultCharacter, action.defaultScope)]
        switch action {
        case .previous: values += [("←", .outsideGalleryVideo), ("↑", .gallery)]
        case .next: values += [("→", .outsideGalleryVideo), ("↓", .gallery), ("Space", .nonPlayable)]
        case .playPause: values += [("Space", .playable)]
        case .grid: values = [("⇥", .all), ("g", .all)]
        default: break
        }
        return values.enumerated().map { offset, value in
            let index = ReviewShortcutAction.allCases.firstIndex(of: action)! * 16 + offset + 1
            let id = UUID(uuidString: "00000000-0000-0000-0000-" + String(format: "%012x", index))!
            return .init(id: id, binding: makeBinding(value.0), scope: value.1)
        }
    }
    func display(for binding: ReviewShortcutBinding) -> String {
        if let special = ReviewShortcutBinding.specialLabels[binding.keyCode] {
            if special == "Space" { return L10n.text("Space") }
            if special == "⇥" { return L10n.text("Tab") }
            return special
        }
        switch interpretation {
        case .keyboardLayout: return binding.character.uppercased()
        case .physicalPosition: return L10n.text("\(ReviewShortcutBinding.positionLabels[binding.keyCode, default: binding.character].uppercased()) position")
        }
    }
    func hint(for action: ReviewShortcutAction) -> String { joinedHints(assignments(for: action)) }
    func hint(for action: ReviewShortcutAction, context: ReviewShortcutContext) -> String {
        joinedHints(assignments(for: action).filter { effectiveContexts(for: action, scope: $0.scope).contains(context) })
    }
    private func joinedHints(_ assignments: [ReviewShortcutAssignment]) -> String {
        var labels: [String] = []
        for assignment in assignments {
            let label = display(for: assignment.binding)
            if !labels.contains(label) { labels.append(label) }
        }
        return labels.joined(separator: " / ")
    }
    func effectiveContexts(for action: ReviewShortcutAction, scope: ReviewShortcutScope) -> Set<ReviewShortcutContext> {
        action.contexts.intersection(scope.contexts)
    }
    func conflict(for binding: ReviewShortcutBinding, action: ReviewShortcutAction, scope: ReviewShortcutScope = .all, excludingID: UUID? = nil) -> ReviewShortcutConflict? {
        let proposed = effectiveContexts(for: action, scope: scope)
        for other in ReviewShortcutAction.allCases {
            for assignment in assignments(for: other) where assignment.id != excludingID {
                guard sameKey(binding, assignment.binding) else { continue }
                let overlap = proposed.intersection(effectiveContexts(for: other, scope: assignment.scope))
                if let context = ReviewShortcutContext.allCases.first(where: { overlap.contains($0) }) {
                    return .init(action: other, contextLabel: context.title)
                }
            }
        }
        return nil
    }
    private func sameKey(_ first: ReviewShortcutBinding, _ second: ReviewShortcutBinding) -> Bool {
        if first.isSpecial || second.isSpecial { return first.isSpecial && second.isSpecial && first.keyCode == second.keyCode }
        return interpretation == .physicalPosition ? first.keyCode == second.keyCode : first.character == second.character
    }
    @discardableResult
    mutating func add(_ binding: ReviewShortcutBinding, for action: ReviewShortcutAction, scope: ReviewShortcutScope = .all) -> Bool {
        guard binding.isValid, !effectiveContexts(for: action, scope: scope).isEmpty,
              assignments(for: action).count < 64, conflict(for: binding, action: action, scope: scope) == nil else { return false }
        store(assignments(for: action) + [.init(binding: binding, scope: scope)], for: action)
        return true
    }
    @discardableResult
    mutating func replace(_ id: UUID, with binding: ReviewShortcutBinding, for action: ReviewShortcutAction, scope: ReviewShortcutScope) -> Bool {
        var values = assignments(for: action)
        guard let index = values.firstIndex(where: { $0.id == id }), binding.isValid,
              !effectiveContexts(for: action, scope: scope).isEmpty,
              conflict(for: binding, action: action, scope: scope, excludingID: id) == nil else { return false }
        values[index] = .init(id: id, binding: binding, scope: scope)
        store(values, for: action)
        return true
    }
    @discardableResult
    mutating func remove(_ id: UUID, for action: ReviewShortcutAction) -> Bool {
        let values = assignments(for: action)
        guard values.contains(where: { $0.id == id }) else { return false }
        store(values.filter { $0.id != id }, for: action)
        return true
    }
    func resetConflict(for action: ReviewShortcutAction) -> ReviewShortcutConflict? {
        var proposal = self
        let defaults = Self.defaultAssignments(for: action)
        proposal.store(defaults, for: action)
        for assignment in defaults {
            if let conflict = proposal.conflict(for: assignment.binding, action: action, scope: assignment.scope, excludingID: assignment.id) { return conflict }
        }
        return nil
    }
    /// Reset only succeeds if another action has not claimed a default key.
    @discardableResult
    mutating func reset(for action: ReviewShortcutAction) -> Bool {
        var proposal = self
        proposal.store(Self.defaultAssignments(for: action), for: action)
        guard proposal.hasValidBindings(in: interpretation) else { return false }
        self = proposal
        return true
    }
    mutating func resetCurrentMode() {
        if interpretation == .keyboardLayout { layoutBindings = [:] } else { physicalBindings = [:] }
    }
    func match(for event: NSEvent, context: ReviewShortcutContext) -> ReviewShortcutMatch? {
        var modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if (123...126).contains(event.keyCode) { modifiers.subtract([.numericPad, .function]) }
        guard modifiers.subtracting(.shift).isEmpty else { return nil }
        let character = event.charactersIgnoringModifiers?.lowercased()
        for action in ReviewShortcutAction.allCases {
            for assignment in assignments(for: action) where effectiveContexts(for: action, scope: assignment.scope).contains(context) {
                let binding = assignment.binding
                let matches: Bool
                if binding.isSpecial { matches = event.keyCode == binding.keyCode }
                else if interpretation == .physicalPosition { matches = event.keyCode == binding.keyCode }
                else { matches = character == binding.character && ReviewShortcutBinding.specialLabels[event.keyCode] == nil }
                guard matches else { continue }
                let meaning = interpretation == .physicalPosition ? ReviewShortcutBinding.positionLabels[binding.keyCode, default: ""] : binding.character
                if modifiers.contains(.shift), binding.isSpecial || !meaning.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) { continue }
                return .init(action: action, requiresNavigationFocus: binding.isSpecial)
            }
        }
        return nil
    }
    // Compatibility for the original one-key editor and focused callers.
    func binding(for action: ReviewShortcutAction) -> ReviewShortcutBinding {
        let active = assignments(for: action).first?.binding ?? Self.defaultBinding(for: action)
        var other = self
        other.interpretation = interpretation == .keyboardLayout ? .physicalPosition : .keyboardLayout
        let inactive = other.assignments(for: action).first?.binding ?? Self.defaultBinding(for: action)
        return interpretation == .keyboardLayout ? .init(character: active.character, keyCode: inactive.keyCode) : .init(character: inactive.character, keyCode: active.keyCode)
    }
    func conflictingAction(for binding: ReviewShortcutBinding, excluding action: ReviewShortcutAction) -> ReviewShortcutAction? {
        conflict(for: binding, action: action, scope: assignments(for: action).first?.scope ?? action.defaultScope,
                 excludingID: assignments(for: action).first?.id)?.action
    }
    @discardableResult
    mutating func set(_ binding: ReviewShortcutBinding, for action: ReviewShortcutAction) -> Bool {
        if let first = assignments(for: action).first { return replace(first.id, with: binding, for: action, scope: first.scope) }
        return add(binding, for: action, scope: action.defaultScope)
    }
    func action(for event: NSEvent) -> ReviewShortcutAction? { match(for: event, context: .galleryPhoto)?.action }
    var encoded: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    /// Settings and event routing often request the same persisted value more
    /// than once. Cache one validated immutable value, returning a CoW copy.
    private final class DecodedCache: @unchecked Sendable {
        let lock = NSLock()
        var raw: String?
        var value = ReviewShortcutPreferences()
    }
    private static let decodedCache = DecodedCache()
    static func decode(_ value: String) -> Self {
        decodedCache.lock.lock()
        defer { decodedCache.lock.unlock() }
        if decodedCache.raw == value { return decodedCache.value }
        let decoded: Self
        if !value.isEmpty, value.utf8.count < 1_000_000,
           let result = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)) {
            decoded = result
        } else { decoded = Self() }
        // Oversized invalid input should not retain an unbounded raw string.
        decodedCache.raw = value.utf8.count < 1_000_000 ? value : nil
        decodedCache.value = decoded
        return decoded
    }
    private var hasValidBindings: Bool {
        ReviewShortcutInterpretation.allCases.allSatisfy { hasValidBindings(in: $0) }
    }
    private enum KeyIdentity: Hashable {
        case character(String), position(UInt16), special(UInt16)
    }
    private func identity(for binding: ReviewShortcutBinding) -> KeyIdentity {
        if binding.isSpecial { return .special(binding.keyCode) }
        return interpretation == .physicalPosition ? .position(binding.keyCode) : .character(binding.character)
    }
    private func hasValidBindings(in mode: ReviewShortcutInterpretation) -> Bool {
        var selected = self
        selected.interpretation = mode
        let map = mode == .keyboardLayout ? layoutBindings : physicalBindings
        guard map.allSatisfy({ ReviewShortcutAction(rawValue: $0.key) != nil && $0.value.count <= 64 }) else { return false }
        var ids = Set<UUID>()
        var claimed: [KeyIdentity: Set<ReviewShortcutContext>] = [:]
        for action in ReviewShortcutAction.allCases {
            for assignment in selected.assignments(for: action) {
                let contexts = selected.effectiveContexts(for: action, scope: assignment.scope)
                let key = selected.identity(for: assignment.binding)
                guard ids.insert(assignment.id).inserted, assignment.binding.isValid, !contexts.isEmpty,
                      claimed[key, default: []].isDisjoint(with: contexts) else { return false }
                claimed[key, default: []].formUnion(contexts)
            }
        }
        return true
    }
    static func load(from defaults: UserDefaults = .standard) -> Self { decode(defaults.string(forKey: preferenceKey) ?? "") }
    func save(to defaults: UserDefaults = .standard) { defaults.set(encoded, forKey: Self.preferenceKey) }
}
