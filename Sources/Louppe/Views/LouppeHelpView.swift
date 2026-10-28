import SwiftUI

enum LouppeHelpWindow {
    static let id = "help"
}

/// A small, searchable reference that can open independently of a photo session.
struct LouppeHelpView: View {
    @State private var shortcutSearch = ""
    @AppStorage(ReviewShortcutPreferences.preferenceKey) private var shortcutSettings = ""
    @AppStorage(CommandShortcutPreferences.preferenceKey) private var commandShortcutSettings = ""

    private var shortcuts: ReviewShortcutPreferences { ReviewShortcutPreferences.decode(shortcutSettings) }
    private var commandShortcuts: CommandShortcutPreferences { .decode(commandShortcutSettings) }

    private struct Shortcut: Identifiable {
        let id: String
        let keys: String
        let action: String
        var context: String = ""

        func matches(_ query: String) -> Bool {
            keys.localizedStandardContains(query)
                || action.localizedStandardContains(query)
                || context.localizedStandardContains(query)
        }
    }

    private var shortcutReference: [Shortcut] {
        let configurable = ReviewShortcutAction.allCases.flatMap { action -> [Shortcut] in
            let assignments = shortcuts.assignments(for: action)
            if assignments.isEmpty {
                return [.init(id: "action-\(action.rawValue)", keys: L10n.text("No shortcut assigned"), action: action.title,
                              context: action.contextLabel)]
            }
            return assignments.map { assignment in
                .init(id: "action-\(action.rawValue)-\(assignment.id)", keys: shortcuts.display(for: assignment.binding),
                      action: action.title,
                      context: assignment.scope == .all ? action.contextLabel : assignment.scope.title)
            }
        }
        let commands = CommandShortcutAction.allCases.map { action -> Shortcut in
            let hint = commandShortcuts.hint(for: action)
            return .init(id: "command-\(action.rawValue)",
                         keys: hint.isEmpty ? L10n.text("No shortcut assigned") : hint,
                         action: action.title, context: action.contextLabel)
        }
        return configurable + commands + [
            .init(id: "escape", keys: "Esc", action: L10n.text("Cancel a scan or clear selection")),
        ]
    }

    private var matchingShortcuts: [Shortcut] {
        let query = shortcutSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return shortcutReference }
        return shortcutReference.filter { $0.matches(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Get started"))
                        .font(.title2.bold())
                    LouppeQuickStartContent()
                    Link(L10n.text("User guide (English)"), destination: AppBuildInfo.userGuideURL)
                        .foregroundStyle(Color.louppeAccent)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Apple Photos"))
                        .font(.headline)
                    Text(L10n.text("File → Open Apple Photos… opens your System Photo Library or an album, with an optional date range. Review images load as you browse and exclude Photos edits."))
                    Text(L10n.text("Review images load as you browse. Photos may download source data to make a preview. Originals are requested separately for original detail and Copy. Decisions save in Louppe; your library stays unchanged. Live Photos use their still image."))
                    Text(L10n.text("Ratings stay local. Copy exports primary originals; Move, Rename, Organize, XMP, and Trash are unavailable for Photos."))
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("File safety and saved decisions"))
                        .font(.headline)
                    Text(L10n.text("Export copies by default. Move transfers originals and cannot be undone. Rename and Organize change file names or locations only after confirmation."))
                    Text(L10n.text("Clean Up asks before moving files to Trash. ⌘⌫ trashes the selection without a dialog. ⌘Z restores trashed files during the open session while they remain in Trash."))
                    Text(L10n.text("Folder ratings save to .louppe_session.json; File → Check Saved Decisions… offers recovery. Photos ratings save locally by asset ID."))
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Look closer and find similar photos"))
                        .font(.headline)
                    Text(L10n.text("Zoom with the slider or pinch; pan with two-finger scrolling or dragging. Double-click a point to inspect it at 100%. Use the photo size controls to return to Fit, 100%, or Phone size."))
                    Text(L10n.text("View → Review Groups finds exact duplicates, similar photos, and capture bursts locally. Ratings and files stay unchanged. Normal Review exits groups."))
                    Text(L10n.text("Review matching RAW + JPEG files together or separately in Filter or the Command Palette. Search for RAW, JPEG, or pairing."))
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Supported media"))
                        .font(.headline)
                    Text(L10n.text("Photos: RAW, JPEG, HEIC, PNG, TIFF, and other ImageIO formats. Video: MOV, MP4, M4V, and other macOS formats. Audio: MP3, M4A, WAV, FLAC, and more."))
                    Text(L10n.text("Text previews are read-only and selectable: plain text, Markdown, JSON, XML, CSV, TSV, logs, and YAML, up to 1 MiB per file."))
                    Text(L10n.text("Files macOS cannot decode appear without a preview."))
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("Keyboard shortcuts"))
                        .font(.headline)
                    Text(L10n.text("Change review keys and keyboard-layout behavior in Settings → Keyboard shortcuts."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.text("Each key below shows when it applies. Shared keys perform different actions only in separate views or media contexts."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    NativeSearchField(
                        text: $shortcutSearch,
                        placeholder: L10n.text("Search shortcuts or actions"),
                        accessibilityLabel: L10n.text("Search keyboard shortcuts"),
                        accessibilityIdentifier: "louppe.helpSearch"
                    )

                    if matchingShortcuts.isEmpty {
                        ContentUnavailableView.search(text: shortcutSearch)
                    } else {
                        ForEach(matchingShortcuts) { shortcut in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(shortcut.keys)
                                    .environment(\.layoutDirection, .leftToRight)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 122, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(shortcut.action)
                                    if !shortcut.context.isEmpty {
                                        Text(shortcut.context)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                Divider()

                Link(L10n.text("Contact Alex · a@alex-markin.com"), destination: URL(string: "mailto:a@alex-markin.com")!)
            }
            .frame(maxWidth: 570, alignment: .leading)
            .padding(24)
        }
        .background(Color.appBackground)
        .tint(Color.louppeAccent)
    }
}

/// The onboarding guide lives in Help; review preferences live in Settings.
struct LouppeQuickStartContent: View {
    @AppStorage(CommandShortcutPreferences.preferenceKey) private var commandShortcutSettings = ""

    var body: some View {
        let paletteShortcut = CommandShortcutPreferences.decode(commandShortcutSettings).hint(for: .commandPalette)
        let paletteName = paletteShortcut.isEmpty ? L10n.text("Command Palette") : L10n.text("Command Palette (\(paletteShortcut))")
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Choose or drop a media folder. Louppe scans its subfolders and opens Gallery or Grid."))
            Text(L10n.text("Mark Yes or No using the buttons or your assigned shortcuts. Both advance to the next undecided item by default (Settings → General → Review). Stars and color labels are independent."))
            Text(L10n.text("Export copies chosen media. Clean Up asks before moving rejects to the macOS Trash."))
            Text(L10n.text("To rename keepers, filter to Yes, open \(paletteName) → Rename Files…, and choose Filtered. Preview the names before confirming; ⌘Z restores the previous names."))
            Text(L10n.text("Decisions, stars, and colors save automatically. Reopen the folder to continue. No never trashes files. Export → Metadata (XMP) shares ratings with compatible editing apps."))
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("louppe.quickStartGuide")
    }
}
