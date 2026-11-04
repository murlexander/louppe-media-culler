import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

@MainActor
final class StagedViewportHandoffTests: XCTestCase {
    func testMountedOpeningHandsOffManualAnchorSeparatelyFromCurrentAfterFinalReorder() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/private/tmp/louppe-anchor-\(UUID())", isDirectory: true)
        let folder = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try jpeg()
        for index in 0..<300 {
            try bytes.write(to: folder.appendingPathComponent(String(format: "FRAME_%04d.JPG", index)))
        }
        let defaultsName = "LouppeAnchor.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(ViewMode.grid.rawValue, forKey: ReviewPreferences.Keys.defaultView)
        defaults.set(false, forKey: CameraQualityWarningPreferences.Keys.isEnabled)
        defaults.set(true, forKey: EarlyUserFeedback.shownKey)
        let store = SessionStore(persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
                                 reviewDefaults: defaults)
        let gate = AnchorMetadataGate()
        defer { gate.release.signal() }
        store.openingWorkerHooksForTesting = .init(metadataReader: { url in
            gate.waitOnce()
            let index = Int(url.deletingPathExtension().lastPathComponent.suffix(4)) ?? 0
            return MetadataExtractor.ScanInfo(captureDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(300 - index)))
        })
        let host = NSHostingView(rootView: RootView(store: store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close(); store.beginTerminationPreparation() }
        store.openFolder(folder)
        try await wait(host) { store.openingSession != nil && self.document(host) != nil }
        let opening = try XCTUnwrap(store.openingSession)
        var early = try XCTUnwrap(document(host))
        let current = opening.items[250]
        opening.select(opening.items[200].id)
        opening.select(current.id, toggling: true)
        let selected = opening.selectedIDs
        // Leave a different, dormant Browser receipt before settling Grid.
        opening.viewMode = .gallery
        try await wait(host) { self.document(host) !== early }
        let browser = try XCTUnwrap(document(host))
        let browserScroll = try XCTUnwrap(browser.enclosingScrollView)
        browserScroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: 1200))
        let browserReceipt = try XCTUnwrap(browser.snapshotViewport())
        opening.recordViewport(.init(surface: .browser, physicalFileID: browserReceipt.physicalFileID,
                                     topOffset: Double(browserReceipt.topOffset)))
        opening.viewMode = .grid
        try await wait(host) { self.document(host) !== browser }
        early = try XCTUnwrap(document(host))
        let scroll = try XCTUnwrap(early.enclosingScrollView)
        scroll.contentView.setBoundsOrigin(CGPoint(x: 0,
            y: max(0, (early.frame.height - scroll.contentView.bounds.height) / 2 + 17)))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        let receipt = try XCTUnwrap(early.snapshotViewport())
        XCTAssertNotEqual(receipt.physicalFileID, current.primaryFile.id)
        opening.recordViewport(.init(surface: .grid, physicalFileID: receipt.physicalFileID, topOffset: Double(receipt.topOffset)))
        gate.release.signal()
        try await wait(host) {
            if case .ready = store.phase {
                return self.document(host) !== early && store.pendingOpeningViewportReceipt(for: .grid) == nil
            }
            return false
        }
        let ready = try XCTUnwrap(document(host))
        XCTAssertEqual(store.currentItem?.id, current.id)
        XCTAssertEqual(Set(store.selectedIndices.map { store.items[$0].id }), selected)
        XCTAssertEqual(store.items.first?.id, "FRAME_0299.JPG", "Final metadata must actually reorder the inventory")
        let anchored = try XCTUnwrap(store.items.first { $0.primaryFile.id == receipt.physicalFileID })
        try await wait(host) {
            self.markers(ready).contains { $0.revision == anchored.contentRevision && !$0.visibleRect.isEmpty }
        }
        let marker = try XCTUnwrap(markers(ready).first { $0.revision == anchored.contentRevision && !$0.visibleRect.isEmpty })
        let readyClip = try XCTUnwrap(ready.enclosingScrollView?.contentView)
        XCTAssertEqual(marker.convert(marker.bounds, to: ready).minY - readyClip.bounds.minY,
                       receipt.topOffset, accuracy: 1, "The browsed anchor must survive separately from current-photo following")
        XCTAssertEqual(readyClip.bounds.minX, 0, accuracy: 0.5)
        store.setIndex(0)
        try await wait(host) {
            self.markers(ready).contains { $0.revision == store.items[0].contentRevision && !$0.visibleRect.isEmpty }
        }
        XCTAssertNil(store.pendingOpeningViewportReceipt(for: .grid), "Later navigation must not reapply the opening anchor")
        XCTAssertNil(store.pendingOpeningViewportReceipt(for: .browser), "Ready navigation expires dormant handoff anchors too")
        store.viewMode = .gallery
        try await wait(host) {
            self.document(host) !== ready && self.markers(host).contains {
                $0.revision == store.items[0].contentRevision && !$0.visibleRect.isEmpty
            }
        }
    }

    private func document(_ view: NSView) -> ReviewCollectionDocument? {
        if let document = view as? ReviewCollectionDocument { return document }
        return view.subviews.compactMap(document).first
    }

    private func markers(_ view: NSView) -> [ThumbnailRenderMarker.MarkerView] {
        if let marker = view as? ThumbnailRenderMarker.MarkerView { return [marker] }
        return view.subviews.flatMap(markers)
    }

    private func wait(_ host: NSView, until predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Mounted opening handoff did not settle")
        throw CocoaError(.coderInvalidValue)
    }

    private func jpeg() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 192, bitsPerComponent: 8,
            bytesPerRow: 1024, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.45, green: 0.2, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 192))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

private final class AnchorMetadataGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    let release = DispatchSemaphore(value: 0)
    func waitOnce() {
        lock.lock()
        let waits = !entered
        entered = true
        lock.unlock()
        if waits { _ = release.wait(timeout: .now() + 15) }
    }
}
