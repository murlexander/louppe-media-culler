import Foundation
import CryptoKit
import Darwin
@testable import Louppe

func item(_ url: URL) -> PhotoItem {
    PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
}
func emit(_ s: String) { print(s); fflush(stdout) }
let root = URL(fileURLWithPath: "/private/tmp/louppe-audit-2026-09-29/file-safety-fixture-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let destination = root.appendingPathComponent("destination")
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
if CommandLine.arguments[1] == "collision" {
    let urls = [root.appendingPathComponent("PHOTO.JPG"), root.appendingPathComponent("PHOTO.jpg")]
    let metadata = XMPPublicationMetadata(decision: .undecided, stars: nil, colorLabel: nil, profile: .universal)
    let members = try urls.map { try XMPStemFamilyMember(mediaURL: $0, metadata: metadata) }
    let resolved = try XMPSidecarResolver.resolve(members: members, directoryEntries: [], caseSensitiveNames: true)
    emit("resolver families=\(resolved.count) members=\(resolved[0].members.count) disposition=\(resolved[0].disposition)")
    let paths = Set(members.map(\.mediaPath))
    let family = XMPExportPreparedFamily(id: "same-stem", filenames: urls.map(\.lastPathComponent), selectedMediaPaths: paths, allMediaPaths: paths, category: .create, message: "", changeCounts: XMPPublicationChangeCounts(), bestEffortFilenames: [], excludedACRCompanionCount: 0, canonicalSourceWasPresent: false, recognizedApplicationPacketCount: 0, canonicalSource: nil, canonicalSourceIdentity: nil, canonicalSourceDigest: nil, finalPacket: Data("packet".utf8), applicationPackets: [], sameStemConflict: nil)
    let plan = XMPExportPreparedPlan(selectedItemCount: 2, physicalFileCount: 2, families: [family])
    emit("calling actual makePlan")
    _ = try ExportWorker.makePlan(for: urls.map(item), in: destination, xmpPlan: plan)
    emit("unexpected completion")
} else if CommandLine.arguments[1] == "hidden" {
    let source = root.appendingPathComponent("PHOTO.JPG")
    try Data("photo".utf8).write(to: source)
    let identity = try FileOperationJournal.captureIdentity(at: source)
    let file = PhotoFile(id: "PHOTO.JPG", url: source, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 5, scannedIdentity: identity)
    let selected = PhotoItem(primaryFile: file)
    var configuration = SourceOrganizationConfiguration.initial(hasMultipleTopLevelFolders: false)
    configuration.levels = [.init(kind: .decision, isEnabled: true)]
    configuration.containerName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".Hidden"
    let plan = try SourceOrganizationPlanner.makePlan(sourceFolder: root, selectedItems: [selected], familyContextItems: [selected], configuration: configuration, knownOriginFolderPathBytesByFileID: [:])
    emit("hidden plan canExecute=\(plan.canExecute) target=\(plan.workerPlan.items[0].files[0].target.path)")
    let result = SourceOrganizationWorker.organize(plan, journalDirectory: destination.appendingPathComponent("journals"), progress: { _, _ in })
    let rescanned = try FolderScanner.scan(root, progress: { _ in })
    emit("movedFiles=\(result.movedFiles) requiresRecovery=\(result.requiresRecovery) scanCount=\(rescanned.count) physicalTargetExists=\(FileManager.default.fileExists(atPath: plan.workerPlan.items[0].files[0].target.path)) undoAvailable=\(result.undoRecord != nil)")
    try FileManager.default.removeItem(at: root)
} else if CommandLine.arguments[1] == "retirement" {
    let source = root.appendingPathComponent("PHOTO.xmp")
    let target = root.appendingPathComponent(".louppe-xmp-retired-audit")
    let bytes = Data("old packet".utf8)
    try bytes.write(to: source)
    let journals = root.appendingPathComponent("journals")
    var quarantine: URL!
    do {
        let photo = root.appendingPathComponent("PHOTO.JPG")
        try Data("photo".utf8).write(to: photo)
        let merged = Data("new merged packet".utf8)
        let writer = try FileOperationJournal.start(kind: .exportMove, seeds: [
            .init(itemID: "family", source: photo, destination: destination.appendingPathComponent("PHOTO.JPG")),
            .init(itemID: "family", source: source, destination: destination.appendingPathComponent("PHOTO.xmp"), role: .preparedXMP, expectedSourceDigest: Data(SHA256.hash(data: bytes)), preparedContentDigest: Data(SHA256.hash(data: merged))),
            .init(itemID: "family", source: source, destination: target, role: .retiredXMPSource, expectedSourceDigest: Data(SHA256.hash(data: bytes)))
        ], directory: journals)
        for index in 0..<3 {
            let temporary = writer.temporaryURL(at: index)!
            let finalTarget = index == 0 ? destination.appendingPathComponent("PHOTO.JPG") : index == 1 ? destination.appendingPathComponent("PHOTO.xmp") : target
            try writer.mark(.started, fileAt: index)
            if index == 1 {
                try DurableFileIO.writeNewFile(merged, to: temporary, fullSync: true)
            } else {
                try DurableFileIO.atomicExclusiveRename(from: index == 0 ? photo : source, to: temporary)
            }
            let staged = try FileOperationJournal.captureIdentity(at: temporary)
            try writer.mark(.staged, fileAt: index, identityAt: temporary, expectedIdentity: staged)
            try DurableFileIO.atomicExclusiveRename(from: temporary, to: finalTarget)
            let final = try FileOperationJournal.captureIdentity(at: finalTarget)
            try writer.mark(.completed, fileAt: index, identityAt: finalTarget, expectedIdentity: final)
        }
        quarantine = writer.temporaryURL(at: 2)!
        try DurableFileIO.atomicExclusiveRename(from: target, to: quarantine)
        try DurableFileIO.syncRenameDirectories(from: target, to: quarantine, fullSync: true)
        emit("retirement completed; cleanup quarantined recorded inode before simulated crash")
    }
    let report = FileOperationJournal.recoverPendingOperations(directory: journals)
    emit("retirement unresolvedOperations=\(report.unresolvedOperations) unresolvedFiles=\(report.unresolvedFiles) quarantineExists=\(FileManager.default.fileExists(atPath: quarantine.path)) details=\(report.details)")
    try FileManager.default.removeItem(at: root)
} else if CommandLine.arguments[1] == "scaling" {
    for n in [100, 200, 400, 800] {
        let selected = (0..<n).map { i in PhotoItem(id: "folder-\(i)/PHOTO.JPG", primaryURL: root.appendingPathComponent("folder-\(i)/PHOTO.JPG"), pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1) }
        let start = Date()
        let result = try ExportWorker.makePlan(for: selected, in: destination)
        emit("n=\(n) seconds=\(Date().timeIntervalSince(start)) files=\(result.totalFiles)")
    }
    try FileManager.default.removeItem(at: root)
} else if CommandLine.arguments[1] == "fifo" {
    let source = root.appendingPathComponent("PHOTO.JPG")
    _ = source.withUnsafeFileSystemRepresentation { Darwin.mkfifo($0!, 0o600) }
    let journals = root.appendingPathComponent("journals")
    do {
        let writer = try FileOperationJournal.start(kind: .exportCopy, seeds: [.init(itemID: "photo", source: source, destination: destination.appendingPathComponent("PHOTO.JPG"))], directory: journals)
        try writer.mark(.started, fileAt: 0)
        try DurableFileIO.writeNewFile(Data("copy".utf8), to: writer.temporaryURL(at: 0)!, fullSync: true)
        emit("journal accepted FIFO source; beginning recovery")
    }
    let report = FileOperationJournal.recoverPendingOperations(directory: journals)
    emit("unexpected recovery completion \(report)")
} else {
    let source = root.appendingPathComponent("PHOTO.JPG")
    try Data("original".utf8).write(to: source)
    let journals = root.appendingPathComponent("journals")
    let generated = Data("complete prepared packet".utf8)
    var partial: URL!
    do {
        let writer = try FileOperationJournal.start(kind: .exportMove, seeds: [
            .init(itemID: "family", source: source, destination: destination.appendingPathComponent("PHOTO.JPG")),
            .init(itemID: "family", source: source, destination: destination.appendingPathComponent("PHOTO.xmp"), role: .preparedXMP, preparedContentDigest: Data(SHA256.hash(data: generated)))
        ], directory: journals)
        partial = writer.temporaryURL(at: 1)!
        try writer.mark(.started, fileAt: 1)
        try DurableFileIO.writeNewFile(Data("incomplete".utf8), to: partial, fullSync: true)
        let identity = try FileOperationJournal.captureIdentity(at: partial)
        try writer.mark(.started, fileAt: 1, identityAt: partial, expectedIdentity: identity, includeStatusChange: false)
        emit("durable started partial with exact identity captured")
    }
    let report = FileOperationJournal.recoverPendingOperations(directory: journals)
    emit("report unresolvedOperations=\(report.unresolvedOperations) unresolvedFiles=\(report.unresolvedFiles) removedPartialCopies=\(report.removedPartialCopies) partialExists=\(FileManager.default.fileExists(atPath: partial.path))")
    emit("details=\(report.details)")
    try FileManager.default.removeItem(at: root)
}
