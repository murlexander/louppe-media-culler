import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

final class FolderScannerIntegrityTests: XCTestCase {
    func testLazyJPEGSplitRejectsReplacementBeforeReadingMetadata() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pair = try scannedPair(in: fixture)
        let jpeg = try XCTUnwrap(pair.pairedFile)
        let expectedMetadata = jpeg.metadataSnapshot
        let expectedIdentity = jpeg.scannedIdentity
        let rawBytes = try Data(contentsOf: fixture.raw)
        let replacement = try jpegBytes(camera: "Replacement camera")
        try replacement.write(to: fixture.jpeg, options: .atomic)

        XCTAssertThrowsError(try FolderScanner.projectPairingMode(
            .separate, from: [pair], root: fixture.root
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Rescan Folder"))
        }
        XCTAssertEqual(jpeg.metadataSnapshot, expectedMetadata)
        XCTAssertEqual(jpeg.scannedIdentity, expectedIdentity)
        XCTAssertFalse(jpeg.metadataIsLoaded)
        XCTAssertEqual(try Data(contentsOf: fixture.jpeg), replacement)
        XCTAssertEqual(try Data(contentsOf: fixture.raw), rawBytes)
    }

    func testLazyJPEGSplitRejectsReplacementDuringMetadataRead() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pair = try scannedPair(in: fixture)
        let jpeg = try XCTUnwrap(pair.pairedFile)
        let expectedMetadata = jpeg.metadataSnapshot
        let expectedIdentity = jpeg.scannedIdentity
        let rawBytes = try Data(contentsOf: fixture.raw)
        let replacement = try jpegBytes(camera: "Replaced during EXIF read")

        XCTAssertThrowsError(try FolderScanner.projectPairingMode(
            .separate, from: [pair], root: fixture.root,
            metadataReaderForTesting: { url in
                // Preflight already proved the original scanned file. Swap
                // it as the reader starts, then read the replacement's EXIF.
                try replacement.write(to: url, options: .atomic)
                let info = MetadataExtractor.scanInfo(for: url)
                XCTAssertEqual(info.cameraModel, "Replaced during EXIF read")
                return info
            }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Rescan Folder"))
        }
        XCTAssertEqual(jpeg.metadataSnapshot, expectedMetadata)
        XCTAssertEqual(jpeg.scannedIdentity, expectedIdentity)
        XCTAssertFalse(jpeg.metadataIsLoaded)
        XCTAssertEqual(try Data(contentsOf: fixture.jpeg), replacement)
        XCTAssertEqual(try Data(contentsOf: fixture.raw), rawBytes)
    }

    func testLazyJPEGSplitRejectsReplacementAfterMetadataRead() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pair = try scannedPair(in: fixture)
        let replacement = try jpegBytes(camera: "Replaced after EXIF read")
        XCTAssertThrowsError(try FolderScanner.projectPairingMode(
            .separate, from: [pair], root: fixture.root,
            metadataReaderForTesting: { url in
                let originalInfo = MetadataExtractor.scanInfo(for: url)
                XCTAssertEqual(originalInfo.cameraModel, "Original camera")
                try replacement.write(to: url, options: .atomic)
                return originalInfo
            }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Rescan Folder"))
        }
        XCTAssertFalse(try XCTUnwrap(pair.pairedFile).metadataIsLoaded)
        XCTAssertEqual(try Data(contentsOf: fixture.jpeg), replacement)
    }

    func testUnchangedLazyJPEGKeepsPhysicalRatingsAndCachedMetadata() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pair = try scannedPair(in: fixture)
        let jpeg = try XCTUnwrap(pair.pairedFile)
        let metadata = jpeg.metadataSnapshot
        let identity = jpeg.scannedIdentity
        let originalBytes = try Data(contentsOf: fixture.jpeg)
        let firstSplit = try FolderScanner.projectPairingMode(
            .separate, from: [pair], root: fixture.root
        )
        let enriched = try XCTUnwrap(firstSplit.items.first { $0.id == jpeg.id })
        XCTAssertEqual(firstSplit.enrichedFileCount, 1)
        XCTAssertEqual(enriched.primaryFile.metadataSnapshot, metadata)
        XCTAssertEqual(enriched.primaryFile.scannedIdentity, identity)
        XCTAssertEqual(enriched.cameraModel, "Original camera")
        XCTAssertEqual(enriched.primaryFile.lensModel, "Original lens")
        XCTAssertEqual(enriched.primaryFile.iso, 200)
        XCTAssertTrue(enriched.primaryFile.metadataIsLoaded)
        let grouped = try FolderScanner.projectPairingMode(
            .together, from: firstSplit.items, root: fixture.root
        )
        let secondSplit = try FolderScanner.projectPairingMode(
            .separate, from: grouped.items, root: fixture.root,
            metadataReaderForTesting: { _ in
                XCTFail("a second split must reuse metadata")
                return MetadataExtractor.ScanInfo()
            }
        )
        XCTAssertEqual(secondSplit.enrichedFileCount, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.jpeg), originalBytes)
    }

    func testIdentityValidationCancellationStopsRemainingProbes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pair = try scannedPair(in: fixture)
        let cancellation = FolderScanner.CancelFlag()
        var probedIDs: [String] = []
        XCTAssertThrowsError(try FolderScanner.validateScannedIdentities(
            [pair],
            isCancelled: { cancellation.isSet },
            beforeIdentityProbeForTesting: { file in
                probedIDs.append(file.id)
                cancellation.set()
            }
        )) { error in XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(probedIDs, [pair.primaryFile.id])

        probedIDs = []
        XCTAssertThrowsError(try FolderScanner.validateScannedIdentities(
            [pair],
            isCancelled: { cancellation.isSet },
            beforeIdentityProbeForTesting: { probedIDs.append($0.id) }
        )) { error in XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(probedIDs.isEmpty)
    }

    func testUncancelledIdentityValidationStillRejectsReplacement() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pair = try scannedPair(in: fixture)
        try jpegBytes(camera: "Replacement").write(to: fixture.jpeg, options: .atomic)
        XCTAssertThrowsError(try FolderScanner.validateScannedIdentities([pair])) { error in
            guard case FolderScanner.ScanError.filesChangedDuringScan = error else {
                return XCTFail("expected the existing replacement safeguard: \(error)")
            }
        }
    }

    @MainActor
    func testFailedSplitKeepsSessionFilterAndDecisionsAndOffersRescan() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pair = try scannedPair(in: fixture)
        let expectedMetadata = pair.metadataSnapshots
        let store = SessionStore()
        store.setRawJPEGPairingMode(.together)
        store.items = [pair]
        store.phase = .ready
        store.filter.excludedTypes = ["PNG"]
        store.rebuildDerivedDataForTesting(sourceFolder: fixture.root)
        let replacement = try jpegBytes(camera: "Replacement")
        try replacement.write(to: fixture.jpeg, options: .atomic)

        store.setRawJPEGPairingMode(.separate)
        for _ in 0..<200 where store.isChangingRawJPEGPairingMode {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(store.isChangingRawJPEGPairingMode)
        XCTAssertFalse(store.isSessionTransitioning)
        XCTAssertEqual(store.rawJPEGPairingMode, .together)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.items.first?.metadataSnapshots, expectedMetadata)
        XCTAssertEqual(store.filter.excludedTypes, ["PNG"])
        XCTAssertTrue(store.pairingMetadataError?.contains("Rescan Folder") == true)
        XCTAssertTrue(store.isSessionCommandPresentationActive,
                      "the new alert must protect ratings and session shortcuts")
        XCTAssertEqual(try Data(contentsOf: fixture.jpeg), replacement)
    }

    @MainActor
    func testCompletedRAWTrashRemainsTruthfulWhenSurvivingJPEGChanged() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pair = try scannedPair(in: fixture)
        let jpeg = try XCTUnwrap(pair.pairedFile)
        let oldJPEGMetadata = jpeg.metadataSnapshot
        let oldJPEGIdentity = jpeg.scannedIdentity
        let rawBytes = try Data(contentsOf: fixture.raw)
        let rawDestination = fixture.root.appendingPathComponent("disposable-trash.NEF")
        // Simulate the worker's confirmed completed result without the user's
        // Trash or journal; the original bytes remain available for assertion.
        try FileManager.default.moveItem(at: fixture.raw, to: rawDestination)
        let replacement = try jpegBytes(camera: "Survivor replacement")
        try replacement.write(to: fixture.jpeg, options: .atomic)
        var metadataError: String?
        do {
            _ = try FolderScanner.prepareStandaloneFiles([jpeg])
            XCTFail("a replacement survivor must not adopt EXIF")
        } catch { metadataError = error.localizedDescription }
        let store = SessionStore()
        store.items = [pair]
        store.phase = .ready
        store.rebuildDerivedDataForTesting(sourceFolder: fixture.root)
        let result = TrashBatchResult(
            succeeded: [TrashedPhotoSnapshot(
                index: 0, item: PhotoItem(primaryFile: pair.primaryFile),
                files: [TrashedFile(
                    original: fixture.raw, trash: rawDestination,
                    identity: pair.primaryFile.scannedIdentity
                )]
            )],
            stalePhotos: [], failedPhotos: 0, inconsistentPhotos: 0,
            journalFailure: false, requiresRecovery: false
        )
        store.finishCleanUpForTesting(
            result, mode: .pairedRAWs,
            preparedSurvivors: [PhotoItem(primaryFile: jpeg)],
            survivorMetadataError: metadataError
        )
        XCTAssertEqual(store.items.map(\.id), [jpeg.id])
        let survivor = try XCTUnwrap(store.items.first)
        XCTAssertEqual(survivor.primaryFile.metadataSnapshot, oldJPEGMetadata)
        XCTAssertEqual(survivor.primaryFile.scannedIdentity, oldJPEGIdentity)
        XCTAssertFalse(survivor.primaryFile.metadataIsLoaded)
        XCTAssertNil(survivor.cameraModel)
        XCTAssertFalse(MediaSourceRevision(survivor).matchesCurrentFile(),
                       "the old evidence record cannot display replacement pixels")
        XCTAssertEqual(store.visibleIndices, [0])
        XCTAssertTrue(store.pairingMetadataError?.contains("Rescan Folder") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.raw.path))
        XCTAssertEqual(try Data(contentsOf: rawDestination), rawBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.jpeg), replacement)
        XCTAssertTrue(store.canUndo)
    }

    @MainActor
    func testCancelDuringPersistenceReadCannotReenterReadyOrSave() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let persistence = PausedScanReadPersistence()
        let store = SessionStore(persistence: persistence)
        store.openFolder(fixture.root)
        for _ in 0..<200 {
            if await persistence.snapshot().started { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let didStartRead = await persistence.snapshot().started
        XCTAssertTrue(didStartRead)
        store.cancelScan()
        for _ in 0..<200 {
            if case .welcome = store.phase { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .welcome = store.phase else {
            await persistence.releaseRead()
            return XCTFail("Cancel must return to Welcome while persistence is paused")
        }
        await persistence.releaseRead()
        for _ in 0..<200 {
            if await persistence.snapshot().finished { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // Let the resumed detached caller cross its completion boundary.
        try await Task.sleep(nanoseconds: 25_000_000)
        let state = await persistence.snapshot()
        XCTAssertTrue(state.finished)
        XCTAssertTrue(state.cancelled)
        XCTAssertEqual(state.saves, 0)
        guard case .welcome = store.phase else {
            return XCTFail("a cancelled scan must never re-enter the session")
        }
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.scanError)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.appendingPathComponent(SessionStore.sidecarName).path
        ))
    }

    private struct Fixture {
        let root: URL
        var raw: URL { root.appendingPathComponent("SHOT.NEF") }
        var jpeg: URL { root.appendingPathComponent("SHOT.JPG") }
    }

    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("Louppe-Scan-Integrity-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = Fixture(root: root)
        try Data("Original RAW".utf8).write(to: fixture.raw)
        try jpegBytes(camera: "Original camera").write(to: fixture.jpeg)
        return fixture
    }

    private func scannedPair(in fixture: Fixture) throws -> PhotoItem {
        let pair = try XCTUnwrap(FolderScanner.scan(
            fixture.root, pairingMode: .together
        ) { _ in }.first)
        XCTAssertNotNil(pair.pairedFile)
        pair.primaryFile.rating = .yes
        let jpeg = try XCTUnwrap(pair.pairedFile)
        jpeg.rating = .no
        jpeg.ratedAt = Date(timeIntervalSince1970: 1_700_000_000)
        jpeg.setStars(.four, changedAt: Date(timeIntervalSince1970: 1_700_000_001))
        jpeg.setColor(.purple, changedAt: Date(timeIntervalSince1970: 1_700_000_002))
        return pair
    }

    private func jpegBytes(camera: String) throws -> Data {
        let data = NSMutableData()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.3, green: 0.2, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: camera],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "Original lens",
                kCGImagePropertyExifFNumber: 4.0,
                kCGImagePropertyExifExposureTime: 0.01,
                kCGImagePropertyExifISOSpeedRatings: [200],
            ],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private actor PausedScanReadPersistence: SessionPersistenceClient {
    private var readStarted = false
    private var readFinished = false
    private var wasCancelled = false
    private var saveCalls = 0
    private var readContinuation: CheckedContinuation<Void, Never>?

    func read(
        for folder: URL,
        folderIdentity: SessionPersistence.SourceFolderIdentity,
        legacySidecarRelocationAuthorization:
            SessionPersistence.LegacySidecarRelocationAuthorization?
    ) async -> SessionPersistence.ReadResult {
        readStarted = true
        await withCheckedContinuation { readContinuation = $0 }
        readFinished = true
        wasCancelled = Task.isCancelled
        return SessionPersistence.ReadResult(
            session: nil, origin: nil, problems: [],
            access: SessionPersistence.AccessContext(
                id: UUID(), folderIdentity: folderIdentity, sidecarRevision: .absent
            )
        )
    }

    func save(
        _ session: SessionFile,
        for folder: URL,
        sequence: UInt64,
        access: SessionPersistence.AccessContext
    ) async -> SessionPersistence.SaveResult {
        saveCalls += 1
        return .savedToSidecar
    }

    func releaseRead() {
        readContinuation?.resume()
        readContinuation = nil
    }

    func snapshot() -> (started: Bool, finished: Bool, cancelled: Bool, saves: Int) {
        (readStarted, readFinished, wasCancelled, saveCalls)
    }
}
