import Foundation
import XCTest
@testable import Louppe

@MainActor
final class ArchiveNavigationMemoryTests: XCTestCase {
    func testRoundTripKeepsIndependentPerFolderPositionsAndNeverWritesSource() async throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let index = try fixture.index()
        let position = try fixture.position(in: "2024/Trip")
        XCTAssertTrue(position.isValid, "fixture positions include complete physical revision evidence")
        let memory = ArchiveNavigationMemory(index: index, selectedFolderID: "2024/Trip",
            includesDescendants: false, expandedFolderIDs: ["", "2024"])
            .remembering(position, for: "2024/Trip", in: index)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.source.path).sorted()
        let rootIdentity = try fixture.rootIdentity()
        try await fixture.persistence().save(memory, for: rootIdentity)

        let restored = try await fixture.persistence().load(for: rootIdentity)
        XCTAssertEqual(restored, memory)
        XCTAssertEqual(restored?.selectedFolderID, "2024/Trip")
        XCTAssertEqual(restored?.position(for: "2024/Trip")?.browser?.topOffset, 12)
        XCTAssertEqual(restored?.position(for: "2024/Trip")?.grid?.topOffset, 35)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.source.path).sorted(), names)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent(".louppe_session.json").path))
        XCTAssertEqual(try Data(contentsOf: fixture.source.appendingPathComponent("2024/Trip/photo.JPG")), Data("unchanged original".utf8))
    }

    func testMissingMemoryIsOptionalAndDoesNotCreateAFile() async throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let loaded = try await fixture.persistence().load(for: fixture.rootIdentity())
        XCTAssertNil(loaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.document.path))
    }

    func testEntryMaterializationSkipsInvalidDuplicatesWithoutLosingTheValidPosition() throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let index = try fixture.index()
        let position = try fixture.position(in: "2024/Trip")
        let identity = try XCTUnwrap(index.node(for: "2024/Trip")?.identity)
        let anchor = try XCTUnwrap(position.current)
        let invalid = PinnedFolderPosition(current: anchor,
            browser: .init(anchor: anchor, topOffset: .nan), grid: nil)
        XCTAssertFalse(invalid.isValid)
        let good = ArchiveNavigationMemory.Entry(folderID: "2024/Trip", directoryIdentity: identity, position: position)
        let memory = ArchiveNavigationMemory(index: index, selectedFolderID: "2024/Trip", entries: [
            .init(folderID: "2024/Trip", directoryIdentity: identity, position: invalid), good, good
        ])
        XCTAssertEqual(memory.entries, [good])
        XCTAssertEqual(memory.position(for: "2024/Trip"), position)
    }

    func testReplacementAtSamePathDropsPositionAndFallsBackToVerifiedAncestor() throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let initial = try fixture.index()
        let original = ArchiveNavigationMemory(index: initial, selectedFolderID: "2024/Trip/Day",
            expandedFolderIDs: ["", "2024", "2024/Trip", "2024/Trip/Day"])
            .remembering(try fixture.position(in: "2024/Trip/Day"), for: "2024/Trip/Day", in: initial)
        let path = fixture.source.appendingPathComponent("2024/Trip/Day")
        try FileManager.default.moveItem(at: path, to: fixture.root.appendingPathComponent("retired-day"))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)

        let reconciled = original.reconciled(with: try fixture.index())
        XCTAssertEqual(reconciled.selectedFolderID, "2024/Trip")
        XCTAssertNil(reconciled.position(for: "2024/Trip/Day"))
        XCTAssertFalse(reconciled.expandedFolderIDs.contains("2024/Trip/Day"))
        XCTAssertTrue(reconciled.expandedFolderIDs.contains("2024/Trip"))
    }

    func testRemovedAncestorsFallBackToRootNeverPrefixSibling() throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let original = ArchiveNavigationMemory(index: try fixture.index(), selectedFolderID: "2024/Trip/Day",
            expandedFolderIDs: ["", "2024", "20240"])
        try FileManager.default.moveItem(at: fixture.source.appendingPathComponent("2024"),
            to: fixture.root.appendingPathComponent("retired-year"))
        let next = try fixture.index(ids: ["20240"])
        let reconciled = original.reconciled(with: next)
        XCTAssertEqual(reconciled.selectedFolderID, "")
        XCTAssertEqual(reconciled.expandedFolderIDs, ["", "20240"])
    }

    func testOrdinaryDirectoryContentsChangesDoNotLoseNavigationIdentity() throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let initial = try fixture.index()
        let original = ArchiveNavigationMemory(index: initial, selectedFolderID: "2024/Trip")
            .remembering(try fixture.position(in: "2024/Trip"), for: "2024/Trip", in: initial)
        try Data("new unrelated file".utf8).write(to: fixture.source.appendingPathComponent("2024/Trip/notes.txt"))
        let reconciled = original.reconciled(with: try fixture.index())
        XCTAssertEqual(reconciled.selectedFolderID, "2024/Trip")
        XCTAssertNotNil(reconciled.position(for: "2024/Trip"))
    }

    func testDirectoryWithoutVerifiedIdentityCannotRestoreSavedPosition() throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let initial = try fixture.index()
        let original = ArchiveNavigationMemory(index: initial, selectedFolderID: "2024/Trip")
            .remembering(try fixture.position(in: "2024/Trip"), for: "2024/Trip", in: initial)
        let unknown = ArchiveFolderIndex(root: fixture.source, directories: [
            .init(id: "2024", parentID: "", name: "2024"),
            .init(id: "2024/Trip", parentID: "2024", name: "Trip")
        ], items: [])
        let reconciled = original.reconciled(with: unknown)
        XCTAssertEqual(reconciled.selectedFolderID, "")
        XCTAssertTrue(reconciled.entries.isEmpty)
    }

    func testEncodedUnicodeFolderIDsStayIndependent() throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let first = try FileOperationJournal.captureIdentity(at: fixture.source.appendingPathComponent("2024"))
        let second = try FileOperationJournal.captureIdentity(at: fixture.source.appendingPathComponent("20240"))
        let index = ArchiveFolderIndex(root: fixture.source, directories: [
            .init(id: "caf%C3%A9", parentID: "", name: "café", identity: first),
            .init(id: "cafe%CC%81", parentID: "", name: "cafe\u{301}", identity: second)
        ], items: [])
        let position = try fixture.position(in: "2024/Trip")
        let memory = ArchiveNavigationMemory(index: index, selectedFolderID: "caf%C3%A9",
            expandedFolderIDs: ["caf%C3%A9", "cafe%CC%81"])
            .remembering(position, for: "caf%C3%A9", in: index)
            .remembering(position, for: "cafe%CC%81", in: index)
        let restored = try JSONDecoder().decode(ArchiveNavigationMemory.self, from: JSONEncoder().encode(memory))
            .reconciled(with: index)
        XCTAssertEqual(restored.entries.count, 2)
        XCTAssertEqual(restored.expandedFolderIDs.count, 2)
        XCTAssertEqual(restored.selectedFolderID, "caf%C3%A9")
    }

    func testDifferentRootAtSamePathCannotInheritMemory() async throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let memory = ArchiveNavigationMemory(index: try fixture.index(), selectedFolderID: "2024/Trip")
        let oldIdentity = try fixture.rootIdentity()
        let worker = fixture.persistence()
        try await worker.save(memory, for: oldIdentity)
        try FileManager.default.moveItem(at: fixture.source, to: fixture.root.appendingPathComponent("retired-root"))
        try FileManager.default.createDirectory(at: fixture.source, withIntermediateDirectories: false)
        let newIdentity = try fixture.rootIdentity()
        XCTAssertNotEqual(oldIdentity, newIdentity)
        let replacement = try await fixture.persistence().load(for: newIdentity)
        XCTAssertNil(replacement)
    }

    func testCorruptOrOversizedDocumentNeverGetsOverwrittenAsEmpty() async throws {
        for content in [Data("not json".utf8), Data(repeating: 65, count: ArchiveNavigationPersistence.maximumBytes + 1)] {
            let fixture = try NavigationFixture()
            defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.document.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: fixture.document)
            let worker = fixture.persistence()
            let identity = try fixture.rootIdentity()
            do {
                _ = try await worker.load(for: identity)
                XCTFail("corrupt document must be reported")
            } catch {}
            do {
                try await worker.save(ArchiveNavigationMemory(index: fixture.index()), for: identity)
                XCTFail("saving must preserve unreadable evidence")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: fixture.document), content)
        }
    }

    func testExplicitResetPreservesInvalidPrimaryAndPreviousAndAllowsSavingAgain() async throws {
        for primary in [Data("bad JSON".utf8), Data(repeating: 65, count: ArchiveNavigationPersistence.maximumBytes + 1), nil] {
            let fixture = try NavigationFixture(); defer { fixture.remove() }
            try FileManager.default.createDirectory(at: fixture.document.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let primary { try primary.write(to: fixture.document) }
            let previous = Data("retained prior evidence".utf8)
            try previous.write(to: fixture.document.appendingPathExtension("previous"))
            let worker = fixture.persistence()
            try await worker.resetPreservingEvidence()
            let recovered = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.document.deletingLastPathComponent(),
                includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("ArchiveNavigation.recovered-") })
            if let primary {
                XCTAssertEqual(try Data(contentsOf: recovered.appendingPathComponent(fixture.document.lastPathComponent)), primary)
            }
            XCTAssertEqual(try Data(contentsOf: recovered.appendingPathComponent(fixture.document.lastPathComponent + ".previous")), previous)
            let memory = ArchiveNavigationMemory(index: try fixture.index(), selectedFolderID: "2024/Trip")
            let identity = try fixture.rootIdentity()
            try await worker.save(memory, for: identity)
            let restored = try await fixture.persistence().load(for: identity)
            XCTAssertEqual(restored, memory)
        }
    }

    func testExplicitResetPreservesSymlinkWithoutReadingOrChangingItsTarget() async throws {
        let fixture = try NavigationFixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.document.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target = fixture.root.appendingPathComponent("target.json")
        let bytes = Data("unrelated target".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.document, withDestinationURL: target)
        let worker = fixture.persistence()
        try await worker.resetPreservingEvidence()
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        let recovered = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.document.deletingLastPathComponent(),
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("ArchiveNavigation.recovered-") })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: recovered.appendingPathComponent(fixture.document.lastPathComponent).path), target.path)
    }

    func testMalformedSnapshotBoundsAreRejectedBeforeReplacingDocument() async throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let valid = ArchiveNavigationMemory(index: try fixture.index(), selectedFolderID: "2024/Trip")
        let worker = fixture.persistence()
        let rootIdentity = try fixture.rootIdentity()
        try await worker.save(valid, for: rootIdentity)
        let before = try Data(contentsOf: fixture.document)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        // A Set collapses duplicates, so use distinct IDs to exceed its bound.
        object["expandedFolderIDs"] = (0..<513).map { "untrusted-\($0)" }
        let malformed = try JSONDecoder().decode(ArchiveNavigationMemory.self, from: JSONSerialization.data(withJSONObject: object))
        do {
            try await worker.save(malformed, for: rootIdentity)
            XCTFail("untrusted oversized state must not be accepted")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.document), before)
    }

    func testFailedWriteRetainsPreviousStateAndAllowsRetry() async throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let identity = try fixture.rootIdentity()
        let initial = ArchiveNavigationMemory(index: try fixture.index())
        try await fixture.persistence().save(initial, for: identity)
        let bytes = try Data(contentsOf: fixture.document)
        let failure = NavigationWriteFailure()
        let worker = ArchiveNavigationPersistence(fileURL: fixture.document, write: { data, url in
            if url.lastPathComponent == "ArchiveNavigation.json", failure.shouldFail() {
                throw CocoaError(.fileWriteNoPermission)
            }
            try DurableFileIO.atomicWrite(data, to: url, fullSync: true)
        })
        let desired = ArchiveNavigationMemory(index: try fixture.index(), selectedFolderID: "2024/Trip")
        do {
            try await worker.save(desired, for: identity)
            XCTFail("injected write must fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.document), bytes)
        XCTAssertEqual(try Data(contentsOf: fixture.document.appendingPathExtension("previous")), bytes)
        try await worker.save(desired, for: identity)
        let restored = try await fixture.persistence().load(for: identity)
        XCTAssertEqual(restored, desired)
    }

    func testExternalWriterAndSymlinkLeafAreNotOverwritten() async throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let identity = try fixture.rootIdentity()
        let index = try fixture.index()
        let worker = fixture.persistence()
        try await worker.save(ArchiveNavigationMemory(index: index), for: identity)
        let external = Data("external unreadable evidence".utf8)
        try external.write(to: fixture.document)
        do {
            try await worker.save(ArchiveNavigationMemory(index: index, selectedFolderID: "2024"), for: identity)
            XCTFail("external bytes cannot be replaced")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.document), external)
        try FileManager.default.removeItem(at: fixture.document)
        let target = fixture.root.appendingPathComponent("target.json")
        try external.write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.document, withDestinationURL: target)
        do {
            _ = try await fixture.persistence().load(for: identity)
            XCTFail("leaf symlink must be rejected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: target), external)
    }

    func testFailureAfterRenameRetainsPriorBytesAndRetryCanBecomeDurable() async throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let identity = try fixture.rootIdentity()
        let index = try fixture.index()
        let initial = ArchiveNavigationMemory(index: index)
        try await fixture.persistence().save(initial, for: identity)
        let priorBytes = try Data(contentsOf: fixture.document)
        let failure = NavigationWriteFailure()
        let worker = ArchiveNavigationPersistence(fileURL: fixture.document, write: { data, url in
            try DurableFileIO.atomicWrite(data, to: url, fullSync: true)
            if url.lastPathComponent == "ArchiveNavigation.json", failure.shouldFail() {
                throw CocoaError(.fileWriteUnknown)
            }
        })
        let desired = ArchiveNavigationMemory(index: index, selectedFolderID: "2024/Trip")
        do {
            try await worker.save(desired, for: identity)
            XCTFail("an after-rename failure remains visible")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.document.appendingPathExtension("previous")), priorBytes)
        let stillPending = try await worker.load(for: identity)
        XCTAssertEqual(stillPending, initial, "failed persistence cannot publish success in memory")
        try await worker.save(desired, for: identity)
        let restored = try await fixture.persistence().load(for: identity)
        XCTAssertEqual(restored, desired)
    }

    func testPositionCapacityDropsLeastRecentEntriesWithoutChangingDecisions() throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let realIdentity = try FileOperationJournal.captureIdentity(at: fixture.source.appendingPathComponent("2024"))
        let directories = (0..<140).map { id in
            ArchiveFolderIndex.Directory(id: "folder-\(id)", parentID: "", name: "folder-\(id)", identity: realIdentity)
        }
        let index = ArchiveFolderIndex(root: fixture.source, directories: directories, items: [])
        let position = try fixture.position(in: "2024/Trip")
        var memory = ArchiveNavigationMemory(index: index)
        for id in 0..<140 {
            memory = memory.remembering(position, for: "folder-\(id)", in: index)
        }
        XCTAssertEqual(memory.entries.count, ArchiveNavigationMemory.maximumEntries)
        XCTAssertNil(memory.position(for: "folder-0"))
        XCTAssertNotNil(memory.position(for: "folder-139"))
        XCTAssertEqual(memory.entries.first?.folderID, "folder-139")
    }

    func testRootCapacityEvictsOldestBrowsingMemoryOnly() async throws {
        let fixture = try NavigationFixture()
        defer { fixture.remove() }
        let worker = fixture.persistence()
        let memory = ArchiveNavigationMemory(index: try fixture.index())
        var identities: [PinnedFolderIdentity] = []
        for number in 0...ArchiveNavigationPersistence.maximumRoots {
            let folder = fixture.root.appendingPathComponent("root-\(number)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let identity = PinnedFolderIdentity(source: try .capture(at: folder))
            identities.append(identity)
            try await worker.save(memory, for: identity)
        }
        let oldest = try await worker.load(for: identities[0])
        let newest = try await worker.load(for: XCTUnwrap(identities.last))
        XCTAssertNil(oldest)
        XCTAssertEqual(newest, memory)
        XCTAssertLessThanOrEqual(try Data(contentsOf: fixture.document).count, ArchiveNavigationPersistence.maximumBytes)
    }
}

private struct NavigationFixture {
    let root: URL
    let source: URL
    let document: URL
    private let ids = ["2024", "2024/Trip", "2024/Trip/Day", "20240"]

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/louppe-navigation-memory-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        document = root.appendingPathComponent("state/ArchiveNavigation.json")
        for id in ids {
            try FileManager.default.createDirectory(at: source.appendingPathComponent(id), withIntermediateDirectories: true)
        }
    }

    func rootIdentity() throws -> PinnedFolderIdentity {
        PinnedFolderIdentity(source: try .capture(at: source))
    }

    func index(ids requested: [String]? = nil) throws -> ArchiveFolderIndex {
        let directories = try ([""] + (requested ?? ids)).map { id -> ArchiveFolderIndex.Directory in
            let url = id.isEmpty ? source : source.appendingPathComponent(id)
            let parent = id.isEmpty ? nil : id.lastIndex(of: "/").map { String(id[..<$0]) } ?? ""
            return .init(id: id, parentID: parent, name: url.lastPathComponent,
                identity: try FileOperationJournal.captureIdentity(at: url))
        }
        return ArchiveFolderIndex(root: source, directories: directories, items: [])
    }

    func position(in folder: String) throws -> PinnedFolderPosition {
        let url = source.appendingPathComponent(folder).appendingPathComponent("photo.JPG")
        if !FileManager.default.fileExists(atPath: url.path) { try Data("unchanged original".utf8).write(to: url) }
        let anchor = PinnedFolderFileAnchor(physicalFileID: folder + "/photo.JPG",
            identity: try FileOperationJournal.captureIdentity(at: url))
        return .init(current: anchor, browser: .init(anchor: anchor, topOffset: 12), grid: .init(anchor: anchor, topOffset: 35))
    }

    func persistence() -> ArchiveNavigationPersistence { .init(fileURL: document) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class NavigationWriteFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 1
    func shouldFail() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}
