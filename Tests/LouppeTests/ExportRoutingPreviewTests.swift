import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import Louppe

/// AUD-12: the routing Copy confirmation lists every planned file and every
/// unmatched item. These tests mount the real preview offscreen (never ordered
/// front or made key) and check that large plans realize only nearby rows
/// while every exact path, role suffix, and duplicate unmatched name remains
/// reachable as its own accessible text row.
@MainActor
final class ExportRoutingPreviewTests: XCTestCase {
    func testPreviewRowsKeepExactPathsRolesAndDuplicateUnmatchedNames() async throws {
        let plan = Self.plan(routeFiles: [3], unmatched: 0, roles: [.media, .preparedXMP, .applicationXMP])
        let duplicateNames = MultiDestinationExportPlan(
            routes: plan.routes,
            unmatchedNames: ["IMG_0001.JPG", "IMG_0001.JPG", "Ünicode name.JPG"],
            workerPlan: plan.workerPlan,
            xmpPlan: nil
        )
        let mounted = try await Self.mount(MultiDestinationPlanPreviewList(plan: duplicateNames))
        defer { mounted.close() }
        let texts = Self.selectableRowTexts(in: mounted.host)
        for file in duplicateNames.routes[0].files {
            let expected = MultiDestinationPlanPreviewList.filePreviewText(file)
            XCTAssertTrue(texts.contains(expected), "Missing exact preview row: \(expected)")
            XCTAssertTrue(expected.contains(file.sourcePath))
            XCTAssertTrue(expected.contains(file.destinationPath))
        }
        XCTAssertTrue(texts.contains { $0.hasSuffix("(prepared XMP sidecar)") })
        XCTAssertTrue(texts.contains { $0.hasSuffix("(XMP application packet)") })
        XCTAssertEqual(texts.filter { $0 == "IMG_0001.JPG" }.count, 2,
                       "Same-named unmatched items in different folders each need a row")
        XCTAssertTrue(texts.contains("Ünicode name.JPG"))
        XCTAssertFalse(mounted.window.isVisible)
        XCTAssertFalse(mounted.window.isKeyWindow)
    }

    func testPreviewIdentifiesSameSourceAndDestinationPathOnce() {
        let file = MultiDestinationExportPlan.RoutePreview.FilePreview(
            id: "/a/B.JPG", sourceName: "B.JPG", destinationName: "B.JPG",
            sourcePath: "/a/B.JPG", destinationPath: "/a/B.JPG", role: .media
        )
        XCTAssertEqual(MultiDestinationPlanPreviewList.filePreviewText(file), "/a/B.JPG")
        let renamed = MultiDestinationExportPlan.RoutePreview.FilePreview(
            id: "/d/B-1.JPG", sourceName: "B.JPG", destinationName: "B-1.JPG",
            sourcePath: "/s/B.JPG", destinationPath: "/d/B-1.JPG", role: .retiredXMPSource
        )
        XCTAssertEqual(MultiDestinationPlanPreviewList.filePreviewText(renamed),
                       "/s/B.JPG → /d/B-1.JPG (XMP safety record)")
    }

    /// A single 10k-file route and 10k unmatched names must not realize every
    /// row. The eager layout this replaces realized all ~20k texts on open.
    func testLargeSingleRouteAndUnmatchedPreviewRealizesOnlyNearbyRows() async throws {
        let plan = Self.plan(routeFiles: [10_000], unmatched: 10_000)
        let mounted = try await Self.mount(Self.sheet(MultiDestinationPlanPreviewList(plan: plan)))
        defer { mounted.close() }
        let realized = Self.selectableRowTexts(in: mounted.host).count
        XCTAssertLessThan(realized, 400, "Opening realized \(realized) rows")
        let scroll = try XCTUnwrap(Self.scrollView(in: mounted.host))
        let height = scroll.documentView?.frame.height ?? 0
        XCTAssertGreaterThan(height, 10_000, "Estimated document must still span every row")
        Self.scroll(scroll, toFraction: 0.75)
        mounted.host.layoutSubtreeIfNeeded()
        XCTAssertLessThan(Self.selectableRowTexts(in: mounted.host).count, 400)
        Self.scroll(scroll, toFraction: 1)
        mounted.host.layoutSubtreeIfNeeded()
        let tail = Self.selectableRowTexts(in: mounted.host)
        XCTAssertTrue(tail.contains("UNMATCHED_09999.JPG"), "The last unmatched item must stay reachable")
    }

    /// Interleaved A/B measurement harness for AUD-12. Opt in with
    /// LOUPPE_EXPORT_PREVIEW_MEASURE=1; it prints medians and is not a gate.
    func testMeasureEagerVersusLazyRoutingPreview() async throws {
        guard ProcessInfo.processInfo.environment["LOUPPE_EXPORT_PREVIEW_MEASURE"] == "1" else {
            throw XCTSkip("Set LOUPPE_EXPORT_PREVIEW_MEASURE=1 to measure")
        }
        let samples = Int(ProcessInfo.processInfo.environment["LOUPPE_EXPORT_PREVIEW_SAMPLES"] ?? "") ?? 5
        for (name, files, unmatched) in [("single-route-10k", 10_000, 0), ("unmatched-10k", 1, 10_000), ("both-10k", 10_000, 10_000)] {
            let plan = Self.plan(routeFiles: [files], unmatched: unmatched)
            var results: [String: [Sample]] = ["eager": [], "lazy": []]
            for _ in 0..<samples {
                for variant in ["eager", "lazy"] {
                    let view: AnyView = variant == "eager"
                        ? AnyView(Self.sheet(EagerRoutingPreviewBaseline(plan: plan)))
                        : AnyView(Self.sheet(MultiDestinationPlanPreviewList(plan: plan)))
                    results[variant]!.append(try await Self.measure(view))
                }
            }
            for variant in ["eager", "lazy"] {
                let values = results[variant]!
                func summary(_ key: KeyPath<Sample, Double>) -> String {
                    let sorted = values.map { $0[keyPath: key] }.sorted()
                    return String(format: "median %.1f [%.1f–%.1f]", sorted[sorted.count / 2], sorted.first!, sorted.last!)
                }
                print("AUD12 \(name) \(variant): open ms \(summary(\.openMilliseconds)); scroll20 ms \(summary(\.scrollMilliseconds)); realized \(summary(\.realizedRows)); footprint MiB \(summary(\.footprintDeltaMiB))")
            }
        }
    }

    // MARK: - Fixtures and measurement

    struct Sample {
        let openMilliseconds: Double
        let scrollMilliseconds: Double
        let realizedRows: Double
        let footprintDeltaMiB: Double
    }

    struct Mounted {
        let host: NSView
        let window: NSWindow
        func close() { window.contentView = nil; window.close() }
    }

    static func plan(
        routeFiles: [Int],
        unmatched: Int,
        roles: [FileOperationJournal.PlannedFileRole] = [.media]
    ) -> MultiDestinationExportPlan {
        let routes = routeFiles.enumerated().map { routeIndex, count in
            let destination = URL(fileURLWithPath: "/private/tmp/route-\(routeIndex)", isDirectory: true)
            let files = (0..<count).map { index in
                let name = String(format: "IMG_%05d.JPG", index)
                return MultiDestinationExportPlan.RoutePreview.FilePreview(
                    id: "\(destination.path)/\(name)", sourceName: name, destinationName: name,
                    sourcePath: "/private/tmp/source/day-\(index % 31)/\(name)",
                    destinationPath: "\(destination.path)/\(name)",
                    role: roles[index % roles.count]
                )
            }
            return MultiDestinationExportPlan.RoutePreview(
                route: MultiDestinationExportRoute(predicate: .decision(.yes), destination: destination),
                destination: destination, itemCount: count, mediaFileCount: count, files: files
            )
        }
        return MultiDestinationExportPlan(
            routes: routes,
            unmatchedNames: (0..<unmatched).map { String(format: "UNMATCHED_%05d.JPG", $0) },
            workerPlan: ExportWorker.Plan(items: []),
            xmpPlan: nil
        )
    }

    static func sheet<Content: View>(_ content: Content) -> some View {
        SheetForm(title: "Review Copy Plan") {
            Text("Files will be copied. Originals stay in place.")
            content
            Text("Completed copies stay at their destinations after interruption.")
        } actions: {
            Button("Start Copy") {}
        }
        .frame(width: 640, height: 620)
    }

    static func mount<V: View>(_ view: V) async throws -> Mounted {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        return Mounted(host: host, window: window)
    }

    static func measure(_ view: AnyView) async throws -> Sample {
        let footprintBefore = physicalFootprint()
        let start = ContinuousClock.now
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let opened = ContinuousClock.now
        let footprintAfter = physicalFootprint()
        var scrollDuration = Duration.zero
        if let scroll = scrollView(in: host) {
            let scrollStart = ContinuousClock.now
            for step in 1...20 {
                Self.scroll(scroll, toFraction: Double(step) / 20)
                host.layoutSubtreeIfNeeded()
            }
            scrollDuration = ContinuousClock.now - scrollStart
            Self.scroll(scroll, toFraction: 0)
            host.layoutSubtreeIfNeeded()
        }
        let realized = selectableRowTexts(in: host).count
        window.contentView = nil
        window.close()
        try await Task.sleep(for: .milliseconds(30))
        return Sample(
            openMilliseconds: milliseconds(opened - start),
            scrollMilliseconds: milliseconds(scrollDuration),
            realizedRows: Double(realized),
            footprintDeltaMiB: Double(Int64(footprintAfter) - Int64(footprintBefore)) / 1_048_576
        )
    }

    static func scroll(_ scroll: NSScrollView, toFraction fraction: Double) {
        guard let document = scroll.documentView else { return }
        let maxY = max(0, document.frame.height - scroll.contentView.bounds.height)
        let y = document.isFlipped ? maxY * fraction : maxY * (1 - fraction)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    /// Selectable SwiftUI texts are backed by one native static-text view per
    /// realized row, exposing its exact string to accessibility. Lazy rows
    /// that were never realized have no view. (XCTest hosts expose no
    /// in-process SwiftUI accessibility tree, so the views are walked directly.)
    static func selectableRowTexts(in view: NSView) -> [String] {
        var texts: [String] = []
        func visit(_ view: NSView) {
            if view.accessibilityRole() == .staticText,
               let value = view.accessibilityValue() as? String {
                texts.append(value)
            }
            view.subviews.forEach(visit)
        }
        visit(view)
        return texts
    }

    static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}

/// Verbatim layout of the pre-AUD-12 preview: one lazy child per route, each
/// containing an eager VStack of every file, plus an eager unmatched stack.
/// Kept only as the measurement baseline.
private struct EagerRoutingPreviewBaseline: View {
    let plan: MultiDestinationExportPlan

    var body: some View {
        Group {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(plan.routes) { route in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(route.route.predicate.displayName) → \(route.destination.path)")
                            .font(.subheadline.weight(.semibold))
                        Text(MultiDestinationPlanPreviewList.routeCountText(route))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(route.files) { file in
                            Text(MultiDestinationPlanPreviewList.filePreviewText(file))
                                .font(.caption.monospaced())
                                .foregroundStyle(file.role == .media ? .primary : .secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Divider()
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Unmatched — not copied")
                        .font(.subheadline.weight(.semibold))
                    if plan.unmatchedNames.isEmpty {
                        Text("Every current item is routed exactly once.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(plan.unmatchedNames, id: \.self) { name in
                            Text(name)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}
