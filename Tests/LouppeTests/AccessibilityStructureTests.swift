import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class AccessibilityStructureTests: XCTestCase {
    func testNativeCollectionExposesHostedItemsInReadingOrderAfterReuse() async throws {
        try await checkCollection(style: .browser, rightToLeft: false)
    }

    func testGridAccessibilityOrderFollowsRTLColumnsAfterReuse() async throws {
        try await checkCollection(style: .grid(thumbnailSize: 170), rightToLeft: true)
    }

    func testOpeningTilesExposeNamesAndReadOnlyActions() async throws {
        for mode in [ViewMode.gallery, .grid] {
            let items = (0..<4).map { index in
                PhotoItem(id: "Opening-\(index).JPG", primaryURL: URL(fileURLWithPath: "/tmp/Opening-\(index).JPG"),
                          pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
            }
            let state = OpeningSessionState(snapshot: .init(items: items), viewMode: mode, sourceAccess: nil)
            let host = NSHostingView(rootView: OpeningSessionContent(state: state, showsBrowser: true,
                showsInfo: false, gridThumbnailSize: 170).environment(\.accessibilityEnabled, true))
            let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 700, height: 500),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let document = try XCTUnwrap(descendants(host).compactMap { $0 as? ReviewCollectionDocument }.first)
            var children: [NSObject] = []
            var visited = Set<ObjectIdentifier>()
            func collect(_ object: NSObject) {
                guard visited.insert(ObjectIdentifier(object)).inserted else { return }
                children.append(object)
                let selector = NSSelectorFromString("accessibilityChildren")
                if object.responds(to: selector),
                   let nested = object.perform(selector)?.takeUnretainedValue() as? [NSObject] { nested.forEach(collect) }
            }
            collect(document)
            let labels = children.map { object -> String in
                let selector = NSSelectorFromString("accessibilityLabel")
                return object.responds(to: selector) ? (object.perform(selector)?.takeUnretainedValue() as? String ?? "<nil>") : "<no label>"
            }
            print("Opening \(mode) AX labels: \(labels)")
            let second = try XCTUnwrap(children.first { object in
                let selector = NSSelectorFromString("accessibilityLabel")
                return object.responds(to: selector)
                    && object.perform(selector)?.takeUnretainedValue() as? String == items[1].displayName
            }, "Opening Browser and Grid tiles must expose filenames")
            XCTAssertTrue(second.responds(to: NSSelectorFromString("accessibilityPerformPress")))
            second.perform(NSSelectorFromString("accessibilityPerformPress"))
            XCTAssertEqual(state.currentItem?.id, items[1].id)
            XCTAssertTrue(state.selectedIDs.isEmpty, "Showing a photo uses Ready's implicit-current selection")
            let actions = (second.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? []
            XCTAssertTrue(actions.contains { $0.name == "Open in Gallery" })
            XCTAssertTrue(actions.contains { $0.name == "Add to Selection" || $0.name == "Remove from Selection" })
            XCTAssertFalse(actions.contains { $0.name.contains("Decide") || $0.name.contains("Stars") || $0.name.contains("Label") })
            XCTAssertTrue(items.allSatisfy { $0.rating == .undecided })
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertFalse(NSApp.isActive)
        }
    }

    func testChangingDocumentTextSizePreservesNativeSelection() async throws {
        _ = NSApplication.shared
        let suite = "Louppe.AccessibilityTextSize.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: NativeTextPreview(text: AttributedString("Selected document text"),
                                                            filename: "Document.txt")
            .defaultAppStorage(defaults))
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let view = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        view.setSelectedRange(NSRange(location: 0, length: 8))
        let originalFont = try XCTUnwrap(view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        defaults.set(TextPreviewSize.largest.rawValue, forKey: TextPreviewSize.preferenceKey)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let updated = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTextView }.first)
        XCTAssertTrue(updated === view)
        XCTAssertEqual(updated.selectedRange(), NSRange(location: 0, length: 8))
        let largeFont = try XCTUnwrap(updated.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(largeFont.pointSize, originalFont.pointSize * 2, accuracy: 0.01)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    private func checkCollection(style: ReviewCollectionStyle, rightToLeft: Bool) async throws {
        _ = NSApplication.shared
        let entries = (0..<100).map {
            ReviewCollectionEntry(id: "item-\($0)", index: $0, physicalFileIDs: ["file-\($0)"])
        }
        let projection = ReviewCollectionProjection(sections: [
            ReviewCollectionSection(id: "all", title: nil, entries: entries)
        ])
        let controller = ReviewCollectionController()
        let host = NSHostingView(rootView: ReviewCollection(
            projection: projection, style: style, controller: controller
        ) { entry in
            AnyView(Text(entry.id).accessibilityLabel(entry.id).accessibilityIdentifier(entry.id)
                .frame(width: 102, height: 102))
        }.environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
            .environment(\.accessibilityEnabled, false))
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000,
                                                 width: style == .browser ? 140 : 650, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let document = try XCTUnwrap(descendants(host).compactMap { $0 as? ReviewCollectionDocument }.first)
        XCTAssertFalse(window.isKeyWindow)
        let initial = try XCTUnwrap(document.accessibilityChildren()?.compactMap { $0 as? any NSAccessibilityElementProtocol })
        XCTAssertFalse(initial.isEmpty, "The native document must expose its hosted SwiftUI content")
        XCTAssertEqual(initial.count, document.realizedItemCount)
        for element in initial {
            XCTAssertTrue(element.accessibilityParent() as? NSView === document)
        }
        controller.follow(id: "item-50")
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        controller.follow(id: "item-48")
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let reusedElements = try XCTUnwrap(document.accessibilityChildren()?.compactMap { $0 as? any NSAccessibilityElementProtocol })
        let reused = reusedElements.compactMap { $0.accessibilityIdentifier?() }
        XCTAssertFalse(reused.isEmpty)
        XCTAssertEqual(reused.count, document.realizedItemCount)
        let positions = reused.compactMap { projection.positionByID[$0] }
        XCTAssertEqual(positions, positions.sorted(), "Reused views must retain logical reading order")
        XCTAssertEqual(document.accessibilityChildrenInNavigationOrder()?.compactMap { $0.accessibilityIdentifier?() }, reused)
        XCTAssertLessThan(document.retainedHostCount, 30)

        let receipt = try XCTUnwrap(controller.snapshotViewport())
        var environment = EnvironmentValues()
        environment.layoutDirection = rightToLeft ? .rightToLeft : .leftToRight
        func reconfigure() {
            document.configure(projection: projection, style: style, controller: controller,
                               rubberBand: nil, environment: environment) { entry in
                AnyView(Text(entry.id).frame(width: 102, height: 102))
            }
        }
        reconfigure()
        let initialBindingCount = document.contentBindCount
        environment.accessibilityEnabled = true
        reconfigure()
        XCTAssertGreaterThan(document.contentBindCount, initialBindingCount,
                             "Starting assistive technology must refresh already mounted cells")
        XCTAssertEqual(controller.snapshotViewport()?.physicalFileID, receipt.physicalFileID)
        XCTAssertEqual(controller.snapshotViewport()?.topOffset ?? .nan, receipt.topOffset, accuracy: 0.5)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
