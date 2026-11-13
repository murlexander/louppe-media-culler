import AVFoundation
import XCTest
@testable import Louppe

final class AudioTrackSelectionTests: XCTestCase {
    func testSingleEnabledDefaultRequiresExplicitFallbackForAlternatives() async throws {
        for enabled in [[true, false], [false, true], [true, true], [false, false]] {
            for fallback in [false, true] {
                try await checkEnabledTracks(enabled, fallback: fallback)
            }
        }
    }

    private func checkEnabledTracks(_ enabled: [Bool], fallback: Bool) async throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AudioTrackSelection/alternate-levels.mov")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LouppeAudioSelection-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("alternate-levels.mov")
        var bytes = try Data(contentsOf: source)
        // Only edit this disposable fixture's documented QuickTime tkhd enabled
        // flags. Its tracks have deliberately different levels and channel counts.
        var offset = 0
        for isEnabled in enabled {
            let header = try XCTUnwrap(bytes.range(of: Data("tkhd".utf8), in: offset..<bytes.count))
            bytes[header.lowerBound + 7] = isEnabled ? 3 : 2
            if enabled.allSatisfy({ $0 }) {
                // Separate groups permit two simultaneous enabled tracks;
                // AVFoundation normalizes invalid dual-enabled alternatives.
                bytes[header.lowerBound + 38] = 0
                bytes[header.lowerBound + 39] = 0
            }
            offset = header.upperBound
        }
        try bytes.write(to: url)
        if fallback { try await addDefaultAudioFallback(to: url) }
        let original = try Data(contentsOf: url)
        let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 2, "Fixture must contain distinct selectable tracks")
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let item = PhotoItem(id: url.path, primaryURL: url, pairedURL: nil, captureDate: nil,
            cameraModel: nil, lensModel: nil, mediaKind: .audio, duration: 1,
            audioIsPlayable: true, primaryModificationDate: values.contentModificationDate,
            fileSize: Int64(try XCTUnwrap(values.fileSize)))
        let pipeline = AudioLevelPipeline()
        let analysis = await pipeline.analysis(for: item)
        var actualEnabled: [Bool] = []
        for track in tracks { actualEnabled.append(try await track.load(.isEnabled)) }
        XCTAssertEqual(actualEnabled, enabled)
        if fallback && enabled.filter({ $0 }).count == 1 {
            let levels = try XCTUnwrap(analysis, "One enabled track has an unambiguous authored default")
            XCTAssertEqual(levels.channels.count, enabled[0] ? 1 : 2)
            XCTAssertEqual(levels.channels[0].peak, enabled[0] ? 0.125 : 0.75, accuracy: 0.01)
            if !enabled[0] { XCTAssertEqual(levels.channels[1].peak, 0.5, accuracy: 0.01) }
            let repeated = await pipeline.analysis(for: item)
            XCTAssertEqual(repeated, analysis)
        } else {
            XCTAssertNil(analysis, "Ambiguous or independent alternatives must remain unavailable")
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}

/// Adds an explicit QuickTime fallback reference using AVFoundation, only to a
/// disposable fixture. Original fixture bytes and playback code stay untouched.
func addDefaultAudioFallback(to url: URL) async throws {
    let movie = try AVMutableMovie(url: url, options: nil)
    let tracks = try await movie.loadTracks(withMediaType: .audio)
    guard tracks.count == 2,
          let first = tracks[0] as? AVMutableMovieTrack,
          let second = tracks[1] as? AVMutableMovieTrack else { throw CocoaError(.coderInvalidValue) }
    first.extendedLanguageTag = "und"
    second.extendedLanguageTag = "und"
    let firstEnabled = try await first.load(.isEnabled)
    let defaultTrack = firstEnabled ? first : second
    let alternative = firstEnabled ? second : first
    alternative.addTrackAssociation(to: defaultTrack, type: .audioFallback)
    try movie.writeHeader(to: url, fileType: .mov, options: .addMovieHeaderToDestination)
}
