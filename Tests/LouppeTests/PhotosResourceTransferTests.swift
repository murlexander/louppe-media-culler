import Foundation
import XCTest
@testable import Louppe

final class PhotosResourceTransferTests: XCTestCase, @unchecked Sendable {
    func testChunksStreamInOrderAndNeverOverwriteAnExistingFile() async throws {
        let url = temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try PhotosResourceTransfer(destination: url, maximumBytes: 16)
        let bytes = try await writer.read { receive, complete in
            receive(Data("first".utf8)); receive(Data("second".utf8)); complete(nil)
            return 77
        }
        XCTAssertEqual(bytes, 11)
        XCTAssertEqual(try Data(contentsOf: url), Data("firstsecond".utf8))
        XCTAssertThrowsError(try PhotosResourceTransfer(destination: url, maximumBytes: 16))
        XCTAssertEqual(try Data(contentsOf: url), Data("firstsecond".utf8))
    }

    func testByteBudgetStopsBeforeWritingAnOversizedChunk() async throws {
        let url = temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = CancellationProbe()
        let writer = try PhotosResourceTransfer(destination: url, maximumBytes: 5, cancelRequest: probe.cancel)
        do {
            _ = try await writer.read { receive, complete in
                receive(Data("1234".utf8)); receive(Data("56".utf8)); receive(Data("late".utf8)); complete(nil)
                return 77
            }
            XCTFail("The byte ceiling must fail the batch")
        } catch PhotosLibraryError.batchTooLarge {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: url), Data("1234".utf8))
        XCTAssertEqual(probe.ids, [77])
    }

    func testCancelRacingRequestIDAssignmentRetiresTheActualPhotoKitRequest() async throws {
        let url = temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = CancellationProbe()
        let writer = try PhotosResourceTransfer(destination: url, maximumBytes: 16, cancelRequest: probe.cancel)
        let task = Task {
            try await writer.read { receive, complete in
                receive(Data("first".utf8))
                withUnsafeCurrentTask { $0?.cancel() }
                receive(Data("late".utf8)); complete(nil)
                return 88
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(probe.ids, [88])
        XCTAssertEqual(try Data(contentsOf: url), Data("first".utf8))
    }

    func testFrameworkFailureDoesNotBecomeSuccessAfterASecondCompletion() async throws {
        let url = temporary()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try PhotosResourceTransfer(destination: url, maximumBytes: 16)
        do {
            _ = try await writer.read { receive, complete in
                receive(Data("partial".utf8)); complete(CocoaError(.fileReadNoSuchFile)); complete(nil)
                return 77
            }
            XCTFail("A partial read must not be accepted")
        } catch { XCTAssertEqual((error as NSError).code, NSFileReadNoSuchFileError) }
    }
    private func temporary() -> URL {
        URL(fileURLWithPath: "/private/tmp/LouppePhotosTransfer-\(UUID().uuidString)")
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int32] = []
    var ids: [Int32] { lock.withLock { values } }
    func cancel(_ id: Int32) { lock.withLock { values.append(id) } }
}
