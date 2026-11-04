import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Louppe

/// Copy flush order (AUD-13), within-file progress and Stop (AUD-15), and the
/// path-based ExFAT Move window (AUD-05), all on disposable files.
final class TransferDurabilityTests: XCTestCase {

    // MARK: AUD-15 descriptor copy progress and Stop

    func testDescriptorCopyReportsWritesAndPreservesMetadataAndForks() throws {
        let fixture = try Fixture(named: "DescriptorProgress")
        defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("CLIP.MOV")
        let contents = Self.patternedData(count: 9 * 1_048_576 + 123)
        try contents.write(to: source)
        try setXattr("com.louppe.test", Data("label".utf8), on: source)
        let fork = Data(repeating: 0x5A, count: 70_000)
        try setXattr(XATTR_RESOURCEFORK_NAME, fork, on: source)
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: modified, .posixPermissions: 0o640], ofItemAtPath: source.path
        )
        let sourceBefore = try Self.digest(source)
        let directory = try DurableFileIO.BoundDirectory(.init(url: fixture.destination))
        let temporary = fixture.destination.appendingPathComponent(".copy.partial")
        var reports: [Int64] = []

        try directory.copy(from: source, to: temporary, progress: { reports.append($0); return true })

        XCTAssertGreaterThan(reports.count, 2, "a large file must report progress before it completes")
        XCTAssertEqual(reports, reports.sorted(), "copied bytes never move backwards")
        XCTAssertLessThan(reports.first ?? .max, Int64(contents.count))
        XCTAssertEqual(reports.last, Int64(contents.count))
        XCTAssertEqual(try Data(contentsOf: temporary), contents)
        XCTAssertEqual(try xattr("com.louppe.test", of: temporary), Data("label".utf8))
        XCTAssertEqual(try xattr(XATTR_RESOURCEFORK_NAME, of: temporary), fork)
        let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, modified)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(try Self.digest(source), sourceBefore)
    }

    func testDescriptorCopyStopThrowsAndLeavesPartialForCallerCleanup() throws {
        let fixture = try Fixture(named: "DescriptorStop")
        defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("CLIP.MOV")
        let contents = Self.patternedData(count: 8 * 1_048_576)
        try contents.write(to: source)
        let directory = try DurableFileIO.BoundDirectory(.init(url: fixture.destination))
        let temporary = fixture.destination.appendingPathComponent(".copy.partial")
        var calls = 0

        XCTAssertThrowsError(try directory.copy(from: source, to: temporary, progress: { _ in
            calls += 1
            return false
        })) { error in
            XCTAssertEqual(error as? DurableFileIO.CopyStopped, DurableFileIO.CopyStopped())
        }
        XCTAssertEqual(calls, 1, "Stop takes effect at the next write")
        let partial = try FileManager.default.attributesOfItem(atPath: temporary.path)
        XCTAssertLessThan((partial[.size] as? NSNumber)?.intValue ?? .max, contents.count)
        XCTAssertEqual(try Data(contentsOf: source), contents)
    }

    /// The error callback must keep failing the copy with the real errno;
    /// CONTINUE would retry forever and ECANCELED would look like a Stop.
    func testDescriptorCopyWriteFailureKeepsRealErrorWithProgressCallback() throws {
        let images = try DisposableImages(named: "CopyENOSPC")
        defer { images.cleanUp() }
        let mount: URL
        do {
            mount = try images.attachNew(megabytes: 4, fileSystem: "ExFAT", name: "LWS4FULL")
        } catch {
            throw XCTSkip("hdiutil unavailable: \(error)")
        }
        let fixture = try Fixture(named: "CopyENOSPC")
        defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("CLIP.MOV")
        try Self.patternedData(count: 8 * 1_048_576).write(to: source)
        let directory = try DurableFileIO.BoundDirectory(.init(url: mount))
        var calls = 0
        XCTAssertThrowsError(try directory.copy(
            from: source, to: mount.appendingPathComponent("FULL.partial"),
            progress: { _ in calls += 1; return true }
        )) { error in
            XCTAssertNil(error as? DurableFileIO.CopyStopped)
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertNotEqual((error as NSError).code, Int(ECANCELED))
        }
        XCTAssertGreaterThan(calls, 0)
    }

    // MARK: AUD-15 worker progress and Stop inside one file

    func testCopyReportsBytesWithinOneLargeFile() throws {
        let fixture = try Fixture(named: "InFileProgress")
        defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("CLIP.MOV")
        let size = 48 * 1_048_576
        try Self.patternedData(count: size).write(to: source)
        let recorder = ProgressRecorder()
        let result = ExportWorker.copy(
            [Self.item(source, size: Int64(size))], to: fixture.destination,
            journalDirectory: fixture.journals,
            progress: { _, _ in }, byteProgress: recorder.record
        )
        XCTAssertEqual(result.copiedFiles, 1, result.failureMessage ?? "")
        let values = recorder.values
        XCTAssertTrue(values.contains { $0.completed > 0 && $0.completed < Int64(size) },
                      "progress must move before the file finishes: \(values)")
        XCTAssertEqual(values.map(\.completed), values.map(\.completed).sorted())
        XCTAssertEqual(values.last?.completed, Int64(size))
        XCTAssertEqual(try Self.digest(fixture.destination.appendingPathComponent("CLIP.MOV")),
                       try Self.digest(source))
    }

    func testStopDuringLargeFileRemovesOnlyRecordedPartialAndKeepsOriginal() throws {
        let fixture = try Fixture(named: "InFileStop")
        defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("CLIP.MOV")
        let size = 32 * 1_048_576
        try Self.patternedData(count: size).write(to: source)
        let before = try Self.digest(source)
        let cancellation = ExportWorker.CancelFlag()
        let recorder = ProgressRecorder()
        let result = ExportWorker.copy(
            [Self.item(source, size: Int64(size))], to: fixture.destination,
            journalDirectory: fixture.journals,
            isCancelled: { cancellation.isSet },
            cancellationReason: { cancellation.reason },
            progress: { _, _ in },
            byteProgress: { completed, total in
                recorder.record(completed: completed, total: total)
                if completed > 0, completed < total { cancellation.request(.userConfirmed) }
            }
        )
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.cancellationReason, .userConfirmed)
        XCTAssertEqual(result.copiedFiles, 0)
        XCTAssertEqual(result.failedPhotos, 0)
        XCTAssertEqual(result.inconsistentPhotos, 0)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path), [])
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: fixture.journals))
        XCTAssertEqual(try Self.digest(source), before)
        XCTAssertEqual(recorder.values.last?.completed, 0, "rolled-back bytes are retracted at once")
    }

    func testStopDuringSecondPairMemberRollsBackPublishedFirstMember() throws {
        let fixture = try Fixture(named: "PairStop")
        defer { fixture.remove() }
        let raw = fixture.source.appendingPathComponent("A.RAF")
        let jpeg = fixture.source.appendingPathComponent("A.JPG")
        try Self.patternedData(count: 4_096).write(to: raw)
        try Self.patternedData(count: 24 * 1_048_576).write(to: jpeg)
        let hashes = try [Self.digest(raw), Self.digest(jpeg)]
        let foreign = fixture.destination.appendingPathComponent("UNRELATED.JPG")
        try Data("keep me".utf8).write(to: foreign)
        let cancellation = ExportWorker.CancelFlag()
        let item = PhotoItem(id: "A.RAF", primaryURL: raw, pairedURL: jpeg,
            captureDate: nil, cameraModel: nil, lensModel: nil,
            fileSize: 4_096, pairedFileSize: 24 * 1_048_576, rating: .yes)
        let destination = fixture.destination
        // Stop only once the RAW is published and the JPEG's data copy has
        // started writing, so the Stop lands inside the second file.
        let isCancelled: @Sendable () -> Bool = {
            if cancellation.isSet { return true }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
            let writing = names.contains { name in
                name.hasSuffix(".partial")
                    && ((try? FileManager.default.attributesOfItem(
                        atPath: destination.appendingPathComponent(name).path
                    )[.size] as? NSNumber)?.intValue ?? 0) > 0
            }
            if names.contains("A.RAF"), writing { cancellation.request(.userConfirmed) }
            return cancellation.isSet
        }
        let result = ExportWorker.copy(
            [item], to: fixture.destination, journalDirectory: fixture.journals,
            isCancelled: isCancelled,
            cancellationReason: { cancellation.reason },
            progress: { _, _ in }
        )
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.copiedFiles, 0)
        XCTAssertEqual(result.inconsistentPhotos, 0)
        XCTAssertFalse(result.requiresRecovery)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path),
                       ["UNRELATED.JPG"])
        XCTAssertEqual(try Data(contentsOf: foreign), Data("keep me".utf8))
        XCTAssertEqual(try [Self.digest(raw), Self.digest(jpeg)], hashes)
        XCTAssertFalse(FileOperationJournal.hasPendingOperations(directory: fixture.journals))
    }

    // MARK: AUD-13 flush order and count

    /// Per file: started checkpoint, flushed temporary, its directory entry,
    /// staged checkpoint, published directory, completed record. No step is
    /// flushed twice.
    func testCopyFlushesEachBoundaryOnceInDurableOrder() throws {
        for injected in [false, true] {
            let fixture = try Fixture(named: injected ? "FlushInjected" : "FlushProduction")
            defer { fixture.remove() }
            var items: [PhotoItem] = []
            for index in 0..<3 {
                let url = fixture.source.appendingPathComponent("IMG_\(index).JPG")
                try Data("photo \(index)".utf8).write(to: url)
                items.append(Self.item(url, size: 7))
            }
            let log = SyncLog()
            let copier: ExportWorker.FileCopier? = injected
                ? { @Sendable source, target in try FileManager().copyItem(at: source, to: target) } : nil
            let result = DurableFileIO.observingSyncsForTesting(log.record) {
                ExportWorker.copy(items, to: fixture.destination,
                    journalDirectory: fixture.journals, fileCopier: copier,
                    progress: { _, _ in })
            }
            XCTAssertEqual(result.copiedFiles, 3, result.failureMessage ?? "")
            let signature = log.events.compactMap { fixture.classify($0) }.joined(separator: " ")
            let perFile = "J+f J+d T+f D+d J+f J+d D+d J-f J-d"
            XCTAssertTrue(signature.contains(Array(repeating: perFile, count: 3).joined(separator: " ")),
                          "\(injected ? "injected" : "production"): \(signature)")
            let media = log.events.filter { fixture.isMedia($0) }
            XCTAssertEqual(media.filter { !$0.isDirectory }.count, 3, signature)
            XCTAssertEqual(media.filter(\.isDirectory).count, 6, signature)
            XCTAssertTrue(media.allSatisfy(\.fullSync))
        }
    }

    // MARK: AUD-05 path-based ExFAT Move window

    /// Replaces a parent in the narrow window after Louppe rechecked its bound
    /// folders and before Foundation's path-based ExFAT move. Runs locally
    /// with the forced fallback and, when provided, on a disposable ExFAT
    /// mount (LOUPPE_FILE_VOLUME_ROOT + LOUPPE_FILE_VOLUME_FS=exfat).
    func testFoundationMoveWindowReplacementNeverLosesOrOverwritesFiles() throws {
        var bases: [(URL, String)] = [(FileManager.default.temporaryDirectory, "local")]
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["LOUPPE_FILE_VOLUME_ROOT"], environment["LOUPPE_FILE_VOLUME_FS"] == "exfat",
           root.hasPrefix("/Volumes/Louppe") {
            let volume = URL(fileURLWithPath: root, isDirectory: true)
            XCTAssertEqual(SourceOrganizationStorageSafety.detect(at: volume).fileSystemName, "exfat")
            bases.append((volume, "exfat"))
        }
        for (base, label) in bases {
            for replaceSource in [false, true] {
                try assertFoundationWindowReplacement(base: base, label: "\(label) replaceSource=\(replaceSource)",
                                                      replaceSource: replaceSource)
            }
        }
    }

    private func assertFoundationWindowReplacement(base: URL, label: String, replaceSource: Bool) throws {
        let fixture = try Fixture(named: "FoundationWindow", base: base)
        defer { fixture.remove() }
        let source = fixture.source.appendingPathComponent("PHOTO.JPG")
        let original = Data("original photo bytes".utf8)
        try original.write(to: source)
        let item = Self.item(source, size: Int64(original.count))
        let plan = try ExportWorker.makePlan(for: [item], in: fixture.destination, mode: .move)
        let replaced = replaceSource ? fixture.source : fixture.destination
        let retained = fixture.root.appendingPathComponent("Retained", isDirectory: true)
        let foreign = Data("foreign bytes".utf8)
        var injected = false
        let result = DurableFileIO.interceptingFoundationRenameForTesting({
            guard !injected else { return }
            injected = true
            do {
                try FileManager.default.moveItem(at: replaced, to: retained)
                try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: false)
                // A same-named foreign file is the worst case for a path move.
                try foreign.write(to: replaced.appendingPathComponent("PHOTO.JPG"))
            } catch { XCTFail("\(label): could not inject replacement: \(error)") }
        }) {
            ExportWorker.move(
                [item], to: fixture.destination, preparedPlan: plan,
                journalDirectory: fixture.journals, journalKind: .organizeSource,
                directorySyncPolicy: .allowUnsupported, renameStrategy: .foundation,
                progress: { _, _ in }
            )
        }
        XCTAssertTrue(injected, label)
        XCTAssertEqual(result.movedFiles, 0, label)
        XCTAssertEqual(result.failedPhotos, 1, label)
        _ = FileOperationJournal.recoverPendingOperations(directory: fixture.journals)
        // The original keeps its exact bytes in one findable place, and the
        // foreign file is never overwritten, removed, or adopted.
        let all = try fixture.regularFiles()
        let originals = all.filter { (try? Data(contentsOf: $0)) == original }
        let foreigners = all.filter { (try? Data(contentsOf: $0)) == foreign }
        XCTAssertEqual(originals.count, 1, "\(label): \(all.map(\.path))")
        XCTAssertEqual(foreigners.count, 1, "\(label): \(all.map(\.path))")
        if replaceSource {
            XCTAssertEqual(originals.first?.standardizedFileURL.path,
                           retained.appendingPathComponent("PHOTO.JPG").standardizedFileURL.path, label)
        }
        // Any journal left behind stays retryable rather than silently resolved.
        if FileOperationJournal.hasPendingOperations(directory: fixture.journals) {
            let again = FileOperationJournal.recoverPendingOperations(directory: fixture.journals)
            XCTAssertGreaterThan(again.unresolvedOperations, 0, label)
        }
        print("AUD-05 \(label): files=\(all.map { $0.path.replacingOccurrences(of: fixture.root.path, with: "") }) pending=\(FileOperationJournal.hasPendingOperations(directory: fixture.journals))")
    }

    // MARK: Helpers

    private static func item(_ url: URL, size: Int64) -> PhotoItem {
        PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil,
            captureDate: nil, cameraModel: nil, lensModel: nil,
            fileSize: size, rating: .yes)
    }

    static func patternedData(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for index in 0..<count { buffer[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 13) }
        }
        return data
    }

    static func digest(_ url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url)))
    }

    private func setXattr(_ name: String, _ value: Data, on url: URL) throws {
        let result = value.withUnsafeBytes {
            setxattr(url.path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func xattr(_ name: String, of url: URL) throws -> Data {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes {
            getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
        }
        guard read == size else { throw POSIXError(.EIO) }
        return data
    }
}

private struct Fixture {
    let root: URL
    let source: URL
    let destination: URL
    let journals: URL

    init(named name: String, base: URL = FileManager.default.temporaryDirectory) throws {
        root = base.appendingPathComponent("LouppeTransfer-\(name)-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Source", isDirectory: true)
        destination = root.appendingPathComponent("Destination", isDirectory: true)
        // Journals stay on the local volume, as in production.
        journals = FileManager.default.temporaryDirectory
            .appendingPathComponent("LouppeTransferJournals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: journals)
    }

    func regularFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []
        )
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && !$0.lastPathComponent.hasPrefix("._")
        }
    }

    private var journalMarker: String { "/" + journals.lastPathComponent + "/" }
    private var destinationMarker: String { "/" + root.lastPathComponent + "/Destination" }

    func isMedia(_ event: DurableFileIO.SyncEventForTesting) -> Bool {
        event.path.contains(destinationMarker)
    }

    /// J = journal, T = temporary media file, D = destination directory;
    /// + full sync, - plain fsync; f = file, d = directory.
    func classify(_ event: DurableFileIO.SyncEventForTesting) -> String? {
        let kind: String
        if event.path.contains(journalMarker) {
            kind = "J"
        } else if event.path.contains(destinationMarker) {
            kind = event.isDirectory ? "D" : "T"
        } else {
            return nil
        }
        return kind + (event.fullSync ? "+" : "-") + (event.isDirectory ? "d" : "f")
    }
}

private final class SyncLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DurableFileIO.SyncEventForTesting] = []
    var events: [DurableFileIO.SyncEventForTesting] { lock.withLock { stored } }
    func record(_ event: DurableFileIO.SyncEventForTesting) { lock.withLock { stored.append(event) } }
}

private final class ProgressRecorder: @unchecked Sendable {
    struct Value: Equatable { let completed: Int64; let total: Int64 }
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func record(completed: Int64, total: Int64) {
        lock.withLock { stored.append(.init(completed: completed, total: total)) }
    }
}

/// Disposable images mounted under one /private/tmp folder; never other disks.
final class DisposableImages {
    let base: URL
    private var mounts: [URL] = []

    init(named name: String) throws {
        base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("LouppeImages-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func attachNew(megabytes: Int, fileSystem: String, name: String) throws -> URL {
        let image = base.appendingPathComponent("\(name).dmg")
        var arguments = ["create", "-quiet", "-size", "\(megabytes)m", "-fs", fileSystem, "-volname", name]
        if fileSystem == "ExFAT" { arguments += ["-layout", "MBRSPUD"] }
        try run(arguments + [image.path])
        let mount = base.appendingPathComponent("mnt-\(name)", isDirectory: true)
        try run(["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        mounts.append(mount)
        return mount
    }

    func detach(_ mount: URL) throws {
        var detached = false
        for _ in 0..<3 where !detached {
            detached = (try? run(["detach", "-quiet", mount.path])) != nil
            if !detached { Thread.sleep(forTimeInterval: 0.5) }
        }
        if !detached { try run(["detach", "-quiet", "-force", mount.path]) }
        mounts.removeAll { $0 == mount }
    }

    func cleanUp() {
        for mount in mounts { try? detach(mount) }
        try? FileManager.default.removeItem(at: base)
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DisposableImages", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "hdiutil \(arguments.first ?? "") failed"])
        }
    }
}
