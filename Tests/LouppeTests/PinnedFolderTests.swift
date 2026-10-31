import Foundation
import XCTest
@testable import Louppe

/// Only disposable /private/tmp folders; bookmarks are injectable capabilities,
/// while identities, renames, replacement and persistence use real filesystem I/O.
@MainActor
final class PinnedFolderPersistenceTests: XCTestCase {
    func testSelectedFolderPinsWithoutSessionAndPersistsWithoutSourceWrites() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let originalNames = try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).sorted()
        let originalBytes = try originalNames.map { try Data(contentsOf: fixture.folder.appendingPathComponent($0)) }
        let store = PinnedFoldersStore(storageDirectory: fixture.storage,
                                       persistence: fixture.worker(), observesSystemChanges: false)

        let selectedID = await store.pinSelectedFolder(url: fixture.folder)
        let id = try XCTUnwrap(selectedID)
        XCTAssertEqual(store.folders.first?.identity, fixture.identity)
        XCTAssertEqual(store.folders.first?.availability, .available)
        XCTAssertNil(store.statusMessage)
        XCTAssertFalse(store.isWorking)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.document.path))

        let relaunched = fixture.worker()
        let restored = await relaunched.refresh()
        XCTAssertEqual(restored.folders.map(\.id), [id])
        let position = try await relaunched.position(for: fixture.identity)
        XCTAssertNil(position, "Selecting a folder must not invent review state")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).sorted(), originalNames)
        XCTAssertEqual(try originalNames.map { try Data(contentsOf: fixture.folder.appendingPathComponent($0)) }, originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent(".louppe_session.json").path))
    }

    func testSelectedFolderRepinKeepsIDPositionAndPinOrdering() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let worker = fixture.worker()
        let (id, _) = try await worker.pinSelectedFolder(url: fixture.folder)
        let position = try fixture.position()
        _ = try await worker.savePosition(position, for: fixture.identity)
        let other = fixture.root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let (otherID, _) = try await worker.pinSelectedFolder(url: other)

        let (repinnedID, snapshot) = try await worker.pinSelectedFolder(url: fixture.folder)
        XCTAssertEqual(repinnedID, id)
        XCTAssertEqual(snapshot.folders.map(\.id), [id, otherID])
        let saved = try await fixture.worker().position(for: fixture.identity)
        XCTAssertEqual(saved, position)
    }

    func testSelectedFolderWriteFailureRetainsPriorPinAndPosition() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let fault = PinnedFolderWriteFault()
        let worker = PinnedFoldersPersistence(storageDirectory: fixture.storage, operations: fixture.operations(), write: fault.write)
        let store = PinnedFoldersStore(storageDirectory: fixture.storage, persistence: worker, observesSystemChanges: false)
        let id = await store.pinSelectedFolder(url: fixture.folder)
        XCTAssertNotNil(id)
        let position = try fixture.position()
        _ = try await worker.savePosition(position, for: fixture.identity)
        let prior = try Data(contentsOf: fixture.document)
        let other = fixture.root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        fault.setFailure(true)

        let failedID = await store.pinSelectedFolder(url: other)
        XCTAssertNil(failedID)
        XCTAssertEqual(store.folders.map(\.id), [try XCTUnwrap(id)])
        XCTAssertNotNil(store.statusMessage)
        XCTAssertFalse(store.isWorking)
        XCTAssertEqual(try Data(contentsOf: fixture.document), prior)
        let saved = try await fixture.worker().position(for: fixture.identity)
        XCTAssertEqual(saved, position)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    func testSelectedFolderBookmarkFailureRetainsPriorRecords() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let (id, _) = try await fixture.worker().pinSelectedFolder(url: fixture.folder)
        let prior = try Data(contentsOf: fixture.document)
        let worker = fixture.worker(operations: fixture.operations(createFailure: true))
        do {
            _ = try await worker.pinSelectedFolder(url: fixture.folder)
            XCTFail("A selected folder needs a durable bookmark before pinning succeeds")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.document), prior)
        let snapshot = await worker.refresh()
        XCTAssertEqual(snapshot.folders.map(\.id), [id])
    }

    func testSelectedFolderReplacementDuringBookmarkCreationCannotChangePriorRecords() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let first = fixture.worker()
        let (id, _) = try await first.pinSelectedFolder(url: fixture.folder)
        let position = try fixture.position()
        _ = try await first.savePosition(position, for: fixture.identity)
        let prior = try Data(contentsOf: fixture.document)
        let base = fixture.operations()
        let moved = fixture.root.appendingPathComponent("Original")
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: base.resolve,
            create: { url in
                try FileManager.default.moveItem(at: fixture.folder, to: moved)
                try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: false)
                return try base.create(url)
            }, exists: base.exists, access: base.access)
        let worker = fixture.worker(operations: operations)
        do {
            _ = try await worker.pinSelectedFolder(url: fixture.folder)
            XCTFail("Identity captured before bookmark creation must still match afterward")
        } catch PinnedFolderError.changedIdentity {}
        XCTAssertEqual(try Data(contentsOf: fixture.document), prior)
        let snapshot = await worker.refresh()
        XCTAssertEqual(snapshot.folders.map(\.id), [id])
        XCTAssertEqual(snapshot.folders.first?.availability, .unavailable)
        let saved = try await worker.position(for: fixture.identity)
        XCTAssertEqual(saved, position)
    }

    func testSelectedReplacementIsANewPinWithoutOldPosition() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let worker = fixture.worker()
        let (oldID, _) = try await worker.pinSelectedFolder(url: fixture.folder)
        let position = try fixture.position()
        _ = try await worker.savePosition(position, for: fixture.identity)
        try FileManager.default.moveItem(at: fixture.folder, to: fixture.root.appendingPathComponent("Original"))
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: false)

        let (newID, snapshot) = try await worker.pinSelectedFolder(url: fixture.folder)
        XCTAssertNotEqual(newID, oldID)
        XCTAssertEqual(snapshot.folders.map(\.id), [newID, oldID])
        XCTAssertEqual(snapshot.folders.first?.availability, .available)
        XCTAssertEqual(snapshot.folders.last?.availability, .unavailable)
        let newIdentity = try XCTUnwrap(snapshot.folders.first?.identity)
        let newPosition = try await worker.position(for: newIdentity)
        XCTAssertNil(newPosition)
        let retained = try await worker.position(for: fixture.identity)
        XCTAssertEqual(retained, position)
    }

    func testSelectedFolderUsesExactGrantOffMainAndBalancesScopesOnFailure() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("Via"), withIntermediateDirectories: false)
        let granted = try XCTUnwrap(URL(string: fixture.root.absoluteString + "Via/../Photos/"))
        let recorder = PinnedFolderScopeRecorder()
        let base = fixture.operations(resolvedURL: granted)
        let original = granted.absoluteString
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: base.resolve,
            create: { url in
                XCTAssertFalse(Thread.isMainThread, "Bookmark I/O belongs to the persistence actor")
                XCTAssertEqual(url.absoluteString, original)
                XCTAssertGreaterThan(recorder.events.filter { $0.hasPrefix("start:") }.count,
                                     recorder.events.filter { $0.hasPrefix("stop:") }.count)
                return try base.create(url)
            }, exists: base.exists, access: recorder.access)
        let (id, _) = try await fixture.worker(operations: operations).pinSelectedFolder(url: granted)
        let failing = SecurityScopedFolderBookmarks.Operations(
            resolve: base.resolve, create: { _ in throw PinnedFolderTestFailure.injected },
            exists: base.exists, access: recorder.access)
        do { _ = try await fixture.worker(operations: failing).pinSelectedFolder(url: granted); XCTFail("Expected bookmark failure") }
        catch {}
        let (request, _) = try await fixture.worker(operations: operations).prepareOpen(id: id)
        XCTAssertEqual(request.authorityURL.absoluteString, original)
        XCTAssertTrue(recorder.events.allSatisfy { $0 == "start:" + original || $0 == "stop:" + original })
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("start:") }.count,
                       recorder.events.filter { $0.hasPrefix("stop:") }.count)
    }

    /// Opening a pin resolves and verifies only that pin, writes nothing when
    /// its record is unchanged, and keeps the other pins' last availability.
    func testOpeningAPinChecksOnlyThatPinAndWritesNothingWhenUnchanged() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let resolves = PinnedCallCounter()
        let writes = PinnedCallCounter()
        let base = fixture.operations()
        let counting = SecurityScopedFolderBookmarks.Operations(
            resolve: { resolves.increment(); return try base.resolve($0) },
            create: base.create, exists: base.exists, access: base.access)
        let worker = PinnedFoldersPersistence(storageDirectory: fixture.storage, operations: counting,
            write: { data, url in writes.increment(); try DurableFileIO.atomicWrite(data, to: url, fullSync: true) })
        let missing = fixture.root.appendingPathComponent("Missing")
        let other = fixture.root.appendingPathComponent("Other")
        for folder in [missing, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            _ = try await worker.pinSelectedFolder(url: folder)
        }
        let (id, _) = try await worker.pinSelectedFolder(url: fixture.folder)
        try FileManager.default.removeItem(at: missing)
        let refreshed = await worker.refresh()
        XCTAssertEqual(refreshed.folders.map(\.availability), [.available, .available, .unavailable])
        let resolvesBefore = resolves.value
        let writesBefore = writes.value

        let (request, snapshot) = try await worker.prepareOpen(id: id)
        XCTAssertEqual(resolves.value - resolvesBefore, 1, "only the opened pin's bookmark")
        XCTAssertEqual(writes.value, writesBefore, "an unchanged record needs no durable write")
        XCTAssertEqual(request.pinID, id)
        XCTAssertEqual(request.expectedIdentity, fixture.identity)
        XCTAssertEqual(snapshot.folders.map(\.id), refreshed.folders.map(\.id))
        XCTAssertEqual(snapshot.folders.map(\.availability), [.available, .available, .unavailable])
        XCTAssertGreaterThan(snapshot.revision, refreshed.revision)

        // A replaced folder at the pinned path is still refused.
        try FileManager.default.moveItem(at: fixture.folder, to: fixture.root.appendingPathComponent("Moved"))
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: false)
        do { _ = try await worker.prepareOpen(id: id); XCTFail("a same-path replacement must not open") }
        catch { XCTAssertEqual(error as? PinnedFolderError, .changedIdentity) }
        XCTAssertEqual(writes.value, writesBefore)
    }

    func testPinAndIndependentPositionsSurviveRelaunchAndUnpinKeepsPosition() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let position = try fixture.position()
        let worker = fixture.worker()
        let (id, initial) = try await worker.pin(url: fixture.folder, expectedIdentity: fixture.identity)
        XCTAssertEqual(initial.folders.map(\.id), [id])
        _ = try await worker.savePosition(position, for: fixture.identity)

        let relaunched = fixture.worker()
        let restored = await relaunched.refresh()
        XCTAssertEqual(restored.folders.first?.id, id)
        XCTAssertEqual(restored.folders.first?.availability, .available)
        let saved = try await relaunched.position(for: fixture.identity)
        XCTAssertEqual(saved, position)
        _ = try await relaunched.unpin(id: id)
        let finalWorker = fixture.worker()
        let final = await finalWorker.refresh()
        XCTAssertTrue(final.folders.isEmpty)
        let retained = try await finalWorker.position(for: fixture.identity)
        XCTAssertEqual(retained, position)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.appendingPathComponent(".louppe_session.json").path))
    }

    func testMissingFolderRetainsPinAndPositionAcrossRelaunch() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let worker = fixture.worker()
        let (id, _) = try await worker.pin(url: fixture.folder, expectedIdentity: fixture.identity)
        let position = try fixture.position()
        _ = try await worker.savePosition(position, for: fixture.identity)
        try FileManager.default.removeItem(at: fixture.folder)
        let relaunched = fixture.worker()
        let snapshot = await relaunched.refresh()
        XCTAssertEqual(snapshot.folders.first?.id, id)
        XCTAssertEqual(snapshot.folders.first?.availability, .unavailable)
        let saved = try await relaunched.position(for: fixture.identity)
        XCTAssertEqual(saved, position)
        do { _ = try await relaunched.prepareOpen(id: id); XCTFail("Absent folder must not open") }
        catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.path))
        let unpinned = try await relaunched.unpin(id: id)
        XCTAssertTrue(unpinned.folders.isEmpty, "Unavailable pins must remain removable")
    }

    func testSamePathReplacementCannotOpenOrReconnect() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let worker = fixture.worker()
        let (id, _) = try await worker.pin(url: fixture.folder, expectedIdentity: fixture.identity)
        let moved = fixture.root.appendingPathComponent("Original")
        try FileManager.default.moveItem(at: fixture.folder, to: moved)
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: false)
        let snapshot = await worker.refresh()
        XCTAssertEqual(snapshot.folders.first?.availability, .unavailable)
        do { _ = try await worker.prepareOpen(id: id); XCTFail("Same pathname is not identity") }
        catch {}
        do { _ = try await worker.prepareOpen(id: id, reconnectingWith: fixture.folder); XCTFail("Replacement grant must be refused") }
        catch { XCTAssertTrue(error is PinnedFolderError) }
        let (request, _) = try await worker.prepareOpen(id: id, reconnectingWith: moved)
        XCTAssertEqual(request.expectedIdentity, fixture.identity)
        XCTAssertEqual(request.authorityURL, moved)
        let relaunched = fixture.worker()
        let restored = await relaunched.refresh()
        XCTAssertEqual(restored.folders.first?.path, moved.path)
        XCTAssertEqual(restored.folders.first?.availability, .available)
    }

    func testRenamedFolderBookmarkRefreshKeepsStablePinAndPosition() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let first = fixture.worker()
        let (id, _) = try await first.pin(url: fixture.folder, expectedIdentity: fixture.identity)
        let position = try fixture.position()
        _ = try await first.savePosition(position, for: fixture.identity)
        let renamed = fixture.root.appendingPathComponent("Renamed")
        try FileManager.default.moveItem(at: fixture.folder, to: renamed)
        let operations = fixture.operations(resolvedURL: renamed, stale: true)
        let worker = fixture.worker(operations: operations)
        let snapshot = await worker.refresh()
        XCTAssertEqual(snapshot.folders.first?.id, id)
        XCTAssertEqual(snapshot.folders.first?.path, renamed.path)
        XCTAssertEqual(snapshot.folders.first?.availability, .available)
        let saved = try await worker.position(for: fixture.identity)
        XCTAssertEqual(saved, position)
        let (request, _) = try await worker.prepareOpen(id: id)
        XCTAssertEqual(request.authorityURL, renamed)
    }

    func testRevokedResolutionDoesNotFallBackToExistingPath() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let first = fixture.worker()
        let (id, _) = try await first.pin(url: fixture.folder, expectedIdentity: fixture.identity)
        let prior = try Data(contentsOf: fixture.document)
        let worker = fixture.worker(operations: fixture.operations(resolveFailure: true))
        let snapshot = await worker.refresh()
        XCTAssertEqual(snapshot.folders.first?.availability, .needsReconnect)
        do { _ = try await worker.prepareOpen(id: id); XCTFail("Never substitute a stored path for a failed bookmark") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.document), prior)
        let (request, _) = try await worker.prepareOpen(id: id, reconnectingWith: fixture.folder)
        XCTAssertEqual(request.expectedIdentity, fixture.identity)
    }

    func testFailedStaleRefreshPreservesWorkingBookmarkBytes() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let worker = fixture.worker()
        let (id, _) = try await worker.pin(url: fixture.folder, expectedIdentity: fixture.identity)
        let prior = try Data(contentsOf: fixture.document)
        let stale = fixture.worker(operations: fixture.operations(stale: true, createFailure: true))
        let snapshot = await stale.refresh()
        XCTAssertEqual(snapshot.folders.first?.availability, .available)
        XCTAssertEqual(try Data(contentsOf: fixture.document), prior)
        let (request, _) = try await stale.prepareOpen(id: id)
        XCTAssertEqual(request.expectedIdentity, fixture.identity)
    }

    func testFailedReconnectBookmarkWriteRetainsOldGrantAndPin() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let worker = fixture.worker()
        let (id, _) = try await worker.pin(url: fixture.folder, expectedIdentity: fixture.identity)
        let prior = try Data(contentsOf: fixture.document)
        let failed = fixture.worker(operations: fixture.operations(createFailure: true))
        do { _ = try await failed.prepareOpen(id: id, reconnectingWith: fixture.folder); XCTFail("Reconnect must save its grant") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.document), prior)
        let snapshot = await failed.refresh()
        XCTAssertEqual(snapshot.folders.first?.id, id)
    }

    func testFailedWriteRetainsPriorPinAndPosition() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let fault = PinnedFolderWriteFault()
        let worker = PinnedFoldersPersistence(storageDirectory: fixture.storage, operations: fixture.operations(), write: fault.write)
        let (id, _) = try await worker.pin(url: fixture.folder, expectedIdentity: fixture.identity)
        let position = try fixture.position()
        _ = try await worker.savePosition(position, for: fixture.identity)
        let prior = try Data(contentsOf: fixture.document)
        fault.setFailure(true)
        do { _ = try await worker.unpin(id: id); XCTFail("Write failure cannot report successful unpin") }
        catch {}
        let changed = PinnedFolderPosition(current: nil, browser: nil, grid: nil)
        do { _ = try await worker.savePosition(changed, for: fixture.identity); XCTFail("Write failure cannot report saved position") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.document), prior)
        let saved = try await worker.position(for: fixture.identity)
        XCTAssertEqual(saved, position)
        let snapshot = await worker.refresh()
        XCTAssertEqual(snapshot.folders.first?.id, id)
        fault.setFailure(false)
        let unpinned = try await worker.unpin(id: id)
        XCTAssertTrue(unpinned.folders.isEmpty)
    }

    func testCorruptPrimaryShowsPreviousRecordsWithoutOverwritingEitherCopy() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let first = fixture.worker()
        let (id, _) = try await first.pin(url: fixture.folder, expectedIdentity: fixture.identity)
        // A position checkpoint secures the pin in the previous document.
        _ = try await first.savePosition(try fixture.position(), for: fixture.identity)
        let corrupt = Data("broken document".utf8)
        try corrupt.write(to: fixture.document)
        let previous = try Data(contentsOf: fixture.document.appendingPathExtension("previous"))
        let worker = fixture.worker()
        let snapshot = await worker.refresh()
        XCTAssertEqual(snapshot.folders.first?.id, id)
        XCTAssertNotNil(snapshot.message)
        do { _ = try await worker.unpin(id: id); XCTFail("Unreadable primary must block overwriting prior records") }
        catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.document), corrupt)
        XCTAssertEqual(try Data(contentsOf: fixture.document.appendingPathExtension("previous")), previous)
    }

    func testOversizeReadAndInvalidPositionRetainPriorRecords() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let first = fixture.worker()
        let (id, _) = try await first.pin(url: fixture.folder, expectedIdentity: fixture.identity)
        let position = try fixture.position()
        _ = try await first.savePosition(position, for: fixture.identity)
        let invalid = PinnedFolderPosition(current: position.current,
                                          browser: .init(anchor: try XCTUnwrap(position.current), topOffset: .infinity), grid: nil)
        do { _ = try await first.savePosition(invalid, for: fixture.identity); XCTFail("Nonfinite viewport must not persist") }
        catch {}
        let saved = try await first.position(for: fixture.identity)
        XCTAssertEqual(saved, position)
        try Data(repeating: 0, count: PinnedFoldersPersistence.maximumBytes + 1).write(to: fixture.document)
        let snapshot = await fixture.worker().refresh()
        XCTAssertEqual(snapshot.folders.first?.id, id)
        XCTAssertNotNil(snapshot.message)
        XCTAssertEqual(try Data(contentsOf: fixture.document).count, PinnedFoldersPersistence.maximumBytes + 1)
    }

    func testStoreInjectionPublishesWithoutWelcomeAndReportsWriteFailure() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let fault = PinnedFolderWriteFault()
        let worker = PinnedFoldersPersistence(storageDirectory: fixture.storage, operations: fixture.operations(), write: fault.write)
        let store = PinnedFoldersStore(storageDirectory: fixture.storage, persistence: worker, observesSystemChanges: false)
        let id = await store.pin(url: fixture.folder, expectedIdentity: fixture.identity)
        XCTAssertNotNil(id)
        XCTAssertEqual(store.folders.first?.id, id)
        fault.setFailure(true)
        let saved = await store.savePosition(try fixture.position(), for: fixture.identity)
        XCTAssertFalse(saved)
        XCTAssertNotNil(store.statusMessage)
        XCTAssertFalse(store.isWorking)
        let independent = PinnedFoldersStore(storageDirectory: fixture.storage,
                                             persistence: fixture.worker(), observesSystemChanges: false)
        await independent.refresh()
        XCTAssertEqual(independent.folders.first?.id, id)
    }

    func testScopeAuthorityUsesExactGrantedURLAndBalancesLeases() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let via = fixture.root.appendingPathComponent("Via")
        try FileManager.default.createDirectory(at: via, withIntermediateDirectories: false)
        let granted = try XCTUnwrap(URL(string: fixture.root.absoluteString + "Via/../Photos/"))
        let recorder = PinnedFolderScopeRecorder()
        let base = fixture.operations(resolvedURL: granted)
        let original = granted.absoluteString
        let operations = SecurityScopedFolderBookmarks.Operations(
            resolve: base.resolve,
            create: { url in
                guard url.absoluteString == original else { throw PinnedFolderTestFailure.injected }
                return try base.create(url)
            }, exists: base.exists, access: recorder.access)
        let worker = fixture.worker(operations: operations)
        let (id, _) = try await worker.pin(url: granted, expectedIdentity: fixture.identity)
        let (request, _) = try await worker.prepareOpen(id: id)
        XCTAssertEqual(request.authorityURL.absoluteString, original)
        XCTAssertTrue(recorder.events.allSatisfy { $0 == "start:" + original || $0 == "stop:" + original })
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("start:") }.count,
                       recorder.events.filter { $0.hasPrefix("stop:") }.count)
    }

    func testLiveFoundationBookmarkRoundTrip() async throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        // A real Foundation bookmark on a real temporary directory. No picker or
        // native UI; sandbox grant revocation remains deterministically injected.
        let worker = fixture.worker(operations: .live)
        let (id, _) = try await worker.pin(url: fixture.folder, expectedIdentity: fixture.identity)
        let relaunched = fixture.worker(operations: .live)
        let (request, _) = try await relaunched.prepareOpen(id: id)
        XCTAssertTrue(request.expectedIdentity.matches(try SessionPersistence.SourceFolderIdentity.capture(at: request.authorityURL)))
    }
}

@MainActor
final class PinnedFolderPositionTests: XCTestCase {
    func testIndependentViewportOffsetsRestoreAgainstExactPhysicalRevisions() throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let position = try fixture.position()
        let candidates = [try fixture.anchor(fixture.first), try fixture.anchor(fixture.second)]
        let restored = try XCTUnwrap(position.restored(for: fixture.identity, expectedFolder: fixture.identity, candidates: candidates))
        XCTAssertEqual(restored.currentPhysicalFileID, "A.JPG")
        XCTAssertEqual(restored.browser?.physicalFileID, "A.JPG")
        XCTAssertEqual(restored.browser?.topOffset, -17.5)
        XCTAssertEqual(restored.grid?.physicalFileID, "B.JPG")
        XCTAssertEqual(restored.grid?.topOffset, 23)
    }

    func testRemovalFallsBackOnlyToSurvivingViewportAnchor() throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let position = try fixture.position()
        try FileManager.default.removeItem(at: fixture.first)
        let restored = try XCTUnwrap(position.restored(for: fixture.identity, expectedFolder: fixture.identity,
                                                     candidates: [try fixture.anchor(fixture.second)]))
        XCTAssertEqual(restored.currentPhysicalFileID, "B.JPG")
        XCTAssertNil(restored.browser)
        XCTAssertEqual(restored.grid?.topOffset, 23)
    }

    func testChangedRevisionOrSamePathReplacementCannotInheritPosition() throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let position = try fixture.position()
        try Data("Different length and contents".utf8).write(to: fixture.first)
        try FileManager.default.moveItem(at: fixture.second, to: fixture.folder.appendingPathComponent("Old-B.JPG"))
        try Data("second".utf8).write(to: fixture.second)
        let restored = try XCTUnwrap(position.restored(for: fixture.identity, expectedFolder: fixture.identity,
                                                     candidates: [try fixture.anchor(fixture.first), try fixture.anchor(fixture.second)]))
        XCTAssertNil(restored.currentPhysicalFileID)
        XCTAssertNil(restored.browser)
        XCTAssertNil(restored.grid)
    }

    func testDifferentFolderOrVolumeNeverRestoresPositions() throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let other = fixture.root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        let otherIdentity = PinnedFolderIdentity(source: try .capture(at: other))
        let position = try fixture.position()
        let candidates = [try fixture.anchor(fixture.first), try fixture.anchor(fixture.second)]
        XCTAssertNil(position.restored(for: otherIdentity, expectedFolder: fixture.identity, candidates: candidates))
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.identity)) as? [String: Any])
        fields["volumeUUIDString"] = "another-volume"
        let differentDrive = try JSONDecoder().decode(PinnedFolderIdentity.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertNil(position.restored(for: differentDrive, expectedFolder: fixture.identity, candidates: candidates))
    }

    func testAmbiguousHardLinksCannotBorrowViewportOrCurrent() throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let alias = fixture.folder.appendingPathComponent("Hardlink.JPG")
        try FileManager.default.linkItem(at: fixture.first, to: alias)
        let anchor = try fixture.anchor(fixture.first)
        let position = PinnedFolderPosition(current: anchor, browser: .init(anchor: anchor, topOffset: 9), grid: nil)
        let restored = try XCTUnwrap(position.restored(for: fixture.identity, expectedFolder: fixture.identity,
                                                     candidates: [anchor, try fixture.anchor(alias)]))
        XCTAssertNil(restored.currentPhysicalFileID)
        XCTAssertNil(restored.browser)
    }

    func testCtimeOnlyChangeCannotReusePositionWhenSizeAndMtimeArePreserved() throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let position = try fixture.position()
        let anchor = try XCTUnwrap(position.current)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(anchor)) as? [String: Any])
        var identity = try XCTUnwrap(fields["identity"] as? [String: Any])
        var change = try XCTUnwrap(identity["statusChangeTime"] as? [String: Any])
        change["seconds"] = try XCTUnwrap(change["seconds"] as? Int64) + 1
        identity["statusChangeTime"] = change
        fields["identity"] = identity
        let changed = try JSONDecoder().decode(PinnedFolderFileAnchor.self, from: JSONSerialization.data(withJSONObject: fields))
        let restored = try XCTUnwrap(position.restored(for: fixture.identity, expectedFolder: fixture.identity,
                                                     candidates: [changed]))
        XCTAssertNil(restored.currentPhysicalFileID)
        XCTAssertNil(restored.browser)
    }

    func testUUIDIdentityAllowsDeviceRemapButNotDifferentFolder() throws {
        let fixture = try PinnedFolderFixture()
        defer { fixture.remove() }
        let source = try SessionPersistence.SourceFolderIdentity.capture(at: fixture.folder)
        let remapped = source.remappingSourceSystemNumberForTesting(to: source.systemNumber &+ 1)
        XCTAssertEqual(fixture.identity.matches(remapped), source.volumeUUIDString != nil)
    }
}

private enum PinnedFolderTestFailure: Error { case injected }

private struct PinnedFolderFixture {
    let root: URL
    let folder: URL
    let storage: URL
    let first: URL
    let second: URL
    let identity: PinnedFolderIdentity
    var document: URL { storage.appendingPathComponent("PinnedFolders.json") }

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("LouppePins-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("Photos", isDirectory: true)
        storage = root.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        first = folder.appendingPathComponent("A.JPG")
        second = folder.appendingPathComponent("B.JPG")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        identity = PinnedFolderIdentity(source: try .capture(at: folder))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func worker(operations: SecurityScopedFolderBookmarks.Operations? = nil) -> PinnedFoldersPersistence {
        PinnedFoldersPersistence(storageDirectory: storage, operations: operations ?? self.operations())
    }
    func operations(resolvedURL: URL? = nil, resolveFailure: Bool = false,
                    stale: Bool = false, createFailure: Bool = false) -> SecurityScopedFolderBookmarks.Operations {
        .init(resolve: { data in
            guard !resolveFailure, let string = String(data: data, encoding: .utf8), let url = URL(string: string) else {
                throw PinnedFolderTestFailure.injected
            }
            return .init(url: resolvedURL ?? url, isStale: stale)
        }, create: {
            guard !createFailure else { throw PinnedFolderTestFailure.injected }
            return Data($0.absoluteString.utf8)
        }, exists: { FileManager.default.fileExists(atPath: $0.path) },
              access: .init(start: { _ in true }, stop: { _ in }))
    }
    func anchor(_ url: URL) throws -> PinnedFolderFileAnchor {
        .init(physicalFileID: url.lastPathComponent, identity: try FileOperationJournal.captureIdentity(at: url))
    }
    func position() throws -> PinnedFolderPosition {
        let current = try anchor(first)
        return .init(current: current, browser: .init(anchor: current, topOffset: -17.5),
                     grid: .init(anchor: try anchor(second), topOffset: 23))
    }
}

private final class PinnedCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class PinnedFolderWriteFault: @unchecked Sendable {
    private let lock = NSLock()
    private var fail = false
    func setFailure(_ enabled: Bool) { lock.withLock { fail = enabled } }
    func write(_ data: Data, _ url: URL) throws {
        if lock.withLock({ fail }) { throw POSIXError(.ENOSPC) }
        try DurableFileIO.atomicWrite(data, to: url, fullSync: true)
    }
}

private final class PinnedFolderScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    var access: SecurityScopedResourceAccess {
        .init(start: { [self] url in
            lock.withLock { recorded.append("start:" + url.absoluteString) }
            return true
        }, stop: { [self] url in lock.withLock { recorded.append("stop:" + url.absoluteString) } })
    }
}
