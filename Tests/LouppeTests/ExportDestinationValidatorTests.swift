import XCTest
@testable import Louppe

final class ExportDestinationValidatorTests: XCTestCase {
    func testZeroImportantUsageCapacityFallsBackToFileSystemCapacity() {
        XCTAssertEqual(
            ExportDestinationValidator.effectiveAvailableCapacity(
                importantUsage: 0,
                fileSystem: 24_000_000_000
            ),
            24_000_000_000
        )
        XCTAssertNil(
            ExportDestinationValidator.effectiveAvailableCapacity(
                importantUsage: 0,
                fileSystem: nil
            ),
            "an ambiguous zero must not be reported as a full disk"
        )
        XCTAssertEqual(
            ExportDestinationValidator.effectiveAvailableCapacity(
                importantUsage: 0,
                fileSystem: 0
            ),
            0,
            "statfs zero is an independent confirmation that the disk is full"
        )
        XCTAssertEqual(
            ExportDestinationValidator.effectiveAvailableCapacity(
                importantUsage: 30_000_000_000,
                fileSystem: 10_000_000_000
            ),
            30_000_000_000,
            "positive important-usage capacity includes space macOS can reclaim"
        )
    }

    /// Move preflight queries every physical source's volume. A cancelled
    /// detached check must stop instead of finishing a large or slow scan.
    func testCancelledMovePreflightStopsBeforeVolumeQueriesAndChangesNothing() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/LouppeValidatorCancel-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("MOVE.JPG")
        try Data("original".utf8).write(to: file)
        let item = PhotoItem(id: "MOVE.JPG", primaryURL: file, pairedURL: nil, captureDate: nil,
                             cameraModel: nil, lensModel: nil, fileSize: 8)

        let started = AsyncStream<Void>.makeStream()
        let resume = AsyncStream<Void>.makeStream()
        let check = Task.detached { () -> Result<URL, Error> in
            started.continuation.yield()
            for await _ in resume.stream { break }
            return Result {
                try ExportDestinationValidator.validateBound(
                    sourceFolder: source, destination: destination, items: [item], mode: .move
                ).url
            }
        }
        for await _ in started.stream { break }
        check.cancel()
        resume.continuation.yield()
        let result = await check.value
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)

        // Copy has no per-source volume loop and still validates normally.
        let copy = try ExportDestinationValidator.validateBound(
            sourceFolder: source, destination: destination, items: [item], mode: .copy)
        XCTAssertTrue(FileOperationJournal.exactPathsEqual(
            copy.url, try FileOperationJournal.resolvingSymlinksExactly(destination)))
    }

    func testMoveRequiresEveryPhysicalFileOnOneKnownDestinationVolume() {
        let volumeA = AnyHashable("volume-a")
        let volumeB = AnyHashable("volume-b")

        XCTAssertTrue(
            ExportDestinationValidator.volumeIdentifiersAllowAtomicMove(
                source: [volumeA, volumeA],
                destination: volumeA
            )
        )
        XCTAssertFalse(
            ExportDestinationValidator.volumeIdentifiersAllowAtomicMove(
                source: [volumeA, volumeB],
                destination: volumeA
            )
        )
        XCTAssertFalse(
            ExportDestinationValidator.volumeIdentifiersAllowAtomicMove(
                source: [volumeA, nil],
                destination: volumeA
            )
        )
        XCTAssertFalse(
            ExportDestinationValidator.volumeIdentifiersAllowAtomicMove(
                source: [volumeA],
                destination: nil
            )
        )
        XCTAssertFalse(
            ExportDestinationValidator.volumeIdentifiersAllowAtomicMove(
                source: [],
                destination: volumeA
            )
        )
    }
}
