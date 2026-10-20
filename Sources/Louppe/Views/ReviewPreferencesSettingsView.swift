import SwiftUI

struct ReviewPreferencesSettingsView: View {
    @State private var preferences = ReviewPreferences.load()
    @AppStorage(RawDisplayMode.preferenceKey) private var rawDisplayMode = RawDisplayMode.fast
    @AppStorage(AppleRawDecoder.preferenceKey) private var rawDecoder = AppleRawDecoder.appleDefault

    // Save each edit once, even when the other sections are scrolled offscreen.
    private var savedPreferences: Binding<ReviewPreferences> {
        Binding(get: { preferences }, set: { value in
            preferences = value
            value.save()
        })
    }

    var body: some View {
        Group {
            Section {
                Toggle(L10n.text("Advance after a decision"), isOn: savedPreferences.advancesAfterDecision)
                    .onAppear { preferences = ReviewPreferences.load() }
            } header: {
                Text(L10n.text("Review"))
            }

            ReviewShortcutsSettingsView()

            Section {
                Picker(L10n.text("View"), selection: savedPreferences.defaultView) {
                    Text(L10n.text("Gallery")).tag(ViewMode.gallery)
                    Text(L10n.text("Grid")).tag(ViewMode.grid)
                }
                Picker(L10n.text("Sort by"), selection: savedPreferences.defaultSort.key) {
                    ForEach(PhotoSort.Key.allCases, id: \.self) { key in
                        Text(key.preferenceTitle).tag(key)
                    }
                }
                Picker(L10n.text("Order"), selection: savedPreferences.defaultSort.ascending) {
                    Text(preferences.defaultSort.key.ascendingLabel).tag(true)
                    Text(preferences.defaultSort.key.descendingLabel).tag(false)
                }
                Toggle(L10n.text("Divide into groups"), isOn: savedPreferences.isGroupingEnabled)
                    .disabled(preferences.defaultSort.key == .name)
            } header: {
                Text(L10n.text("New folders"))
            }

            Section {
                Picker(L10n.text("RAW display"), selection: $rawDisplayMode) {
                    Text(L10n.text("Fast")).tag(RawDisplayMode.fast)
                    Text(L10n.text("RAW at all zoom levels")).tag(RawDisplayMode.raw)
                }
                Picker(L10n.text("Apple RAW decoder"), selection: $rawDecoder) {
                    ForEach(AppleRawDecoder.allCases, id: \.self) { decoder in
                        Text(decoder.title).tag(decoder)
                            .disabled(decoder == .raw9 && !AppleRawDecoder.supportsRAW9)
                    }
                }
            } header: {
                Text(L10n.text("RAW display"))
            }

            Section {
                Button(L10n.text("Restore Review Defaults")) {
                    preferences = ReviewPreferences()
                    preferences.save()
                    rawDisplayMode = .fast
                    rawDecoder = .appleDefault
                }
            }
        }
        .tint(Color.louppeAccent)
    }
}
