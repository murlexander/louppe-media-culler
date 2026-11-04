import CryptoKit
import Darwin
import Foundation

// Copy crash-boundary check. Built by Tests/run_copy_crash_boundary_check.sh
// with -D DEBUG -D LOUPPE_TESTING. Each `crash` run SIGKILLs itself
// immediately before the Nth file/directory flush of a RAW+JPEG Copy (or
// during the JPEG's data copy), modelling process death at that boundary.
// A fresh `recover` process then runs launch recovery and checks originals,
// no-overwrite, leftovers and retry. Page caches survive SIGKILL, so this is
// not a power-loss test.

@main
enum CrashBoundaryChecks {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3, !arguments[1].hasPrefix("crash") || arguments.count == 4 else {
            fail("usage: prepare|prepare-organize ROOT | crash|crash-organize ROOT N|data | recover|recover-organize ROOT")
        }
        let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let fixture = Fixture(root: root)
        switch arguments[1] {
        case "prepare":
            fixture.prepare()
        case "crash":
            crash(fixture, at: arguments[3])
        case "recover":
            recover(fixture)
        case "prepare-organize":
            OrganizeFixture(root: root).prepare()
        case "crash-organize":
            crashOrganize(OrganizeFixture(root: root), at: arguments[3])
        case "recover-organize":
            recoverOrganize(OrganizeFixture(root: root))
        default:
            fail("unknown mode \(arguments[1])")
        }
    }

    /// Organize moves originals inside the source folder; on ExFAT it uses
    /// the path-based Foundation fallback and reduced directory durability.
    static func crashOrganize(_ fixture: OrganizeFixture, at boundary: String) {
        let counter = Counter()
        let target = Int(boundary)
        let item = PhotoItem(id: "A.NEF", primaryURL: fixture.raw, pairedURL: fixture.jpeg,
            captureDate: nil, cameraModel: nil, lensModel: nil,
            fileSize: 5, pairedFileSize: 5, rating: .yes)
        let plan: SourceOrganizationPlan
        do {
            plan = try SourceOrganizationPlanner.makePlan(
                sourceFolder: fixture.source, selectedItems: [item],
                familyContextItems: [item],
                configuration: SourceOrganizationConfiguration(
                    levels: [.init(kind: .decision, isEnabled: true)],
                    dateGranularity: .day, existingFolderDepth: .topLevel,
                    containerName: "Organized"
                ),
                knownOriginFolderPathBytesByFileID: [:]
            )
        } catch { fail("plan failed: \(error)") }
        guard plan.canExecute else { fail("plan cannot execute") }
        let result = DurableFileIO.observingSyncsForTesting({ _ in
            if let target, counter.next() == target { kill(getpid(), SIGKILL) }
        }) {
            SourceOrganizationWorker.organize(plan, journalDirectory: fixture.journals,
                                              progress: { _, _ in })
        }
        print("COMPLETED moved=\(result.movedFiles) flushes=\(counter.value) fs=\(plan.storageSafety.fileSystemName ?? "-")")
    }

    static func recoverOrganize(_ fixture: OrganizeFixture) {
        var problems: [String] = []
        let first = FileOperationJournal.recoverPendingOperations(directory: fixture.journals)
        let pending = FileOperationJournal.hasPendingOperations(directory: fixture.journals)
        let second = FileOperationJournal.recoverPendingOperations(directory: fixture.journals)
        if pending && second.unresolvedOperations == 0 {
            problems.append("pending journal is not reported unresolved on retry")
        }
        let files = fixture.regularFiles()
        for (name, digest) in fixture.originalDigests {
            let copies = files.filter { (try? Fixture.digest($0)) == digest }
            if copies.count != 1 {
                problems.append("\(name) found \(copies.count) times")
            } else if let only = copies.first, only.lastPathComponent != name && !pending {
                problems.append("\(name) renamed to \(only.lastPathComponent)")
            }
        }
        if (try? Data(contentsOf: fixture.foreign)) != Fixture.foreignBytes {
            problems.append("foreign file changed")
        }
        // The ExFAT move probe runs before any photo moves and is not
        // journaled; death inside it leaves one tiny hidden probe file.
        // Report it, but it is not a media or journal inconsistency.
        let probes = files.filter { $0.lastPathComponent.hasPrefix(".louppe-move-probe-") }
        let leftovers = files.filter {
            $0.lastPathComponent.hasPrefix(".louppe-") && !probes.contains($0)
        }
        if !pending && !leftovers.isEmpty { problems.append("resolved recovery left \(leftovers.map(\.lastPathComponent))") }
        if !probes.isEmpty { print("WARN_PROBE_LEFTOVER \(probes.map(\.lastPathComponent))") }
        let layout = files.map { $0.path.replacingOccurrences(of: fixture.source.path, with: "") }.sorted()
        print("RECOVERY restored=\(first.restoredFiles) preservedMoves=\(first.preservedMoves) unresolved=\(first.unresolvedOperations) pending=\(pending) files=\(layout)")
        if problems.isEmpty {
            print("CHECK_OK")
        } else {
            print("CHECK_FAILED \(problems.joined(separator: "; "))")
            exit(1)
        }
    }

    static func crash(_ fixture: Fixture, at boundary: String) {
        let counter = Counter()
        let target = Int(boundary)
        let destination = fixture.destination
        let isCancelled: @Sendable () -> Bool = {
            // `data`: die while the JPEG's bytes are being written.
            if boundary == "data",
               let names = try? FileManager.default.contentsOfDirectory(atPath: destination.path),
               names.contains(where: { $0.hasSuffix("-1.partial") }) {
                kill(getpid(), SIGKILL)
            }
            return false
        }
        let result = DurableFileIO.observingSyncsForTesting({ _ in
            if let target, counter.next() == target { kill(getpid(), SIGKILL) }
        }) {
            ExportWorker.copy(
                [fixture.item], to: fixture.destination,
                journalDirectory: fixture.journals,
                isCancelled: isCancelled,
                progress: { _, _ in }
            )
        }
        print("COMPLETED copied=\(result.copiedFiles) flushes=\(counter.value)")
    }

    static func recover(_ fixture: Fixture) {
        var problems: [String] = []
        let first = FileOperationJournal.recoverPendingOperations(directory: fixture.journals)
        let pending = FileOperationJournal.hasPendingOperations(directory: fixture.journals)
        let second = FileOperationJournal.recoverPendingOperations(directory: fixture.journals)
        if pending && second.unresolvedOperations == 0 {
            problems.append("pending journal is not reported unresolved on retry")
        }
        for (url, digest) in fixture.sourceDigests where (try? Fixture.digest(url)) != digest {
            problems.append("original changed: \(url.lastPathComponent)")
        }
        if (try? Data(contentsOf: fixture.foreign)) != Fixture.foreignBytes {
            problems.append("foreign destination file changed")
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: fixture.destination.path)) ?? []).sorted()
        let leftovers = names.filter { $0.hasPrefix(".louppe-") }
        if !pending && !leftovers.isEmpty { problems.append("resolved recovery left \(leftovers)") }
        for name in names where !name.hasPrefix(".") && name != "A.JPG" {
            let url = fixture.destination.appendingPathComponent(name)
            let matches = fixture.sourceDigests.contains { $0.value == (try? Fixture.digest(url)) }
            if !matches { problems.append("unexpected destination bytes in \(name)") }
        }
        // A resolved state must accept an ordinary retry of the same photo.
        var retry = "-"
        if !pending {
            let result = ExportWorker.copy(
                [fixture.item], to: fixture.destination,
                journalDirectory: fixture.journals, progress: { _, _ in }
            )
            retry = "copied=\(result.copiedFiles) failed=\(result.failedPhotos)"
            if result.copiedFiles != 2 || result.requiresRecovery {
                problems.append("retry failed: \(result.failureMessage ?? "-")")
            }
        }
        print("RECOVERY restored=\(first.restoredFiles) preservedCopies=\(first.preservedCopies) removedPartials=\(first.removedPartialCopies) unresolved=\(first.unresolvedOperations) pending=\(pending) destination=\(names) retry=\(retry)")
        if problems.isEmpty {
            print("CHECK_OK")
        } else {
            print("CHECK_FAILED \(problems.joined(separator: "; "))")
            exit(1)
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func next() -> Int { lock.withLock { count += 1; return count } }
}

struct Fixture {
    static let foreignBytes = Data("foreign file already at the destination".utf8)
    let root: URL
    var source: URL { root.appendingPathComponent("Source", isDirectory: true) }
    var destination: URL { root.appendingPathComponent("Destination", isDirectory: true) }
    /// Journals stay on the local system volume, as in production.
    var journals: URL { Fixture.localJournals(for: root) }
    var raw: URL { source.appendingPathComponent("A.RAF") }
    var jpeg: URL { source.appendingPathComponent("A.JPG") }
    /// Occupies the JPEG's natural name so Copy must reserve a suffix.
    var foreign: URL { destination.appendingPathComponent("A.JPG") }
    var digestsURL: URL { root.appendingPathComponent("digests.json") }

    var item: PhotoItem {
        PhotoItem(id: "A.RAF", primaryURL: raw, pairedURL: jpeg,
            captureDate: nil, cameraModel: nil, lensModel: nil,
            fileSize: 64 * 1024, pairedFileSize: 8 * 1_048_576, rating: .yes)
    }

    var sourceDigests: [URL: Data] {
        [raw: try! Data(contentsOf: digestsURL.appendingPathExtension("raw")),
         jpeg: try! Data(contentsOf: digestsURL.appendingPathExtension("jpg"))]
    }

    func prepare() {
        let fm = FileManager.default
        try! fm.createDirectory(at: source, withIntermediateDirectories: true)
        try! fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try! Self.patterned(64 * 1024, seed: 3).write(to: raw)
        try! Self.patterned(8 * 1_048_576, seed: 7).write(to: jpeg)
        try! Self.foreignBytes.write(to: foreign)
        try! Self.digest(raw).write(to: digestsURL.appendingPathExtension("raw"))
        try! Self.digest(jpeg).write(to: digestsURL.appendingPathExtension("jpg"))
    }

    static func localJournals(for root: URL) -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("\(root.lastPathComponent)-journals", isDirectory: true)
    }

    static func patterned(_ count: Int, seed: UInt8) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for index in 0..<count { buffer[index] = UInt8(truncatingIfNeeded: index &* 31) &+ seed }
        }
        return data
    }

    static func digest(_ url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url)))
    }
}

struct OrganizeFixture {
    let root: URL
    var source: URL { root.appendingPathComponent("Photos", isDirectory: true) }
    var journals: URL { Fixture.localJournals(for: root) }
    var raw: URL { source.appendingPathComponent("A.NEF") }
    var jpeg: URL { source.appendingPathComponent("A.JPG") }
    var xmp: URL { source.appendingPathComponent("A.xmp") }
    /// An unrelated file the operation must never touch.
    var foreign: URL { source.appendingPathComponent("NOTES.TXT") }

    var originalDigests: [String: Data] {
        ["A.NEF": Data(SHA256.hash(data: Data("raw original".utf8))),
         "A.JPG": Data(SHA256.hash(data: Data("jpeg original".utf8))),
         "A.xmp": Data(SHA256.hash(data: Data("<x:xmpmeta/>".utf8)))]
    }

    func prepare() {
        try! FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try! Data("raw original".utf8).write(to: raw)
        try! Data("jpeg original".utf8).write(to: jpeg)
        try! Data("<x:xmpmeta/>".utf8).write(to: xmp)
        try! Fixture.foreignBytes.write(to: foreign)
    }

    func regularFiles() -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []
        )
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && !$0.lastPathComponent.hasPrefix("._")
        }
    }
}
