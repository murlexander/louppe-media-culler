import AVKit
import XCTest
@testable import Louppe

@MainActor
final class MediaTrackOptionsTests: XCTestCase {
    func testAbsentGroupsRemainASuccessfulEmptyResult() async throws {
        let asset = AVMutableComposition()
        var characteristics: [AVMediaCharacteristic] = []
        let result = try await MediaTrackOptionsResult.load(from: asset) { _, characteristic in
            characteristics.append(characteristic)
            return nil
        }
        guard case .loaded(let subtitles, let audio) = result else {
            return XCTFail("No groups must not become a load failure")
        }
        XCTAssertNil(subtitles)
        XCTAssertNil(audio)
        XCTAssertEqual(characteristics, [.legible, .audible])
    }

    func testEitherGroupFailureProducesRetryableFailure() async throws {
        for failingCharacteristic in [AVMediaCharacteristic.legible, .audible] {
            let result = try await MediaTrackOptionsResult.load(from: AVMutableComposition()) { _, characteristic in
                if characteristic == failingCharacteristic { throw CocoaError(.fileReadUnknown) }
                return nil
            }
            guard case .failed = result else { return XCTFail("Read errors must remain visible") }
            let retry = try await MediaTrackOptionsResult.load(from: AVMutableComposition()) { _, _ in nil }
            guard case .loaded = retry else { return XCTFail("A retry must be able to recover") }
        }
    }

    func testCancellationBetweenGroupsStopsWithoutFailureState() async {
        let task = Task { @MainActor in
            var characteristics: [AVMediaCharacteristic] = []
            do {
                _ = try await MediaTrackOptionsResult.load(from: AVMutableComposition()) { _, characteristic in
                    characteristics.append(characteristic)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return nil
                }
                XCTFail("Cancelled load returned a result")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            return characteristics
        }
        let characteristics = await task.value
        XCTAssertEqual(characteristics, [.legible])
    }

    func testLoaderCancellationDoesNotBecomeRetryableFailure() async {
        do {
            _ = try await MediaTrackOptionsResult.load(from: AVMutableComposition()) { _, _ in
                throw CancellationError()
            }
            XCTFail("Cancellation returned a result")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}
