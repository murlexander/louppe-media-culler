import AVFoundation
import XCTest
@testable import Louppe

final class AudioTrackSelectionTests: XCTestCase {
    func testAlternateAudioTracksNeverProduceMisleadingFirstTrackMeasurements() async throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/AudioTrackSelection/alternate-levels.mov")
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LouppeAudioSelection-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("alternate-levels.mov")
        try FileManager.default.copyItem(at: source, to: url)
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
        XCTAssertNil(analysis, "Without a resolved selected track, Info and Gallery must show unavailable instead of measuring track 1")
        let repeated = await pipeline.analysis(for: item)
        XCTAssertNil(repeated, "A wrong-track result must not enter the shared cache")
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
