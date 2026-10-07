import XCTest
import CryptoKit
import AppKit
import SwiftUI
@testable import Louppe

final class LocalizationTests: XCTestCase {
    func testLaunchedMacOSLanguagePreference() {
        if let expected = ProcessInfo.processInfo.environment["LOUPPE_TEST_LANGUAGE"] {
            XCTAssertEqual(L10n.language, expected)
        } else {
            XCTAssertTrue(L10n.supportedLanguages.contains(L10n.language))
        }
    }

    func testLanguagePreferencesAndRegionalVariants() {
        XCTAssertEqual(L10n.language(for: ["es-MX", "en-US"]), "es")
        XCTAssertEqual(L10n.language(for: ["zh-CN"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["zh-SG"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["zh-Hant", "pt-BR"]), "pt")
        XCTAssertEqual(L10n.language(for: ["zh-TW"]), "en")
        XCTAssertEqual(L10n.language(for: ["hi-IN"]), "hi")
        XCTAssertEqual(L10n.language(for: ["ar-SA"]), "ar")
        XCTAssertEqual(L10n.language(for: ["fr-FR", "es-ES"]), "es")
        XCTAssertEqual(L10n.language(for: ["en-GB", "ar"]), "en")
        XCTAssertEqual(L10n.language(for: ["de-DE"]), "en")
    }

    func testCompleteCatalogsPreserveSafetyArgumentsAndFormats() throws {
        let english = try catalog("en")
        XCTAssertGreaterThan(english.count, 1000)
        for language in L10n.supportedLanguages {
            let translated = try catalog(language)
            XCTAssertEqual(Set(translated.keys), Set(english.keys), language)
            for (key, value) in translated {
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertEqual(L10n.placeholders(in: key), L10n.placeholders(in: value), "\(language): \(key)")
                if key.contains("⌘Z") { XCTAssertTrue(value.contains("⌘Z"), "\(language): \(key)") }
                if key.contains(".acr") { XCTAssertTrue(value.contains(".acr"), "\(language): \(key)") }
                if key.contains("xmp:Label") { XCTAssertTrue(value.contains("xmp:Label"), "\(language): \(key)") }
                for token in ["%.1f", "%.0f", "%.2f"] where key.contains(token) {
                    XCTAssertTrue(value.contains(token), "\(language): \(key)")
                }
            }
        }
    }

    func testEachRequestedLanguageLoadsItsOwnBundledText() {
        let expected = ["es": "Copiar", "zh-Hans": "复制", "hi": "कॉपी करें", "pt": "Copiar", "ar": "نسخ"]
        for (language, copy) in expected {
            XCTAssertEqual(L10n.render("Copy", language: language), copy)
        }
    }

    func testInterpolationDoesNotTranslateOrReinterpretFilenames() {
        let filename = "No {1} — ملف.JPG"
        let size = "12 MB"
        let message: L10n.Message = "\(filename) (about \(size)) will be moved to the Trash. The matching \("RAW") files will stay in the folder."
        for language in L10n.supportedLanguages {
            let rendered = L10n.render(message, language: language)
            XCTAssertTrue(rendered.contains(filename), language)
            XCTAssertTrue(rendered.contains(size), language)
            XCTAssertTrue(rendered.contains("RAW"), language)
            XCTAssertFalse(rendered.contains("{0}"), language)
        }
    }

    func testEnglishFallbackForUnknownLanguageAndMissingKey() {
        let message: L10n.Message = "New untranslated warning for \("{0}.JPG")"
        XCTAssertEqual(L10n.render(message, language: "fr"), "New untranslated warning for {0}.JPG")
        XCTAssertEqual(L10n.render(message, language: "ar"), "New untranslated warning for {0}.JPG")
    }

    func testStoredMetadataAndFilenameRecipeWordsStayEnglish() {
        XCTAssertEqual(PhotoColorLabel.red.displayName, "Red")
        XCTAssertEqual(PhotoColorLabel.purple.rawValue, "purple")
        XCTAssertEqual(MediaKind.photo.label, "Photos")
        XCTAssertEqual(SessionConstants.sidecarName, ".louppe_session.json")
        XCTAssertEqual(Rating.yes.rawValue, "yes")
    }

    @MainActor
    func testFolderAndVideoFilterIdentitiesStayStable() {
        let store = SessionStore(automaticallyRecoversInterruptedOperations: false)
        store.items = [PhotoItem(primaryFile: PhotoFile(
            id: "root.JPG", url: URL(fileURLWithPath: "/tmp/root.JPG"),
            captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1,
            rating: .undecided
        ))]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        XCTAssertEqual(store.availableSubfolders, ["None"])
        XCTAssertEqual(store.subfolderCounts["None"], 1)
        XCTAssertEqual(store.availableCameras, ["Unknown"])
        XCTAssertEqual(store.availableLenses, ["Unknown"])
        store.filter.excludedSubfolders = ["None"]
        XCTAssertTrue(store.visibleIndices.isEmpty)
    }

    @MainActor
    func testArabicMirrorsLeadingLayoutAndKeepsShortcutOrder() throws {
        let english = measuredLayout(language: "en")
        let arabic = measuredLayout(language: "ar")
        XCTAssertLessThan(english.first, english.second)
        XCTAssertGreaterThan(arabic.first, arabic.second)
        XCTAssertEqual(arabic.shortcutDirection, .leftToRight)
        XCTAssertEqual(english.shortcutDirection, .leftToRight)
    }

    // These contracts run again in isolated processes for every app language.
    // Expected backup names match the pre-localization on-disk protocol.
    func testBackupAndLockKeepExistingIdentityAndRecoverRatings() async throws {
        let root = try localizationFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos")
        let backups = root.appendingPathComponent("Backups")
        let file = photos.appendingPathComponent("A.JPG")
        try Data("original".utf8).write(to: file)
        let identity = try SessionPersistence.SourceFolderIdentity.capture(at: photos)
        let volume = identity.volumeUUIDString.map { "uuid:\($0)" }
            ?? "legacy:\(identity.volumeRootPath):\(identity.systemNumber)"
        let input = "\(volume)|\(identity.fileNumber)|\(identity.birthTime.seconds)|\(identity.birthTime.nanoseconds)"
        let digest = SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let backup = backups.appendingPathComponent("folder-\(digest).json")
        let lock = FileManager.default.temporaryDirectory
            .appendingPathComponent("Louppe/SessionLocks/folder-\(digest).lock")
        defer { try? FileManager.default.removeItem(at: lock) }
        let persistence = SessionPersistence(backupDirectory: backups)
        let session = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: photos.path,
            scannedAt: Date(),
            entries: [SessionEntry(
                filename: "A.JPG", pairedFilename: nil, rating: "yes", ratedAt: nil,
                fileIdentity: try FileOperationJournal.captureIdentity(at: file)
            )],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let saved = await persistence.save(session, for: photos, sequence: 1)
        XCTAssertEqual(saved, .savedToSidecar)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        try FileManager.default.removeItem(at: SessionPersistence.sidecarURL(for: photos))
        let recovered = await SessionPersistence(backupDirectory: backups).read(for: photos)
        XCTAssertEqual(recovered.session?.entries.first?.rating, "yes")
        XCTAssertEqual(recovered.session?.entries.first?.filename, "A.JPG")
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    }

    func testExportGroupingRetainsXMPFamilyAndGeneratedPacket() async throws {
        let root = try localizationFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Photos/A.JPG")
        try Data("original".utf8).write(to: file)
        let photo = PhotoItem(primaryFile: PhotoFile(
            id: "A.JPG", url: file, captureDate: nil, cameraModel: nil,
            lensModel: nil, fileSize: 8,
            scannedIdentity: try FileOperationJournal.captureIdentity(at: file), rating: .yes
        ))
        let xmp = try await XMPExportPlanner.prepare(
            selected: [photo], familyContextItems: [photo], profile: .universal,
            visibleDecisionKeywords: false, allowExternalLabelReplacement: false
        )
        let family = try XCTUnwrap(xmp.families.first)
        XCTAssertNotNil(family.finalPacket)
        let destination = root.appendingPathComponent("Destination")
        let plan = try ExportWorker.makePlan(for: [photo], in: destination, xmpPlan: xmp)
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items.first?.itemID, "xmp:\(family.id)")
        XCTAssertEqual(Set(plan.items.flatMap(\.files).map { $0.target.lastPathComponent }), ["A.JPG", "A.xmp"])
        let ordinary = try ExportWorker.makePlan(for: [photo], in: destination)
        XCTAssertEqual(ordinary.items.first?.itemID, "item:A.JPG")
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    }

    func testUndoJournalIdentityAndOriginalBytesRemainStable() throws {
        let root = try localizationFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos")
        let file = photos.appendingPathComponent("A.JPG")
        try Data("original".utf8).write(to: file)
        let photo = PhotoItem(primaryFile: PhotoFile(
            id: "A.JPG", url: file, captureDate: nil, cameraModel: nil,
            lensModel: nil, fileSize: 8,
            scannedIdentity: try FileOperationJournal.captureIdentity(at: file), rating: .yes
        ))
        let plan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: photos, selectedItems: [photo], familyContextItems: [photo],
            configuration: FileRenamingPlanner.sourceConfiguration(customBaseName: "Renamed"),
            knownOriginFolderPathBytesByFileID: [:]
        )
        XCTAssertTrue(plan.canExecute)
        let journals = root.appendingPathComponent("Journals")
        let result = SourceOrganizationWorker.organize(plan, journalDirectory: journals) { _, _ in }
        XCTAssertEqual(result.movedFiles, 1, result.failureMessage ?? "")
        let undo = try XCTUnwrap(result.undoRecord)
        XCTAssertEqual(undo.reversePlan.items.first?.itemID, "undo:\(try XCTUnwrap(plan.workerPlan.items.first?.itemID))")
        let restored = SourceOrganizationWorker.undo(undo, currentItems: [], journalDirectory: journals) { _, _ in }
        XCTAssertEqual(restored.movedFiles, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    }

    private func localizationFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LouppeLocalization-\(UUID().uuidString)")
        for name in ["Photos", "Destination"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }
        return root
    }

    private func catalog(_ language: String) throws -> [String: String] {
        let path = try XCTUnwrap(L10n.resourceBundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: String])
    }

    @MainActor
    private func measuredLayout(language: String) -> (first: CGFloat, second: CGFloat, shortcutDirection: LayoutDirection) {
        let first = NSView(frame: .zero)
        let second = NSView(frame: .zero)
        var direction: LayoutDirection = .rightToLeft
        let content = HStack(spacing: 20) {
            LayoutProbe(view: first).frame(width: 40, height: 20)
            LayoutProbe(view: second).frame(width: 40, height: 20)
            DirectionProbe { direction = $0 }
                .environment(\.layoutDirection, .leftToRight)
                .frame(width: 40, height: 20)
        }.localizedInterface(language: language)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        host.layoutSubtreeIfNeeded()
        return (first.convert(first.bounds, to: host).midX, second.convert(second.bounds, to: host).midX, direction)
    }
}

private struct LayoutProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct DirectionProbe: NSViewRepresentable {
    @Environment(\.layoutDirection) private var direction
    let record: (LayoutDirection) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { record(direction) }
}
