import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class PaneHeaderLayoutTests: XCTestCase {
    func testSessionPaneHeaderDividersAlignInBothDirections() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneHeaders-\(UUID())")
        let child = root.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Packaging/AppIcon/AppIcon.iconset/icon_128x128.png")
        let url = child.appendingPathComponent("Photo.png")
        try FileManager.default.copyItem(at: fixture, to: url)
        let suite = "PaneHeaderLayoutTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(reviewDefaults: defaults)
        store.items = [PhotoItem(id: "Child/Photo.png", primaryURL: url, pairedURL: nil,
                                captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)]
        store.archiveFolderIndex = ArchiveFolderIndex(root: root,
            directories: [.init(id: "Child", parentID: "", name: "Child")], items: store.items)
        store.archiveLeadingPane = .browser
        store.showBrowser = true
        store.showMetadataPanel = true
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.archiveSelectedFolderID = "Child"
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let host = NSHostingView(rootView: SessionView(store: store)
                .defaultAppStorage(defaults)
                .environment(\.layoutDirection, direction)
                .preferredColorScheme(.light))
            let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1100, height: 720),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            let views = descendants(host)
            let browser = try XCTUnwrap(views.compactMap { $0 as? ReviewCollectionDocument }.first?.enclosingScrollView)
            let gallery = try XCTUnwrap(views.compactMap { $0 as? SessionRenderMarker.MarkerView }.first { $0.kind == .gallery })
            let browserFrame = browser.convert(browser.bounds, to: host)
            let galleryFrame = gallery.convert(gallery.bounds, to: host)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Measure painted separators across each real pane rather than a
            // shared constant. Info has no header row (its filename and
            // decision lead the panel), so only header-bearing panes compare.
            let browserDivider = try firstDivider(in: bitmap, host: host, pane: browserFrame)
            let galleryDivider = try firstDivider(in: bitmap, host: host, pane: galleryFrame)
            XCTAssertEqual(browserDivider, galleryDivider, accuracy: 1,
                           "Browser and Gallery header dividers must align (\(direction))")
            XCTAssertFalse(window.isKeyWindow)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func firstDivider(in bitmap: NSBitmapImageRep, host: NSView, pane: CGRect) throws -> CGFloat {
        let scaleX = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / host.bounds.height
        let left = Int((pane.minX + 16) * scaleX)
        let right = Int((pane.maxX - 16) * scaleX)
        // Both navigation headers are above 240pt. A separator is thin,
        // uniform, and darker than pixels on BOTH sides; text, photos and
        // native control fills cannot satisfy the whole span.
        for y in Int(5 * scaleY)..<Int(240 * scaleY) {
            var values: [CGFloat] = []
            var contrasts: [CGFloat] = []
            for x in stride(from: left, through: right, by: 2) {
                func luminance(_ row: Int) throws -> CGFloat {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB))
                    return (color.redComponent + color.greenComponent + color.blueComponent) / 3
                }
                let value = try luminance(y)
                values.append(value)
                contrasts.append(min(try luminance(y - 4), try luminance(y + 4)) - value)
            }
            if let minValue = values.min(), let maxValue = values.max(),
               maxValue - minValue < 0.02, (contrasts.min() ?? 0) > 0.04 {
                return CGFloat(y) / scaleY
            }
        }
        XCTFail("No painted header divider found in real pane \(pane)")
        throw NSError(domain: "PaneHeaderLayoutTests", code: 1)
    }
}
