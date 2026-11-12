import AppKit
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class ReviewReadoutTests: XCTestCase {
    func testLabelAndValueAreOneAccessibleElement() async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: LabeledReadout(label: "Capture date") {
            Text("12 November 2026").font(.callout)
        }.environment(\.accessibilityEnabled, true))
        let window = mount(host, width: 300, height: 100)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let elements = accessibilityElements(in: host)
        let readout = elements.filter {
            let label = accessibilityLabel($0) ?? ""
            return label.contains("Capture date") && label.contains("12 November 2026")
        }
        XCTAssertEqual(readout.count, 1, "VoiceOver should read a field name and value together: \(elements.compactMap(accessibilityLabel))")
        XCTAssertFalse(window.isKeyWindow)
    }

    private func mount(_ host: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: width, height: height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func accessibilityLabel(_ object: NSObject) -> String? {
        // Static text exposes its spoken content as AXValue; groups and
        // controls can use AXLabel. SwiftUI nodes need not implement the full
        // NSAccessibilityProtocol, so query these public selectors directly.
        for name in ["accessibilityLabel", "accessibilityValue"] {
            let selector = NSSelectorFromString(name)
            if object.responds(to: selector),
               let text = object.perform(selector)?.takeUnretainedValue() as? String {
                return text
            }
        }
        return nil
    }

    private func accessibilityElements(in root: NSView) -> [NSObject] {
        var result: [NSObject] = []
        var visited: Set<ObjectIdentifier> = []
        func walk(_ value: Any) {
            guard let object = value as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            if let accessible = object as? any NSAccessibilityProtocol {
                for child in accessible.accessibilityChildren() ?? [] { walk(child) }
            } else if object.responds(to: NSSelectorFromString("accessibilityChildren")),
                      let children = object.perform(NSSelectorFromString("accessibilityChildren"))?.takeUnretainedValue() as? [Any] {
                for child in children { walk(child) }
            }
            // ScrollView embeds another ignored hosting boundary. Unwrap each
            // native view too, rather than falling back to NSTextField children.
            if let view = object as? NSView {
                for child in NSAccessibility.unignoredChildren(from: [view]) { walk(child) }
                for child in view.subviews { walk(child) }
            }
        }
        // Hosting views are ignored AX wrappers. Ask AppKit for their public
        // unignored roots before walking the SwiftUI nodes.
        for child in NSAccessibility.unignoredChildren(from: [root]) { walk(child) }
        return result
    }
}
