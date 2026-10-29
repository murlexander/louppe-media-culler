import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class DirectTouchInteractionTests: XCTestCase {
    func testTouchActionsDoNotClaimMouseInputAndYieldToScrolling() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Direct touch requires macOS 27") }
        let view = GridImmediateClickSurface.ClickView(onSingleClick: { _ in }, onDoubleClick: {})
        let taps = view.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }
        XCTAssertEqual(taps.map(\.numberOfClicksRequired), [1, 2])
        for tap in taps {
            XCTAssertEqual(tap.buttonMask, 0, "The existing immediate mouse route must remain independent")
            XCTAssertEqual(tap.allowedTouchTypes, .direct)
            XCTAssertTrue(tap.isCancellableByScrollGesture)
        }
        let first = try XCTUnwrap(taps.first)
        let second = try XCTUnwrap(taps.last)
        let owner = try XCTUnwrap(first.delegate as? DirectTouchClickActions)
        XCTAssertTrue(owner.gestureRecognizer(first, shouldRecognizeSimultaneouslyWith: second))
        XCTAssertFalse(owner.gestureRecognizer(first, shouldRecognizeSimultaneouslyWith: NSPanGestureRecognizer()))
        owner.install(on: view, includesSingleTap: true)
        XCTAssertEqual(view.gestureRecognizers.count, 2, "Rebinding cannot duplicate activations")
    }

    func testCancelledOutOfBoundsHiddenAndModalTouchesCannotActivate() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Direct touch requires macOS 27") }
        _ = NSApplication.shared
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window = window(containing: view)
        defer { window.close() }
        let owner = DirectTouchClickActions()
        var activations: [String] = []
        owner.singleTap = { _, modifiers in activations.append(modifiers.contains(.command) ? "modified" : "tap") }
        owner.doubleTap = { _ in activations.append("double") }
        let recognizer = TouchResultRecognizer()
        view.addGestureRecognizer(recognizer)
        recognizer.result = .cancelled
        owner.activate(recognizer)
        recognizer.result = .possible
        owner.activate(recognizer)
        recognizer.result = .ended
        recognizer.point = CGPoint(x: 101, y: 50)
        owner.activate(recognizer)
        recognizer.point = CGPoint(x: 50, y: 50)
        view.isHidden = true
        owner.activate(recognizer)
        view.isHidden = false
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 30, height: 30),
                             styleMask: .borderless, backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        // Override the attached sheet without presenting or focusing any UI.
        window.modalSheet = sheet
        owner.activate(recognizer)
        window.modalSheet = nil
        sheet.close()
        XCTAssertTrue(activations.isEmpty)
        recognizer.flags = .command
        owner.activate(recognizer)
        recognizer.numberOfClicksRequired = 2
        owner.activate(recognizer)
        XCTAssertEqual(activations, ["modified", "double"])
        XCTAssertFalse(window.isVisible)
    }

    func testBothPhotoSurfacesOfferDirectDoubleTapWithoutInterceptingNativePan() throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Direct touch requires macOS 27") }
        _ = NSApplication.shared
        let fit = FittedImageDoubleClickView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let scroll = ActualSizeScrollView(frame: fit.bounds)
        defer { scroll.prepareForRemoval() }
        for view in [fit, try XCTUnwrap(scroll.documentView)] {
            let recognizers = view.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }
            XCTAssertEqual(recognizers.count, 1)
            let doubleTap = try XCTUnwrap(recognizers.first)
            XCTAssertEqual(doubleTap.numberOfClicksRequired, 2)
            XCTAssertEqual(doubleTap.buttonMask, 0)
            XCTAssertTrue(doubleTap.isCancellableByScrollGesture)
        }
        XCTAssertTrue(scroll.isTouchScrollingEnabled)
        XCTAssertEqual(scroll.minimumNumberOfTouchesForScrolling, 1)
        XCTAssertTrue(scroll.allowsMagnification)
        XCTAssertTrue(fit.gestureRecognizers.contains { $0 is NSMagnificationGestureRecognizer })
    }

    func testNativeTileMenuHonorsSelectionAndFileOperationGate() throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("NSHostingMenu requires macOS 14.4") }
        _ = NSApplication.shared
        let suite = "DirectTouchInteractionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SessionStore(reviewDefaults: defaults)
        store.items = ["A.JPG", "B.JPG"].map { name in
            PhotoItem(primaryFile: PhotoFile(id: name, url: URL(fileURLWithPath: "/tmp/\(name)"),
                captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1))
        }
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.setIndex(0)
        let paths = store.items.map(\.primaryURL)
        var opens = 0
        let revision = store.items[1].contentRevision
        let menu = NSHostingMenu(rootView: MediaTileContextMenu(store: store, index: 1, revision: revision, open: { opens += 1 }))
        menu.update()
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.count, 5)
        menu.performActionForItem(at: 0)
        XCTAssertEqual(opens, 1)
        menu.performActionForItem(at: 1)
        XCTAssertTrue(store.selectedIndices.contains(1))
        let yes = try XCTUnwrap(menu.items.firstIndex { $0.title == L10n.text("Decide Yes") })
        menu.performActionForItem(at: yes)
        XCTAssertEqual(store.items[1].rating, .yes)
        XCTAssertEqual(store.items[0].rating, .yes, "The menu shares the existing selected-items rating behavior")
        store.items.swapAt(0, 1)
        menu.performActionForItem(at: 0)
        XCTAssertEqual(opens, 1, "A stale menu cannot open a replacement at the old index")
        store.items.swapAt(0, 1)
        XCTAssertTrue(store.exportWillStart(mode: .copy))
        defer { store.finishExport(mode: .copy, movedIDs: [], requiresRecovery: false) }
        let blocked = NSHostingMenu(rootView: MediaTileContextMenu(store: store, index: 1, revision: revision, open: {}))
        blocked.update()
        XCTAssertFalse(try XCTUnwrap(blocked.items.first { $0.title == L10n.text("Decide No") }).isEnabled)
        XCTAssertEqual(store.items.map(\.primaryURL), paths)
    }

    func testWindowKeepsTabOrderCurrentWithoutTakingFocus() {
        _ = NSApplication.shared
        let view = WindowContentLayout.Configurator()
        let window = window(containing: view)
        defer { window.close() }
        XCTAssertTrue(window.autorecalculatesKeyViewLoop)
        XCTAssertFalse(window.isVisible)
    }

    func testQualityCueTargetDoesNotStartRubberBandAndMirrorsInRTL() {
        let frames = [0: CGRect(x: 0, y: 0, width: 170, height: 190)]
        for rtl in [false, true] {
            // This point is inside the expanded target, above the old glyph.
            let point = CGPoint(x: rtl ? 140 : 30, y: 132)
            XCTAssertFalse(GridRubberBandHitTest.shouldTrackCanvasDrag(
                startingAt: point, tileFrames: frames, playableVideoIndices: [], rightToLeft: rtl))
            XCTAssertTrue(GridRubberBandHitTest.shouldTrackCanvasDrag(
                startingAt: CGPoint(x: point.x, y: 120), tileFrames: frames,
                playableVideoIndices: [], rightToLeft: rtl))
            XCTAssertTrue(GridRubberBandHitTest.shouldTrackCanvasDrag(
                startingAt: point, tileFrames: frames, playableVideoIndices: [0], rightToLeft: rtl),
                "Video tiles have no photo quality-cue control to reserve")
        }
    }

    private func window(containing view: NSView) -> TouchTestWindow {
        let window = TouchTestWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }
}

@MainActor
private final class TouchTestWindow: NSWindow {
    var modalSheet: NSWindow?
    override var attachedSheet: NSWindow? { modalSheet }
}

@MainActor
private final class TouchResultRecognizer: NSClickGestureRecognizer {
    var result: NSGestureRecognizer.State = .ended
    var point = CGPoint(x: 50, y: 50)
    var flags: NSEvent.ModifierFlags = []
    override var state: NSGestureRecognizer.State {
        get { result }
        set { result = newValue }
    }
    override func location(in view: NSView?) -> NSPoint { point }
    @available(macOS 26.0, *)
    override var modifierFlags: NSEvent.ModifierFlags { flags }
}
