import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Rendered Browser and Grid tiles in offscreen, never-key windows: Browser
/// badges must not cover each other, the duration or the quality-cue row on
/// narrow portraits in either direction, and Grid keeps its one-row badges.
@MainActor
final class BrowserTileBadgeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserTileBadges-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func portraitVideo(duration: TimeInterval = 8) -> PhotoItem {
        PhotoItem(id: "PORTRAIT.mov", primaryURL: root.appendingPathComponent("PORTRAIT.mov"), pairedURL: nil,
                  captureDate: nil, cameraModel: nil, lensModel: nil, mediaKind: .video, duration: duration,
                  videoDimensions: CGSize(width: 360, height: 640), videoIsPlayable: true, fileSize: 1,
                  rating: .yes, starRating: .five, colorLabel: .red)
    }

    private func portraitPhoto() throws -> PhotoItem {
        let url = root.appendingPathComponent("PORTRAIT.png")
        let image = NSImage(size: CGSize(width: 400, height: 600), flipped: false) { rect in
            NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
            rect.fill()
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return PhotoItem(id: "PORTRAIT.png", primaryURL: url, pairedURL: nil, captureDate: nil,
                         cameraModel: nil, lensModel: nil, fileSize: 1, rating: .no,
                         starRating: .three, colorLabel: .green)
    }

    private func mount(_ view: some View, size: CGSize, direction: LayoutDirection) -> (NSHostingView<AnyView>, NSWindow) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)
            .environment(\.layoutDirection, direction).preferredColorScheme(.light)))
        host.frame = CGRect(origin: .zero, size: size)
        return (host, SelectionInteractionFixture.mount(host, size: size))
    }

    /// Top-left-origin frame of `view` in `host`.
    private func frame(of view: NSView, in host: NSView) -> CGRect {
        var rect = view.convert(view.bounds, to: host)
        if !host.isFlipped { rect.origin.y = host.bounds.height - rect.maxY }
        return rect
    }

    private func waitForThumbnail(_ host: NSView) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            try await SelectionInteractionFixture.settle(host)
            if SelectionInteractionFixture.descendants(host).contains(where: {
                ($0 as? ThumbnailRenderMarker.MarkerView)?.hasImage == true
            }) { return }
        }
        XCTFail("thumbnail did not load")
    }

    func testNarrowPortraitBadgesNeverOverlapInBothDirections() async throws {
        let slot = CGRect(x: 0, y: 0, width: ReviewCollectionMetrics.browserTileWidth,
                          height: ReviewCollectionMetrics.browserTileHeight)
        let photo = try portraitPhoto()
        // Four quality cues, as QualityCueTileIcons draws them in Browser.
        let cues = AnyView(QualityCueIconRow(symbols: CameraQualityWarning.Kind.allCases.prefix(4).map(\.symbol), wraps: true))
        let cases: [(PhotoItem, CGSize, AnyView?, Set<BrowserBadgeRole>)] = [
            (portraitVideo(), CGSize(width: 9, height: 16), nil, [.decision, .stars, .label, .duration]),
            (portraitVideo(duration: 3_600), CGSize(width: 9, height: 16), nil, [.decision, .stars, .label, .duration]),
            (photo, CGSize(width: 2, height: 3), cues, [.decision, .stars, .label, .cues]),
        ]
        for (item, shape, cueView, roles) in cases {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let (host, window) = mount(
                    ThumbnailView(item: item, isCurrent: true, badgePlacement: .browser(reservesCueRow: cueView != nil),
                                  browserCues: cueView),
                    size: slot.size, direction: direction)
                defer { window.contentView = nil; window.close() }
                if item.mediaKind == .photo { try await waitForThumbnail(host) } else {
                    try await SelectionInteractionFixture.settle(host)
                }
                let context = "\(item.id) \(item.duration ?? 0) \(direction)"
                let markers = SelectionInteractionFixture.descendants(host).compactMap { $0 as? BrowserBadgeMarker.MarkerView }
                XCTAssertEqual(Set(markers.map(\.role)), roles, context)
                let badges = markers.map { ($0.role, frame(of: $0, in: host)) }
                let media = TileMediaGeometry.fittedRect(in: slot, imageSize: shape)
                // The cue marker spans the whole button: icons and 36-point target.
                let occupied = badges.map(\.1)
                if let cueTarget = badges.first(where: { $0.0 == .cues })?.1 {
                    XCTAssertGreaterThanOrEqual(cueTarget.height, TileBadgeLayout.cueTargetHeight, context)
                    XCTAssertTrue(slot.insetBy(dx: -0.5, dy: -0.5).contains(cueTarget), "cues \(cueTarget) outside slot: \(context)")
                }
                let overhang = ReviewCollectionMetrics.browserHorizontalInset - 4
                for (index, rect) in occupied.enumerated() {
                    XCTAssertGreaterThan(rect.width, 0, context)
                    XCTAssertTrue(slot.insetBy(dx: -overhang - 0.5, dy: -0.5).contains(rect), "\(rect) outside column: \(context)")
                    for other in occupied[(index + 1)...] {
                        XCTAssertFalse(rect.insetBy(dx: 0.5, dy: 0.5).intersects(other), "\(rect) × \(other): \(context)")
                    }
                }
                let covered = badges.filter { $0.0 != .cues }.reduce(CGFloat(0)) {
                    let part = $1.1.intersection(media)
                    return $0 + (part.isNull ? 0 : part.width * part.height)
                }
                XCTAssertLessThan(covered, media.width * media.height / 2, "media mostly visible: \(context)")
                // Stars and label sit in the spare width beside the media.
                for (role, rect) in badges where role == .stars || role == .label {
                    XCTAssertTrue(rect.maxX <= media.minX + 0.5 || rect.minX >= media.maxX - 0.5, "\(role): \(context)")
                }
                let decision = try XCTUnwrap(badges.first { $0.0 == .decision }?.1, context)
                XCTAssertEqual(direction == .leftToRight ? decision.maxX : media.maxX - decision.minX + media.minX,
                               media.maxX - TileBadgeLayout.inset, accuracy: 0.5, context)
                XCTAssertFalse(window.isKeyWindow)
            }
        }
    }

    /// Alex's contact-sheet Grid keeps b66ac87's rendering: stars and color
    /// label on one row at the photo's top, even on a narrow portrait.
    func testGridNarrowPortraitKeepsOneBadgeRow() async throws {
        let side: CGFloat = 120
        let (host, window) = mount(
            ThumbnailView(item: portraitVideo(), isCurrent: false, showsRatingBadge: false, mediaAlignment: .bottom),
            size: CGSize(width: side, height: side), direction: .leftToRight)
        defer { window.contentView = nil; window.close() }
        try await SelectionInteractionFixture.settle(host)
        XCTAssertTrue(SelectionInteractionFixture.descendants(host).allSatisfy { !($0 is BrowserBadgeMarker.MarkerView) })
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / side
        let media = TileMediaGeometry.fittedRect(in: CGRect(x: 0, y: 0, width: side, height: side),
                                                 imageSize: CGSize(width: 9, height: 16), alignment: .bottom)
        var redRows: [CGFloat] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.8, color.greenComponent < 0.4, color.blueComponent < 0.4 {
                    redRows.append(CGFloat(y) / scale)
                }
            }
        }
        // The red label's swatch: inside the top badge row, not wrapped below it.
        XCTAssertFalse(redRows.isEmpty)
        let top = media.minY + TileBadgeLayout.inset
        XCTAssertGreaterThanOrEqual(redRows.min() ?? 0, top - 0.5)
        XCTAssertLessThanOrEqual(redRows.max() ?? .infinity, top + TileBadgeLayout.height + 0.5)
    }

    /// The opening Browser uses Ready's 102 × 80 slot, so previews keep their
    /// size when Ready takes over; before, it fitted them in an 80-point square.
    func testOpeningBrowserUsesReadySlot() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let ready = try fixture.readyStore(count: 4)
        defer { ready.beginTerminationPreparation() }
        let opening = OpeningSessionState(snapshot: .init(items: ready.items), viewMode: .gallery, sourceAccess: nil,
                                          initialPhysicalFileID: ready.items[0].primaryFile.id)
        let store = fixture.store()
        store.showBrowser = true
        store.showMetadataPanel = false
        store.presentOpeningSessionForTesting(opening)
        let host = NSHostingView(rootView: SessionView(store: store).preferredColorScheme(.light))
        let window = SelectionInteractionFixture.mount(host, size: CGSize(width: 1000, height: 600))
        defer { store.beginTerminationPreparation(); window.contentView = nil; window.close() }
        try await SelectionInteractionFixture.settle(host)
        let tiles = SelectionInteractionFixture.descendants(host)
            .compactMap { $0 as? ThumbnailRenderMarker.MarkerView }
            .map { $0.convert($0.bounds, to: host).size }
            .filter { $0.width <= 200 }
        XCTAssertFalse(tiles.isEmpty)
        for size in tiles {
            XCTAssertEqual(size.width, ReviewCollectionMetrics.browserTileWidth, accuracy: 0.5)
            XCTAssertEqual(size.height, ReviewCollectionMetrics.browserTileHeight, accuracy: 0.5)
        }
    }
}
