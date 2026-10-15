import Foundation
import AVFoundation

@main struct AuditSeek {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/louppe-audit-2026-09-29/media-repro/fixtures")
        let first = PhotoItem(id: "long.wav", primaryURL: root.appendingPathComponent("long.wav"), pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, mediaKind: .audio, duration: 3600, audioIsPlayable: true, fileSize: 1)
        let second = PhotoItem(id: "short.wav", primaryURL: root.appendingPathComponent("short.wav"), pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, mediaKind: .audio, duration: 1, audioIsPlayable: true, fileSize: 1)
        let controller = VideoPlaybackController()
        controller.prepare(first)
        for _ in 0..<200 {
            if controller.player.currentItem?.status == .readyToPlay { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        print("READY=\(controller.player.currentItem!.status.rawValue)")
        let sought = await controller.player.seek(to: CMTime(seconds: 20, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        print("INITIAL_SEEK_DONE=\(sought), TIME=\(controller.player.currentTime().seconds)")
        controller.seek(first, to: 60)
        print("PENDING_SEEK_TARGET=\(controller.currentTimeSeconds), ACTUAL_TIME=\(controller.player.currentTime().seconds), REMEMBERED=\(controller.rememberedPosition(for: first) ?? -1)")
        controller.prepare(second)
        print("AFTER_IMMEDIATE_NAVIGATION_REMEMBERED=\(controller.rememberedPosition(for: first) ?? -1)")
        controller.stop()
    }
}
