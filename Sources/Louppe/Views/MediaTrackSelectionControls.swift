import AVKit
import SwiftUI

/// The current AVPlayerItem owns both automatic criteria and manual choices.
/// Info loads only that item's optional groups; Gallery and Grid share it.
struct MediaTrackSelectionControls: View {
    let item: PhotoItem
    @ObservedObject var playback: VideoPlaybackController

    private enum Choice: Hashable {
        case automatic, off
        case option(AVMediaSelectionOption)
    }

    @State private var loadedItem: AVPlayerItem?
    @State private var subtitles: AVMediaSelectionGroup?
    @State private var audio: AVMediaSelectionGroup?
    @State private var subtitleChoice = Choice.automatic
    @State private var audioChoice = Choice.automatic
    @State private var automaticSubtitleName: String?
    @State private var automaticAudioName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if playback.represents(item), let current = playback.player.currentItem {
                if #available(macOS 26.4, *) {
                    NativeSubtitleOptionsButton(player: playback.player, expectedItem: current,
                                                fallbackGroup: loadedItem === current ? subtitles : nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if loadedItem === playback.player.currentItem, playback.represents(item) {
                if #unavailable(macOS 26.4) {
                    if let subtitles, !subtitles.options.isEmpty {
                        trackPicker(L10n.text("Subtitles"), group: subtitles, choice: $subtitleChoice)
                    }
                }
                if let audio, audio.options.count > 1 {
                    trackPicker(L10n.text("Audio track"), group: audio, choice: $audioChoice)
                }
            } else if playback.represents(item), playback.player.currentItem != nil {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L10n.text("Loading media options"))
            }
        }
        .task(id: playback.player.currentItem) {
            loadedItem = nil
            subtitles = nil
            audio = nil
            guard playback.represents(item), let current = playback.player.currentItem else { return }
            let subtitleGroup = try? await current.asset.loadMediaSelectionGroup(for: .legible)
            guard !Task.isCancelled else { return }
            let audioGroup = try? await current.asset.loadMediaSelectionGroup(for: .audible)
            guard !Task.isCancelled, current === playback.player.currentItem,
                  playback.represents(item) else { return }
            loadedItem = current
            subtitles = subtitleGroup
            audio = audioGroup
            refreshChoices()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.mediaSelectionDidChangeNotification)) { notification in
            guard let changed = notification.object as? AVPlayerItem,
                  changed === loadedItem, changed === playback.player.currentItem else { return }
            refreshChoices()
        }
    }

    private func trackPicker(_ title: String, group: AVMediaSelectionGroup, choice: Binding<Choice>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(.subheadline.weight(.semibold))
            Picker(title, selection: Binding(
                get: { choice.wrappedValue },
                set: { select($0, in: group) }
            )) {
                Text(verbatim: L10n.text("Automatic") + ((group === audio ? automaticAudioName : automaticSubtitleName)
                    .map { " — " + $0 } ?? "")).tag(Choice.automatic)
                if group.allowsEmptySelection {
                    Text(L10n.text("Off")).tag(Choice.off)
                }
                ForEach(group.options, id: \.self) { option in
                    Text(verbatim: option.displayName).tag(Choice.option(option))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func select(_ choice: Choice, in group: AVMediaSelectionGroup) {
        guard let loadedItem, loadedItem === playback.player.currentItem,
              playback.represents(item) else { return }
        switch choice {
        case .automatic:
            loadedItem.selectMediaOptionAutomatically(in: group)
        case .off:
            guard group.allowsEmptySelection else { return }
            loadedItem.select(nil, in: group)
        case .option(let option):
            guard group.options.contains(option) else { return }
            loadedItem.select(option, in: group)
        }
        refreshChoices()
    }

    private func refreshChoices() {
        guard let loadedItem, loadedItem === playback.player.currentItem else { return }
        func choice(in group: AVMediaSelectionGroup?) -> Choice {
            guard let group else { return .automatic }
            let selection = loadedItem.currentMediaSelection
            if selection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: group) { return .automatic }
            return selection.selectedMediaOption(in: group).map(Choice.option) ?? .off
        }
        subtitleChoice = choice(in: subtitles)
        audioChoice = choice(in: audio)
        func automaticName(in group: AVMediaSelectionGroup?) -> String? {
            guard let group, loadedItem.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: group) else { return nil }
            return loadedItem.currentMediaSelection.selectedMediaOption(in: group)?.displayName
        }
        automaticSubtitleName = automaticName(in: subtitles)
        automaticAudioName = automaticName(in: audio)
    }
}

/// AVKit owns current subtitle choices, including generated options, on current
/// macOS. An ordinary native button opens the framework's accessible NSMenu.
@available(macOS 26.4, *)
struct NativeSubtitleOptionsButton: NSViewRepresentable {
    let player: AVPlayer
    let expectedItem: AVPlayerItem
    let fallbackGroup: AVMediaSelectionGroup?

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player, expectedItem: expectedItem, fallbackGroup: fallbackGroup)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = context.coordinator.makeButton()
        context.coordinator.configure(player: player, item: expectedItem, group: fallbackGroup, enabled: context.environment.isEnabled)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.configure(player: player, item: expectedItem, group: fallbackGroup, enabled: context.environment.isEnabled)
    }

    @MainActor
    final class Coordinator: NSObject, AVLegibleMediaOptionsMenuController.Delegate {
        let controller: AVLegibleMediaOptionsMenuController
        private weak var expectedItem: AVPlayerItem?
        private var fallbackGroup: AVMediaSelectionGroup?
        private weak var button: NSButton?
        private var environmentEnabled = true

        init(player: AVPlayer, expectedItem: AVPlayerItem, fallbackGroup: AVMediaSelectionGroup?) {
            controller = AVLegibleMediaOptionsMenuController(player: player)
            self.expectedItem = expectedItem
            self.fallbackGroup = fallbackGroup
            super.init()
            controller.delegate = self
        }

        func makeButton() -> NSButton {
            let button = NSButton(title: L10n.text("Subtitles"), target: self, action: #selector(showOptions(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)
            button.imagePosition = .imageTrailing
            button.contentTintColor = .louppeAccentColor
            button.setAccessibilityLabel(L10n.text("Subtitles"))
            self.button = button
            refreshEnabled()
            return button
        }

        func configure(player: AVPlayer, item: AVPlayerItem, group: AVMediaSelectionGroup?, enabled: Bool) {
            if controller.player !== player { controller.player = player }
            expectedItem = item
            fallbackGroup = group
            environmentEnabled = enabled
            refreshEnabled()
        }

        func menuForCurrentItem() -> NSMenu? {
            guard let expectedItem, expectedItem === controller.player.currentItem else { return nil }
            let native = controller.menu(contents: .legible)
            guard let group = fallbackGroup, !group.options.isEmpty else { return native }
            let options = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
            let tracks = authoredTrackMenu(for: group, item: expectedItem)
            guard let native else { return tracks }
            let identifier = NSUserInterfaceItemIdentifier("louppe.subtitle-tracks")
            for entry in native.items where entry.identifier == identifier { native.removeItem(entry) }
            func titles(_ menu: NSMenu) -> [String] {
                menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) }
            }
            // AVKit can vend only On/Off/style controls for a local asset.
            // Keep every authored language reachable when that happens.
            func normalized(_ title: String) -> String {
                title.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !Set(titles(native).map(normalized)).isSuperset(of: options.map { normalized($0.displayName) }) {
                let entry = NSMenuItem(title: L10n.text("Subtitle tracks"), action: nil, keyEquivalent: "")
                entry.identifier = identifier
                entry.submenu = tracks
                native.addItem(entry)
            }
            return native
        }

        func authoredTrackMenu(for group: AVMediaSelectionGroup, item: AVPlayerItem) -> NSMenu {
            let tracks = NSMenu()
            let automatic = item.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: group)
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            func add(_ title: String, tag: Int, option: AVMediaSelectionOption? = nil, selected: Bool) {
                let entry = NSMenuItem(title: title, action: #selector(selectFallbackOption(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = tag
                entry.representedObject = TrackChoice(item: item, group: group, option: option)
                entry.state = selected ? .on : .off
                tracks.addItem(entry)
            }
            add(L10n.text("Automatic"), tag: 0, selected: automatic)
            if group.allowsEmptySelection {
                add(L10n.text("Off"), tag: 1, selected: !automatic && selected == nil)
            }
            for option in group.options where !option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) {
                add(option.displayName, tag: 2, option: option, selected: !automatic && selected == option)
            }
            return tracks
        }

        private final class TrackChoice {
            weak var item: AVPlayerItem?
            let group: AVMediaSelectionGroup
            let option: AVMediaSelectionOption?
            init(item: AVPlayerItem, group: AVMediaSelectionGroup, option: AVMediaSelectionOption?) {
                self.item = item
                self.group = group
                self.option = option
            }
        }

        @objc private func selectFallbackOption(_ sender: NSMenuItem) {
            guard let expectedItem, expectedItem === controller.player.currentItem,
                  let choice = sender.representedObject as? TrackChoice,
                  choice.item === expectedItem else { return }
            let group = choice.group
            if sender.tag == 0 { expectedItem.selectMediaOptionAutomatically(in: group) }
            else if sender.tag == 1, group.allowsEmptySelection { expectedItem.select(nil, in: group) }
            else if let option = choice.option, group.options.contains(option) {
                expectedItem.select(option, in: group)
            }
        }

        @objc private func showOptions(_ sender: NSButton) {
            menuForCurrentItem()?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY - 2), in: sender)
        }

        private func refreshEnabled() {
            button?.isEnabled = environmentEnabled && expectedItem != nil && expectedItem === controller.player.currentItem
                && (controller.menuState.enabled.boolValue || fallbackGroup?.options.isEmpty == false)
        }

        nonisolated func legibleMenuController(_ menuController: AVLegibleMediaOptionsMenuController,
                                               didChange state: AVLegibleMediaOptionsMenuState) {
            Task { @MainActor [weak self] in self?.refreshEnabled() }
        }
    }
}
