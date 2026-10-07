import SwiftUI

enum LouppeHelpWindow {
    static let id = "help"
}

/// A small, searchable reference that can open independently of a photo session.
struct LouppeHelpView: View {
    @State private var shortcutSearch = ""
    @AppStorage("louppe.showQuickStart") private var showQuickStart = true

    private struct Shortcut: Identifiable {
        let keys: String
        let action: String
        var id: String { keys }

        func matches(_ query: String) -> Bool {
            keys.localizedStandardContains(query)
                || action.localizedStandardContains(query)
        }
    }

    private static let shortcuts: [Shortcut] = [
        .init(keys: "F / D", action: L10n.text("Mark Yes / No; advance by default (Settings → Review)")),
        .init(keys: "0–5", action: L10n.text("Clear or set stars, independently of Yes / No")),
        .init(keys: "← / →, J / L", action: L10n.text("Previous / next item; arrows seek in Gallery video")),
        .init(keys: "↑ / ↓", action: L10n.text("Previous / next item or Grid row")),
        .init(keys: "Space / K", action: L10n.text("Play or pause media; Space advances on photos")),
        .init(keys: "⇧← / ⇧→", action: L10n.text("Seek five seconds in Gallery video")),
        .init(keys: "S", action: L10n.text("Toggle 100% photo view")),
        .init(keys: "A", action: L10n.text("Toggle phone-sized photo view")),
        .init(keys: "X", action: L10n.text("Toggle photo clipping overlay")),
        .init(keys: "Tab / G", action: L10n.text("Switch Gallery / Grid")),
        .init(keys: "Q", action: L10n.text("Show or hide Gallery thumbnail browser")),
        .init(keys: "W", action: L10n.text("Show or hide Info panel")),
        .init(keys: "⌘+ / ⌘−", action: L10n.text("Make Grid thumbnails larger / smaller")),
        .init(keys: "E / ⌘E", action: L10n.text("Open Export")),
        .init(keys: "R", action: L10n.text("Clear all Yes / No decisions")),
        .init(keys: "Z / ⌘Z", action: L10n.text("Undo the latest review or file action")),
        .init(keys: "⌘O", action: L10n.text("Open another folder")),
        .init(keys: "⌘R", action: L10n.text("Rescan the current folder")),
        .init(keys: "⌘F", action: L10n.text("Open Filter and focus Search")),
        .init(keys: "⌘K", action: L10n.text("Open Command Palette")),
        .init(keys: "⌘A", action: L10n.text("Select all visible items")),
        .init(keys: "⌘← / ⌘→", action: L10n.text("Change playback speed; previous / next photo")),
        .init(keys: "⌘⇧← / ⌘⇧→", action: L10n.text("Select to the first / last item")),
        .init(keys: "Esc", action: L10n.text("Cancel a scan or clear selection")),
        .init(keys: "⌘⌫", action: L10n.text("Move selected items to Trash; ⌘Z restores them")),
    ]

    private var matchingShortcuts: [Shortcut] {
        let query = shortcutSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Self.shortcuts }
        return Self.shortcuts.filter { $0.matches(query) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Get started"))
                        .font(.title2.bold())
                    Text(L10n.text("Choose or drop a media folder. Louppe scans its subfolders and opens Gallery or Grid."))
                    Text(L10n.text("F marks Yes; D marks No. Both advance to the next undecided item by default (Settings → Review). Stars (0–5) and color labels are independent."))
                    Text(L10n.text("Export copies chosen media. Clean Up asks before moving rejects to the macOS Trash."))
                    Text(L10n.text("Decisions, stars, and colors save automatically. Reopen the folder to continue. No never trashes files. Export → Metadata (XMP) shares ratings with compatible editing apps."))
                    Toggle(L10n.text("Show quick-start tips while reviewing"), isOn: $showQuickStart)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Look closer and find similar photos"))
                        .font(.headline)
                    Text(L10n.text("Zoom with the slider or pinch; pan with two-finger scrolling or dragging. S returns custom zoom to centered 100%, then toggles Fit. A toggles Phone size. Double-click a point to inspect it at 100%."))
                    Text(L10n.text("View → Review Groups finds exact duplicates, similar photos, and capture bursts locally. Ratings and files stay unchanged. Normal Review exits groups."))
                    Text(L10n.text("Review matching RAW + JPEG files together or separately in Filter or the Command Palette (⌘K). Search for RAW, JPEG, or pairing."))
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Supported media"))
                        .font(.headline)
                    Text(L10n.text("Photos: RAW, JPEG, HEIC, PNG, TIFF, and other ImageIO formats. Video: MOV, MP4, M4V, and other macOS formats. Audio: MP3, M4A, WAV, FLAC, and more."))
                    Text(L10n.text("Files macOS cannot decode appear without a preview."))
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("Keyboard shortcuts"))
                        .font(.headline)
                    TextField(L10n.text("Search shortcuts or actions"), text: $shortcutSearch)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.text("Search keyboard shortcuts"))

                    if matchingShortcuts.isEmpty {
                        ContentUnavailableView.search(text: shortcutSearch)
                    } else {
                        ForEach(matchingShortcuts) { shortcut in
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(shortcut.keys)
                                    .environment(\.layoutDirection, .leftToRight)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 122, alignment: .leading)
                                Text(shortcut.action)
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
    }
}
