import AVKit
import XCTest
@testable import Louppe

@MainActor
final class MediaAccessibilityTests: XCTestCase {
    func testSubtitleMenuOffersTracksAndRejectsAReplacedItem() async throws {
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("The native AVKit subtitle menu requires macOS 26.4")
        }
        let item = try fixtureCopy()
        let controller = configuredController()
        defer { controller.stop() }
        controller.prepare(item)
        let (playerItem, subtitles, _) = try await groups(for: controller)
        let coordinator = NativeSubtitleOptionsButton.Coordinator(player: controller.player, expectedItem: playerItem,
                                                                  fallbackGroup: subtitles)
        let button = coordinator.makeButton()
        coordinator.configure(player: controller.player, item: playerItem, group: subtitles, enabled: true)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(coordinator.controller.player === controller.player)
        XCTAssertEqual(button.accessibilityLabel(), "Subtitles")
        let menu = try XCTUnwrap(coordinator.menuForCurrentItem())
        func titles(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) }
        }
        XCTAssertTrue(titles(menu).contains { $0.localizedCaseInsensitiveContains("French") }, titles(menu).description)
        XCTAssertEqual(titles(menu).filter { $0 == "French" }.count, 1,
                       "Do not duplicate AVKit's authored-language choices in the supplemental menu")
        // Only invoke Louppe's authored-track action here; AVKit's own On/Off
        // controls can change system-wide caption preferences.
        let choices = coordinator.authoredTrackMenu(for: subtitles, item: playerItem)
        let frenchIndex = try XCTUnwrap(choices.items.firstIndex { $0.title == "French" })
        choices.performActionForItem(at: frenchIndex)
        try await waitUntil {
            playerItem.currentMediaSelection.selectedMediaOption(in: subtitles)?.locale?.language.languageCode?.identifier == "fr"
        }
        controller.prepare(try fixtureCopy())
        XCTAssertNil(coordinator.menuForCurrentItem(), "A menu for the retired AVPlayerItem must not act on its replacement")
        let (replacement, replacementSubtitles, _) = try await groups(for: controller)
        coordinator.configure(player: controller.player, item: replacement, group: replacementSubtitles, enabled: true)
        let oldOffIndex = try XCTUnwrap(choices.items.firstIndex { $0.tag == 1 })
        choices.performActionForItem(at: oldOffIndex)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(replacement.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: replacementSubtitles),
                      "An old menu's Off action must not change the replacement, even after the coordinator updates")
    }

    func testAutomaticSDHAndDescribedAudioSelectionsReachGalleryAndGrid() async throws {
        let item = try fixtureCopy()
        let controller = configuredController()
        defer { controller.stop() }
        controller.prepare(item)
        let (playerItem, subtitles, audio) = try await groups(for: controller)
        try await waitUntil {
            playerItem.currentMediaSelection.selectedMediaOption(in: subtitles)?
                .hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility) == true
                && playerItem.currentMediaSelection.selectedMediaOption(in: audio)?
                .hasMediaCharacteristic(.describesVideoForAccessibility) == true
        }
        XCTAssertTrue(controller.player.appliesMediaSelectionCriteriaAutomatically)
        XCTAssertTrue(playerItem.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: subtitles))
        XCTAssertTrue(playerItem.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: audio))
        XCTAssertTrue(subtitles.options.contains { $0.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility) })

        let gallery = GalleryVideoSurfaceView(frame: CGRect(x: 0, y: 0, width: 640, height: 360))
        gallery.configure(player: controller.player, presentationSize: CGSize(width: 640, height: 360))
        XCTAssertTrue(gallery.playerLayer.player === controller.player)
        let grid = AVPlayerView()
        NativeVideoPlayer.configure(grid, player: controller.player, controls: .none)
        XCTAssertTrue(grid.player === controller.player)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(playerItem.currentMediaSelection.selectedMediaOption(in: subtitles)?
            .hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility) == true)
        XCTAssertTrue(playerItem.currentMediaSelection.selectedMediaOption(in: audio)?
            .hasMediaCharacteristic(.describesVideoForAccessibility) == true)
        XCTAssertFalse(controller.isPlaying, "Preparing or attaching an accessible track must not autoplay")
    }

    func testManualSubtitleChoiceAndOffCanReturnToAutomatic() async throws {
        let item = try fixtureCopy()
        let controller = configuredController()
        defer { controller.stop() }
        controller.prepare(item)
        let (playerItem, subtitles, _) = try await groups(for: controller)
        let french = try XCTUnwrap(subtitles.options.first { $0.locale?.language.languageCode?.identifier == "fr" })
        playerItem.select(french, in: subtitles)
        try await waitUntil {
            playerItem.currentMediaSelection.selectedMediaOption(in: subtitles)?.locale?.language.languageCode?.identifier == "fr"
        }
        controller.prepare(item)
        XCTAssertTrue(controller.player.currentItem === playerItem)
        XCTAssertFalse(playerItem.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: subtitles))
        XCTAssertTrue(controller.player.appliesMediaSelectionCriteriaAutomatically)

        XCTAssertTrue(subtitles.allowsEmptySelection)
        playerItem.select(nil, in: subtitles)
        try await waitUntil { playerItem.currentMediaSelection.selectedMediaOption(in: subtitles) == nil }
        playerItem.selectMediaOptionAutomatically(in: subtitles)
        try await waitUntil {
            playerItem.currentMediaSelection.selectedMediaOption(in: subtitles)?
                .hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility) == true
        }
        XCTAssertTrue(playerItem.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: subtitles))
    }

    func testNewItemUsesAutomaticCriteriaInsteadOfPreviousItemsManualSelection() async throws {
        let first = try fixtureCopy()
        let second = try fixtureCopy()
        let controller = configuredController()
        defer { controller.stop() }
        controller.prepare(first)
        let (oldItem, subtitles, _) = try await groups(for: controller)
        let french = try XCTUnwrap(subtitles.options.first { $0.locale?.language.languageCode?.identifier == "fr" })
        oldItem.select(french, in: subtitles)
        controller.prepare(second)
        let (newItem, newSubtitles, newAudio) = try await groups(for: controller)
        XCTAssertFalse(newItem === oldItem)
        XCTAssertTrue(controller.represents(second))
        try await waitUntil {
            newItem.currentMediaSelection.selectedMediaOption(in: newSubtitles)?
                .hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility) == true
                && newItem.currentMediaSelection.selectedMediaOption(in: newAudio)?
                .hasMediaCharacteristic(.describesVideoForAccessibility) == true
        }
        XCTAssertTrue(newItem.currentMediaSelection.mediaSelectionCriteriaCanBeAppliedAutomatically(to: newSubtitles))
    }

    private func configuredController() -> VideoPlaybackController {
        _ = NSApplication.shared
        let controller = VideoPlaybackController()
        controller.player.isMuted = true
        // Per-player preferences exercise the same AVFoundation selection path
        // without changing Alex's system caption/audio-description settings.
        controller.player.setMediaSelectionCriteria(AVPlayerMediaSelectionCriteria(
            preferredLanguages: ["en"], preferredMediaCharacteristics: [
                .transcribesSpokenDialogForAccessibility, .describesMusicAndSoundForAccessibility,
            ]), forMediaCharacteristic: .legible)
        controller.player.setMediaSelectionCriteria(AVPlayerMediaSelectionCriteria(
            preferredLanguages: ["en"], preferredMediaCharacteristics: [.describesVideoForAccessibility]),
            forMediaCharacteristic: .audible)
        return controller
    }

    private func groups(for controller: VideoPlaybackController) async throws
        -> (AVPlayerItem, AVMediaSelectionGroup, AVMediaSelectionGroup) {
        let playerItem = try XCTUnwrap(controller.player.currentItem)
        try await waitUntil { playerItem.status != .unknown }
        XCTAssertEqual(playerItem.status, .readyToPlay, playerItem.error?.localizedDescription ?? "")
        let loadedSubtitles = try await playerItem.asset.loadMediaSelectionGroup(for: .legible)
        let loadedAudio = try await playerItem.asset.loadMediaSelectionGroup(for: .audible)
        let subtitles = try XCTUnwrap(loadedSubtitles)
        let audio = try XCTUnwrap(loadedAudio)
        let sdh = try XCTUnwrap(subtitles.options.first {
            $0.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
                && $0.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
        })
        let french = try XCTUnwrap(subtitles.options.first { $0.locale?.language.languageCode?.identifier == "fr" })
        let described = try XCTUnwrap(audio.options.first { $0.hasMediaCharacteristic(.describesVideoForAccessibility) })
        let original = try XCTUnwrap(audio.options.first { !$0.hasMediaCharacteristic(.describesVideoForAccessibility) })
        if #available(macOS 27.0, *) {
            // macOS can add generated transcript choices. Check the authored
            // options remain selectable rather than fixing the group count.
            let selectableSubtitles = playerItem.selectableMediaSelectionOptions(in: subtitles)
            let selectableAudio = playerItem.selectableMediaSelectionOptions(in: audio)
            XCTAssertTrue(selectableSubtitles.contains(sdh))
            XCTAssertTrue(selectableSubtitles.contains(french))
            XCTAssertTrue(selectableAudio.contains(described))
            XCTAssertTrue(selectableAudio.contains(original))
        }
        return (playerItem, subtitles, audio)
    }

    private func fixtureCopy() throws -> PhotoItem {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AccessibilityMedia/captioned-described.mov")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LouppeMediaAccessibility-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("captioned-described.mov")
        try FileManager.default.copyItem(at: source, to: url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return PhotoItem(id: url.path, primaryURL: url, pairedURL: nil, captureDate: nil,
                         cameraModel: nil, lensModel: nil, mediaKind: .video, duration: 8,
                         videoDimensions: CGSize(width: 640, height: 360), videoIsPlayable: true,
                         primaryModificationDate: values.contentModificationDate,
                         fileSize: Int64(try XCTUnwrap(values.fileSize)))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Native media selection did not settle before the deadline")
    }

}
