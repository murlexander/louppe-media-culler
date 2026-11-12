import AVKit
import XCTest
import SwiftUI
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

    func testTrackOptionsFailureOffersWorkingRetryInBothDirections() async throws {
        let item = try fixtureCopy()
        let controller = configuredController()
        defer { controller.stop() }
        controller.prepare(item)
        _ = try await groups(for: controller)
        for scheme in [ColorScheme.light, .dark] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                var attempts = 0
                let host = NSHostingView(rootView: HStack(alignment: .top, spacing: 16) {
                    MediaTrackSelectionControls(item: item, playback: controller, loadOptions: { _ in
                        attempts += 1
                        return attempts == 1 ? .failed : .loaded(subtitles: nil, audio: nil)
                    })
                    .frame(width: 240, alignment: .leading)
                    Divider()
                    MediaTrackSelectionControls(item: item, playback: controller)
                        .frame(width: 240, alignment: .leading)
                }
                .padding(16)
                .frame(width: 530, height: 160, alignment: .topLeading)
                .background(Color.appBackground)
                .tint(Color.louppeAccent)
                .environment(\.colorScheme, scheme)
                .environment(\.layoutDirection, direction)
                .environment(\.accessibilityEnabled, true))
                let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 530, height: 160),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.layoutSubtreeIfNeeded()
                try await waitUntil { attempts == 1 && self.retryButton(in: host) != nil }
                host.layoutSubtreeIfNeeded()
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
                let retry = try XCTUnwrap(retryButton(in: host))
                if let output = ProcessInfo.processInfo.environment["LOUPPE_TRACK_OPTIONS_SNAPSHOTS"] {
                    let folder = URL(fileURLWithPath: output, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let suffix = "\(scheme == .light ? "light" : "dark")-\(direction == .leftToRight ? "ltr" : "rtl")"
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        .write(to: folder.appendingPathComponent("track-options-\(suffix).png"))
                }
                let press = NSSelectorFromString("accessibilityPerformPress")
                XCTAssertTrue(retry.responds(to: press))
                retry.perform(press)
                try await waitUntil { attempts == 2 && self.retryButton(in: host) == nil }
            }
        }
    }

    func testRetiredTrackFailureCannotReplaceOptionsAfterReturningToSamePhoto() async throws {
        let first = try fixtureCopy()
        let second = try fixtureCopy()
        let controller = configuredController()
        defer { controller.stop() }
        controller.prepare(first)
        _ = try await groups(for: controller)
        let originalPlayerItem = try XCTUnwrap(controller.player.currentItem)
        let retiredTaskFinished = expectation(description: "The retired options task has exited")
        let didFinish: (AVPlayerItem) -> Void = { current in
            if current === originalPlayerItem { retiredTaskFinished.fulfill() }
        }
        var attempts = 0
        var retiredLoad: CheckedContinuation<MediaTrackOptionsResult, Never>?
        let loader: @MainActor (AVAsset) async throws -> MediaTrackOptionsResult = { _ in
            attempts += 1
            if attempts == 1 {
                // Deliberately ignore cancellation, like a late native read.
                return await withCheckedContinuation { retiredLoad = $0 }
            }
            return .loaded(subtitles: nil, audio: nil)
        }
        let host = NSHostingView(rootView: MediaTrackSelectionControls(
            item: first, playback: controller, loadOptions: loader, onOptionsLoadFinishedForTesting: didFinish)
            .environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 300, height: 160),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            retiredLoad?.resume(returning: .failed)
            window.contentView = nil
            window.close()
        }
        try await waitUntil { retiredLoad != nil }
        controller.prepare(second)
        host.rootView = MediaTrackSelectionControls(item: second, playback: controller, loadOptions: loader, onOptionsLoadFinishedForTesting: didFinish)
            .environment(\.accessibilityEnabled, true)
        try await waitUntil { attempts == 2 }
        controller.prepare(first)
        host.rootView = MediaTrackSelectionControls(item: first, playback: controller, loadOptions: loader, onOptionsLoadFinishedForTesting: didFinish)
            .environment(\.accessibilityEnabled, true)
        try await waitUntil { attempts == 3 }
        let late = try XCTUnwrap(retiredLoad)
        retiredLoad = nil
        late.resume(returning: .failed)
        await fulfillment(of: [retiredTaskFinished], timeout: 5)
        host.layoutSubtreeIfNeeded()
        XCTAssertNil(retryButton(in: host), "The first A player's late failure must not replace the new A's successful options")
        XCTAssertEqual(attempts, 3, "A stale failure must not start an automatic retry loop")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    private func retryButton(in root: NSView) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            let label = NSSelectorFromString("accessibilityLabel")
            if object.responds(to: label),
               object.perform(label)?.takeUnretainedValue() as? String == L10n.text("Try Again") { return object }
            let children = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: children),
               let entries = object.perform(children)?.takeUnretainedValue() as? [NSObject] {
                for entry in entries { if let button = find(entry) { return button } }
            }
            if let view = object as? NSView {
                for child in NSAccessibility.unignoredChildren(from: [view]) {
                    if let child = child as? NSObject, let button = find(child) { return button }
                }
                for child in view.subviews { if let button = find(child) { return button } }
            }
            return nil
        }
        return find(root)
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
