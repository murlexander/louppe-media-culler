import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class GalleryVideoAccessibilityTests: XCTestCase {
    func testPlayingKeepsGalleryTransportMountedWithoutHover() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("louppe-video-keyboard-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("playback.wav")
        try writeSilentWAV(to: url)
        // The real AVPlayer may play an audio-only asset on a Gallery surface;
        // it gives the focus contract an inexpensive, deterministic minute.
        let item = PhotoItem(id: url.lastPathComponent, primaryURL: url,
            pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil,
            mediaKind: .video, duration: 60, videoIsPlayable: true, fileSize: 960_044)
        let playback = VideoPlaybackController()
        let host = NSHostingView(rootView: GalleryVideoPlayerView(item: item, playback: playback))
        host.frame = NSRect(x: 0, y: 50, width: 640, height: 360)
        let outside = NSButton(title: "Outside video", target: nil, action: nil)
        outside.frame = NSRect(x: 10, y: 10, width: 140, height: 28)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 410))
        container.addSubview(host)
        container.addSubview(outside)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        defer { playback.stop(); window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(outside))
        let ready = await waitForPlayer(in: host) {
            GalleryVideoControlsTestProbe.isMounted(for: playback)
                && playback.player.currentItem?.status == .readyToPlay
        }
        guard ready else {
            return XCTFail("native fixture did not become ready: \(String(describing: playback.errorMessage)), status \(String(describing: playback.player.currentItem?.status))")
        }
        playback.toggle(item)
        // toggle() publishes optimistic intent immediately. Wait for the real
        // native playing state and a subsequent time tick, allowing SwiftUI
        // to render the playing branch before inspecting control lifetime.
        let playing = await waitForPlayer(in: host) {
            playback.player.timeControlStatus == .playing
                && playback.isPlaying && playback.currentTimeSeconds > 0.05
        }
        guard playing else {
            return XCTFail("native fixture did not advance while playing: \(String(describing: playback.errorMessage)), timeControlStatus \(playback.player.timeControlStatus), time \(playback.currentTimeSeconds)")
        }
        XCTAssertTrue(window.firstResponder === outside)
        XCTAssertTrue(GalleryVideoControlsTestProbe.isMounted(for: playback),
                      "actual playing with focus and pointer elsewhere must retain the native transport")
        let labels = Set(accessibilityElements(in: host).compactMap { $0.accessibilityLabel() })
        if !labels.isEmpty {
            XCTAssertTrue(labels.contains("Pause"))
            XCTAssertTrue(labels.contains("Timeline"))
            XCTAssertTrue(labels.contains("Volume"))
            XCTAssertTrue(labels.contains("Toggle full screen"))
        }
        // Keyboard traversal requires the user's Full Keyboard Access setting.
        // Do not change their global preference from a hosted unit test.
        if NSApp.isFullKeyboardAccessEnabled {
            outside.nextKeyView = host
            host.nextKeyView = outside
            sendTab(in: window)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertFalse(window.firstResponder === outside)
        }
        playback.pause()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(GalleryVideoControlsTestProbe.isMounted(for: playback))
    }

    private func waitForPlayer(
        in host: NSView, condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func sendTab(in window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) else { return }
        window.sendEvent(event)
    }

    private func accessibilityElements(in root: NSView) -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var visited: Set<ObjectIdentifier> = []
        func walk(_ value: Any) {
            guard let object = value as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return }
            if let accessible = object as? any NSAccessibilityProtocol {
                result.append(accessible)
                for child in accessible.accessibilityChildren() ?? [] { walk(child) }
            }
            else if object.responds(to: NSSelectorFromString("accessibilityChildren")),
                    let children = object.perform(NSSelectorFromString("accessibilityChildren"))?.takeUnretainedValue() as? [Any] {
                for child in children { walk(child) }
            }
            if let view = object as? NSView { for child in view.subviews { walk(child) } }
        }
        walk(root)
        return result
    }

    private func writeSilentWAV(to url: URL) throws {
        let sampleRate: UInt32 = 8_000
        let dataByteCount: UInt32 = 60 * sampleRate * 2
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); put(36 + dataByteCount)
        data.append(contentsOf: "WAVEfmt ".utf8); put(UInt32(16)); put(UInt16(1))
        put(UInt16(1)); put(sampleRate); put(sampleRate * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: "data".utf8); put(dataByteCount)
        data.append(Data(count: Int(dataByteCount)))
        try data.write(to: url)
    }
}
