import AppKit
import Darwin
import Foundation

@main
struct StateAuditRepro {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/private/tmp/louppe-audit-2026-09-29/state-fixture", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let preferences = UserDefaults(suiteName: "LouppeAudit-\(UUID().uuidString)")!
        var review = ReviewPreferences()
        review.advancesAfterDecision = false
        review.save(to: preferences)
        let store = SessionStore(reviewDefaults: preferences)
        store.items = ["A", "B", "C"].map { name in
            PhotoItem(id: "\(name).jpg", primaryURL: root.appendingPathComponent("\(name).jpg"), pairedURL: nil,
                      captureDate: Date(timeIntervalSince1970: Double(name.utf8.first!)),
                      cameraModel: name, lensModel: nil, fileSize: 1)
        }
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        store.setIndex(0)
        store.setSelection([0, 2])
        store.commitSelectionAnchor()
        var filter = store.filter
        filter.excludedCameras = ["A"]
        store.filter = filter
        print("FILTER SELECTION: visible=\(store.visibleIndices), selected=\(store.selectedIndices.sorted()), current=\(store.currentIndex), displayed=\(store.currentItem!.id)")
        store.rate(.yes)
        print("RATE AFTER FILTER: displayed=\(store.currentItem!.id), ratings=\(store.items.map { $0.rating.rawValue })")

        let groupedItems = ["Camera", "camera", "Camera"].enumerated().map { index, camera in
            PhotoItem(id: "\(index).jpg", primaryURL: root.appendingPathComponent("\(index).jpg"), pairedURL: nil,
                      captureDate: Date(timeIntervalSince1970: Double(index)), cameraModel: camera, lensModel: nil, fileSize: 1)
        }
        var prepared = PreparedSessionIndex()
        let cameraSort = PhotoSort(key: .camera, ascending: true)
        prepared.rebuildItems(groupedItems, sort: cameraSort)
        prepared.applyFilter(PhotoFilter(), to: groupedItems, sort: cameraSort, isGroupingEnabled: true)
        print("CAMERA COLLATION: localized comparison=\("Camera".localizedStandardCompare("camera").rawValue), groups=\(prepared.visibleGroups.map { ($0.title!, $0.indices) }), uniqueGroupIDs=\(Set(prepared.visibleGroups.map(\.id)).count), groupCount=\(prepared.visibleGroups.count)")

        let pairedStore = SessionStore(reviewDefaults: preferences)
        pairedStore.items = ["SHOT.NEF", "SHOT.JPG"].map { name in
            PhotoItem(id: name, primaryURL: root.appendingPathComponent(name), pairedURL: nil,
                      captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
        }
        pairedStore.phase = .ready
        pairedStore.rebuildDerivedDataForTesting(sourceFolder: root)
        pairedStore.filter.excludedTypes = ["JPEG"]
        pairedStore.cleanUpScope = .filtered
        print("HIDDEN PAIR CLEANUP: mode=\(pairedStore.rawJPEGPairingMode), visible=\(pairedStore.visibleIndices), excluded=JPEG, pairedJPEGTargets=\(pairedStore.cleanUpCounts(for: .pairedJPEGs).files)")
        pairedStore.resetFilter()
        pairedStore.setIndex(0)
        pairedStore.cleanUpScope = .selected
        print("UNSELECTED PAIR CLEANUP: effectiveSelection=\(pairedStore.effectiveSelection.sorted()), current=\(pairedStore.currentItem!.id), pairedJPEGTargets=\(pairedStore.cleanUpCounts(for: .pairedJPEGs).files)")

        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        let original = photos.appendingPathComponent("Original.jpg")
        try Data("original-photo-bytes".utf8).write(to: original)
        let unusableBackup = root.appendingPathComponent("BackupBlockedByRegularFile")
        try Data("blocked".utf8).write(to: unusableBackup)
        let persistence = SessionPersistence(backupDirectory: unusableBackup,
            afterSidecarReplaceForTesting: {
                throw DurableFileIO.IOError.system(operation: "fsync", path: photos.path, code: EIO)
            })
        let read = await persistence.read(for: photos)
        let identity = try FileOperationJournal.captureIdentity(at: original)
        let session = SessionFile(version: SessionConstants.currentSchemaVersion,
            sourcePath: photos.path, scannedAt: Date(), entries: [
                SessionEntry(filename: "Original.jpg", pairedFilename: nil, rating: "yes", ratedAt: Date(), fileIdentity: identity)
            ], fileIDEncoding: .percentEncodedFileSystemPath)
        let result = await persistence.save(session, for: photos, sequence: 1, access: read.access!)
        print("POST-RENAME SYNC FAILURE + BLOCKED BACKUP: result=\(result), canDiscard=\(result.canDiscardInMemoryState)")
        print("BACKUP IS REGULAR FILE: \((try unusableBackup.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true)")
        let readOnlyPersistence = SessionPersistence(backupDirectory: root.appendingPathComponent("ReadOnlyBackup", isDirectory: true))
        let readOnlyAccess = await readOnlyPersistence.read(for: photos)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: photos.path)
        let readOnlySave = await readOnlyPersistence.save(session, for: photos, sequence: 1, access: readOnlyAccess.access!)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: photos.path)
        print("READ-ONLY SIDECAR ERROR CLASSIFICATION: \(readOnlySave)")
        let customError = DurableFileIO.IOError.system(operation: "open", path: photos.path, code: EACCES) as NSError
        print("DURABLE ERROR NSError DOMAIN: \(customError.domain), code=\(customError.code), expected POSIX domain=\(NSPOSIXErrorDomain)")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print("REPRESENTATIVE ONE-ENTRY ENCODED BYTES: \(try encoder.encode(session).count)")
    }
}
