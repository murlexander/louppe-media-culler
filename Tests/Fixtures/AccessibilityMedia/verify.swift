import AVFoundation
import Foundation

// Standalone AVFoundation verification: do not initialize NSApplication.
// An inactive XCTest app can defer legible output until it owns the foreground.
private final class CaptionSink: NSObject, AVPlayerItemLegibleOutputPushDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var found = false
    var decodedExpectedCue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return found
    }
    func legibleOutput(_ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        found = found || strings.contains { $0.string == "[Silence]" }
    }
}

@main struct VerifyCaptionFixture {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "CaptionFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass the generated MOV path."])
        }
        let item = AVPlayerItem(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let sink = CaptionSink()
        let output = AVPlayerItemLegibleOutput()
        output.setDelegate(sink, queue: DispatchQueue(label: "CaptionFixture.Decode"))
        item.add(output)
        guard let group = try await item.asset.loadMediaSelectionGroup(for: .legible),
              let sdh = group.options.first(where: {
                  $0.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
                      && !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
              }) else { throw NSError(domain: "CaptionFixture", code: 2) }
        item.select(sdh, in: group)
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while item.status == .unknown, ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard item.status == .readyToPlay else { throw item.error ?? NSError(domain: "CaptionFixture", code: 3) }
        await item.seek(to: .zero)
        player.play()
        let decodeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !sink.decodedExpectedCue, ContinuousClock.now < decodeDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard sink.decodedExpectedCue else { throw NSError(domain: "CaptionFixture", code: 4) }
        print("Authored SDH caption decoded successfully.")
    }
}
