import AppKit
import XCTest
@testable import Louppe

@MainActor
enum VerticalScrollRegression {
    /// Deliver actual AppKit wheel events without posting input to the desktop.
    static func assertWheelInputStaysVertical(
        _ scroll: NSScrollView, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let clip = scroll.contentView
        let verticalOrigin = clip.bounds.minY
        clip.setBoundsOrigin(NSPoint(x: 17, y: verticalOrigin))
        XCTAssertEqual(clip.bounds.minX, 0, accuracy: 0.01, "Layout/follow-scroll must not introduce X travel", file: file, line: line)
        XCTAssertEqual(clip.bounds.minY, verticalOrigin, accuracy: 0.01, file: file, line: line)
        // Core Graphics and AppKit use different phase bit values.
        let began = Int64(CGScrollPhase.began.rawValue)
        let changed = Int64(CGScrollPhase.changed.rawValue)
        let ended = Int64(CGScrollPhase.ended.rawValue)
        for (horizontal, vertical, phase, momentum): (Int32, Int32, Int64, Int64) in [
            (80, 0, began, 0), (-80, 0, changed, 0), (0, 0, ended, 0),
            (-8, -40, began, 0), (8, -40, changed, 0), (0, 0, ended, 0),
            (0, -40, began, 0), (0, -40, changed, 0), (0, 0, ended, 0),
            (8, -40, 0, 1), (-8, -40, 0, 2), (0, 0, 0, 3)
        ] {
            let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                              wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0))
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            cgEvent.flags = []
            if let window = scroll.window {
                cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            }
            let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            if phase == began { XCTAssertEqual(event.phase, .began, file: file, line: line) }
            if phase == changed { XCTAssertEqual(event.phase, .changed, file: file, line: line) }
            if phase == ended { XCTAssertEqual(event.phase, .ended, file: file, line: line) }
            XCTAssertTrue(event.hasPreciseScrollingDeltas, file: file, line: line)
            XCTAssertEqual(event.scrollingDeltaX, CGFloat(horizontal), file: file, line: line)
            XCTAssertEqual(event.scrollingDeltaY, CGFloat(vertical), file: file, line: line)
            scroll.scrollWheel(with: event)
            XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.01,
                           "Horizontal/diagonal wheel input must not move the thumbnail canvas", file: file, line: line)
        }
    }
}

@MainActor
final class PersistentVerticalScrollerTests: XCTestCase {
    func testAxisLockRepairsDocumentDriftAndPreservesNativeVerticalScrolling() async throws {
        _ = NSApplication.shared
        let (scroll, document, bridge) = mountedScroller()
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        window.makeKey()
        defer { window.close() }
        let nativeScroller = try XCTUnwrap(scroll.verticalScroller)
        let clip = scroll.contentView
        // Simulate a layout pass briefly making a document wider than the clip.
        document.setFrameSize(NSSize(width: 317, height: 2000))
        clip.setBoundsOrigin(NSPoint(x: 17, y: 120))
        XCTAssertEqual(clip.bounds.minX, 0, accuracy: 0.01)
        XCTAssertEqual(clip.bounds.minY, 120, accuracy: 0.01)
        clip.scroll(to: NSPoint(x: -17, y: 240))
        XCTAssertEqual(clip.bounds.minX, 0, accuracy: 0.01)
        XCTAssertEqual(clip.bounds.minY, 240, accuracy: 0.01)
        let previousY = clip.bounds.minY
        try VerticalScrollRegression.assertWheelInputStaysVertical(scroll)
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                         wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        wheel.flags = []
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(scroll.verticalScroller === nativeScroller)
        XCTAssertNotEqual(clip.bounds.minY, previousY, "The X lock must retain vertical wheel scrolling")
        withExtendedLifetime(bridge) {}
    }

    func testAxisLockDetachesAndRebindsWithoutOwningOldClip() {
        _ = NSApplication.shared
        let (first, _, bridge) = mountedScroller()
        let oldClip = first.contentView
        bridge.removeFromSuperview()
        oldClip.setBoundsOrigin(NSPoint(x: 17, y: 100))
        XCTAssertEqual(oldClip.bounds.minX, 17, accuracy: 0.01, "Detached bridges must release observation")
        let (second, document, otherBridge) = mountedScroller()
        otherBridge.removeFromSuperview()
        document.addSubview(bridge)
        bridge.scheduleConfiguration()
        second.contentView.setBoundsOrigin(NSPoint(x: 17, y: 80))
        XCTAssertEqual(second.contentView.bounds.minX, 0, accuracy: 0.01)
        XCTAssertEqual(second.contentView.bounds.minY, 80, accuracy: 0.01)
        bridge.dismantle()
        bridge.scheduleConfiguration()
        second.contentView.setBoundsOrigin(NSPoint(x: 17, y: 160))
        XCTAssertEqual(second.contentView.bounds.minX, 17, accuracy: 0.01)
    }

    func testAxisLockRebindsWhenNativeClipIsReplaced() {
        _ = NSApplication.shared
        let (scroll, document, bridge) = mountedScroller()
        let oldClip = scroll.contentView
        let replacement = NSClipView(frame: oldClip.frame)
        scroll.contentView = replacement
        scroll.documentView = document
        bridge.scheduleConfiguration()
        replacement.setBoundsOrigin(NSPoint(x: 17, y: 90))
        XCTAssertEqual(replacement.bounds.minX, 0, accuracy: 0.01)
        XCTAssertEqual(replacement.bounds.minY, 90, accuracy: 0.01)
        oldClip.setBoundsOrigin(NSPoint(x: 17, y: 50))
        XCTAssertEqual(oldClip.bounds.minX, 17, accuracy: 0.01)
    }

    private func mountedScroller() -> (NSScrollView, NSView, PersistentVerticalScroller.Configurator) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 317, height: 2000))
        scroll.documentView = document
        let bridge = PersistentVerticalScroller.Configurator()
        document.addSubview(bridge)
        bridge.scheduleConfiguration()
        return (scroll, document, bridge)
    }
}
