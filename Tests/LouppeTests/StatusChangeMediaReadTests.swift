import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Open With hands an original to another app, and Launch Services then writes
/// `com.apple.lastuseddate#PS` / `com.apple.macl` (and users may change
/// permissions). That moves only the inode change time. Louppe must keep
/// showing the photo; a real content change must still be detected.
@MainActor
final class StatusChangeMediaReadTests: XCTestCase {
    func testAttributeOnlyChangesKeepEveryMediaReadAndContentChangesStillFail() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 12)
        store.items = try store.items.map { item in
            PhotoItem(primaryFile: PhotoFile(id: item.id, url: item.primaryURL, captureDate: nil,
                cameraModel: nil, lensModel: nil, fileSize: item.fileSize,
                scannedIdentity: try FileOperationJournal.captureIdentity(at: item.primaryURL)))
        }
        store.rebuildDerivedDataForTesting()
        store.viewMode = .gallery
        store.setIndex(0)
        let (host, window) = mount(GalleryView(store: store), size: CGSize(width: 900, height: 600))
        defer { store.beginTerminationPreparation(); window.contentView = nil; window.close() }
        // A photo already on screen, and its thumbnail.
        _ = try await fittedSurface(in: host)
        let initialThumbnail = await ImagePipeline.shared.thumbnail(for: store.items[0])
        XCTAssertNotNil(initialThumbnail)
        await ImagePipeline.shared.waitForPendingDiskWrites()

        // Opened in another app: attributes and permissions only.
        // Item 6 is outside Gallery's four-photo prefetch, so nothing of it is cached.
        for index in [0, 6] { try touchMetadataLikeLaunchServices(store.items[index].primaryURL) }
        let touched = store.items[6] // Never loaded before the change.
        let shown = store.items[0]   // Loaded before the change.

        // Thumbnails: a cold tile and a memory-evicted one.
        ImagePipeline.shared.evictThumbnailForTesting(for: shown)
        let shownThumbnail = await ImagePipeline.shared.thumbnail(for: shown)
        let coldThumbnail = await ImagePipeline.shared.thumbnail(for: touched)
        // Gallery Fit, 100% and Info for the touched photo.
        let fit = await ImagePipeline.shared.fullImage(for: touched)
        let pixels = await HighResolutionImagePipeline.shared.pixelSize(for: touched, decoder: .appleDefault, sourceAccess: nil)
        let info = MetadataExtractor.fields(for: touched)
        let changed = info.contains { $0.label == "File changed" }
        print("STATUS-CHANGE reads: shownThumbnail=\(shownThumbnail != nil) coldThumbnail=\(coldThumbnail != nil) fit=\(fit != nil) pixels=\(String(describing: pixels)) infoChanged=\(changed)")
        XCTAssertNotNil(shownThumbnail, "A photo shown before keeps its thumbnail")
        XCTAssertNotNil(coldThumbnail, "A tile first loaded after the change still shows")
        XCTAssertNotNil(fit, "Gallery Fit still decodes")
        XCTAssertNotNil(pixels, "100% still prepares its source")
        XCTAssertFalse(changed, "Info shows EXIF, not File changed")

        // Mounted Gallery: navigate to the touched photo.
        store.setIndex(6)
        let mounted = try? await fittedSurface(in: host, timeout: .seconds(4))
        print("STATUS-CHANGE gallery mounted=\(mounted != nil)")
        XCTAssertNotNil(mounted, "Gallery shows the photo, not Can't preview")

        // A real content change (same inode, new bytes) is still refused.
        let rewritten = store.items[11] // Outside both prefetch neighbourhoods.
        let handle = try FileHandle(forWritingTo: rewritten.primaryURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0, count: 64))
        try handle.close()
        let rewrittenFit = await ImagePipeline.shared.fullImage(for: rewritten)
        let rewrittenThumbnail = await ImagePipeline.shared.thumbnail(for: rewritten)
        XCTAssertNil(rewrittenFit, "Changed content is not decoded as the reviewed revision")
        XCTAssertNil(rewrittenThumbnail)
        XCTAssertTrue(MetadataExtractor.fields(for: rewritten).contains { $0.label == "File changed" })
        XCTAssertFalse(MediaSourceRevision(rewritten).matchesCurrentFile())
        XCTAssertTrue(MediaSourceRevision(touched).matchesCurrentFile())
        // Cache identity is untouched by the attribute change.
        XCTAssertEqual(store.items[6].contentRevision, touched.contentRevision)
    }

    func testTextPreviewIgnoresAttributeOnlyChangesButNotEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StatusChangeText-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Notes.md")
        try Data("# Shoot notes\nKeep the blue hour frames.".utf8).write(to: url)
        let item = PhotoItem(primaryFile: PhotoFile(id: "Notes.md", url: url, captureDate: nil, cameraModel: nil,
            lensModel: nil, mediaKind: .text, fileSize: 40,
            scannedIdentity: try FileOperationJournal.captureIdentity(at: url)))
        try touchMetadataLikeLaunchServices(url)
        let text = try await TextPreviewLoader.shared.load(item: item)
        XCTAssertTrue(String(text.characters).contains("blue hour"), "Opened elsewhere: still previews")

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" Edited.".utf8))
        try handle.close()
        do {
            _ = try await TextPreviewLoader.shared.load(item: item)
            XCTFail("An edited document is not shown as the scanned revision")
        } catch {}
    }

    private func mount<V: View>(_ view: V, size: CGSize) -> (NSHostingView<AnyView>, NSWindow) {
        let host = NSHostingView(rootView: AnyView(view))
        return (host, SelectionInteractionFixture.mount(host, size: size))
    }

    private func fittedSurface(in host: NSView, timeout: Duration = .seconds(10)) async throws -> NSView {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let view = SelectionInteractionFixture.descendants(host).first(where: {
                $0 is FittedImageDoubleClickView && $0.window != nil && $0.bounds.width > 50
            }) { return view }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }
}
