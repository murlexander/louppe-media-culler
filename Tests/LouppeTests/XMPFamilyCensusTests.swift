import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Louppe

final class XMPFamilyCensusTests: XCTestCase {
    func testNestedStemWithoutApplicationPacketAllowsCanonicalPublicationAndMove() async throws {
        let root = try folder()
        let source = try folder(in: root)
        let destination = try folder(in: root)
        let raw = source.appendingPathComponent("IMG.NEF")
        let jpeg = source.appendingPathComponent("IMG.NEF.jpg")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        let family = try XCTUnwrap(XMPSidecarResolver.resolve(members: [member(raw), member(jpeg)])
            .first { $0.members.contains { $0.mediaPath.url == raw } })
        XCTAssertEqual(family.disposition, .publish)
        let sidecar = source.appendingPathComponent("IMG.xmp")
        let validation = try XMPPublicationSourceValidation(family: family, sourceFolder: nil, sourceFolderIdentity: nil)
        let store = XMPMetadataStore()
        let prepared = try await store.prepareWrite(path: XMPExactFileSystemPath(url: sidecar), metadata: metadata, sourceValidation: validation)
        _ = try await store.commit(prepared, sourceValidation: validation)
        let published = try Data(contentsOf: sidecar)
        let selected = try item(raw)
        let xmp = try await XMPExportPlanner.prepare(selected: [selected], familyContextItems: [selected, item(jpeg)], profile: .universal, visibleDecisionKeywords: false, allowExternalLabelReplacement: false)
        let plan = try ExportWorker.makePlan(for: [selected], in: destination, xmpPlan: xmp, mode: .move)
        let result = ExportWorker.move([selected], to: destination, xmpPlan: xmp, preparedPlan: plan,
            journalDirectory: root.appendingPathComponent("Journals")) { _, _ in }
        XCTAssertEqual(result.movedItemIDs, [selected.id])
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: jpeg), Data("jpeg".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("IMG.NEF")), Data("raw".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("IMG.xmp")), published)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    func testTemporaryParentSwapCannotSubstituteMembershipListing() throws {
        let root = try folder()
        let source = try folder(in: root)
        let replacement = try folder(in: root)
        let held = root.appendingPathComponent("held")
        let raw = source.appendingPathComponent("PAIR.NEF")
        try Data("raw".utf8).write(to: raw)
        let expectation = try XMPFamilyMembership(members: [member(raw)])
        let jpeg = source.appendingPathComponent("PAIR.JPG")
        try Data("jpeg".utf8).write(to: jpeg)
        try Data("foreign raw".utf8).write(to: replacement.appendingPathComponent("PAIR.NEF"))
        var swapped = false
        func restore() throws {
            guard swapped else { return }
            try FileManager.default.moveItem(at: source, to: replacement)
            try FileManager.default.moveItem(at: held, to: source)
            swapped = false
        }
        defer { try? restore() }
        var polls = 0
        XCTAssertThrowsError(try expectation.validate(isCancelled: {
            polls += 1
            do {
                if polls == 1 {
                    try FileManager.default.moveItem(at: source, to: held)
                    try FileManager.default.moveItem(at: replacement, to: source)
                    swapped = true
                } else if polls == 2 {
                    try restore()
                }
            } catch { XCTFail("Swap probe failed: \(error)"); return true }
            return false
        }))
        try restore()
        XCTAssertEqual(try Data(contentsOf: raw), Data("raw".utf8))
        XCTAssertEqual(try Data(contentsOf: jpeg), Data("jpeg".utf8))
    }

    func testNestedSiblingAfterPlanProtectsApplicationPacketBeingMoved() async throws {
        let root = try folder()
        let source = try folder(in: root)
        let destination = try folder(in: root)
        let raw = source.appendingPathComponent("PAIR.NEF")
        let application = source.appendingPathComponent("PAIR.NEF.xmp")
        let privateBytes = Data("private processing history".utf8)
        try Data("raw".utf8).write(to: raw)
        try privateBytes.write(to: application)
        let selected = try item(raw)
        let xmp = try await XMPExportPlanner.prepare(selected: [selected], familyContextItems: [selected], profile: .universal, visibleDecisionKeywords: false, allowExternalLabelReplacement: false)
        XCTAssertEqual(xmp.applicationPacketCount, 1)
        let plan = try ExportWorker.makePlan(for: [selected], in: destination, xmpPlan: xmp, mode: .move)
        let jpeg = source.appendingPathComponent("PAIR.NEF.jpg")
        try Data("jpeg".utf8).write(to: jpeg)
        let result = ExportWorker.move([selected], to: destination, xmpPlan: xmp, preparedPlan: plan,
            journalDirectory: root.appendingPathComponent("Journals")) { _, _ in }
        XCTAssertEqual(result.movedItemIDs, [])
        XCTAssertEqual(result.failedPhotos, 1)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: raw), Data("raw".utf8))
        XCTAssertEqual(try Data(contentsOf: jpeg), Data("jpeg".utf8))
        XCTAssertEqual(try Data(contentsOf: application), privateBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("PAIR.NEF").path))
    }

    func testUnreviewedSiblingBeforeDiscoveryRefusesPublication() throws {
        let root = try folder()
        let raw = root.appendingPathComponent("PAIR.NEF")
        try Data("raw".utf8).write(to: raw)
        let member = try member(raw)
        try Data("jpeg".utf8).write(to: root.appendingPathComponent("PAIR.JPG"))
        let family = try XCTUnwrap(XMPSidecarResolver.resolve(members: [member]).first)
        XCTAssertNotEqual(family.disposition, .publish)
    }

    func testSiblingAddedAfterImmutableMovePlanRollsBackFamily() async throws {
        let root = try folder()
        let source = try folder(in: root)
        let destination = try folder(in: root)
        let raw = source.appendingPathComponent("PAIR.NEF")
        let sidecar = source.appendingPathComponent("PAIR.xmp")
        try Data("raw".utf8).write(to: raw)
        let original = try packet()
        try original.write(to: sidecar)
        let selected = try item(raw)
        let xmp = try await XMPExportPlanner.prepare(selected: [selected], familyContextItems: [selected], profile: .universal, visibleDecisionKeywords: false, allowExternalLabelReplacement: false)
        let plan = try ExportWorker.makePlan(for: [selected], in: destination, xmpPlan: xmp, mode: .move)
        try Data("jpeg".utf8).write(to: source.appendingPathComponent("PAIR.JPG"))
        let result = ExportWorker.move([selected], to: destination, xmpPlan: xmp, preparedPlan: plan, journalDirectory: root.appendingPathComponent("Journals")) { _, _ in }
        XCTAssertEqual(result.movedItemIDs, [])
        XCTAssertEqual(result.failedPhotos, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("PAIR.NEF").path))
        XCTAssertEqual(try Data(contentsOf: sidecar), original)
    }

    func testCopyAfterImmutablePlanKeepsSourcePacketForNewSibling() async throws {
        let root = try folder()
        let source = try folder(in: root)
        let destination = try folder(in: root)
        let raw = source.appendingPathComponent("PAIR.NEF")
        let sidecar = source.appendingPathComponent("PAIR.xmp")
        try Data("raw".utf8).write(to: raw)
        let original = try packet()
        try original.write(to: sidecar)
        let selected = try item(raw)
        let xmp = try await XMPExportPlanner.prepare(selected: [selected], familyContextItems: [selected], profile: .universal, visibleDecisionKeywords: false, allowExternalLabelReplacement: false)
        let plan = try ExportWorker.makePlan(for: [selected], in: destination, xmpPlan: xmp, mode: .copy)
        try Data("jpeg".utf8).write(to: source.appendingPathComponent("PAIR.JPG"))
        let result = ExportWorker.copy([selected], to: destination, xmpPlan: xmp, preparedPlan: plan, journalDirectory: root.appendingPathComponent("Journals")) { _, _ in }
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: sidecar), original)
        XCTAssertEqual(try Data(contentsOf: raw), Data("raw".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("PAIR.NEF")), Data("raw".utf8))
    }

    func testSiblingDuringFlushedTemporaryRefusesCreateAndUpdate() async throws {
        for existing in [false, true] {
            let root = try folder()
            let raw = root.appendingPathComponent("PAIR.NEF")
            let sidecar = root.appendingPathComponent("PAIR.xmp")
            try Data("raw".utf8).write(to: raw)
            let original = try packet()
            if existing { try original.write(to: sidecar) }
            let family = try XCTUnwrap(XMPSidecarResolver.resolve(members: [member(raw)]).first)
            let validation = try XMPPublicationSourceValidation(family: family, sourceFolder: nil, sourceFolderIdentity: nil)
            let store = XMPMetadataStore()
            let prepared = try await store.prepareWrite(path: XMPExactFileSystemPath(url: sidecar), metadata: metadata, sourceValidation: validation)
            do {
                _ = try await store.commit(prepared, sourceValidation: validation, testHooks: .init(beforeFinalValidation: {
                    try Data("jpeg".utf8).write(to: root.appendingPathComponent("PAIR.JPG"))
                }))
                XCTFail("Unreviewed sibling published")
            } catch {}
            if existing { XCTAssertEqual(try Data(contentsOf: sidecar), original) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path)) }
        }
    }

    func testRetirementRecoveryPreservesPacketAcrossCrashStatesAndCollision() throws {
        for state in ["staged", "completed", "completedTemporary", "canonical", "collision"] {
            let root = try folder()
            let source = root.appendingPathComponent("PAIR.xmp")
            let retired = root.appendingPathComponent(".retired-xmp")
            let bytes = try packet()
            try bytes.write(to: source)
            let journals = try folder(in: root)
            let writer = try FileOperationJournal.start(kind: .exportMove, seeds: [.init(itemID: "family", source: source, destination: retired, expectedIdentity: FileOperationJournal.captureIdentity(at: source), role: .retiredXMPSource, expectedSourceDigest: Data(SHA256.hash(data: bytes)))], directory: journals)
            try writer.mark(.started, fileAt: 0)
            let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
            try DurableFileIO.atomicExclusiveRename(from: source, to: temporary)
            try writer.mark(.staged, fileAt: 0, identityAt: temporary, expectedIdentity: FileOperationJournal.captureIdentity(at: temporary))
            if state != "staged" {
                try DurableFileIO.atomicExclusiveRename(from: temporary, to: retired)
                try writer.mark(.completed, fileAt: 0, identityAt: retired, expectedIdentity: FileOperationJournal.captureIdentity(at: retired))
                if state == "completedTemporary" { try DurableFileIO.atomicExclusiveRename(from: retired, to: temporary) }
                if state == "canonical" { try DurableFileIO.atomicExclusiveRename(from: retired, to: source) }
            }
            XCTAssertTrue(FileOperationJournal.finalize(writer, operationIsConsistent: false))
            try Data("jpeg".utf8).write(to: root.appendingPathComponent("PAIR.JPG"))
            let foreign = Data("foreign canonical packet".utf8)
            if state == "collision" { try foreign.write(to: source) }
            let report = FileOperationJournal.recoverPendingOperations(directory: journals)
            XCTAssertEqual(report.unresolvedOperations, state == "collision" ? 1 : 0, state)
            XCTAssertEqual(try Data(contentsOf: source), state == "collision" ? foreign : bytes, state)
            if state == "collision" { XCTAssertEqual(try Data(contentsOf: retired), bytes) }
            else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path), state)
                XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path), state)
            }
        }
    }

    func testStagedAndCompletedPreparedCopyRecoverWithoutSourceParent() throws {
        for completed in [false, true] {
            let root = try folder()
            let sourceFolder = try folder(in: root)
            let source = sourceFolder.appendingPathComponent("PAIR.xmp")
            let destination = root.appendingPathComponent("PAIR.xmp")
            let original = try packet()
            let final = try XMPFieldMapping.merge(packet: nil, metadata: metadata)
            try original.write(to: source)
            let journals = root.appendingPathComponent("Journals")
            let writer = try FileOperationJournal.start(kind: .exportCopy, seeds: [.init(itemID: "family", source: source, destination: destination,
                expectedIdentity: FileOperationJournal.captureIdentity(at: source), role: .preparedXMP,
                expectedSourceDigest: Data(SHA256.hash(data: original)), preparedContentDigest: Data(SHA256.hash(data: final)))], directory: journals)
            let temporary = try XCTUnwrap(writer.temporaryURL(at: 0))
            try writer.mark(.started, fileAt: 0)
            try DurableFileIO.writeNewFile(final, to: temporary, fullSync: true)
            try writer.mark(.staged, fileAt: 0, identityAt: temporary, expectedIdentity: FileOperationJournal.captureIdentity(at: temporary))
            if completed {
                try DurableFileIO.atomicExclusiveRename(from: temporary, to: destination)
                try writer.mark(.completed, fileAt: 0, identityAt: destination, expectedIdentity: FileOperationJournal.captureIdentity(at: destination))
            }
            try FileManager.default.removeItem(at: sourceFolder)
            XCTAssertTrue(FileOperationJournal.finalize(writer, operationIsConsistent: false))
            let report = FileOperationJournal.recoverPendingOperations(directory: journals)
            XCTAssertEqual(report.unresolvedOperations, 0)
            XCTAssertEqual(report.preservedCopies, 1)
            XCTAssertEqual(try Data(contentsOf: destination), final)
        }
    }

    func testSiblingAtFirstRetirementBoundaryRollsBackOnlyCurrentFamily() async throws {
        let root = try folder()
        let source = try folder(in: root)
        let destination = try folder(in: root)
        var selected: [PhotoItem] = []
        let bytes = try packet()
        for stem in ["FIRST", "PAIR"] {
            let raw = source.appendingPathComponent("\(stem).NEF")
            try Data("raw".utf8).write(to: raw)
            try bytes.write(to: source.appendingPathComponent("\(stem).xmp"))
            selected.append(try item(raw))
        }
        let xmp = try await XMPExportPlanner.prepare(selected: selected, familyContextItems: selected, profile: .universal, visibleDecisionKeywords: false, allowExternalLabelReplacement: false)
        var boundaries = 0
        let result = ExportWorker.move(selected, to: destination, xmpPlan: xmp,
            journalDirectory: root.appendingPathComponent("Journals"), beforeXMPSourceRetirement: {
                boundaries += 1
                if boundaries == 2 {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("PAIR.NEF").path))
                    try Data("jpeg".utf8).write(to: source.appendingPathComponent("PAIR.JPG"))
                }
            }) { _, _ in }
        XCTAssertEqual(boundaries, 2)
        XCTAssertEqual(result.movedItemIDs, [selected[0].id])
        XCTAssertEqual(result.failedPhotos, 1)
        XCTAssertEqual(result.inconsistentPhotos, 0)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("FIRST.NEF").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("FIRST.xmp").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("PAIR.NEF")), Data("raw".utf8))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("PAIR.xmp")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("PAIR.NEF").path))
    }

    func testSiblingAfterCompletedRetirementRestoresCanonicalDuringWorkerCleanup() async throws {
        let root = try folder()
        let source = try folder(in: root)
        let destination = try folder(in: root)
        let raw = source.appendingPathComponent("PAIR.NEF")
        let sidecar = source.appendingPathComponent("PAIR.xmp")
        try Data("raw".utf8).write(to: raw)
        let bytes = try packet()
        try bytes.write(to: sidecar)
        let selected = try item(raw)
        let xmp = try await XMPExportPlanner.prepare(selected: [selected], familyContextItems: [selected], profile: .universal, visibleDecisionKeywords: false, allowExternalLabelReplacement: false)
        let result = ExportWorker.move([selected], to: destination, xmpPlan: xmp,
            journalDirectory: root.appendingPathComponent("Journals")) { done, total in
                if done == total { try? Data("jpeg".utf8).write(to: source.appendingPathComponent("PAIR.JPG")) }
            }
        XCTAssertEqual(result.movedItemIDs, [selected.id])
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("PAIR.NEF").path))
    }

    func testCaseUnicodeAndUnsafeNewOwnersNeverGrantCompleteness() throws {
        for name in ["pair.JPG", "PAIR.NEF.jpg", "PAIR.mov", "PAIR.wav"] {
            let root = try folder()
            let raw = root.appendingPathComponent("PAIR.NEF")
            try Data("raw".utf8).write(to: raw)
            let expectation = try XMPFamilyMembership(members: [member(raw)],
                applicationOwnerPaths: [XMPExactFileSystemPath(url: raw)])
            let other = root.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: other, withDestinationURL: raw)
            XCTAssertThrowsError(try expectation.validate(), name)
        }
        let root = try folder()
        let raw = root.appendingPathComponent("Café.NEF")
        try Data("raw".utf8).write(to: raw)
        let expectation = try XMPFamilyMembership(members: [member(raw)])
        try Data("jpeg".utf8).write(to: root.appendingPathComponent("Cafe\u{301}.JPG"))
        XCTAssertThrowsError(try expectation.validate())
        XCTAssertThrowsError(try XMPFamilyMembership.requireKnownCaseSensitivity(nil))
        XCTAssertEqual(try XMPFamilyMembership.requireKnownCaseSensitivity(true), true)
        XCTAssertEqual(try XMPFamilyMembership.requireKnownCaseSensitivity(false), false)
    }

    func testDynamicRecognizedMediaAndUnreadableEntriesRefuseMembership() throws {
        let dynamic = try XCTUnwrap(["aifc", "au", "snd", "m1v"].first {
            !FolderScanner.recognizedExtensions.contains($0) && FolderScanner.isRecognizedExtension($0)
        }, "The SDK must provide at least one dynamically recognized media extension")
        let root = try folder()
        let raw = root.appendingPathComponent("PAIR.NEF")
        try Data("raw".utf8).write(to: raw)
        let expectation = try XMPFamilyMembership(members: [member(raw)])
        let other = root.appendingPathComponent("PAIR.\(dynamic)")
        try Data("unreviewed dynamic media".utf8).write(to: other)
        XCTAssertThrowsError(try expectation.validate())
        XCTAssertNotEqual(try XMPSidecarResolver.resolve(members: [member(raw)])[0].disposition, .publish)
        try FileManager.default.removeItem(at: other)
        let unreadable = root.appendingPathComponent("PAIR.JPG")
        try Data("unreadable".utf8).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path) }
        XCTAssertThrowsError(try expectation.validate())
        XCTAssertNotEqual(try XMPSidecarResolver.resolve(members: [member(raw)])[0].disposition, .publish)
    }

    func testCensusRejectsParentReplacementAndPollsCancellation() throws {
        let root = try folder()
        let source = try folder(in: root)
        let raw = source.appendingPathComponent("PAIR.NEF")
        try Data("raw".utf8).write(to: raw)
        let expectation = try XMPFamilyMembership(members: [member(raw)])
        var polls = 0
        XCTAssertThrowsError(try expectation.validate(isCancelled: {
            polls += 1
            return polls == 2
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(polls, 2)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("held"))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("foreign".utf8).write(to: raw)
        XCTAssertThrowsError(try expectation.validate())
    }

    /// Opt-in because the accepted fresh-boundary guarantee deliberately costs
    /// Theta(N * F) for F risky families in one N-entry directory.
    func testBoundaryCensusBenchmark() throws {
        guard ProcessInfo.processInfo.environment["LOUPPE_XMP_CENSUS_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in real-I/O census benchmark")
        }
        for count in [1000, 2000, 4000] {
            for dispersed in [false, true] {
                let root = try folder(in: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
                addTeardownBlock { try? FileManager.default.removeItem(at: root) }
                var expectations: [XMPFamilyMembership] = []
                for index in 0..<count {
                    let directory = dispersed ? try folder(in: root) : root
                    let raw = directory.appendingPathComponent("IMG_\(index).NEF")
                    try Data("raw".utf8).write(to: raw)
                    try Data("packet".utf8).write(to: directory.appendingPathComponent("IMG_\(index).xmp"))
                    expectations.append(try XMPFamilyMembership(members: [member(raw)]))
                }
                var enumerations = 0, entries = 0, peakMembers = 0
                let start = Date.timeIntervalSinceReferenceDate
                for expectation in expectations {
                    try expectation.validate(measured: { visited, retained in
                        enumerations += 1
                        entries += visited
                        peakMembers = max(peakMembers, retained)
                    })
                }
                let elapsed = Date.timeIntervalSinceReferenceDate - start
                XCTAssertEqual(enumerations, count)
                XCTAssertEqual(entries, dispersed ? count * 2 : count * count * 2)
                XCTAssertEqual(peakMembers, 1)
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                print("CENSUS_BENCH families=\(count) dispersed=\(dispersed) enumerations=\(enumerations) entries=\(entries) seconds=\(elapsed) peakMatchedMembers=\(peakMembers) retainedExpectedMembers=\(expectations.count) peakListedEntries=1 workerCount=1 publicationWorkerLimit=\(XMPPublicationPlanner.concurrencyLimit) packetBytesRetainedByCensus=0 processPeakRSSBytes=\(usage.ru_maxrss)")
                fflush(nil)
                // Cancellation is requested on a different thread while the
                // real directory read/entry walk is in progress; join it here.
                let cancel = CensusBenchmarkCancellation()
                let work = DispatchGroup()
                work.enter()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.001) {
                    cancel.set()
                    work.leave()
                }
                let cancelStart = Date.timeIntervalSinceReferenceDate
                var cancelled = false
                do { try expectations[0].validate(isCancelled: { cancel.isSet }) }
                catch { XCTAssertTrue(error is CancellationError); cancelled = true }
                let returned = Date.timeIntervalSinceReferenceDate
                work.wait()
                print("CENSUS_CANCEL families=\(count) dispersed=\(dispersed) cancelled=\(cancelled) callSeconds=\(returned - cancelStart) latencyAfterRequestSeconds=\(max(0, returned - cancel.requestedAt))")
                fflush(nil)
                try FileManager.default.removeItem(at: root)
            }
        }
    }

    private var metadata: XMPPublicationMetadata { .init(decision: .yes, stars: .five, colorLabel: .red, profile: .universal) }
    private func packet() throws -> Data { try XMPFieldMapping.merge(packet: nil, metadata: .init(decision: .no, stars: .one, colorLabel: nil, profile: .universal)) }
    private func member(_ url: URL) throws -> XMPStemFamilyMember {
        try .init(mediaURL: url, metadata: metadata, scannedIdentity: FileOperationJournal.captureIdentity(at: url))
    }
    private func item(_ url: URL) throws -> PhotoItem {
        PhotoItem(primaryFile: PhotoFile(id: url.lastPathComponent, url: url, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 3, scannedIdentity: try FileOperationJournal.captureIdentity(at: url), rating: .yes, starRating: .five, colorLabel: .red))
    }
    private func folder(in parent: URL? = nil) throws -> URL {
        let url = (parent ?? FileManager.default.temporaryDirectory).appendingPathComponent("louppe-census-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        if parent == nil { addTeardownBlock { try? FileManager.default.removeItem(at: url) } }
        return url
    }
}

private final class CensusBenchmarkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval?
    func set() { lock.lock(); time = Date.timeIntervalSinceReferenceDate; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return time != nil }
    var requestedAt: TimeInterval { lock.lock(); defer { lock.unlock() }; return time ?? 0 }
}
