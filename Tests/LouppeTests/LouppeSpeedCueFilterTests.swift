import Foundation
import XCTest
@testable import Louppe

@MainActor
final class LouppeSpeedCueFilterTests: XCTestCase {
    func testCueSwitchesAndClassificationStages() throws {
        try SpeedBenchmark.requireEnabled()
        let report = SpeedReport(suite: "cue-filter")
        for count in SpeedBenchmark.sizes {
            let domain = "CueFilterSpeed.\(UUID())"
            let defaults = UserDefaults(suiteName: domain)!
            defer { defaults.removePersistentDomain(forName: domain) }
            CameraQualityWarningPreferences(isClippingEnabled: false).save(to: defaults)
            let store = SessionStore(reviewDefaults: defaults)
            let items = (0..<count).map { i in
                PhotoItem(primaryFile: PhotoFile(
                    id: "photo-\(i)", url: URL(fileURLWithPath: "/private/tmp/cue-filter-synthetic/\(i).JPG"),
                    captureDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                    cameraModel: "Camera \(i % 4)", lensModel: nil,
                    shutterSpeed: i.isMultiple(of: 5) ? 0.1 : 0.001,
                    iso: i.isMultiple(of: 2) ? 6_400 : 100, fileSize: 1,
                    rating: i.isMultiple(of: 3) ? .yes : .undecided))
            }
            store.items = items
            store.rebuildDerivedDataForTesting()
            store.phase = .ready
            store.pauseQualityCueAnalysis(userInitiated: true)
            let rows: [(String, Set<QualityCueKind>, Int)] = [
                ("high-iso", [.highISO], (count + 1) / 2),
                ("slow-shutter", [.slowShutter], (count + 4) / 5),
                ("either-metadata", [.highISO, .slowShutter], (0..<count).filter { $0.isMultiple(of: 2) || $0.isMultiple(of: 5) }.count),
                ("unmeasured-clipping", [.highlightClipping], 0),
                ("none", [], count)
            ]
            for (name, cues, expected) in rows {
                try report.measure(name: "cue.switch.\(name)", count: count, prepare: {
                    store.filter.selectedQualityCues = cues == [.shadowClipping] ? [.highISO] : [.shadowClipping]
                }) {
                    store.filter.selectedQualityCues = cues
                }
                XCTAssertEqual(store.visibleIndices.count, expected)
                let reference = items.indices.filter { index in
                    cues.isEmpty || CameraQualityWarning.warnings(for: items[index], analysis: nil,
                        preferences: store.qualityCuePreferences).contains { cues.contains($0.kind) }
                }
                XCTAssertEqual(store.visibleIndices, reference)
            }
            try report.measure(name: "cue.first-use.high-iso", count: count, prepare: {
                store.filter.selectedQualityCues = []
                store.items = items
                store.rebuildDerivedDataForTesting()
            }) { store.filter.selectedQualityCues = [.highISO] }
            XCTAssertEqual(store.visibleIndices.count, (count + 1) / 2)
            store.setSelection(Set(stride(from: 0, to: count, by: 10)))
            let selected = store.selectedIndices
            try report.measure(name: "cue.switch.high-iso.with-selection", count: count, prepare: {
                store.filter.selectedQualityCues = [.highISO, .slowShutter]
            }) { store.filter.selectedQualityCues = [.highISO] }
            XCTAssertEqual(store.selectedIndices, selected)
            store.clearSelection()
            store.isGroupingEnabled = false
            try report.measure(name: "cue.switch.high-iso.ungrouped", count: count, prepare: {
                store.filter.selectedQualityCues = [.slowShutter]
            }) { store.filter.selectedQualityCues = [.highISO] }
            XCTAssertEqual(store.visibleGroups.count, 1)
            var ids: Set<String> = []
            try report.measure(name: "legacy.classify-and-build-ids", count: count) {
                ids = Set(items.lazy.filter { item in
                    store.qualityCues(for: item).contains { $0.kind == .highISO }
                }.map(\.id))
            }
            XCTAssertEqual(ids.count, (count + 1) / 2)
            store.beginTerminationPreparation()
        }
        try report.finish()
    }
}
