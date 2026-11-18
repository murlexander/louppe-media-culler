import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Real AppKit knob drags through the mounted Grid. Events are app-local and
/// the windows stay offscreen; nothing is posted to the desktop.
@MainActor
final class GridScrollerDateLabelTests: XCTestCase {
    private struct Sample {
        let clipX: CGFloat
        let clipY: CGFloat
        let text: String?
        let expected: String?
        let frame: CGRect
        let knob: CGRect
        let clip: CGRect
        let scroller: CGRect
        let visible: Bool
    }

    /// AppKit treats a press in a non-key window as a first click, which a
    /// native scroller ignores. The offscreen app stays inactive, so report
    /// key status without activating anything.
    private final class KeyedWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    private var samples: [Sample] = []

    override func tearDown() {
        ReviewCollectionKnobLabel.didUpdate = nil
        super.tearDown()
    }

    func testKnobDragShowsMonthBesideKnobAndKeepsVerticalOnlyInLTRAndMirroredGrid() async throws {
        _ = NSApplication.shared
        // In-process AppKit keeps the app's left-to-right scroller side; the
        // SwiftUI direction still mirrors the Grid's columns.
        for rightToLeft in [false, true] {
            try await assertKnobDrag(rightToLeftContent: rightToLeft, leftGutter: false)
        }
    }

    /// AppKit places the scroller from the app-wide direction, which it caches
    /// at first use. Prove the Arabic layout in a child test process launched
    /// with right-to-left direction, as an Arabic system language does.
    func testKnobDragWithNativeRightToLeftScrollerOnTheLeft() async throws {
        _ = NSApplication.shared
        if NSApp.userInterfaceLayoutDirection == .rightToLeft {
            return try await assertKnobDrag(rightToLeftContent: true, leftGutter: true)
        }
        try runInRightToLeftChild("testKnobDragWithNativeRightToLeftScrollerOnTheLeft")
    }

    /// Reruns one test of this suite in a child process launched with the
    /// right-to-left direction and requires it to pass.
    private func runInRightToLeftChild(_ test: String) throws {
        if ProcessInfo.processInfo.environment[Self.childKey] != nil {
            return XCTFail("The child process did not receive the right-to-left direction")
        }
        let bundle = Bundle(for: Self.self).bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["-AppleTextDirection", "YES", "-NSForceRightToLeftWritingDirection", "YES",
                             "-XCTest", "LouppeTests.GridScrollerDateLabelTests/\(test)", bundle]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.childKey] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let log = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, log)
        XCTAssertTrue(log.contains("Executed 1 test, with 0 failures"), log)
    }

    private static let childKey = "LOUPPE_RTL_KNOB_CHILD"

    private func assertKnobDrag(rightToLeftContent: Bool, leftGutter: Bool) async throws {
        let store = datedStore()
        let (host, window) = mount(store, rightToLeft: rightToLeftContent)
        defer { window.close() }
        try await settle(host)
        let scroll = try gridScroll(in: host)
        let scroller = try XCTUnwrap(scroll.verticalScroller)
        XCTAssertEqual(scroller.frame.midX < scroll.contentView.frame.midX, leftGutter,
                       "The native gutter is on the \(leftGutter ? "left" : "right")")
        let startY = scroll.contentView.bounds.minY
        record(scroll, store: store)
        var injections = 0
        ReviewCollectionKnobLabel.didUpdate = { [unowned self] label in
            // Unconstrained X at every step of the drag is corrected at once.
            injections += 1
            let clip = scroll.contentView
            clip.setBoundsOrigin(NSPoint(x: CGFloat(20 * injections), y: clip.bounds.minY))
            XCTAssertEqual(clip.bounds.minX, 0, accuracy: 0.01, "X injection \(injections)")
            self.capture(label, scroll: scroll, store: store)
        }
        try dragKnob(scroll, to: [0.1, 0.2, 0.3, 0.45, 0.62, 0.8, 0.65, 0.5], diagonal: 45)
        XCTAssertGreaterThanOrEqual(samples.count, 5, "The label updates inside AppKit's tracking loop")
        XCTAssertGreaterThanOrEqual(injections, 5)
        XCTAssertGreaterThanOrEqual(Set(samples.compactMap(\.text)).count, 3, "Several months pass under the knob")
        for sample in samples {
            XCTAssertEqual(sample.clipX, 0, accuracy: 0.01, "X stays zero during the knob drag")
            XCTAssertTrue(sample.visible)
            XCTAssertEqual(sample.text, sample.expected, "Month of the first visible item")
            XCTAssertTrue(sample.clip.insetBy(dx: -0.5, dy: -0.5).contains(sample.frame), "Inside the clip")
            XCTAssertFalse(sample.frame.intersects(sample.scroller), "Never over the scroller")
            if leftGutter {
                XCTAssertEqual(sample.frame.minX, sample.clip.minX + 6, accuracy: 1, "Inboard of the left gutter")
            } else {
                XCTAssertEqual(sample.frame.maxX, sample.clip.maxX - 6, accuracy: 1, "Inboard of the right gutter")
            }
            let clampedTop = sample.clip.minY + 5, clampedBottom = sample.clip.maxY - 5
            if sample.knob.midY - sample.frame.height / 2 > clampedTop,
               sample.knob.midY + sample.frame.height / 2 < clampedBottom {
                XCTAssertEqual(sample.frame.midY, sample.knob.midY, accuracy: 1, "Centered on the knob")
            }
        }
        let label = try XCTUnwrap(scroll.knobLabel)
        XCTAssertFalse(label.isShowing, "Mouse-up hides the label")
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.01)
        XCTAssertNotEqual(scroll.contentView.bounds.minY, startY, "The knob drag scrolled")
        XCTAssertNil(scroller.accessibilityValueDescription(), "The scroller's own description returns")
        samples = []
    }

    func testTrackClicksHoverWheelAndStillPressShowNothing() async throws {
        _ = NSApplication.shared
        let store = datedStore()
        let (host, window) = mount(store, rightToLeft: false)
        defer { window.close() }
        try await settle(host)
        let scroll = try gridScroll(in: host)
        let scroller = try XCTUnwrap(scroll.verticalScroller)
        var shown = 0
        ReviewCollectionKnobLabel.didUpdate = { _ in shown += 1 }

        // Page and jump-to-click (Option flips the system preference), then a
        // drag that continues after the knob jumped under the pointer.
        for modifiers: NSEvent.ModifierFlags in [[], .option] {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            let slot = scroller.rect(for: .knobSlot)
            let trackPoint = CGPoint(x: slot.midX, y: slot.minY + slot.height * 0.85)
            XCTAssertNotEqual(scroller.testPart(scroller.convert(trackPoint, to: nil)), .knob)
            let before = scroll.contentView.bounds.minY
            try press(scroll, at: trackPoint, drags: [0.9, 0.95].map { CGPoint(x: slot.midX, y: slot.minY + slot.height * $0) },
                      modifiers: modifiers)
            try await settle(host)
            XCTAssertNotEqual(scroll.contentView.bounds.minY, before, "Track click scrolls natively")
            XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.01)
        }
        // Press and release on the knob without moving.
        let knob = scroller.rect(for: .knob)
        try press(scroll, at: CGPoint(x: knob.midX, y: knob.midY), drags: [])
        // Hover over the knob.
        for offset in [CGFloat(0), 4, 8] {
            let point = scroller.convert(CGPoint(x: knob.midX, y: knob.midY + offset), to: nil)
            let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            NSApp.sendEvent(moved)
        }
        // Wheel, trackpad phases and momentum.
        try VerticalScrollRegression.assertWheelInputStaysVertical(scroll)
        XCTAssertEqual(shown, 0, "Only a drag that began on the knob shows the label")
        XCTAssertFalse(try XCTUnwrap(scroll.knobLabel).isShowing)

        // A knob drag right after the wheel still works.
        try dragKnob(scroll, to: [0.4, 0.6], diagonal: 0)
        XCTAssertGreaterThan(shown, 0)
    }

    func testOtherSortKeysShowNothingAndDescendingAndUndatedTailRead() async throws {
        _ = NSApplication.shared
        let store = datedStore()
        let (host, window) = mount(store, rightToLeft: false)
        defer { window.close() }
        try await settle(host)
        let scroll = try gridScroll(in: host)
        record(scroll, store: store)

        // The undated tail is longer than the viewport.
        try dragKnob(scroll, to: [0.5, 1], diagonal: 0)
        XCTAssertEqual(samples.last?.text, L10n.text("No Date"))
        XCTAssertEqual(samples.last?.expected, L10n.text("No Date"))

        // Newest first keeps undated items last.
        samples = []
        store.sort = PhotoSort(key: .captureDate, ascending: false)
        try await settle(host)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try dragKnob(scroll, to: [0.03, 0.2], diagonal: 0)
        let first = try XCTUnwrap(samples.first)
        XCTAssertEqual(first.text, first.expected)
        XCTAssertTrue(samples.allSatisfy { $0.text == $0.expected })
        // Newest months come first while the knob moves down.
        let months = Dictionary(uniqueKeysWithValues: (1...12).map { (AppDateFormat.yearAndMonth(month($0)), $0) })
        let order = samples.compactMap { $0.text.flatMap { months[$0] } }
        XCTAssertEqual(order.count, samples.count)
        XCTAssertGreaterThanOrEqual(order.first ?? 0, 9, "Starts among the newest months: \(order)")
        XCTAssertEqual(order, order.sorted(by: >), "Descending months: \(order)")

        for key in [PhotoSort.Key.name, .fileType] {
            samples = []
            store.sort = PhotoSort(key: key, ascending: true)
            try await settle(host)
            try dragKnob(scroll, to: [0.2, 0.4, 0.7], diagonal: 0)
            XCTAssertTrue(samples.isEmpty, "\(key) sort shows no label")
            XCTAssertFalse(scroll.knobLabel?.isShowing ?? false)
            XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.01)
        }
    }

    func testLargeGridDragDoesNotRebuildProjectionOrGeometry() async throws {
        _ = NSApplication.shared
        let store = datedStore(dated: 100_000, undated: 0)
        var projections = 0
        GridCollectionContent.didBuildProjection = { projections += 1 }
        defer { GridCollectionContent.didBuildProjection = nil }
        let (host, window) = mount(store, rightToLeft: false)
        defer { window.close() }
        try await settle(host)
        let scroll = try gridScroll(in: host)
        let document = try XCTUnwrap(scroll.documentView as? ReviewCollectionDocument)
        let geometry = document.geometryGeneration
        let projection = document.projectionGeneration
        let builtProjections = projections
        let label = try XCTUnwrap(scroll.knobLabel)
        let lookups = label.lookupCount
        var updates = 0
        ReviewCollectionKnobLabel.didUpdate = { _ in updates += 1 }
        try dragKnob(scroll, to: [0.1, 0.35, 0.6, 0.85, 0.99], diagonal: 0)
        XCTAssertGreaterThan(updates, 0)
        XCTAssertLessThanOrEqual(label.lookupCount - lookups, updates, "One indexed lookup per update at most")
        XCTAssertEqual(document.geometryGeneration, geometry)
        XCTAssertEqual(document.projectionGeneration, projection)
        XCTAssertEqual(projections, builtProjections, "No prepared projection rebuild")
        XCTAssertLessThanOrEqual(document.retainedHostCount, 200, "Only viewport cells stay realized")
    }

    func testNewDragNeverOpensWithThePreviousMonth() async throws {
        _ = NSApplication.shared
        let store = datedStore()
        let (host, window) = mount(store, rightToLeft: false)
        defer { window.close() }
        try await settle(host)
        let scroll = try gridScroll(in: host)
        record(scroll, store: store)
        try dragKnob(scroll, to: [0.5, 1], diagonal: 0)
        XCTAssertEqual(samples.last?.text, L10n.text("No Date"))
        // New identities the mounted projection has not seen yet: until
        // SwiftUI delivers them, every lookup is stale and resolves nothing.
        store.items = store.items.enumerated().map { index, _ in
            PhotoItem(id: "NEW_\(index).JPG", primaryURL: URL(fileURLWithPath: "/tmp/NEW_\(index).JPG"),
                      pairedURL: nil, captureDate: month(1), cameraModel: nil, lensModel: nil, fileSize: 1)
        }
        store.rebuildDerivedDataForTesting()
        let label = try XCTUnwrap(scroll.knobLabel)
        label.presentForCapture()
        XCTAssertNil(label.text, "A new presentation starts without the previous drag's month")
        XCTAssertFalse(label.isShowing)
        label.cancel()
        // Once current, a real drag names the new items' month.
        try await settle(host)
        samples = []
        try dragKnob(scroll, to: [0.3, 0.6], diagonal: 0)
        XCTAssertFalse(samples.isEmpty)
        for sample in samples {
            XCTAssertTrue(sample.visible)
            XCTAssertEqual(sample.text, AppDateFormat.yearAndMonth(month(1)))
        }
    }

    func testItemsChangingMidDragNeverShowAStaleMonth() async throws {
        _ = NSApplication.shared
        let store = datedStore()
        let (host, window) = mount(store, rightToLeft: false)
        defer { window.close() }
        try await settle(host)
        let scroll = try gridScroll(in: host)
        var changedAt: Int?
        samples = []
        ReviewCollectionKnobLabel.didUpdate = { [unowned self] label in
            self.capture(label, scroll: scroll, store: store)
            guard changedAt == nil, self.samples.count == 2 else { return }
            changedAt = self.samples.count
            // A rescan replaces every item inside AppKit's tracking loop.
            store.items = store.items.enumerated().map { index, _ in
                PhotoItem(id: "RESCAN_\(index).JPG", primaryURL: URL(fileURLWithPath: "/tmp/RESCAN_\(index).JPG"),
                          pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
            }
            store.rebuildDerivedDataForTesting()
        }
        try dragKnob(scroll, to: [0.1, 0.2, 0.35, 0.5, 0.65, 0.8], diagonal: 0)
        let changed = try XCTUnwrap(changedAt)
        XCTAssertGreaterThan(samples.count, changed, "The drag continued after the change")
        for sample in samples.dropFirst(changed) where sample.visible {
            XCTAssertEqual(sample.text, sample.expected)
            XCTAssertEqual(sample.text, L10n.text("No Date"), "Only the current, undated items are named")
        }
        XCTAssertFalse(try XCTUnwrap(scroll.knobLabel).isShowing)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.01)
    }

    func testSwitchingToGalleryMidDragRetiresTheLabel() async throws {
        _ = NSApplication.shared
        let store = datedStore()
        let host = NSHostingView(rootView: SessionView(store: store))
        let window = KeyedWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                 styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        defer { window.close() }
        try await settle(host)
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? ReviewCollectionScrollView }
            .first { $0.knobLabel != nil })
        let label = try XCTUnwrap(scroll.knobLabel)
        var detachedDuringDrag = false
        var updates = 0
        ReviewCollectionKnobLabel.didUpdate = { _ in
            updates += 1
            guard updates == 2 else { return }
            store.viewMode = .gallery
            host.layoutSubtreeIfNeeded()
            detachedDuringDrag = scroll.window == nil
        }
        try dragKnob(scroll, to: [0.1, 0.2, 0.3, 0.45, 0.6], diagonal: 0)
        try await settle(host)
        XCTAssertTrue(detachedDuringDrag, "The Grid left the window inside the drag")
        XCTAssertEqual(updates, 2, "No update after the Grid retired")
        XCTAssertFalse(label.isShowing)
        XCTAssertNil(scroll.window)
        XCTAssertFalse(descendants(host).contains { $0 is ReviewCollectionKnobLabelOverlay && !$0.isHidden },
                       "No label remains in the window")
    }

    func testGroupedReviewShowsNoLabel() async throws {
        _ = NSApplication.shared
        let store = SessionStore()
        // Pairs one second apart: every pair is a capture burst.
        store.items = (0..<300).map { index in
            let name = String(format: "BURST_%04d.JPG", index)
            let date = month(1 + index / 25).addingTimeInterval(Double(index / 2) * 60 + Double(index % 2))
            return PhotoItem(id: name, primaryURL: URL(fileURLWithPath: "/tmp/\(name)"), pairedURL: nil,
                             captureDate: date, cameraModel: nil, lensModel: nil, fileSize: 1)
        }
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.viewMode = .grid
        store.gridThumbSize = 90
        store.setBurstGroupingInterval(2)
        store.enterGroupedReview(.captureBursts)
        let deadline = Date().addingTimeInterval(5)
        while store.isDuplicateBurstAnalysisRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.isGroupedReviewActive)
        XCTAssertEqual(store.sort.key, .captureDate)
        let (host, window) = mount(store, rightToLeft: false)
        defer { window.close() }
        try await settle(host)
        let scroll = try gridScroll(in: host)
        record(scroll, store: store)
        let before = scroll.contentView.bounds.minY
        try dragKnob(scroll, to: [0.2, 0.5, 0.8], diagonal: 0)
        XCTAssertNotEqual(scroll.contentView.bounds.minY, before, "The knob drag scrolled")
        XCTAssertTrue(samples.isEmpty, "Grouped Review shows no label")
        XCTAssertFalse(scroll.knobLabel?.isShowing ?? false)
    }

    func testRawPlusJPEGUsesTheItemsSortDate() async throws {
        _ = NSApplication.shared
        let store = SessionStore()
        func file(_ name: String, _ date: Date?) -> PhotoFile {
            PhotoFile(id: name, url: URL(fileURLWithPath: "/tmp/\(name)"), captureDate: date,
                      cameraModel: nil, lensModel: nil, fileSize: 1)
        }
        // The companion JPEGs carry other dates; the last pairs have no RAW date.
        store.items = (0..<300).map { index in
            let raw = index < 240 ? month(1 + index / 20) : nil
            return PhotoItem(primaryFile: file(String(format: "PAIR_%04d.RAF", index), raw),
                             pairedFile: file(String(format: "PAIR_%04d.JPG", index),
                                              Calendar.current.date(byAdding: .year, value: -6, to: month(1 + index % 12))))
        }
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.viewMode = .grid
        store.gridThumbSize = 90
        let (host, window) = mount(store, rightToLeft: false)
        defer { window.close() }
        try await settle(host)
        let scroll = try gridScroll(in: host)
        record(scroll, store: store)
        try dragKnob(scroll, to: [0.1, 0.3, 0.5, 0.7, 1], diagonal: 0)
        let rawMonths = Set((1...12).map { AppDateFormat.yearAndMonth(month($0)) } + [L10n.text("No Date")])
        XCTAssertGreaterThanOrEqual(samples.count, 3)
        for sample in samples where sample.visible {
            XCTAssertEqual(sample.text, sample.expected)
            XCTAssertTrue(sample.text.map(rawMonths.contains) ?? false, "RAW sort date, not the JPEG's: \(sample.text ?? "")")
        }
        XCTAssertEqual(samples.last?.text, L10n.text("No Date"), "A date-less RAW reads No Date despite its dated JPEG")
    }

    func testOverlayStyleScrollerKeepsTheLabelClearOfTheKnob() async throws {
        _ = NSApplication.shared
        try await assertOverlayClearance(leftGutter: false)
    }

    /// The mirrored overlay case: AppKit puts the scroller on the left only
    /// under the app-wide right-to-left direction, so it runs in a child.
    func testOverlayStyleLeftScrollerKeepsTheLabelClearOfTheKnob() async throws {
        _ = NSApplication.shared
        if NSApp.userInterfaceLayoutDirection == .rightToLeft {
            return try await assertOverlayClearance(leftGutter: true)
        }
        try runInRightToLeftChild("testOverlayStyleLeftScrollerKeepsTheLabelClearOfTheKnob")
    }

    private func assertOverlayClearance(leftGutter: Bool) async throws {
        let store = datedStore()
        let (host, window) = mount(store, rightToLeft: leftGutter)
        defer { window.close() }
        try await settle(host)
        let scroll = try gridScroll(in: host)
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: 600))
        scroll.reflectScrolledClipView(clip)
        // A preferred-style change can briefly run the clip under the scroller.
        scroll.scrollerStyle = .overlay
        scroll.tile()
        let scroller = try XCTUnwrap(scroll.verticalScroller)
        let bar = scroll.convert(scroller.bounds, from: scroller)
        XCTAssertEqual(bar.midX < clip.frame.midX, leftGutter,
                       "The overlay scroller is on the \(leftGutter ? "left" : "right")")
        if leftGutter {
            // AppKit's left-side tile keeps the clip beside the scroller;
            // recreate the transient overlap the right side shows.
            if clip.frame.minX >= bar.maxX {
                clip.frame = NSRect(x: bar.minX, y: clip.frame.minY,
                                    width: clip.frame.maxX - bar.minX, height: clip.frame.height)
            }
            XCTAssertLessThan(clip.frame.minX, bar.maxX, "The overlay scroller lies over the clip")
        } else {
            XCTAssertGreaterThan(clip.frame.maxX, bar.minX, "The overlay scroller lies over the clip")
        }
        let label = try XCTUnwrap(scroll.knobLabel)
        label.presentForCapture()
        XCTAssertTrue(label.isShowing)
        XCTAssertFalse(label.frame.intersects(bar), "Never over the overlay scroller")
        if leftGutter {
            XCTAssertEqual(label.frame.minX, bar.maxX + 6, accuracy: 1)
        } else {
            XCTAssertEqual(label.frame.maxX, bar.minX - 6, accuracy: 1)
        }
        label.cancel()
        PersistentVerticalScroller.configure(scroll)
    }

    func testFirstVisiblePositionMatchesViewportReceiptQuery() {
        // Grouped sections of mixed sizes, an empty one and an ungrouped tail.
        let sizes = [1, 7, 0, 23, 4, 60, 2]
        var position = 0
        let sections = sizes.enumerated().map { index, count in
            ReviewCollectionSection(id: "\(index)", title: index == sizes.count - 1 ? nil : "Day \(index)",
                entries: (0..<count).map { _ in
                    defer { position += 1 }
                    return ReviewCollectionEntry(id: "\(position)", index: position, physicalFileIDs: ["\(position)"])
                })
        }
        let projection = ReviewCollectionProjection(sections: sections)
        for rightToLeft in [false, true] {
            for width in [CGFloat(300), 620, 1000] {
                let geometry = ReviewCollectionGeometry(projection: projection, style: .grid(thumbnailSize: 120),
                    width: width, captionHeight: 15, headerHeight: 22, rightToLeft: rightToLeft)
                for height in [CGFloat(8), 40, 300] {
                    var y = CGFloat(-10)
                    while y < geometry.contentHeight + 10 {
                        let visible = CGRect(x: 0, y: y, width: width, height: height)
                        let expected = geometry.elements(in: visible, projection: projection)
                            .compactMap { element -> (Int, CGRect)? in
                                if case .item(let position) = element.key { return (position, element.frame) }
                                return nil
                            }
                            .min { $0.1.minY == $1.1.minY ? $0.0 < $1.0 : $0.1.minY < $1.1.minY }?.0
                        XCTAssertEqual(geometry.firstVisiblePosition(in: visible), expected,
                                       "y \(y), height \(height), width \(width), rtl \(rightToLeft)")
                        y += 3.5
                    }
                }
            }
        }
    }

    // MARK: - Fixture

    private func month(_ month: Int, day: Int = 10) -> Date {
        Calendar.current.date(from: DateComponents(year: 2025, month: month, day: day, hour: 12))!
    }

    /// Twelve months in ascending capture order, then undated items.
    private func datedStore(dated: Int = 240, undated: Int = 60) -> SessionStore {
        let store = SessionStore()
        let perMonth = max(1, dated / 12)
        store.items = (0..<(dated + undated)).map { index in
            let name = String(format: "MONTH_%06d.JPG", index)
            let date: Date? = index < dated
                ? Calendar.current.date(byAdding: .minute, value: index % perMonth,
                                        to: month(min(12, index / perMonth + 1), day: 1 + (index % perMonth) % 27))
                : nil
            return PhotoItem(id: name, primaryURL: URL(fileURLWithPath: "/tmp/\(name)"),
                             pairedURL: nil, captureDate: date, cameraModel: nil, lensModel: nil, fileSize: 1)
        }
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.viewMode = .grid
        store.gridThumbSize = 90
        return store
    }

    private func mount(_ store: SessionStore, rightToLeft: Bool) -> (NSView, NSWindow) {
        let host = NSHostingView(rootView: GridView(store: store)
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight))
        let window = KeyedWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        return (host, window)
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
    }

    private func gridScroll(in view: NSView) throws -> ReviewCollectionScrollView {
        try XCTUnwrap(descendants(view).compactMap { $0 as? ReviewCollectionScrollView }.first)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func record(_ scroll: ReviewCollectionScrollView, store: SessionStore) {
        samples = []
        ReviewCollectionKnobLabel.didUpdate = { [unowned self] label in
            self.capture(label, scroll: scroll, store: store)
        }
    }

    private func capture(_ label: ReviewCollectionKnobLabel, scroll: ReviewCollectionScrollView, store: SessionStore) {
        let scroller = scroll.verticalScroller!
        // Expected text from the independent viewport receipt query.
        let document = scroll.documentView as! ReviewCollectionDocument
        let expected = document.snapshotViewport().flatMap { receipt in
            store.items.first { $0.individualFiles.contains { $0.id == receipt.physicalFileID } }
        }.map { $0.captureDate.map(AppDateFormat.yearAndMonth) ?? L10n.text("No Date") }
        samples.append(Sample(clipX: scroll.contentView.bounds.minX, clipY: scroll.contentView.bounds.minY,
                              text: label.text, expected: expected, frame: label.frame,
                              knob: scroll.convert(scroller.rect(for: .knob), from: scroller),
                              clip: scroll.contentView.frame, scroller: scroller.frame, visible: label.isShowing))
    }

    /// Down on the knob's center, drags to fractions of the knob's travel
    /// (with optional diagonal pointer movement), then up.
    private func dragKnob(_ scroll: NSScrollView, to fractions: [CGFloat], diagonal: CGFloat) throws {
        let scroller = try XCTUnwrap(scroll.verticalScroller)
        let knob = scroller.rect(for: .knob)
        let slot = scroller.rect(for: .knobSlot)
        let travel = slot.height - knob.height
        XCTAssertGreaterThan(travel, 20)
        let start = CGPoint(x: knob.midX, y: knob.midY)
        XCTAssertEqual(scroller.testPart(scroller.convert(start, to: nil)), .knob, "The press begins on the knob")
        let drags = fractions.enumerated().map { index, fraction in
            CGPoint(x: knob.midX + (index.isMultiple(of: 2) ? diagonal : -diagonal),
                    y: slot.minY + knob.height / 2 + fraction * travel)
        }
        try press(scroll, at: start, drags: drags)
    }

    /// Queue the drags and release, then dispatch the press through
    /// NSApplication so local monitors and the scroller's nested loop run.
    private func press(_ scroll: NSScrollView, at point: CGPoint, drags: [CGPoint],
                       modifiers: NSEvent.ModifierFlags = []) throws {
        let scroller = try XCTUnwrap(scroll.verticalScroller)
        let window = try XCTUnwrap(scroll.window)
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ point: CGPoint, _ step: Int) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: scroller.convert(point, to: nil),
                modifierFlags: modifiers, timestamp: time + Double(step) * 0.02, windowNumber: window.windowNumber,
                context: nil, eventNumber: 9_000 + step, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        let down = try event(.leftMouseDown, point, 0)
        // AppKit's nested tracking loop coalesces queued drags. Feed one event
        // per tick so every step reaches the scroller, as a real pointer does.
        let source = EventFeeder(try drags.enumerated().map { try event(.leftMouseDragged, $0.element, $0.offset + 1) }
            + [try event(.leftMouseUp, drags.last ?? point, drags.count + 1)])
        let feeder = Timer(timeInterval: 0.015, target: source, selector: #selector(EventFeeder.tick(_:)),
                           userInfo: nil, repeats: true)
        RunLoop.current.add(feeder, forMode: .common)
        RunLoop.current.add(feeder, forMode: .eventTracking)
        defer { feeder.invalidate() }
        // Model the production pump: the press is the current event.
        NSApp.postEvent(down, atStart: true)
        let dequeued = try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: .distantPast,
                                                     inMode: .default, dequeue: true))
        NSApp.sendEvent(dequeued)
        // A press that did not track returns at once; deliver the rest normally.
        while !source.pending.isEmpty || feeder.isValid {
            if let queued = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                           until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true) {
                NSApp.sendEvent(queued)
            } else if source.pending.isEmpty {
                break
            }
        }
        while let queued = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                          until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
        scroll.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class EventFeeder: NSObject {
    private(set) var pending: [NSEvent]
    init(_ pending: [NSEvent]) { self.pending = pending }

    @objc func tick(_ timer: Timer) {
        if pending.isEmpty { timer.invalidate() } else { NSApp.postEvent(pending.removeFirst(), atStart: false) }
    }
}
