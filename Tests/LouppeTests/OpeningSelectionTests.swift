import AppKit
import SwiftUI
import XCTest
@testable import Louppe

/// Compares the public entry points used by Opening and Ready thumbnail controls.
/// Fixtures have no access to personal preferences, saved sessions or media.
@MainActor
final class OpeningSelectionTests: XCTestCase {
    func testInitialShiftIncludesImplicitCurrentAndKeepsItAsAnchor() throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let ready = try fixture.readyStore(count: 8)
        defer { ready.beginTerminationPreparation() }
        for initial in [0, 3] {
            ready.setIndex(initial)
            let opening = makeOpening(ready, initial: initial)
            click(6, modifiers: .shift, opening: opening, ready: ready)
            assertState(opening, ready, current: initial, selected: Set(initial...6))
            click(1, modifiers: .shift, opening: opening, ready: ready)
            assertState(opening, ready, current: initial, selected: Set(min(initial, 1)...max(initial, 1)))
        }
    }

    func testInitialCommandIncludesImplicitCurrentAndCannotToggleAwayLastItem() throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let ready = try fixture.readyStore(count: 8)
        defer { ready.beginTerminationPreparation() }
        for initial in [0, 3] {
            ready.setIndex(initial)
            let opening = makeOpening(ready, initial: initial)
            click(initial, modifiers: .command, opening: opening, ready: ready)
            assertState(opening, ready, current: initial, selected: [])
            click(6, modifiers: .command, opening: opening, ready: ready)
            assertState(opening, ready, current: initial, selected: [initial, 6])
        }
    }

    func testCurrentRemovalAndRepeatedRangesUseSurvivingCurrent() throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let ready = try fixture.readyStore(count: 8)
        defer { ready.beginTerminationPreparation() }
        ready.setIndex(3)
        let opening = makeOpening(ready, initial: 3)
        click(1, modifiers: .shift, opening: opening, ready: ready)
        assertState(opening, ready, current: 3, selected: [1, 2, 3])
        click(3, modifiers: .command, opening: opening, ready: ready)
        assertState(opening, ready, current: 1, selected: [1, 2])
        click(5, modifiers: .shift, opening: opening, ready: ready)
        assertState(opening, ready, current: 1, selected: Set(1...5))
        click(1, modifiers: .command, opening: opening, ready: ready)
        assertState(opening, ready, current: 2, selected: Set(2...5))
        click(4, modifiers: [.shift, .command], opening: opening, ready: ready)
        assertState(opening, ready, current: 2, selected: [2, 3, 4])
    }

    func testClearAndPlainNavigationReestablishImplicitCurrentForModifiers() throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let ready = try fixture.readyStore(count: 8)
        defer { ready.beginTerminationPreparation() }
        let opening = makeOpening(ready, initial: 0)
        click(4, modifiers: [], opening: opening, ready: ready)
        assertState(opening, ready, current: 4, selected: [])
        click(6, modifiers: .shift, opening: opening, ready: ready)
        XCTAssertTrue(opening.clearSelection())
        ready.clearSelection()
        assertState(opening, ready, current: 4, selected: [])
        XCTAssertFalse(opening.clearSelection())
        click(1, modifiers: .shift, opening: opening, ready: ready)
        assertState(opening, ready, current: 4, selected: Set(1...4))
        XCTAssertTrue(opening.clearSelection())
        ready.clearSelection()
        click(7, modifiers: .command, opening: opening, ready: ready)
        assertState(opening, ready, current: 4, selected: [4, 7])
        opening.moveCurrent(by: 1)
        ready.setIndex(5)
        assertState(opening, ready, current: 5, selected: [])
    }

    func testNonzeroPairedPhysicalStartHandsOffBothFilesAndCurrent() throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let ready = try fixture.readyStore(count: 8)
        defer { ready.beginTerminationPreparation() }
        let jpeg = ready.items[3].primaryURL
        let raw = fixture.root.appendingPathComponent("PHOTO_003.RAF")
        try FileManager.default.copyItem(at: jpeg, to: raw)
        ready.items[3] = PhotoItem(id: raw.lastPathComponent, primaryURL: raw, pairedURL: jpeg,
            captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
        ready.rebuildDerivedDataForTesting()
        ready.setIndex(3)
        let opening = OpeningSessionState(snapshot: .init(items: ready.items), viewMode: .grid,
            sourceAccess: nil, initialPhysicalFileID: jpeg.lastPathComponent)
        XCTAssertEqual(opening.currentIndex, 3)
        XCTAssertNil(opening.handoff().currentPhysicalFileID, "Automatic positioning is not user intent")
        click(6, modifiers: .command, opening: opening, ready: ready)
        assertState(opening, ready, current: 3, selected: [3, 6])
        let handoff = opening.handoff(validatedItems: ready.items)
        XCTAssertEqual(handoff.currentPhysicalFileID, raw.lastPathComponent)
        XCTAssertEqual(handoff.selectedPhysicalFileIDs, [raw.lastPathComponent, jpeg.lastPathComponent, "PHOTO_006.JPG"])
        XCTAssertEqual(opening.items.map(\.contentRevision), ready.items.map(\.contentRevision))
        XCTAssertTrue(ready.items.allSatisfy { $0.rating == .undecided })
    }

    func testMountedOpeningShiftSelectionBesideInfo() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let ready = try fixture.readyStore(count: 8)
        defer { ready.beginTerminationPreparation() }
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for scheme in [ColorScheme.light, .dark] {
                ready.setIndex(0)
                let opening = makeOpening(ready, initial: 0)
                let store = fixture.store()
                store.showBrowser = false
                store.showMetadataPanel = true
                store.presentOpeningSessionForTesting(opening)
                let host = NSHostingView(rootView: SessionView(store: store)
                    .environment(\.accessibilityEnabled, true)
                    .environment(\.layoutDirection, direction).preferredColorScheme(scheme))
                let window = SelectionInteractionFixture.mount(host, size: CGSize(width: 1000, height: 560))
                defer { store.beginTerminationPreparation(); window.contentView = nil; window.close() }
                try await SelectionInteractionFixture.settle(host)
                // The public entry point used by OpeningCell; never fake a
                // system-wide Shift state or take the foreground desktop.
                click(2, modifiers: .shift, opening: opening, ready: ready)
                try await SelectionInteractionFixture.settle(host)
                try fixture.capture(host, name: "opening-shift-\(direction)-\(scheme)")
                assertState(opening, ready, current: 0, selected: [0, 1, 2])
                XCTAssertTrue(store.items.isEmpty, "Opening never publishes authoritative inventory")
                XCTAssertEqual(opening.items.map(\.contentRevision), ready.items.map(\.contentRevision))
                XCTAssertTrue(opening.items.allSatisfy { $0.rating == .undecided })
            }
        }
    }

    func testSmallModifierSelectionsRemainBoundedAt100kItems() {
        let items = (0..<100_000).map { index in
            PhotoItem(primaryFile: PhotoFile(id: "item-\(index)",
                url: URL(fileURLWithPath: "/disposable-selection/\(index).JPG"),
                captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1))
        }
        let opening = OpeningSessionState(snapshot: .init(items: items), viewMode: .grid, sourceAccess: nil,
            initialPhysicalFileID: "item-90000")
        let start = ContinuousClock.now
        for _ in 0..<1_000 {
            opening.select("item-90002", extending: true)
            opening.select("item-90000", toggling: true)
            opening.select("item-90000")
        }
        let elapsed = start.duration(to: .now)
        print("Opening 100k: 3000 selection commands \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(2), "Small selections must not scan or index the 100k inventory per click")
        XCTAssertEqual(opening.currentItem?.id, "item-90000")
        XCTAssertTrue(opening.selectedIDs.isEmpty)
        XCTAssertEqual(opening.items.count, 100_000)
    }

    private func makeOpening(_ ready: SessionStore, initial: Int) -> OpeningSessionState {
        OpeningSessionState(snapshot: .init(items: ready.items), viewMode: .grid, sourceAccess: nil,
                            initialPhysicalFileID: ready.items[initial].primaryFile.id)
    }

    private func click(_ index: Int, modifiers: NSEvent.ModifierFlags,
                       opening: OpeningSessionState, ready: SessionStore) {
        opening.select(ready.items[index].id, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
        ready.handleThumbnailClick(at: index, modifiers: modifiers) { ready.setIndex(index) }
    }

    private func assertState(_ opening: OpeningSessionState, _ ready: SessionStore,
                             current: Int, selected: Set<Int>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ready.currentIndex, current, file: file, line: line)
        XCTAssertEqual(ready.selectedIndices, selected, file: file, line: line)
        XCTAssertEqual(opening.currentItem?.id, ready.currentItem?.id, file: file, line: line)
        XCTAssertEqual(opening.selectedIDs, Set(selected.map { ready.items[$0].id }), file: file, line: line)
        let effective = opening.selectedIDs.isEmpty ? Set([opening.currentItem!.id]) : opening.selectedIDs
        XCTAssertEqual(effective, Set(ready.effectiveSelection.map { ready.items[$0].id }), file: file, line: line)
        let handoff = opening.handoff()
        XCTAssertEqual(handoff.currentPhysicalFileID, ready.currentItem?.primaryFile.id, file: file, line: line)
        XCTAssertEqual(handoff.selectedPhysicalFileIDs,
            Set(selected.flatMap { ready.items[$0].individualFiles.map(\.id) }), file: file, line: line)
    }
}
