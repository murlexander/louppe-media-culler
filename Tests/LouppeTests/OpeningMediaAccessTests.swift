#if DEBUG
import AppKit
import XCTest
@testable import Louppe

@MainActor
final class OpeningMediaAccessTests: XCTestCase {
    func testCancelledWaiterDoesNotReleaseExecutingDecodeScope() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/Louppe-Read-Access-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("disposable photo".utf8).write(to: root.appendingPathComponent("A.JPG"))
        let photo = try XCTUnwrap(FolderScanner.discoverInventory(root).items.first)
        let probe = OpeningScopeProbe()
        let originalAuthorityURL = root.appendingPathComponent("child/../", isDirectory: true)
        let folderLease = SecurityScopedFolderAccess(url: originalAuthorityURL, resourceAccess: probe.access)
        let authority = folderLease.makeReadAuthority()
        let entered = expectation(description: "native decoder entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let pipeline = ImagePipeline(testingDiskCacheRoot: root.appendingPathComponent("cache"), fullConcurrency: 1,
                                     decoder: { _, _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 10)
            return CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let request = Task { await pipeline.fullImage(for: photo, sourceAccess: authority) }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(probe.active, 2)
        folderLease.stop()
        XCTAssertEqual(probe.active, 1)
        request.cancel()
        let cancelledResult = await request.value
        XCTAssertNil(cancelledResult)
        XCTAssertEqual(probe.active, 1, "the cancelled waiter has returned, but native I/O still owns its scope")
        XCTAssertTrue(probe.startedURLs.allSatisfy { $0 == originalAuthorityURL.absoluteString })
        release.signal()
        await pipeline.waitForFullWorkForTesting()
        XCTAssertEqual(probe.active, 0)
        XCTAssertNil(pipeline.cachedFullImage(for: photo))
    }

    func testMemoryCacheHitDoesNotStartAnotherScope() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/Louppe-Cached-Access-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("disposable photo".utf8).write(to: root.appendingPathComponent("A.JPG"))
        let photo = try XCTUnwrap(FolderScanner.discoverInventory(root).items.first)
        let probe = OpeningScopeProbe()
        let authority = MediaReadAccess(authorizedURL: root, resourceAccess: probe.access)
        let pipeline = ImagePipeline(testingDiskCacheRoot: root.appendingPathComponent("cache"), decoder: { _, _ in
            CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        })
        let first = await pipeline.fullImage(for: photo, sourceAccess: authority)
        XCTAssertNotNil(first)
        await pipeline.waitForFullWorkForTesting()
        XCTAssertEqual(probe.active, 0)
        let starts = probe.startedURLs.count
        let second = await pipeline.fullImage(for: photo, sourceAccess: authority)
        XCTAssertNotNil(second)
        XCTAssertEqual(probe.startedURLs.count, starts)
    }
}

private final class OpeningScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var urls: [String] = []
    var active: Int { lock.lock(); defer { lock.unlock() }; return activeCount }
    var startedURLs: [String] { lock.lock(); defer { lock.unlock() }; return urls }
    var access: SecurityScopedResourceAccess {
        .init(start: { url in
            self.lock.lock()
            self.activeCount += 1
            self.urls.append(url.absoluteString)
            self.lock.unlock()
            return true
        }, stop: { _ in
            self.lock.lock()
            self.activeCount -= 1
            self.lock.unlock()
        })
    }
}
#endif
