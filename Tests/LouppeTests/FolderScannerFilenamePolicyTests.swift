import Foundation
import XCTest
@testable import Louppe

final class FolderScannerFilenamePolicyTests: XCTestCase {
    func testScanRejectsUnreadableSubfolderInsteadOfReturningPartialSession() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LouppeUnreadable-\(UUID())")
        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? fm.removeItem(at: root)
        }
        try Data("photo".utf8).write(to: locked.appendingPathComponent("hidden.jpg"))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        XCTAssertThrowsError(try FolderScanner.scan(root) { _ in })
    }

    func testScanHonorsCancellationAtFinalValidation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LouppeCancelScan-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let cancelled = FolderScanner.CancelFlag()
        XCTAssertThrowsError(try FolderScanner.scan(
            root,
            isCancelled: { cancelled.isSet },
            beforeFinalIdentityValidation: { cancelled.set() }
        ) { _ in }) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRawJPEGPairsExcludeStandaloneAndAmbiguousFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Louppe-Pair-Discovery-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let names = [
            "MATCH.NEF", "MATCH.JPG", "LONE.JPG",
            "AMBIG.NEF", "AMBIG.CR3", "AMBIG.JPG",
        ]
        let items = names.map { name in
            PhotoItem(
                id: name,
                primaryURL: root.appendingPathComponent(name),
                pairedURL: nil,
                captureDate: nil,
                cameraModel: nil,
                lensModel: nil,
                fileSize: 1
            )
        }

        let pairs = FolderScanner.rawJPEGPairs(from: items, root: root)

        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.raw.url.lastPathComponent, "MATCH.NEF")
        XCTAssertEqual(pairs.first?.jpeg.url.lastPathComponent, "MATCH.JPG")
    }

    /// Issue #5: Hasselblad .3FR and every other RAW pair with a same-stem
    /// JPEG, else HEIF, else JPEG XL. An ambiguous preferred tier never falls
    /// back to a lower one.
    func testScanPairsRAWWithItsPreferredSameStemCompanion() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Louppe-Companions-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for name in [
            "B0001.3FR", "B0001.JPG",
            "B0002.3FR", "B0002.HEIC",
            "B0003.fff", "B0003.hif",
            "N0004.NEF", "N0004.jxl",
            "B0005.3FR", "B0005.JPG", "B0005.HEIC",
            "B0006.3FR", "B0006.JPG", "B0006.jpeg", "B0006.HEIC",
            "B0007.3FR", "B0007.HEIF", "B0007.jxl",
            // Canon and iPhone reuse names: a HEIF elsewhere never pairs.
            "Canon/IMG_0008.CR3", "iPhone/IMG_0008.HEIC",
            "Canon/IMG_0009.CR3", "Canon/IMG_0009.HIF", "iPhone/IMG_0009.HEIC",
            "Card1/DSC_0010.NEF", "Card2/DSC_0010.JPG",
        ] {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: url)
        }

        let items = try FolderScanner.scan(root, pairingMode: .together) { _ in }
        let pairs = Dictionary(uniqueKeysWithValues: items.map {
            ($0.primaryURL.lastPathComponent, $0.pairedURL?.lastPathComponent)
        })

        XCTAssertEqual(pairs["B0001.3FR"], "B0001.JPG")
        XCTAssertEqual(pairs["B0002.3FR"], "B0002.HEIC")
        XCTAssertEqual(pairs["B0003.fff"], "B0003.hif")
        XCTAssertEqual(pairs["N0004.NEF"], "N0004.jxl")
        XCTAssertEqual(pairs["B0005.3FR"], "B0005.JPG")
        XCTAssertEqual(pairs["B0005.HEIC"], .some(nil))
        for name in ["B0006.3FR", "B0006.JPG", "B0006.jpeg", "B0006.HEIC"] {
            XCTAssertEqual(pairs[name], .some(nil), name)
        }
        XCTAssertEqual(pairs["B0007.3FR"], "B0007.HEIF")
        XCTAssertEqual(pairs["B0007.jxl"], .some(nil))
        XCTAssertEqual(pairs["IMG_0008.CR3"], .some(nil))
        XCTAssertEqual(pairs["IMG_0008.HEIC"], .some(nil))
        XCTAssertEqual(pairs["IMG_0009.CR3"], "IMG_0009.HIF")
        XCTAssertEqual(pairs["IMG_0009.HEIC"], .some(nil))
        XCTAssertEqual(pairs["DSC_0010.NEF"], "DSC_0010.JPG")
        XCTAssertEqual(items.count, 17)

        let labels = Dictionary(uniqueKeysWithValues: items.map {
            ($0.primaryURL.lastPathComponent, $0.fileTypeLabel)
        })
        XCTAssertEqual(labels["B0001.3FR"], "RAW + JPEG")
        XCTAssertEqual(labels["B0002.3FR"], "RAW + HEIC")
        XCTAssertEqual(labels["N0004.NEF"], "RAW + JXL")

        let separate = try FolderScanner.scan(root, pairingMode: .separate) { _ in }
        XCTAssertEqual(separate.count, 25)
        XCTAssertTrue(separate.allSatisfy { $0.pairedFile == nil })
    }

    func testAccentedAndUnaccentedNamesNeverPair() {
        let files = [
            mediaURL("cafe.NEF"),
            mediaURL("café.JPG"),
        ]

        for caseSensitiveNames in [true, false] {
            let pairs = FolderScanner.pairFiles(
                files,
                pairingMode: .together,
                filenamePolicy: .init(
                    caseSensitiveNames: caseSensitiveNames
                )
            )

            XCTAssertEqual(pairs.count, 2)
            XCTAssertTrue(pairs.allSatisfy { $0.paired == nil })
        }
    }

    func testCanonicallyEquivalentUnicodeSpellingsRemainSeparate() {
        let composedRAW = rawMediaURL("caf\u{00E9}.NEF")
        let decomposedJPEG = rawMediaURL("cafe\u{0301}.JPG")

        for caseSensitiveNames in [true, false] {
            let pairs = FolderScanner.pairFiles(
                [decomposedJPEG, composedRAW],
                pairingMode: .together,
                filenamePolicy: .init(
                    caseSensitiveNames: caseSensitiveNames
                )
            )

            XCTAssertEqual(pairs.count, 2)
            XCTAssertTrue(pairs.allSatisfy { $0.paired == nil })
        }
    }

    func testCaseOnlyNamesFollowExplicitVolumePolicy() throws {
        let raw = mediaURL("SHOT.NEF")
        let jpeg = mediaURL("shot.JPG")

        let sensitive = FolderScanner.pairFiles(
            [jpeg, raw],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: true)
        )
        XCTAssertEqual(sensitive.count, 2)
        XCTAssertTrue(sensitive.allSatisfy { $0.paired == nil })

        let insensitive = FolderScanner.pairFiles(
            [jpeg, raw],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: false)
        )
        let pair = try XCTUnwrap(insensitive.only)
        XCTAssertEqual(pair.primary.lastPathComponent, "SHOT.NEF")
        XCTAssertEqual(pair.paired?.lastPathComponent, "shot.JPG")
    }

    func testNonASCIICaseFoldingCannotMergeDistinctNames() {
        let pairs = FolderScanner.pairFiles(
            [mediaURL("straße.NEF"), mediaURL("STRASSE.JPG")],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: false)
        )

        XCTAssertEqual(pairs.count, 2)
        XCTAssertTrue(pairs.allSatisfy { $0.paired == nil })
    }

    func testPairingAcrossSubfoldersRequiresOneUnambiguousPair() throws {
        let root = URL(fileURLWithPath: "/Photos", isDirectory: true)
        let raw = root
            .appendingPathComponent("RAW", isDirectory: true)
            .appendingPathComponent("SHOT.NEF")
        let jpeg = root
            .appendingPathComponent("JPEG", isDirectory: true)
            .appendingPathComponent("shot.JPG")

        let pairs = FolderScanner.pairFiles(
            [raw, jpeg],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: false)
        )

        let pair = try XCTUnwrap(pairs.only)
        XCTAssertEqual(pair.primary, raw)
        XCTAssertEqual(pair.paired, jpeg)

        let duplicateJPEG = root
            .appendingPathComponent("Edited", isDirectory: true)
            .appendingPathComponent("SHOT.jpeg")
        let ambiguous = FolderScanner.pairFiles(
            [raw, jpeg, duplicateJPEG],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: false)
        )
        XCTAssertEqual(ambiguous.count, 3)
        XCTAssertTrue(ambiguous.allSatisfy { $0.paired == nil })
    }

    func testUnknownVolumeCapabilityDefaultsToCaseSensitive() {
        let policy = FolderScanner.PairingFilenamePolicy(
            volumeSupportsCaseSensitiveNames: nil
        )
        XCTAssertTrue(policy.caseSensitiveNames)

        let pairs = FolderScanner.pairFiles(
            [mediaURL("SHOT.NEF"), mediaURL("shot.JPG")],
            pairingMode: .together,
            filenamePolicy: policy
        )
        XCTAssertEqual(pairs.count, 2)
        XCTAssertTrue(pairs.allSatisfy { $0.paired == nil })
    }

    func testPairingOrderRemainsIndependentOfInputOrder() {
        let files = [
            mediaURL("zeta.JPG"),
            mediaURL("ALPHA.NEF"),
            mediaURL("alpha.JPG"),
            mediaURL("cafe.NEF"),
            mediaURL("café.JPG"),
        ]
        let policy = FolderScanner.PairingFilenamePolicy(
            caseSensitiveNames: false
        )

        let forward = FolderScanner.pairFiles(
            files,
            pairingMode: .together,
            filenamePolicy: policy
        )
        let reversed = FolderScanner.pairFiles(
            Array(files.reversed()),
            pairingMode: .together,
            filenamePolicy: policy
        )

        XCTAssertEqual(signature(forward), signature(reversed))
    }

    func testAmbiguousRawOrJPEGGroupsNeverPairArbitrarily() {
        let twoRAWs = FolderScanner.pairFiles(
            [
                mediaURL("SHOT.CR2"),
                mediaURL("SHOT.NEF"),
                mediaURL("SHOT.JPG"),
            ],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: true)
        )
        XCTAssertEqual(twoRAWs.count, 3)
        XCTAssertTrue(twoRAWs.allSatisfy { $0.paired == nil })

        let twoJPEGs = FolderScanner.pairFiles(
            [
                mediaURL("FRAME.NEF"),
                mediaURL("FRAME.JPG"),
                mediaURL("FRAME.JPEG"),
            ],
            pairingMode: .together,
            filenamePolicy: .init(caseSensitiveNames: true)
        )
        XCTAssertEqual(twoJPEGs.count, 3)
        XCTAssertTrue(twoJPEGs.allSatisfy { $0.paired == nil })
    }

    func testByteExactIdentitySurvivesProjectionAndRatingLookup() throws {
        let root = rawDirectoryURL("/Photos")
        let composedURL = rawMediaURL("caf\u{00E9}.NEF")
        let decomposedURL = rawMediaURL("cafe\u{0301}.NEF")
        let composedID = FolderScanner.relativeFileIdentity(
            of: composedURL,
            under: root
        )
        let decomposedID = FolderScanner.relativeFileIdentity(
            of: decomposedURL,
            under: root
        )
        XCTAssertNotEqual(composedID, decomposedID)

        let composed = PhotoItem(
            id: composedID,
            primaryURL: composedURL,
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1,
            rating: .yes
        )
        let decomposed = PhotoItem(
            id: decomposedID,
            primaryURL: decomposedURL,
            pairedURL: nil,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1,
            rating: .no
        )
        let projection = try FolderScanner.projectPairingMode(
            .separate,
            from: [composed, decomposed],
            root: root
        )
        XCTAssertEqual(projection.items.count, 2)
        XCTAssertEqual(Set(projection.items.map(\.id)).count, 2)
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: projection.items.map {
                    ($0.id, $0.rating)
                }
            ),
            [composedID: .yes, decomposedID: .no]
        )

        let persisted = SessionFile(
            version: 3,
            sourcePath: root.path,
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: composedID,
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil
                ),
                SessionEntry(
                    filename: decomposedID,
                    pairedFilename: nil,
                    rating: Rating.no.rawValue,
                    ratedAt: nil
                ),
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let decoded = try JSONDecoder().decode(
            SessionFile.self,
            from: JSONEncoder().encode(persisted)
        )
        let ratings = SessionRatingIndex(session: decoded)
        XCTAssertEqual(
            ratings.value(for: projection.items[0].individualFiles[0])?.rating,
            projection.items[0].rating
        )
        XCTAssertEqual(
            ratings.value(for: projection.items[1].individualFiles[0])?.rating,
            projection.items[1].rating
        )
    }

    func testExactSidecarNeverFallsBackToCollidingLegacyAlias() {
        let exactID = "caf%25C3%25A9.NEF"
        let collidingLegacyID = "caf%C3%A9.NEF"
        let literalPercentFile = PhotoFile(
            id: exactID,
            url: mediaURL("caf%C3%A9.NEF"),
            displayRelativePath: collidingLegacyID,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )
        let exactSession = SessionFile(
            version: 3,
            sourcePath: "/Photos",
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: collidingLegacyID,
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil
                ),
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )

        XCTAssertNil(
            SessionRatingIndex(session: exactSession)
                .value(for: literalPercentFile),
            "an exact sidecar entry for another file must not match a legacy decoded alias"
        )

        var legacySession = exactSession
        legacySession.fileIDEncoding = nil
        XCTAssertEqual(
            SessionRatingIndex(session: legacySession)
                .value(for: literalPercentFile)?.rating,
            .yes,
            "unmarked older sidecars should retain their one-way migration fallback"
        )
    }

    func testLegacySidecarAppliesByteDistinctUnicodeRatingsIndependently() {
        let composedName = "caf\u{00E9}.NEF"
        let decomposedName = "cafe\u{0301}.NEF"
        let composedFile = PhotoFile(
            id: "caf%C3%A9.NEF",
            url: mediaURL("composed.NEF"),
            displayRelativePath: composedName,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )
        let decomposedFile = PhotoFile(
            id: "cafe%CC%81.NEF",
            url: mediaURL("decomposed.NEF"),
            displayRelativePath: decomposedName,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 1
        )
        let legacySession = SessionFile(
            version: 2,
            sourcePath: "/Photos",
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: composedName,
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil
                ),
                SessionEntry(
                    filename: decomposedName,
                    pairedFilename: nil,
                    rating: Rating.no.rawValue,
                    ratedAt: nil
                ),
            ]
        )
        let ratings = SessionRatingIndex(session: legacySession)

        XCTAssertEqual(ratings.value(for: composedFile)?.rating, .yes)
        XCTAssertEqual(ratings.value(for: decomposedFile)?.rating, .no)
    }

    func testSchemaFourIdentityUsesVolumeUUIDAcrossRemountsAndIgnoresCTime() {
        let expected = fileIdentity(
            volumeRootPath: "/Volumes/CARD",
            volumeUUIDString: "card-uuid",
            systemNumber: 11,
            fileNumber: 42,
            statusChangeSeconds: 100
        )
        let remounted = fileIdentity(
            volumeRootPath: "/Volumes/CARD 1",
            volumeUUIDString: "card-uuid",
            systemNumber: 999,
            fileNumber: 42,
            statusChangeSeconds: 200
        )

        XCTAssertTrue(
            SessionRatingIndex.persistedIdentityMatches(
                expected: expected,
                actual: remounted
            ),
            "a stable volume UUID must supersede mount path, st_dev, and ctime"
        )
        XCTAssertTrue(
            FileOperationJournal.identitiesMatch(
                expected: expected,
                actual: remounted,
                includeStatusChange: false
            ),
            "recovery must keep recognizing the planned inode after a remount"
        )

        let changedContent = fileIdentity(
            volumeRootPath: "/Volumes/CARD 1",
            volumeUUIDString: "card-uuid",
            systemNumber: 999,
            fileNumber: 42,
            modificationSeconds: 101,
            statusChangeSeconds: 200
        )
        XCTAssertFalse(
            SessionRatingIndex.persistedIdentityMatches(
                expected: expected,
                actual: changedContent
            )
        )
        XCTAssertFalse(
            FileOperationJournal.identitiesMatch(
                expected: expected,
                actual: changedContent,
                includeStatusChange: false
            )
        )
    }

    func testSchemaFourLookupDistinguishesNewPathFromIdentityConflict() {
        let expected = fileIdentity(fileNumber: 41)
        let replacement = fileIdentity(fileNumber: 42)
        let session = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: "/Photos",
            scannedAt: Date(timeIntervalSince1970: 1),
            entries: [
                SessionEntry(
                    filename: "A.JPG",
                    pairedFilename: nil,
                    rating: Rating.yes.rawValue,
                    ratedAt: nil,
                    fileIdentity: expected
                )
            ],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let index = SessionRatingIndex(session: session)
        let conflictingFile = PhotoFile(
            id: "A.JPG",
            url: mediaURL("A.JPG"),
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 12,
            scannedIdentity: replacement
        )
        let newFile = PhotoFile(
            id: "B.JPG",
            url: mediaURL("B.JPG"),
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 12,
            scannedIdentity: replacement
        )

        guard case .identityConflict = index.lookup(for: conflictingFile) else {
            return XCTFail("a same-path replacement must be reported as a conflict")
        }
        XCTAssertEqual(index.lookup(for: newFile), .absent)
    }

    func testScanRejectsReplacementAfterMetadataBeforeReturningItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LouppeScanIdentity-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("PHOTO.png")
        let original = try Data(
            contentsOf: URL(
                fileURLWithPath: "Packaging/AppIcon/AppIcon.iconset/icon_16x16.png"
            )
        )
        try original.write(to: photo)
        let replacement = Data("replacement after metadata".utf8)

        XCTAssertThrowsError(
            try FolderScanner.scan(
                root,
                beforeFinalIdentityValidation: {
                    try FileManager.default.removeItem(at: photo)
                    try replacement.write(
                        to: photo,
                        options: .withoutOverwriting
                    )
                }
            ) { _ in }
        ) { error in
            XCTAssertTrue(error is FolderScanner.ScanError)
        }
        XCTAssertEqual(try Data(contentsOf: photo), replacement)
    }

    private func fileIdentity(
        volumeRootPath: String = "/Volumes/CARD",
        volumeUUIDString: String? = "card-uuid",
        systemNumber: UInt64 = 11,
        fileNumber: UInt64 = 42,
        modificationSeconds: Int64 = 100,
        statusChangeSeconds: Int64 = 100
    ) -> FileOperationJournal.FileIdentity {
        FileOperationJournal.FileIdentity(
            volumeRootPath: volumeRootPath,
            volumeUUIDString: volumeUUIDString,
            systemNumber: systemNumber,
            fileNumber: fileNumber,
            logicalSize: 12,
            modificationTime: .init(
                seconds: modificationSeconds,
                nanoseconds: 1
            ),
            statusChangeTime: .init(
                seconds: statusChangeSeconds,
                nanoseconds: 2
            ),
            birthTime: .init(seconds: 50, nanoseconds: 3)
        )
    }

    private func mediaURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/Photos", isDirectory: true)
            .appendingPathComponent(name)
    }

    private func rawMediaURL(_ name: String) -> URL {
        let bytes = Array("/Photos/\(name)".utf8)
            .map(Int8.init(bitPattern:)) + [0]
        return bytes.withUnsafeBufferPointer { buffer in
            URL(
                fileURLWithFileSystemRepresentation: buffer.baseAddress!,
                isDirectory: false,
                relativeTo: nil
            )
        }
    }

    private func rawDirectoryURL(_ path: String) -> URL {
        let bytes = Array(path.utf8).map(Int8.init(bitPattern:)) + [0]
        return bytes.withUnsafeBufferPointer { buffer in
            URL(
                fileURLWithFileSystemRepresentation: buffer.baseAddress!,
                isDirectory: true,
                relativeTo: nil
            )
        }
    }

    private func signature(
        _ pairs: [(primary: URL, paired: URL?)]
    ) -> [String] {
        pairs.map {
            "\(FolderScanner.fileSystemIdentityPath(for: $0.primary))|\($0.paired.map(FolderScanner.fileSystemIdentityPath) ?? "unpaired")"
        }
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
