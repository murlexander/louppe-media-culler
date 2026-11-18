import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Drag-out of originals through real AppKit mouse events on the rendered
/// Grid, Browser and Gallery. The native session is replaced by a recorder
/// (the global drag loop needs the desktop); pointer routing, the operation
/// mask and the pasteboard payload are the production objects.
@MainActor
final class OriginalFileDragTests: XCTestCase {
    private struct Started {
        let view: NSView
        let items: [NSDraggingItem]
        let event: NSEvent
        let source: OriginalFileDragSource
    }

    private var started: [Started] = []

    override func setUp() async throws {
        try await super.setUp()
        started = []
        OriginalFileDragStarter.override = { [weak self] view, items, event, source in
            self?.started.append(Started(view: view, items: items, event: event, source: source))
        }
    }

    override func tearDown() async throws {
        started.forEach { $0.source.finish() }
        OriginalFileDragStarter.override = nil
        try await super.tearDown()
    }

    // MARK: - Grid

    func testGridMediaDragCopiesSelectionWithoutSelectingOrOpening() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 12)
        try addPair(to: store, fixture: fixture, at: 1)
        store.setIndex(0)
        store.setSelection([0, 1, 2])
        let selectionBefore = store.selectedIndices
        let (host, window) = mount(GridView(store: store), size: CGSize(width: 700, height: 560))
        defer { close(store, window) }
        try await SelectionInteractionFixture.settle(host)
        try await waitForThumbnails(store, indices: [0, 2])
        let surface = try mediaSurface(forItem: 2, store: store, in: host)

        // Below the threshold nothing starts; past it exactly one session.
        let down = try mouse(.leftMouseDown, surface, CGPoint(x: 0.5, y: 0.72), window, number: 1)
        NSApp.sendEvent(down)
        XCTAssertFalse(surface.dragArm.hasPendingSweepForTesting, "Mouse-down resolves and reads nothing")
        let crossing = try mouse(.leftMouseDragged, surface, CGPoint(x: 0.92, y: 0.9), window, number: 4)
        NSApp.sendEvent(try mouse(.leftMouseDragged, surface, CGPoint(x: 0.52, y: 0.72), window, number: 2))
        XCTAssertTrue(started.isEmpty, "Under 8 points is still a click")
        XCTAssertFalse(surface.dragArm.hasPendingSweepForTesting)
        NSApp.sendEvent(try mouse(.leftMouseDragged, surface, CGPoint(x: 0.9, y: 0.9), window, number: 3))
        XCTAssertTrue(surface.dragArm.hasPendingSweepForTesting, "The threshold starts the existence sweep")
        await surface.dragArm.waitForExistenceCheckForTesting()
        NSApp.sendEvent(crossing)
        NSApp.sendEvent(try mouse(.leftMouseUp, surface, CGPoint(x: 0.92, y: 0.9), window, number: 5))
        try await SelectionInteractionFixture.settle(host)

        XCTAssertEqual(started.count, 1)
        let session = try XCTUnwrap(started.first)
        XCTAssertTrue(session.view === surface)
        XCTAssertEqual(session.event.type, .leftMouseDragged, "The session starts from the latest drag event")
        XCTAssertEqual(session.event.locationInWindow, crossing.locationInWindow)
        XCTAssertNotEqual(session.event.locationInWindow, down.locationInWindow)
        let expected = [0, 1, 2].flatMap { store.items[$0].individualFiles.map(\.url) }
        XCTAssertEqual(expected.count, 4, "The RAW+JPEG pair contributes both files")
        XCTAssertEqual(try pasteboardURLs(session.items), expected)
        XCTAssertEqual(session.source.targets.files[session.source.targets.leaderFileIndex].itemIndex, 2,
                       "The grabbed tile leads the drag")
        assertCopyOnly(session.source)
        XCTAssertEqual(store.selectedIndices, selectionBefore, "Drag never changes selection")
        XCTAssertEqual(store.currentIndex, 0, "Drag is not a click")
        XCTAssertEqual(store.viewMode, .grid, "Drag never opens Gallery")
        XCTAssertTrue(OriginalFileDragSource.hasActiveSession, "Louppe's own drop target refuses this session")
        session.source.finish()
        XCTAssertFalse(OriginalFileDragSource.hasActiveSession)
    }

    func testGridDragOfUnselectedTileCarriesOnlyThatItem() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 12)
        store.setIndex(0)
        store.setSelection([0, 1])
        let (host, window) = mount(GridView(store: store), size: CGSize(width: 700, height: 560))
        defer { close(store, window) }
        try await SelectionInteractionFixture.settle(host)
        try await waitForThumbnails(store, indices: [4])
        let surface = try mediaSurface(forItem: 4, store: store, in: host)
        try await drag(surface, from: CGPoint(x: 0.5, y: 0.72), to: CGPoint(x: 0.1, y: 0.95), window: window)

        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(try pasteboardURLs(try XCTUnwrap(started.first).items), [store.items[4].primaryURL])
        XCTAssertEqual(store.selectedIndices, [0, 1])
        XCTAssertEqual(store.currentIndex, 0)
    }

    func testGridLetterboxAndCanvasStillRubberBandAndPlainClickStillSelects() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 12)
        store.setIndex(0)
        let (host, window) = mount(GridView(store: store), size: CGSize(width: 700, height: 560))
        defer { close(store, window) }
        try await SelectionInteractionFixture.settle(host)
        try await waitForThumbnails(store, indices: Array(0..<6))
        let first = try mediaSurface(forItem: 0, store: store, in: host)
        let third = try mediaSurface(forItem: 2, store: store, in: host)
        // Landscape media is bottom-aligned: the top of the square is letterbox.
        let start = first.convert(CGPoint(x: first.bounds.width * 0.5, y: first.bounds.height * 0.12), to: nil)
        let end = third.convert(CGPoint(x: third.bounds.width * 0.5, y: third.bounds.height * 0.8), to: nil)
        try sendDrag(from: start, to: end, window: window)
        try await SelectionInteractionFixture.settle(host)
        XCTAssertTrue(started.isEmpty, "Letterbox is selection canvas, not a drag origin")
        XCTAssertTrue(store.selectedIndices.isSuperset(of: [0, 1, 2]), "The rubber band still selects")

        // A plain click on media still makes the item current on mouse-up.
        store.clearSelection()
        let target = try mediaSurface(forItem: 3, store: store, in: host)
        try SelectionInteractionFixture.click(
            target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.height * 0.72), to: nil), window: window)
        try await SelectionInteractionFixture.settle(host)
        XCTAssertEqual(store.currentIndex, 3)
        XCTAssertTrue(started.isEmpty)
    }

    func testGridMediaDragDoesNotStartRubberBand() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 12)
        store.setIndex(5)
        let (host, window) = mount(GridView(store: store), size: CGSize(width: 700, height: 560))
        defer { close(store, window) }
        try await SelectionInteractionFixture.settle(host)
        try await waitForThumbnails(store, indices: Array(0..<4))
        let first = try mediaSurface(forItem: 0, store: store, in: host)
        let third = try mediaSurface(forItem: 2, store: store, in: host)
        let start = first.convert(CGPoint(x: first.bounds.width * 0.5, y: first.bounds.height * 0.72), to: nil)
        let end = third.convert(CGPoint(x: third.bounds.width * 0.5, y: third.bounds.height * 0.72), to: nil)
        try await sendArmedDrag(from: start, to: end, window: window, arm: first.dragArm)
        try await SelectionInteractionFixture.settle(host)
        XCTAssertEqual(started.count, 1)
        XCTAssertTrue(store.selectedIndices.isEmpty, "A media drag owns the gesture; no rubber band")
        XCTAssertEqual(store.currentIndex, 5)
    }

    func testLargeSelectionKeepsEveryURLAndBoundsDragImages() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 3)
        let template = store.items[0].primaryURL
        var items = store.items
        for index in 3..<1_200 {
            let url = fixture.root.appendingPathComponent(String(format: "BULK_%04d.JPG", index))
            try FileManager.default.copyItem(at: template, to: url)
            items.append(PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil,
                                   captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1))
        }
        store.items = items
        store.rebuildDerivedDataForTesting()
        store.setIndex(0)
        store.selectAllVisible()
        XCTAssertEqual(store.selectedIndices.count, 1_200)
        let (host, window) = mount(GridView(store: store), size: CGSize(width: 700, height: 560))
        defer { close(store, window) }
        try await SelectionInteractionFixture.settle(host)
        let surface = try mediaSurface(forItem: 1, store: store, in: host)
        try await drag(surface, from: CGPoint(x: 0.5, y: 0.72), to: CGPoint(x: 0.9, y: 0.95), window: window)

        let session = try XCTUnwrap(started.first)
        let urls = try pasteboardURLs(session.items)
        XCTAssertEqual(urls.count, 1_200)
        XCTAssertEqual(Set(urls), Set(store.items.map(\.primaryURL)))
        let imaged = session.items.filter { ($0.imageComponents ?? []).contains { $0.contents != nil } }
        XCTAssertLessThanOrEqual(imaged.count, OriginalFileDragItems.maximumImages,
                                 "Drag images stay bounded regardless of selection size")
        XCTAssertGreaterThan(imaged.count, 0)
        for item in imaged {
            XCTAssertLessThanOrEqual(max(item.draggingFrame.width, item.draggingFrame.height),
                                     OriginalFileDragItems.maximumImageSide + 0.5)
        }
    }

    func testMissingOriginalsAreLeftOutAndAllMissingStartsNothing() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 8)
        store.setIndex(0)
        store.setSelection([0, 1])
        try FileManager.default.removeItem(at: store.items[1].primaryURL)
        let (host, window) = mount(GridView(store: store), size: CGSize(width: 700, height: 560))
        defer { close(store, window) }
        try await SelectionInteractionFixture.settle(host)
        try await waitForThumbnails(store, indices: [0, 6])
        let surface = try mediaSurface(forItem: 0, store: store, in: host)
        try await drag(surface, from: CGPoint(x: 0.5, y: 0.72), to: CGPoint(x: 0.9, y: 0.95), window: window)
        XCTAssertEqual(try pasteboardURLs(try XCTUnwrap(started.first).items), [store.items[0].primaryURL])
        started.forEach { $0.source.finish() }
        started = []

        try FileManager.default.removeItem(at: store.items[6].primaryURL)
        let missing = try mediaSurface(forItem: 6, store: store, in: host)
        try await drag(missing, from: CGPoint(x: 0.5, y: 0.72), to: CGPoint(x: 0.9, y: 0.95), window: window)
        XCTAssertTrue(started.isEmpty, "No existing original: no drag")
        XCTAssertEqual(store.currentIndex, 0, "The abandoned drag is not a click either")
    }

    // MARK: - Browser

    func testBrowserTileDragsAndPlainClickStillJumps() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 12)
        store.viewMode = .gallery
        store.setIndex(0)
        let (host, window) = mount(BrowserView(store: store), size: CGSize(width: BrowserView.width, height: 600))
        defer { close(store, window) }
        try await SelectionInteractionFixture.settle(host)
        let surfaces = SelectionInteractionFixture.descendants(host).compactMap { $0 as? GridImmediateClickSurface.ClickView }
        XCTAssertFalse(surfaces.isEmpty, "Browser tiles use the native pointer surface")
        let second = try XCTUnwrap(surfaces.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
            .dropFirst().first)
        try SelectionInteractionFixture.click(second.convert(CGPoint(x: second.bounds.midX, y: second.bounds.midY), to: nil),
                                              window: window)
        try await SelectionInteractionFixture.settle(host)
        XCTAssertEqual(store.currentIndex, 1, "Plain click still jumps")
        XCTAssertTrue(started.isEmpty)

        let third = try XCTUnwrap(surfaces.sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
            .dropFirst(2).first)
        try await drag(third, from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.95, y: 0.95), window: window)
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(try pasteboardURLs(try XCTUnwrap(started.first).items), [store.items[2].primaryURL])
        assertCopyOnly(try XCTUnwrap(started.first).source)
        XCTAssertEqual(store.currentIndex, 1)

        // Touch: single taps only (no double-tap opener), and they yield to
        // the collection's one-finger scrolling.
        if #available(macOS 27.0, *) {
            let recognizers = third.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }
            XCTAssertEqual(recognizers.map(\.numberOfClicksRequired), [1])
            XCTAssertTrue(recognizers.allSatisfy { $0.buttonMask == 0 && $0.isCancellableByScrollGesture })
        }
    }

    func testBrowserCommandClickStillTogglesSelection() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 6)
        store.viewMode = .gallery
        store.setIndex(0)
        let (host, window) = mount(BrowserView(store: store), size: CGSize(width: BrowserView.width, height: 600))
        defer { close(store, window) }
        try await SelectionInteractionFixture.settle(host)
        let surfaces = SelectionInteractionFixture.descendants(host).compactMap { $0 as? GridImmediateClickSurface.ClickView }
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
        let second = try XCTUnwrap(surfaces.dropFirst().first)
        try SelectionInteractionFixture.click(second.convert(CGPoint(x: second.bounds.midX, y: second.bounds.midY), to: nil),
                                              window: window, modifiers: .command)
        try await SelectionInteractionFixture.settle(host)
        XCTAssertEqual(store.selectedIndices, [0, 1])
        XCTAssertEqual(store.currentIndex, 0)
    }

    // MARK: - Gallery

    func testGalleryFitPhotoDragsButZoomedPhotoDoesNot() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 4)
        store.viewMode = .gallery
        store.setIndex(1)
        let (host, window) = mount(GalleryView(store: store), size: CGSize(width: 900, height: 600))
        defer { close(store, window) }
        let fitted = try await waitForView(FittedImageDoubleClickView.self, in: host)
        try await drag(fitted, from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.7, y: 0.7), window: window)
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(try pasteboardURLs(try XCTUnwrap(started.first).items), [store.items[1].primaryURL])
        assertCopyOnly(try XCTUnwrap(started.first).source)
        XCTAssertEqual(store.zoomMode, .fit)
        started.forEach { $0.source.finish() }
        started = []

        // A down that becomes a double-click zooms instead of dragging.
        store.zoomToActual(at: .center)
        try await SelectionInteractionFixture.settle(host)
        XCTAssertEqual(store.zoomMode, .actual)
        XCTAssertTrue(SelectionInteractionFixture.descendants(host).compactMap { $0 as? FittedImageDoubleClickView }.isEmpty,
                      "100% replaces the fitted drag surface with the panning canvas")
        let canvas = try XCTUnwrap(SelectionInteractionFixture.descendants(host).first { $0 is NSScrollView })
        let center = canvas.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
        try sendDrag(from: center, to: CGPoint(x: center.x + 60, y: center.y + 40), window: window)
        try await SelectionInteractionFixture.settle(host)
        XCTAssertTrue(started.isEmpty, "A zoomed photo pans; it never drags files")
        XCTAssertEqual(store.zoomMode, .actual)
    }

    func testGalleryPinchDisarmsDrag() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 2)
        store.viewMode = .gallery
        store.setIndex(0)
        let (host, window) = mount(GalleryView(store: store), size: CGSize(width: 900, height: 600))
        defer { close(store, window) }
        let fitted = try await waitForView(FittedImageDoubleClickView.self, in: host)
        NSApp.sendEvent(try mouse(.leftMouseDown, fitted, CGPoint(x: 0.5, y: 0.5), window, number: 1))
        XCTAssertTrue(fitted.dragArm.isArmed)
        fitted.beginPinch()
        XCTAssertFalse(fitted.dragArm.isArmed)
        NSApp.sendEvent(try mouse(.leftMouseDragged, fitted, CGPoint(x: 0.8, y: 0.8), window, number: 2))
        NSApp.sendEvent(try mouse(.leftMouseUp, fitted, CGPoint(x: 0.8, y: 0.8), window, number: 3))
        XCTAssertTrue(started.isEmpty)
    }

    // MARK: - Mouse-down cost, cancellation, window ordering, touch scrolling

    func testPlainClicksReadNoFilesAndACancelledSweepStops() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 12)
        store.setIndex(0)
        store.selectAllVisible()
        let reads = DragReadCounter()
        OriginalFileDragArm.presenceCheckForTesting = { _ in reads.increment(); return true }
        defer { OriginalFileDragArm.presenceCheckForTesting = nil }
        let (host, window) = mount(GridView(store: store), size: CGSize(width: 700, height: 560))
        defer { close(store, window) }
        try await SelectionInteractionFixture.settle(host)
        try await waitForThumbnails(store, indices: [0, 3])
        let surface = try mediaSurface(forItem: 3, store: store, in: host)
        try SelectionInteractionFixture.click(
            surface.convert(CGPoint(x: surface.bounds.midX, y: surface.bounds.height * 0.72), to: nil), window: window)
        try await SelectionInteractionFixture.settle(host)
        XCTAssertEqual(store.currentIndex, 3, "The click itself still works")
        XCTAssertEqual(reads.value, 0, "A plain click resolves nothing and reads no files")
        XCTAssertFalse(surface.dragArm.hasPendingSweepForTesting)

        // A slow sweep over a large selection stops when the gesture ends.
        OriginalFileDragArm.presenceCheckForTesting = { _ in reads.increment(); usleep(20_000); return true }
        let many = OriginalFileTargets(files: (0..<400).map {
            OriginalFileTarget(fileID: "\($0)", url: URL(fileURLWithPath: "/nonexistent/\($0).jpg"), itemIndex: 0)
        }, leaderFileIndex: 0)
        let plan = try XCTUnwrap(store.originalFileDragPlan(index: 3, revision: store.items[3].contentRevision,
                                                            mediaFrame: surface.bounds))
        let arm = OriginalFileDragArm()
        let down = try mouse(.leftMouseDown, surface, CGPoint(x: 0.5, y: 0.72), window, number: 1)
        arm.arm(event: down, at: .zero, resolve: {
            OriginalFileDragPlan(targets: many, mediaFrame: plan.mediaFrame, leaderImage: nil, readAccess: nil,
                                 cachedImage: { _ in nil }, isStillValid: { true })
        })
        reads.reset()
        arm.dragged(try mouse(.leftMouseDragged, surface, CGPoint(x: 0.9, y: 0.95), window, number: 2),
                    to: CGPoint(x: 20, y: 20), in: surface)
        XCTAssertTrue(arm.hasPendingSweepForTesting)
        try await Task.sleep(for: .milliseconds(60))
        arm.mouseUp()
        try await Task.sleep(for: .milliseconds(100))
        let afterCancel = reads.value
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reads.value, afterCancel, "A cancelled sweep reads no further files")
        XCTAssertLessThan(afterCancel, 400)
        XCTAssertTrue(started.isEmpty)

        let checked = DragReadCounter()
        XCTAssertNil(many.existing(isCancelled: { checked.value >= 3 }, isPresent: { _ in checked.increment(); return true }))
        XCTAssertLessThan(checked.value, 3 + OriginalFileTargets.checkConcurrency,
                          "Each lane checks cancellation before every file")
    }

    func testHeldPointerStartsTheDragWhenTheCheckEnds() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 8)
        store.setIndex(0)
        OriginalFileDragArm.isPointerHeld = { true }
        defer { OriginalFileDragArm.isPointerHeld = { NSEvent.pressedMouseButtons & 1 != 0 } }
        let (host, window) = mount(GridView(store: store), size: CGSize(width: 700, height: 560))
        defer { close(store, window) }
        try await SelectionInteractionFixture.settle(host)
        try await waitForThumbnails(store, indices: [3])
        let surface = try mediaSurface(forItem: 3, store: store, in: host)
        NSApp.sendEvent(try mouse(.leftMouseDown, surface, CGPoint(x: 0.5, y: 0.72), window, number: 1))
        let held = try mouse(.leftMouseDragged, surface, CGPoint(x: 0.85, y: 0.9), window, number: 2)
        NSApp.sendEvent(held)
        XCTAssertTrue(started.isEmpty, "The check is still running")
        // No further mouse events: the pointer stays still with the button down.
        await surface.dragArm.waitForExistenceCheckForTesting()
        XCTAssertEqual(started.count, 1, "The session begins as soon as the check ends")
        XCTAssertEqual(started.first?.event.locationInWindow, held.locationInWindow)
        XCTAssertEqual(try pasteboardURLs(try XCTUnwrap(started.first).items), [store.items[3].primaryURL])

        // Released before the check ended: never start (it would drop at once).
        started.forEach { $0.source.finish() }
        started = []
        OriginalFileDragArm.isPointerHeld = { false }
        NSApp.sendEvent(try mouse(.leftMouseDown, surface, CGPoint(x: 0.5, y: 0.72), window, number: 3))
        NSApp.sendEvent(try mouse(.leftMouseDragged, surface, CGPoint(x: 0.85, y: 0.9), window, number: 4))
        await surface.dragArm.waitForExistenceCheckForTesting()
        XCTAssertTrue(started.isEmpty)
        NSApp.sendEvent(try mouse(.leftMouseUp, surface, CGPoint(x: 0.85, y: 0.9), window, number: 5))
    }

    func testSlowVolumeChecksRunOnBoundedLanes() {
        let files = (0..<80).map {
            OriginalFileTarget(fileID: "\($0)", url: URL(fileURLWithPath: "/Volumes/NAS/\($0).CR3"), itemIndex: $0)
        }
        let targets = OriginalFileTargets(files: files, leaderFileIndex: 5)
        let active = DragReadCounter(), peak = DragReadCounter()
        let lock = NSLock()
        let start = ContinuousClock.now
        let present = targets.existing(isPresent: { file in
            lock.withLock {
                active.increment()
                if active.value > peak.value { peak.increment() }
            }
            usleep(10_000) // 10 ms per metadata round trip; sequential would take 800 ms.
            lock.withLock { active.decrement() }
            return Int(file.fileID)! % 10 != 0
        })
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(400), "Overlapped checks finish well under the sequential 800 ms")
        XCTAssertLessThanOrEqual(peak.value, OriginalFileTargets.checkConcurrency, "At most 8 checks at once")
        XCTAssertGreaterThan(peak.value, 1)
        XCTAssertEqual(present?.files.count, 72, "Order and results are kept per file")
        XCTAssertEqual(present?.files.map(\.fileID), files.map(\.fileID).filter { Int($0)! % 10 != 0 })
        XCTAssertEqual(present?.files[present!.leaderFileIndex].fileID, "5")
    }

    func testSameNameReplacementIsLeftOutOfTheDrag() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 6)
        try bindScannedIdentities(store)
        store.setIndex(0)
        store.setSelection([0, 1])
        // Another app moves the reviewed file aside and writes a new one.
        let replaced = store.items[1].primaryURL
        try FileManager.default.moveItem(at: replaced, to: replaced.appendingPathExtension("moved"))
        try FileManager.default.copyItem(at: store.items[4].primaryURL, to: replaced)
        let (host, window) = mount(GridView(store: store), size: CGSize(width: 700, height: 560))
        defer { close(store, window) }
        try await SelectionInteractionFixture.settle(host)
        try await waitForThumbnails(store, indices: [0])
        // Opened elsewhere: attributes and permissions change, the file doesn't.
        try touchMetadataLikeLaunchServices(store.items[0].primaryURL)
        let surface = try mediaSurface(forItem: 0, store: store, in: host)
        try await drag(surface, from: CGPoint(x: 0.5, y: 0.72), to: CGPoint(x: 0.9, y: 0.95), window: window)
        XCTAssertEqual(try pasteboardURLs(try XCTUnwrap(started.first).items), [store.items[0].primaryURL],
                       "The replacement is not the reviewed original; the neighbor, whose xattrs and permissions changed, stays")
        started.forEach { $0.source.finish() }
        started = []

        // Only the replacement selected: no drag at all.
        store.setSelection([1])
        let replacedTile = try mediaSurface(forItem: 1, store: store, in: host)
        try await drag(replacedTile, from: CGPoint(x: 0.5, y: 0.5), to: CGPoint(x: 0.9, y: 0.95), window: window)
        XCTAssertTrue(started.isEmpty)
    }

    func testIdentityCheckMakesOneStatPerOriginalAndKeepsItsRules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DragIdentity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func make(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }
        let names = ["current.JPG", "touched.JPG", "replaced.JPG", "missing.JPG", "link.JPG", "folder.JPG"]
        var files = try names.enumerated().map { offset, name in
            let url = try make(name)
            return OriginalFileTarget(fileID: name, url: url, itemIndex: offset,
                                      identity: try FileOperationJournal.captureIdentity(at: url))
        }
        let legacyFile = try make("legacy.JPG")
        let legacyLink = root.appendingPathComponent("legacy-link.JPG")
        try FileManager.default.createSymbolicLink(at: legacyLink, withDestinationURL: legacyFile)
        files.append(OriginalFileTarget(fileID: "legacy", url: legacyFile, itemIndex: 6))
        files.append(OriginalFileTarget(fileID: "legacy-link", url: legacyLink, itemIndex: 7))

        try touchMetadataLikeLaunchServices(files[1].url) // ctime only: still current.
        try FileManager.default.moveItem(at: files[2].url, to: root.appendingPathComponent("aside"))
        try Data("new bytes".utf8).write(to: files[2].url) // Same name, new file.
        try FileManager.default.removeItem(at: files[3].url)
        try FileManager.default.removeItem(at: files[4].url)
        try FileManager.default.createSymbolicLink(at: files[4].url, withDestinationURL: files[0].url)
        try FileManager.default.removeItem(at: files[5].url)
        try FileManager.default.createDirectory(at: files[5].url, withIntermediateDirectories: false)

        let targets = OriginalFileTargets(files: files, leaderFileIndex: 2)
        OriginalFileTargets.statCallsForTesting = 0
        let present = try XCTUnwrap(targets.existing())
        XCTAssertEqual(OriginalFileTargets.statCallsForTesting, files.count, "One lstat per original")
        XCTAssertEqual(present.files.map(\.fileID), ["current.JPG", "touched.JPG", "legacy"],
                       "Replacement, missing file, symlink and folder are left out; xattr-only changes stay")
        XCTAssertEqual(present.leaderFileIndex, 0, "A missing leader falls back to the first present file")
    }

    func testInactiveWindowClicksBehaveNormallyAndDragsDoNotOrderFront() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 8)
        store.rate(.yes, at: 2)
        store.setIndex(1)
        var preventions = 0
        OriginalFileDragStarter.didPreventWindowOrdering = { preventions += 1 }
        defer { OriginalFileDragStarter.didPreventWindowOrdering = nil }

        // Gallery: a first click on the photo only arms a drag.
        store.viewMode = .gallery
        let (gallery, galleryWindow) = mount(GalleryView(store: store), size: CGSize(width: 900, height: 600))
        let fitted = try await waitForView(FittedImageDoubleClickView.self, in: gallery)
        XCTAssertFalse(galleryWindow.isKeyWindow)
        let galleryDown = try mouse(.leftMouseDown, fitted, CGPoint(x: 0.5, y: 0.5), galleryWindow, number: 1)
        XCTAssertTrue(fitted.acceptsFirstMouse(for: galleryDown))
        XCTAssertTrue(fitted.shouldDelayWindowOrdering(for: galleryDown), "Ordering waits for mouse-up or a drag")
        try SelectionInteractionFixture.click(fitted.convert(CGPoint(x: fitted.bounds.midX, y: fitted.bounds.midY), to: nil),
                                              window: galleryWindow)
        try await SelectionInteractionFixture.settle(gallery)
        XCTAssertEqual(store.zoomMode, .fit)
        XCTAssertEqual(store.currentIndex, 1)
        XCTAssertTrue(store.selectedIndices.isEmpty)
        XCTAssertEqual(preventions, 0, "A plain click orders the window front as usual")
        galleryWindow.contentView = nil
        galleryWindow.close()

        // Grid: a first click is an ordinary click; a drag keeps the window back.
        store.viewMode = .grid
        let (grid, gridWindow) = mount(GridView(store: store), size: CGSize(width: 700, height: 560))
        defer { close(store, gridWindow) }
        try await SelectionInteractionFixture.settle(grid)
        try await waitForThumbnails(store, indices: [2, 4])
        let tile = try mediaSurface(forItem: 2, store: store, in: grid)
        let tileDown = try mouse(.leftMouseDown, tile, CGPoint(x: 0.5, y: 0.72), gridWindow, number: 1)
        XCTAssertTrue(tile.acceptsFirstMouse(for: tileDown))
        XCTAssertTrue(tile.shouldDelayWindowOrdering(for: tileDown))
        try SelectionInteractionFixture.click(tile.convert(CGPoint(x: tile.bounds.midX, y: tile.bounds.height * 0.72), to: nil),
                                              window: gridWindow)
        try await SelectionInteractionFixture.settle(grid)
        XCTAssertEqual(store.currentIndex, 2, "What a normal click does, nothing more")
        XCTAssertEqual(store.items[2].rating, .yes)
        XCTAssertEqual(store.items.filter { $0.rating == .yes }.count, 1)
        XCTAssertTrue(store.selectedIndices.isEmpty)
        XCTAssertEqual(preventions, 0)

        let other = try mediaSurface(forItem: 4, store: store, in: grid)
        try await drag(other, from: CGPoint(x: 0.5, y: 0.72), to: CGPoint(x: 0.9, y: 0.95), window: gridWindow)
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(preventions, 1, "A drag prevents window ordering")
        XCTAssertFalse(gridWindow.isKeyWindow)
        XCTAssertFalse(NSApp.isActive)
        XCTAssertEqual(store.currentIndex, 2)
    }

    /// Direct touches reach the collection as scroll events, never as mouse
    /// drags; the native tile surface must pass them to the NSScrollView.
    func testBrowserTouchStyleScrollOverATileStillScrollsVertically() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 40)
        store.viewMode = .gallery
        store.setIndex(0)
        let (host, window) = mount(BrowserView(store: store), size: CGSize(width: BrowserView.width, height: 600))
        defer { close(store, window) }
        try await SelectionInteractionFixture.settle(host)
        let scroll = try XCTUnwrap(SelectionInteractionFixture.descendants(host).compactMap { $0 as? ReviewCollectionScrollView }.first)
        let content = try XCTUnwrap(window.contentView)
        let tile = try XCTUnwrap(SelectionInteractionFixture.descendants(host)
            .compactMap { $0 as? GridImmediateClickSurface.ClickView }.first { candidate in
                guard candidate.window != nil else { return false }
                let center = candidate.convert(CGPoint(x: candidate.bounds.midX, y: candidate.bounds.midY), to: nil)
                return content.hitTest(content.superview?.convert(center, from: nil) ?? center) === candidate
            }, "The scroll starts over a hit-tested native tile surface")
        let point = tile.convert(CGPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)
        let screen = window.convertPoint(toScreen: point)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let before = scroll.contentView.bounds.minY
        // Offscreen windows cannot run AppKit's gesture-scroll tracking loop, so
        // precise pixel deltas stand in for the touch scroll's changed events.
        for (delta, phase) in [(Int32(-120), Int64(0)), (-120, 0), (-120, 0)] {
            let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                                wheelCount: 2, wheel1: delta, wheel2: 0, wheel3: 0))
            cgEvent.location = CGPoint(x: screen.x, y: primaryHeight - screen.y)
            cgEvent.timestamp = DispatchTime.now().uptimeNanoseconds
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            // Display arrangements differ; correct the global (top-left) point
            // once so the event lands exactly on the tile.
            let probe = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            cgEvent.location.x -= probe.locationInWindow.x - point.x
            cgEvent.location.y += probe.locationInWindow.y - point.y
            let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            XCTAssertEqual(event.locationInWindow.x, point.x, accuracy: 1)
            XCTAssertEqual(event.locationInWindow.y, point.y, accuracy: 1)
            window.sendEvent(event)
        }
        try await SelectionInteractionFixture.settle(host)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, before + 100, "One-finger scrolling still moves the column")
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, "Vertical only")
        XCTAssertEqual(store.currentIndex, 0, "Scrolling never clicks a tile")
        XCTAssertTrue(started.isEmpty)
        XCTAssertFalse(tile.dragArm.isArmed)
        if #available(macOS 27.0, *) {
            XCTAssertTrue(tile.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }
                .allSatisfy { $0.isCancellableByScrollGesture && $0.allowedTouchTypes == .direct })
        }
    }

    // MARK: - Resolver

    func testResolverOriginRulesPairsAndPhotos() throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 5)
        try addPair(to: store, fixture: fixture, at: 3)
        store.rate(.yes, at: 3)
        store.setIndex(1)

        // No explicit selection: the current item.
        XCTAssertEqual(store.originalFileTargets(for: .selection)?.urls, [store.items[1].primaryURL])
        store.setSelection([3, 0])
        let selected = try XCTUnwrap(store.originalFileTargets(for: .selection))
        XCTAssertEqual(selected.urls, [store.items[0].primaryURL] + store.items[3].individualFiles.map(\.url),
                       "Visible order, primary before companion")
        let grabbed = try XCTUnwrap(store.originalFileTargets(for: .item(index: 3, revision: store.items[3].contentRevision)))
        XCTAssertEqual(grabbed.urls, selected.urls)
        XCTAssertEqual(grabbed.files[grabbed.leaderFileIndex].url, store.items[3].primaryURL)
        XCTAssertEqual(store.originalFileTargets(for: .item(index: 4, revision: store.items[4].contentRevision))?.urls,
                       [store.items[4].primaryURL], "Outside the selection: only the grabbed item")
        XCTAssertNil(store.originalFileTargets(for: .item(index: 4, revision: store.items[0].contentRevision)),
                     "A stale revision resolves nothing")

        store.phase = .scanning(found: 0)
        XCTAssertFalse(store.canHandOffOriginals(.selection))
        XCTAssertNil(store.originalFileTargets(for: .selection))
        store.phase = .ready

        // Apple Photos items carry synthetic URLs and are never handed off.
        let photos = PhotoItem(primaryFile: PhotoFile(id: "photos-1", url: fixture.root.appendingPathComponent("photos-1.heic"),
            captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1,
            photosMedia: PhotosMediaReference(assetID: "asset-0",
                session: PhotosMediaSession(provider: MockPhotosMedia(), folder: fixture.root))))
        store.items.append(photos)
        store.rebuildDerivedDataForTesting()
        let photosIndex = store.items.count - 1
        XCTAssertFalse(store.canDragOriginal(at: photosIndex))
        XCTAssertNil(store.originalFileTargets(for: .item(index: photosIndex, revision: photos.contentRevision)))
    }

    func testCopyMaskIgnoresModifiersAndBothContexts() {
        XCTAssertEqual(OriginalFileDragSource.operationMask(for: .outsideApplication), .copy)
        XCTAssertEqual(OriginalFileDragSource.operationMask(for: .withinApplication), .copy)
    }

    // MARK: - Helpers

    private func assertCopyOnly(_ source: OriginalFileDragSource, file: StaticString = #filePath, line: UInt = #line) {
        let session = NSDraggingSession()
        for context in [NSDraggingContext.outsideApplication, .withinApplication] {
            XCTAssertEqual(source.draggingSession(session, sourceOperationMaskFor: context), .copy,
                           "Copy only, never Move, Link or Delete", file: file, line: line)
        }
        XCTAssertTrue(source.ignoreModifierKeys(for: session), "Command/Option cannot change the mask", file: file, line: line)
    }

    private func pasteboardURLs(_ items: [NSDraggingItem]) throws -> [URL] {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("louppe.test.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items.compactMap { $0.item as? NSPasteboardWriting }))
        XCTAssertEqual(pasteboard.pasteboardItems?.count, items.count, "One pasteboard item per original")
        let urls = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL])
        XCTAssertEqual(urls.count, items.count, "Only file URLs, no promises or other types")
        return urls.map(\.standardizedFileURL)
    }

    /// Gives fixture items the identity a real folder scan records.
    private func bindScannedIdentities(_ store: SessionStore) throws {
        store.items = try store.items.map { item in
            PhotoItem(primaryFile: PhotoFile(id: item.id, url: item.primaryURL, captureDate: nil,
                cameraModel: nil, lensModel: nil, fileSize: item.fileSize,
                scannedIdentity: try FileOperationJournal.captureIdentity(at: item.primaryURL)))
        }
        store.rebuildDerivedDataForTesting()
    }

    private func addPair(to store: SessionStore, fixture: SelectionInteractionFixture, at index: Int) throws {
        let jpeg = store.items[index].primaryURL
        let raw = jpeg.deletingPathExtension().appendingPathExtension("CR3")
        try Data("raw".utf8).write(to: raw)
        store.items[index] = PhotoItem(id: raw.lastPathComponent, primaryURL: raw, pairedURL: jpeg,
                                       captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 3)
        store.rebuildDerivedDataForTesting()
    }

    private func mount<V: View>(_ view: V, size: CGSize) -> (NSHostingView<AnyView>, NSWindow) {
        let host = NSHostingView(rootView: AnyView(view.environment(\.accessibilityEnabled, true)))
        return (host, SelectionInteractionFixture.mount(host, size: size))
    }

    private func close(_ store: SessionStore, _ window: NSWindow) {
        store.beginTerminationPreparation()
        window.contentView = nil
        window.close()
    }

    private func waitForThumbnails(_ store: SessionStore, indices: [Int]) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while indices.contains(where: { ImagePipeline.shared.cachedThumbnail(for: store.items[$0]) == nil }) {
            guard ContinuousClock.now < deadline else { return XCTFail("Thumbnails did not load") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
    }

    private func waitForView<T: NSView>(_ type: T.Type, in host: NSView) async throws -> T {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            if let view = SelectionInteractionFixture.descendants(host).compactMap({ $0 as? T }).first(where: { $0.bounds.width > 50 }) {
                try await Task.sleep(for: .milliseconds(50))
                return view
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("\(T.self) did not mount")
        throw CancellationError()
    }

    /// The media-square surface of the tile showing `index` (its caption
    /// surface is shorter than 100 points).
    private func mediaSurface(forItem index: Int, store: SessionStore, in host: NSView) throws -> GridImmediateClickSurface.ClickView {
        let name = store.items[index].displayName
        let element = try XCTUnwrap(SelectionInteractionFixture.elements(host).first {
            SelectionInteractionFixture.label($0) == name
        }, "Tile \(name) is not mounted")
        let frame = try XCTUnwrap(element.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        let windowFrame = try XCTUnwrap(host.window).convertFromScreen(frame)
        return try XCTUnwrap(SelectionInteractionFixture.descendants(host)
            .compactMap { $0 as? GridImmediateClickSurface.ClickView }
            .filter { $0.bounds.height > 100 }
            .first { $0.convert($0.bounds, to: nil).intersection(windowFrame).width > 50 })
    }

    /// A point given as fractions of the view's bounds, from its top-left.
    private func mouse(_ type: NSEvent.EventType, _ view: NSView, _ unit: CGPoint, _ window: NSWindow,
                       number: Int) throws -> NSEvent {
        let local = CGPoint(x: view.bounds.width * unit.x,
                            y: view.isFlipped ? view.bounds.height * unit.y : view.bounds.height * (1 - unit.y))
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(local, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func drag(_ view: NSView, from: CGPoint, to: CGPoint, window: NSWindow) async throws {
        NSApp.sendEvent(try mouse(.leftMouseDown, view, from, window, number: 1))
        NSApp.sendEvent(try mouse(.leftMouseDragged, view, to, window, number: 2))
        if let arm = (view as? GridImmediateClickSurface.ClickView)?.dragArm ?? (view as? FittedImageDoubleClickView)?.dragArm {
            await arm.waitForExistenceCheckForTesting()
        }
        NSApp.sendEvent(try mouse(.leftMouseDragged, view, to, window, number: 3))
        NSApp.sendEvent(try mouse(.leftMouseUp, view, to, window, number: 4))
        try await Task.sleep(for: .milliseconds(30))
    }

    private func sendArmedDrag(from: CGPoint, to: CGPoint, window: NSWindow, arm: OriginalFileDragArm) async throws {
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ point: CGPoint, _ number: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: time + Double(number) * 0.01, windowNumber: window.windowNumber, context: nil,
                eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        NSApp.sendEvent(try event(.leftMouseDown, from, 1))
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        NSApp.sendEvent(try event(.leftMouseDragged, mid, 2))
        await arm.waitForExistenceCheckForTesting()
        NSApp.sendEvent(try event(.leftMouseDragged, to, 3))
        NSApp.sendEvent(try event(.leftMouseUp, to, 4))
    }

    private func sendDrag(from: CGPoint, to: CGPoint, window: NSWindow) throws {
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ point: CGPoint, _ number: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: time + Double(number) * 0.01, windowNumber: window.windowNumber, context: nil,
                eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        NSApp.sendEvent(try event(.leftMouseDown, from, 1))
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        NSApp.sendEvent(try event(.leftMouseDragged, mid, 2))
        NSApp.sendEvent(try event(.leftMouseDragged, to, 3))
        NSApp.sendEvent(try event(.leftMouseUp, to, 4))
    }
}

/// Thread-safe counter for injected off-main checks.
private final class DragReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func decrement() { lock.withLock { count -= 1 } }
    func reset() { lock.withLock { count = 0 } }
}

/// What macOS and Launch Services do to a file opened elsewhere: an extended
/// attribute and a permission change. Content, inode and mtime stay; ctime moves.
func touchMetadataLikeLaunchServices(_ url: URL) throws {
    var before = stat()
    XCTAssertEqual(lstat(url.path, &before), 0)
    usleep(20_000)
    let value = Data(repeating: 7, count: 16)
    let result = value.withUnsafeBytes { bytes in
        setxattr(url.path, "com.apple.lastuseddate#PS", bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
    }
    XCTAssertEqual(result, 0, "setxattr")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    var after = stat()
    XCTAssertEqual(lstat(url.path, &after), 0)
    XCTAssertNotEqual(after.st_ctimespec.tv_sec * 1_000_000_000 + after.st_ctimespec.tv_nsec,
                      before.st_ctimespec.tv_sec * 1_000_000_000 + before.st_ctimespec.tv_nsec,
                      "The fixture must move the inode change time")
    XCTAssertEqual(after.st_ino, before.st_ino)
}
