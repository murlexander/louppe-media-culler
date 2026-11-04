import Foundation
import XCTest
@testable import Louppe

@MainActor
final class DuplicateBurstWorkerTests: XCTestCase {
    func testMetadataOnlyCaptureInputPreservesCandidatesAndAllAnalysisPayload() throws {
        let date = Date(timeIntervalSince1970: 1_000)
        let items = [
            PhotoItem(primaryFile: file("A.RAF", date: date),
                      pairedFile: file("A.JPG", date: date)),
            PhotoItem(primaryFile: file("B.JPG", date: date.addingTimeInterval(0.5))),
            PhotoItem(primaryFile: file("C.unsupported", date: date.addingTimeInterval(1))),
            PhotoItem(primaryFile: file("D.JPG", date: nil)),
            PhotoItem(primaryFile: file("E.MOV", date: date, kind: .video)),
        ]
        let full = DuplicateBurstAnalysis.inputs(from: items, mode: .all)
        let metadata = DuplicateBurstAnalysis.inputs(from: items, mode: .captureBursts)
        XCTAssertEqual(metadata.map(\.id), items.map(\.id))
        XCTAssertTrue(metadata.allSatisfy { $0.exactFiles.isEmpty && $0.visualFiles.isEmpty })
        XCTAssertEqual(full[0].exactFiles.map(\.url), items[0].individualFiles.map(\.url))
        XCTAssertEqual(full[0].visualFiles.map(\.url), items[0].individualFiles.map(\.url))
        XCTAssertEqual(full[0].exactFiles.map(\.expectedIdentity),
                       items[0].individualFiles.map(\.scannedIdentity))
        XCTAssertEqual(full[0].exactFiles.map(\.reviewItemID), ["A.RAF", "A.RAF"])
        XCTAssertTrue(full[2].visualFiles.isEmpty)
        XCTAssertTrue(full[4].visualFiles.isEmpty)
        let forbiddenAccess = DuplicateBurstAnalysis.FileAccess(
            exactDigest: { _ in XCTFail("Capture input must not hash files"); return nil },
            visualHash: { _ in XCTFail("Capture input must not decode previews"); return nil }
        )
        let expected = try DuplicateBurstAnalysis.analyze(full, mode: .captureBursts,
                                                         fileAccess: forbiddenAccess)
        let actual = try DuplicateBurstAnalysis.analyze(metadata, mode: .captureBursts,
                                                       fileAccess: forbiddenAccess)
        XCTAssertEqual(actual.burstCandidates, expected.burstCandidates)
        XCTAssertEqual(actual.burstCandidates.map(\.itemID), ["A.RAF", "B.JPG", "C.unsupported"])
        XCTAssertEqual(actual.groups(for: .captureBursts, visualDistance: 8, burstInterval: 2),
                       expected.groups(for: .captureBursts, visualDistance: 8, burstInterval: 2))
        XCTAssertEqual(actual.analyzedExactFileCount, 0)
        XCTAssertEqual(actual.analyzedVisualPhotoCount, 0)
        XCTAssertFalse(actual.supports(.exactDuplicates))
        XCTAssertFalse(actual.supports(.likelySimilarPhotos))
    }

    func testCancellableMembershipMatchesCompletedGroupsForEveryModeAndSensitivity() throws {
        let result = fixture(count: 128)
        for mode in DuplicateBurstAnalysis.ReviewMode.allCases {
            for distance in [0, 3, 8, 16, 64] {
                for interval in [0.5, 2, 10] {
                    XCTAssertEqual(
                        try result.groupsCancellable(for: mode, visualDistance: distance,
                                                     burstInterval: interval),
                        result.groups(for: mode, visualDistance: distance, burstInterval: interval)
                    )
                }
            }
        }
    }

    func testMembershipCancellationInterruptsEachModeBeforePublishingPartialGroups() throws {
        let result = fixture(count: 4_000)
        enum Stop: Error { case requested }
        for mode in [DuplicateBurstAnalysis.ReviewMode.exactDuplicates, .likelySimilarPhotos, .captureBursts] {
            var checkpoints = 0
            XCTAssertThrowsError(try result.groups(for: mode, visualDistance: 8, burstInterval: 2,
                                                   checkingCancellation: {
                checkpoints += 1
                if checkpoints == 40 { throw Stop.requested }
            })) { error in
                guard case Stop.requested = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(checkpoints, 40, "Cancellation must interrupt \(mode), not finish its result.")
        }
    }

    func testCancellableMembershipRejectsAnAlreadyCancelledDetachedTask() async throws {
        let result = fixture(count: 128)
        let cancelled = await Task.detached(priority: .utility) {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try result.groupsCancellable(for: .likelySimilarPhotos,
                                                 visualDistance: 8, burstInterval: 2)
                return false
            } catch DuplicateBurstAnalysis.AnalysisError.cancelled {
                return true
            } catch {
                return false
            }
        }.value
        XCTAssertTrue(cancelled)
    }

    private func fixture(count: Int) -> DuplicateBurstAnalysis.Result {
        let ids = (0..<count).map { String(format: "%06d", $0) }
        return .init(
            exactDuplicateItemSets: stride(from: 0, to: count, by: 2).map { [ids[$0 + 1], ids[$0], ids[$0]] },
            visualFingerprints: ids.enumerated().reversed().map {
                .init(itemID: $0.element, hash: UInt64($0.offset / 2))
            },
            burstCandidates: ids.enumerated().reversed().map {
                .init(itemID: $0.element,
                      captureDate: Date(timeIntervalSince1970: Double($0.offset / 2) * 4))
            },
            analyzedExactFileCount: count, analyzedVisualPhotoCount: count
        )
    }

    private func file(_ id: String, date: Date?, kind: MediaKind = .photo) -> PhotoFile {
        PhotoFile(id: id, url: URL(fileURLWithPath: "/private/tmp/LouppeWorkerFixture/\(id)"),
                  captureDate: date,
                  captureDateEvidence: date.map { .init(date: $0, source: .exifOriginal) },
                  cameraModel: nil, lensModel: nil, mediaKind: kind, fileSize: 64)
    }
}
