#if LOUPPE_TEST_SEAMS
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

/// Counts the store's publication turns. Each turn redraws every store
/// observer: toolbar, menus, Info and every realized Browser or Grid tile.
@MainActor
final class PublicationTurnTests: XCTestCase {
    func testCachedGalleryStepPublishesOnce() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("A WindowServer screen is required to mount Gallery") }
        let fixture = try await GalleryFixture(count: 12)
        defer { fixture.close() }
        fixture.store.goNext()
        try await fixture.settle(at: 1)
        // Both photos are decoded now; returning to the first is a cached step.
        let turns = fixture.store.publicationTurnsForTesting
        fixture.rowBodies = []
        fixture.store.goPrevious()
        try await fixture.settle(at: 0)
        let stepTurns = fixture.store.publicationTurnsForTesting - turns
        let rows = Set(fixture.rowBodies).count
        print("PublicationTurnTests cached step: \(stepTurns) store turns, \(fixture.rowBodies.count) Browser row bodies, \(rows) rows")
        XCTAssertGreaterThan(rows, 0)
        XCTAssertEqual(stepTurns, 1, "Only the current-photo change may redraw the window")
        XCTAssertEqual(fixture.rowBodies.count, rows, "Each realized Browser row renders once per cached step")
        await fixture.finish()
    }

    func testUncachedGalleryStepPublishesOnce() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("A WindowServer screen is required to mount Gallery") }
        let fixture = try await GalleryFixture(count: 12)
        defer { fixture.close() }
        fixture.gate.hold(fixture.store.items[1].primaryURL.lastPathComponent)
        let turns = fixture.store.publicationTurnsForTesting
        fixture.rowBodies = []
        fixture.store.goNext()
        // The toolbar spinner and the zoom pill still follow the decode.
        try await fixture.waitUntil {
            fixture.gate.waiters == 1 && fixture.store.fullImageLoads == 1
                && fixture.store.currentPhotoRepresentation == .loadingPreview
        }
        fixture.gate.open()
        try await fixture.settle(at: 1)
        let stepTurns = fixture.store.publicationTurnsForTesting - turns
        print("PublicationTurnTests uncached step: \(stepTurns) store turns, \(fixture.rowBodies.count) Browser row bodies, \(Set(fixture.rowBodies).count) rows")
        XCTAssertEqual(stepTurns, 1, "Decode progress and the fitted scale must not redraw the window")
        await fixture.finish()
    }

    func testArchivePositionFlushPublishesNothingWhenUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PublicationTurnArchive-\(UUID())")
        let media = root.appendingPathComponent("media")
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["A", "B"] {
            try FileManager.default.createDirectory(at: media.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["root.txt", "A/one.txt", "B/two.txt"] {
            try Data(file.utf8).write(to: media.appendingPathComponent(file))
        }
        let (defaults, removeDefaults) = try disabledCueDefaults()
        defer { removeDefaults() }
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
            saveTrailingDelay: 60, saveMaximumDelay: 60, reviewDefaults: defaults,
            archiveNavigationPersistence: ArchiveNavigationPersistence(fileURL: root.appendingPathComponent("navigation.json")))
        store.openFolder(media)
        try await waitUntil { if case .ready = store.phase { return true }; return false }
        XCTAssertNotNil(store.archiveNavigationRootIdentity)
        await store.flushArchiveNavigation()
        try await quiet()
        XCTAssertNil(store.archiveNavigationWarning)

        let turns = store.publicationTurnsForTesting
        await store.flushArchiveNavigation()
        try await quiet()
        let flushTurns = store.publicationTurnsForTesting - turns
        print("PublicationTurnTests archive flush: \(flushTurns) store turns")
        XCTAssertEqual(flushTurns, 0, "A successful write that changes no warning must not redraw the window")
        store.beginTerminationPreparation()
        _ = await store.saveSessionForTermination()
    }

    func testQualityCueWalkDoesNotPublishStore() async throws {
        let count = 8
        let (store, cleanup) = try cueStore(count: count)
        defer { cleanup() }
        try await quiet()

        var cuePublications = 0
        let subscription = store.qualityCuePublication.objectWillChange.sink { _ in cuePublications += 1 }
        defer { subscription.cancel() }
        let turns = store.publicationTurnsForTesting
        store.startQualityCueAnalysis()
        try await waitUntil { store.qualityCueEvidence.count == count }
        try await quiet()
        let walkTurns = store.publicationTurnsForTesting - turns
        print("PublicationTurnTests cue walk: \(walkTurns) store turns, \(cuePublications) cue publications for \(count / 2) batches")
        XCTAssertEqual(walkTurns, 0, "Without a cue filter the walk must not redraw the window")
        XCTAssertEqual(cuePublications, count / 2, "Cue readers update once per batch")
        XCTAssertEqual(store.qualityCueCoverageCountsForTesting.measured, count)
    }

    func testCueIconsAndCoverageFollowTheWalkWithoutStorePublication() async throws {
        guard NSScreen.main != nil else { throw XCTSkip("A WindowServer screen is required to mount cue views") }
        let (store, cleanup) = try cueStore(count: 2)
        defer { cleanup() }
        let host = NSHostingView(rootView: VStack {
            QualityCueCoverageText(store: store)
            QualityCueTileIcons(store: store, item: store.items[0])
        }.environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await quiet()
        host.layoutSubtreeIfNeeded()
        let uncheckedSummary = store.qualityCueCoverageSummary
        XCTAssertTrue(accessibilityTexts(in: host).contains(uncheckedSummary))
        XCTAssertFalse(accessibilityTexts(in: host).contains { $0.hasPrefix("Quality cues for") })

        let turns = store.publicationTurnsForTesting
        store.startQualityCueAnalysis()
        try await waitUntil { store.qualityCueEvidence.count == 2 }
        let checkedSummary = store.qualityCueCoverageSummary
        XCTAssertNotEqual(checkedSummary, uncheckedSummary)
        try await waitUntil {
            host.layoutSubtreeIfNeeded()
            let texts = accessibilityTexts(in: host)
            return texts.contains(checkedSummary) && texts.contains { $0.hasPrefix("Quality cues for") }
        }
        XCTAssertEqual(store.publicationTurnsForTesting - turns, 0)
    }

    func testFingerprintOfFirstRatingPublishesNothingWithoutRecoveryRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PublicationTurnFingerprint-\(UUID())")
        let media = root.appendingPathComponent("media")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for index in 0..<2 { _ = try writePhoto(index: index, in: media) }
        let (defaults, removeDefaults) = try disabledCueDefaults()
        defer { removeDefaults() }
        let verified = TurnCallCounter()
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: root.appendingPathComponent("backups")),
            saveTrailingDelay: 60, saveMaximumDelay: 60, reviewDefaults: defaults,
            sessionContentVerification: { file, _ in
                verified.increment()
                return SessionContentProof(identity: try SessionContentVerifier.validateIdentity(file),
                                           sha256: String(repeating: "0", count: 64))
            })
        store.openFolder(media)
        try await waitUntil { if case .ready = store.phase { return true }; return false }
        try await quiet()
        XCTAssertTrue(store.sessionRecoveryEntries.isEmpty)
        defer { store.beginTerminationPreparation() }

        store.rate(.yes, at: 0)
        // The rating's own turn is not counted; only what the hash adds.
        let turns = store.publicationTurnsForTesting
        try await waitUntil(timeout: .seconds(10)) { verified.count == 1 && store.sessionContentCheck == .finished }
        try await quiet()
        let fingerprintTurns = store.publicationTurnsForTesting - turns
        print("PublicationTurnTests fingerprint: \(fingerprintTurns) store turns")
        XCTAssertEqual(fingerprintTurns, 0, "Fingerprint progress has no reader without recovery records")
    }

    /// Every photo measures with heavy highlight clipping, so each gets a cue.
    private func cueStore(count: Int) throws -> (SessionStore, () -> Void) {
        let name = "PublicationTurnTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        CameraQualityWarningPreferences().save(to: defaults)
        let store = SessionStore(reviewDefaults: defaults, qualityCueMeasurement: { item in
            QualityCueEvidence(item: item, analysis: HistogramAnalysis(
                bins: [], sampleCount: 100, shadowCount: 0, highlightCount: 50,
                width: 10, height: 10), source: .renderedPreview)
        }, qualityCueResources: { .init(lowPower: false, thermal: .nominal) }, qualityCueRest: { _ in })
        store.items = (0..<count).map { index in
            let id = String(format: "TURN_CUE_%04d.JPG", index)
            return PhotoItem(primaryFile: PhotoFile(
                id: id, url: URL(fileURLWithPath: "/private/tmp/louppe-publication-turns-synthetic/\(id)"),
                captureDate: Date(timeIntervalSince1970: Double(index)),
                cameraModel: nil, lensModel: nil, iso: 100, fileSize: 1))
        }
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        return (store, {
            store.beginTerminationPreparation()
            defaults.removePersistentDomain(forName: name)
        })
    }

    /// Static text speaks its AXValue; controls use AXLabel.
    private func accessibilityTexts(in root: NSView) -> [String] {
        var texts: [String] = []
        var visited: Set<ObjectIdentifier> = []
        func walk(_ value: Any) {
            guard let object = value as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return }
            for name in ["accessibilityLabel", "accessibilityValue"] {
                let selector = NSSelectorFromString(name)
                if object.responds(to: selector),
                   let text = object.perform(selector)?.takeUnretainedValue() as? String, !text.isEmpty {
                    texts.append(text)
                }
            }
            if let accessible = object as? any NSAccessibilityProtocol {
                for child in accessible.accessibilityChildren() ?? [] { walk(child) }
            }
            if let view = object as? NSView {
                for child in NSAccessibility.unignoredChildren(from: [view]) { walk(child) }
                for child in view.subviews { walk(child) }
            }
        }
        for child in NSAccessibility.unignoredChildren(from: [root]) { walk(child) }
        return texts
    }

    private func disabledCueDefaults() throws -> (UserDefaults, () -> Void) {
        let name = "PublicationTurnTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        // Cue publications have their own test; here only navigation may publish.
        CameraQualityWarningPreferences(isEnabled: false).save(to: defaults)
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private func quiet() async throws {
        try await Task.sleep(for: .milliseconds(300))
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Condition did not settle before deadline")
                throw NSError(domain: "PublicationTurnTests", code: 1)
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Browser beside Gallery, as SessionView lays them out, with a gated decoder
/// for the Fit and the Browser row bodies recorded.
@MainActor
private final class GalleryFixture {
    let root = URL(fileURLWithPath: "/private/tmp/louppe-publication-turns-\(UUID())", isDirectory: true)
    let defaultsName = "PublicationTurnTests.\(UUID())"
    let store: SessionStore
    let gate: TurnDecodeGate
    let pipeline: ImagePipeline
    let host: NSView
    let window: NSWindow
    var rowBodies: [String] = []
    private var isClosed = false

    init(count: Int) async throws {
        _ = NSApplication.shared
        let root = self.root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        CameraQualityWarningPreferences(isEnabled: false).save(to: defaults)
        let store = SessionStore(saveTrailingDelay: 60, saveMaximumDelay: 60, reviewDefaults: defaults)
        self.store = store
        store.items = try (0..<count).map { try writePhoto(index: $0, in: root) }
        store.rebuildDerivedDataForTesting()
        store.phase = .ready
        store.viewMode = .gallery
        store.showBrowser = true
        store.showMetadataPanel = false
        let gate = TurnDecodeGate()
        self.gate = gate
        let pipeline = ImagePipeline(testingDiskCacheRoot: root.appendingPathComponent("cache")) { url, bound in
            if bound != ImagePipeline.thumbPixelSize { gate.waitIfHeld(url.lastPathComponent) }
            return ImagePipeline.decodeImage(url: url, maxPixel: bound)
        }
        self.pipeline = pipeline
        let content = HStack(spacing: 0) {
            BrowserView(store: store).frame(width: BrowserView.width)
            Divider()
            GalleryView(store: store, imagePipeline: pipeline)
        }
        host = NSHostingView(rootView: content)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 720),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        BrowserRow.didEvaluateBody = { [weak self] id in self?.rowBodies.append(id) }
        try await settle(at: 0)
    }

    /// Fitted detail shown, scale measured, spinner off, then a quiet period
    /// so trailing publications of the step are counted too.
    func settle(at index: Int) async throws {
        try await waitUntil {
            store.currentIndex == index && store.currentPhotoRepresentation == .preview
                && store.displayedPhotoZoomScale != nil && store.fullImageLoads == 0
        }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Gallery did not settle before deadline")
                throw NSError(domain: "PublicationTurnTests", code: 2)
            }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func finish() async {
        gate.open()
        await pipeline.waitForPendingDiskWrites()
        close()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        gate.open()
        BrowserRow.didEvaluateBody = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        store.beginTerminationPreparation()
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class TurnDecodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var held: String?
    private var waiting = 0

    var waiters: Int { lock.withLock { waiting } }

    func hold(_ name: String) { lock.withLock { held = name } }

    func waitIfHeld(_ name: String) {
        let holds = lock.withLock { () -> Bool in
            guard held == name else { return false }
            waiting += 1
            return true
        }
        guard holds else { return }
        _ = release.wait(timeout: .now() + 10)
        lock.withLock { waiting -= 1 }
    }

    func open() {
        let count = lock.withLock { () -> Int in
            held = nil
            return waiting
        }
        for _ in 0..<count { release.signal() }
    }
}

private final class TurnCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

private func writePhoto(index: Int, in folder: URL) throws -> PhotoItem {
    let name = String(format: "TURN_%04d.JPG", index)
    let url = folder.appendingPathComponent(name)
    let width = 96
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: width, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2 + 0.05 * CGFloat(index % 10), green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: width))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return PhotoItem(id: name, primaryURL: url, pairedURL: nil,
                     captureDate: Date(timeIntervalSince1970: Double(index)),
                     cameraModel: nil, lensModel: nil, fileSize: 1)
}
#endif
