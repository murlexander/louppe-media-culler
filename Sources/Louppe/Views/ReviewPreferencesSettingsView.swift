import SwiftUI

struct ReviewPreferencesSettingsView: View {
    @State private var preferences = ReviewPreferences.load()
    @AppStorage(RawDisplayMode.preferenceKey) private var rawDisplayMode = RawDisplayMode.fast
    @AppStorage(AppleRawDecoder.preferenceKey) private var rawDecoder = AppleRawDecoder.appleDefault

    var body: some View {
        Form {
            Section {
                Toggle(L10n.text("Advance after a decision"), isOn: $preferences.advancesAfterDecision)
            }

            Section {
                Picker(L10n.text("View"), selection: $preferences.defaultView) {
                    Text(L10n.text("Gallery")).tag(ViewMode.gallery)
                    Text(L10n.text("Grid")).tag(ViewMode.grid)
                }
                Picker(L10n.text("Sort by"), selection: $preferences.defaultSort.key) {
                    ForEach(PhotoSort.Key.allCases, id: \.self) { key in
                        Text(key.preferenceTitle).tag(key)
                    }
                }
                Picker(L10n.text("Order"), selection: $preferences.defaultSort.ascending) {
                    Text(preferences.defaultSort.key.ascendingLabel).tag(true)
                    Text(preferences.defaultSort.key.descendingLabel).tag(false)
                }
                Toggle(L10n.text("Divide into groups"), isOn: $preferences.isGroupingEnabled)
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
            }

            Section {
                Button(L10n.text("Restore Review Defaults")) {
                    preferences = ReviewPreferences()
                    rawDisplayMode = .fast
                    rawDecoder = .appleDefault
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: preferences) { _, value in value.save() }
        .onAppear { preferences = ReviewPreferences.load() }
        .tint(Color.louppeAccent)
    }
}
