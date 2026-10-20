import Foundation
import XCTest
@testable import Louppe

final class SourceOrganizationTests: XCTestCase {
    func testPartialUndoDoesNotClaimAllNamesOrFoldersWereRestored() {
        for outcome in [
            SourceOrganizationOutcome(movedFiles: 1, failedItems: 1, message: nil, wasUndo: true),
            SourceOrganizationOutcome(movedFiles: 0, failedItems: 0, message: "Volume unavailable", wasUndo: true),
        ] {
            XCTAssertFalse(outcome.succeeded)
            XCTAssertEqual(outcome.title(for: .rename), "Restore finished with problems")
            XCTAssertEqual(outcome.title(for: .organization), "Restore finished with problems")
        }
        let restored = SourceOrganizationOutcome(
            movedFiles: 1, failedItems: 0, message: nil, wasUndo: true
        )
        XCTAssertEqual(restored.title(for: .rename), "Previous filenames restored")
        XCTAssertEqual(restored.title(for: .organization), "Previous folders restored")
        XCTAssertEqual(restored.fileCountDescription(for: .rename), "1 file restored")
    }

    func testMetadataRenameUsesPreferredDateAndPreservesExtensions() throws {
        let fixture = try makeFixture(named: "MetadataRename")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstURL = try mediaFile("DSC_9002.NEF", under: fixture.photos)
        let secondURL = try mediaFile("DSC_9001.JPG", under: fixture.photos)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let firstDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 9,
            day: 4,
            hour: 14,
            minute: 32,
            second: 17
        )))
        let secondDate = firstDate.addingTimeInterval(-1)
        let items = [
            makeItem(
                id: "DSC_9002.NEF",
                url: firstURL,
                captureDate: firstDate,
                cameraModel: "Sony ILCE/7RM5"
            ),
            makeItem(
                id: "DSC_9001.JPG",
                url: secondURL,
                captureDate: secondDate,
                cameraModel: "Sony ILCE/7RM5"
            ),
        ]
        var naming = FileRenamingConfiguration.initial
        naming.parts[naming.parts.firstIndex(where: {
            $0.kind == .camera
        })!].isEnabled = true

        let result = try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: items,
            familyContextItems: items,
            configuration: FileRenamingPlanner.sourceConfiguration(
                metadata: naming
            ),
            knownOriginFolderPathBytesByFileID: [:]
        )

        XCTAssertEqual(result.changeKind, .rename)
        XCTAssertTrue(
            result.canExecute,
            result.collisions.map(\.message).joined(separator: " | ")
        )
        let names = result.mappings.filter(\.isMedia).map {
            $0.destination.lastPathComponent
        }
        XCTAssertEqual(names, [
            "\(FileRenamingPlanner.safeGeneratedPart(AppDateFormat.day(firstDate)))_14-32-17_Sony-ILCE-7RM5_002.NEF",
            "\(FileRenamingPlanner.safeGeneratedPart(AppDateFormat.day(secondDate)))_14-32-16_Sony-ILCE-7RM5_001.JPG",
        ])
        XCTAssertTrue(result.mappings.allSatisfy {
            $0.source.deletingLastPathComponent()
                == $0.destination.deletingLastPathComponent()
        })
    }

    func testRenameMovesPairAndXMPThenUndoRestoresEveryName() throws {
        let fixture = try makeFixture(named: "RenamePair")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let raw = try mediaFile("A.NEF", under: fixture.photos)
        let jpeg = try mediaFile("A.JPG", under: fixture.photos)
        let xmp = fixture.photos.appendingPathComponent("A.xmp")
        try Data("xmp metadata".utf8).write(to: xmp)
        let item = makePair(
            id: "A.NEF",
            raw: raw,
            jpeg: jpeg,
            rating: .yes
        )
        let plan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: [item],
            familyContextItems: [item],
            configuration: FileRenamingPlanner.sourceConfiguration(
                customBaseName: "Wedding-0001"
            ),
            knownOriginFolderPathBytesByFileID: [:]
        )

        XCTAssertTrue(
            plan.canExecute,
            plan.collisions.map(\.message).joined(separator: " | ")
        )
        XCTAssertEqual(plan.sidecarFileCount, 1)
        XCTAssertEqual(
            Set(plan.mappings.map { $0.destination.lastPathComponent }),
            ["Wedding-0001.NEF", "Wedding-0001.JPG", "Wedding-0001.xmp"]
        )

        let result = SourceOrganizationWorker.organize(
            plan,
            journalDirectory: fixture.journals
        ) { _, _ in }
        XCTAssertEqual(result.movedFiles, 3, result.failureMessage ?? "")
        XCTAssertEqual(result.failedItems, 0)
        XCTAssertNotNil(result.undoRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            fixture.photos.appendingPathComponent("Wedding-0001.NEF").path
        ))

        let undo = SourceOrganizationWorker.undo(
            try XCTUnwrap(result.undoRecord),
            currentItems: [],
            journalDirectory: fixture.journals
        ) { _, _ in }
        XCTAssertEqual(undo.movedFiles, 3)
        XCTAssertEqual(try Data(contentsOf: raw), Data("A.NEF".utf8))
        XCTAssertEqual(try Data(contentsOf: jpeg), Data("A.JPG".utf8))
        XCTAssertEqual(try Data(contentsOf: xmp), Data("xmp metadata".utf8))
    }

    func testMetadataRenameKeepsSeparateCrossFolderPairAtomic() throws {
        let fixture = try makeFixture(named: "SeparatePairRename")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rawFolder = try directory("RAW", under: fixture.photos)
        let jpegFolder = try directory("JPEG", under: fixture.photos)
        let raw = try mediaFile("A.NEF", under: rawFolder)
        let jpeg = try mediaFile("A.JPG", under: jpegFolder)
        let rawXMP = rawFolder.appendingPathComponent("A.xmp")
        let jpegXMP = jpegFolder.appendingPathComponent("A.xmp")
        try Data("raw edits".utf8).write(to: rawXMP)
        try Data("jpeg edits".utf8).write(to: jpegXMP)
        let shotDate = Date(timeIntervalSince1970: 1_800_000_000)
        let rawItem = makeItem(
            id: "RAW/A.NEF",
            url: raw,
            captureDate: shotDate,
            cameraModel: "RAW Camera"
        )
        let jpegItem = makeItem(
            id: "JPEG/A.JPG",
            url: jpeg,
            captureDate: shotDate.addingTimeInterval(300),
            cameraModel: "Different cached JPEG camera"
        )
        let pair = SourceOrganizationPairedFiles(
            rawFileID: rawItem.primaryFile.id,
            jpegFileID: jpegItem.primaryFile.id
        )

        let plan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: [rawItem, jpegItem],
            familyContextItems: [rawItem, jpegItem],
            configuration: FileRenamingPlanner.sourceConfiguration(
                metadata: .initial
            ),
            knownOriginFolderPathBytesByFileID: [:],
            pairedFiles: [pair]
        )

        XCTAssertTrue(
            plan.canExecute,
            plan.collisions.map(\.message).joined(separator: " | ")
        )
        XCTAssertEqual(plan.workerPlan.items.count, 1)
        XCTAssertEqual(
            Set(plan.workerPlan.items[0].movedItemIDs),
            [rawItem.id, jpegItem.id]
        )
        XCTAssertEqual(plan.sidecarFileCount, 2)
        let destinationStems = Set(plan.mappings.filter(\.isMedia).map {
            ($0.destination.lastPathComponent as NSString)
                .deletingPathExtension
        })
        XCTAssertEqual(destinationStems.count, 1)
        XCTAssertTrue(destinationStems.first?.hasSuffix("_001") == true)
    }

    func testRenameBlocksNewFalsePairAndLightroomACRCompanion() throws {
        let fixture = try makeFixture(named: "RenameCollisions")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let raw = try mediaFile("A.NEF", under: fixture.photos)
        let jpeg = try mediaFile("B.JPG", under: fixture.photos)
        let rawItem = makeItem(id: "A.NEF", url: raw)
        let jpegItem = makeItem(id: "B.JPG", url: jpeg)

        let falsePair = try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: [rawItem],
            familyContextItems: [rawItem, jpegItem],
            configuration: FileRenamingPlanner.sourceConfiguration(
                customBaseName: "B"
            ),
            knownOriginFolderPathBytesByFileID: [:]
        )
        XCTAssertFalse(falsePair.canExecute)
        XCTAssertTrue(falsePair.collisions.contains {
            $0.message.contains("RAW + JPEG pair")
        })

        try Data("Lightroom edits".utf8).write(
            to: fixture.photos.appendingPathComponent("A.acr")
        )
        let acr = try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: [rawItem],
            familyContextItems: [rawItem, jpegItem],
            configuration: FileRenamingPlanner.sourceConfiguration(
                customBaseName: "C"
            ),
            knownOriginFolderPathBytesByFileID: [:]
        )
        XCTAssertFalse(acr.canExecute)
        XCTAssertTrue(acr.collisions.contains {
            $0.message.contains(".acr companion")
        })
    }

    func testRenameBlocksNewFalsePairAcrossSubfolders() throws {
        let fixture = try makeFixture(named: "CrossFolderFalsePair")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rawFolder = try directory("RAW", under: fixture.photos)
        let jpegFolder = try directory("JPEG", under: fixture.photos)
        let raw = try mediaFile("A.NEF", under: rawFolder)
        let jpeg = try mediaFile("B.JPG", under: jpegFolder)
        let rawItem = makeItem(id: "RAW/A.NEF", url: raw)
        let jpegItem = makeItem(id: "JPEG/B.JPG", url: jpeg)

        let plan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: [rawItem],
            familyContextItems: [rawItem, jpegItem],
            configuration: FileRenamingPlanner.sourceConfiguration(
                customBaseName: "B"
            ),
            knownOriginFolderPathBytesByFileID: [:]
        )

        XCTAssertFalse(plan.canExecute)
        XCTAssertTrue(plan.collisions.contains {
            $0.message.contains("RAW + JPEG pair")
        })
    }

    func testRenameBlocksMakingAnExistingPairAmbiguous() throws {
        let fixture = try makeFixture(named: "AmbiguousExistingPair")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originals = try directory("Originals", under: fixture.photos)
        let others = try directory("Others", under: fixture.photos)
        let pairedRAW = try mediaFile("A.NEF", under: originals)
        let pairedJPEG = try mediaFile("A.JPG", under: originals)
        let extraRAW = try mediaFile("B.CR3", under: others)
        let rawItem = makeItem(id: "Originals/A.NEF", url: pairedRAW)
        let jpegItem = makeItem(id: "Originals/A.JPG", url: pairedJPEG)
        let extraItem = makeItem(id: "Others/B.CR3", url: extraRAW)
        let knownPair = SourceOrganizationPairedFiles(
            rawFileID: rawItem.primaryFile.id,
            jpegFileID: jpegItem.primaryFile.id
        )

        let plan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: [extraItem],
            familyContextItems: [rawItem, jpegItem, extraItem],
            configuration: FileRenamingPlanner.sourceConfiguration(
                customBaseName: "A"
            ),
            knownOriginFolderPathBytesByFileID: [:],
            pairedFiles: [knownPair]
        )

        XCTAssertFalse(plan.canExecute)
        XCTAssertTrue(plan.collisions.contains {
            $0.message.contains("existing RAW + JPEG pair ambiguous")
        })
    }

    func testRenameRejectsHiddenCustomAndGeneratedNames() throws {
        XCTAssertNotNil(
            FileRenamingPlanner.validationMessage(
                forCustomBaseName: ".hidden"
            )
        )

        let fixture = try makeFixture(named: "HiddenGeneratedRename")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try mediaFile("A.JPG", under: fixture.photos)
        let item = makeItem(
            id: "A.JPG",
            url: source,
            cameraModel: ".hidden-camera"
        )
        let metadata = FileRenamingConfiguration(parts: [
            FileRenamingPart(kind: .camera, isEnabled: true),
        ])

        XCTAssertThrowsError(try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: [item],
            familyContextItems: [item],
            configuration: FileRenamingPlanner.sourceConfiguration(
                metadata: metadata
            ),
            knownOriginFolderPathBytesByFileID: [:]
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("hidden"))
        }
    }

    func testVideoRenameMovesRecognizedXMPAndBlocksACR() throws {
        let fixture = try makeFixture(named: "VideoRenameSidecars")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let movie = try mediaFile("clip.MOV", under: fixture.photos)
        let canonicalXMP = fixture.photos.appendingPathComponent("clip.xmp")
        let qualifiedXMP = fixture.photos.appendingPathComponent("clip.MOV.xmp")
        try Data("canonical".utf8).write(to: canonicalXMP)
        try Data("qualified".utf8).write(to: qualifiedXMP)
        let item = makeItem(id: "clip.MOV", url: movie, mediaKind: .video)

        let plan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: [item],
            familyContextItems: [item],
            configuration: FileRenamingPlanner.sourceConfiguration(
                customBaseName: "ceremony"
            ),
            knownOriginFolderPathBytesByFileID: [:]
        )
        XCTAssertTrue(
            plan.canExecute,
            plan.collisions.map(\.message).joined(separator: " | ")
        )
        XCTAssertEqual(
            Set(plan.mappings.map { $0.destination.lastPathComponent }),
            ["ceremony.MOV", "ceremony.xmp", "ceremony.MOV.xmp"]
        )

        try Data("heavy edits".utf8).write(
            to: fixture.photos.appendingPathComponent("clip.acr")
        )
        let blocked = try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: [item],
            familyContextItems: [item],
            configuration: FileRenamingPlanner.sourceConfiguration(
                customBaseName: "ceremony"
            ),
            knownOriginFolderPathBytesByFileID: [:]
        )
        XCTAssertFalse(blocked.canExecute)
        XCTAssertTrue(blocked.collisions.contains {
            $0.message.contains(".acr companion")
        })
    }

    func testMetadataRenameWithoutSequenceBlocksDuplicateGeneratedStem() throws {
        let fixture = try makeFixture(named: "DuplicateMetadataStem")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let raw = try mediaFile("A.NEF", under: fixture.photos)
        let jpeg = try mediaFile("B.JPG", under: fixture.photos)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            makeItem(id: "A.NEF", url: raw, captureDate: date),
            makeItem(id: "B.JPG", url: jpeg, captureDate: date),
        ]
        var naming = FileRenamingConfiguration.initial
        naming.parts[naming.parts.firstIndex(where: {
            $0.kind == .sequence
        })!].isEnabled = false

        let result = try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: items,
            familyContextItems: items,
            configuration: FileRenamingPlanner.sourceConfiguration(
                metadata: naming
            ),
            knownOriginFolderPathBytesByFileID: [:]
        )
        XCTAssertFalse(result.canExecute)
        XCTAssertTrue(result.collisions.contains {
            $0.message.contains("same stem")
        })
    }

    func testDateTakenOnlyPresetEnablesNoOtherFolderLevel() {
        let preset = SourceOrganizationConfiguration.dateTakenOnly

        XCTAssertEqual(
            preset.enabledLevels.map(\.kind),
            [.dateTaken]
        )
        XCTAssertEqual(preset.dateGranularity, .day)
        XCTAssertEqual(preset.containerName, "Organized")
    }

    func testExFATSafetySelectsScopedFoundationRenameFallback() {
        let exFAT = SourceOrganizationStorageSafety(
            fileSystemName: "exfat"
        )
        let apfs = SourceOrganizationStorageSafety(
            fileSystemName: "apfs"
        )

        XCTAssertEqual(exFAT.noOverwriteRenameStrategy, .foundation)
        XCTAssertEqual(apfs.noOverwriteRenameStrategy, .exclusivePOSIX)
        XCTAssertEqual(exFAT.directorySyncPolicy, .allowUnsupported)
        XCTAssertEqual(apfs.directorySyncPolicy, .required)
    }

    func testCancelledPlanStopsBeforeFilesystemPlanning() throws {
        let fixture = try makeFixture(named: "Cancelled")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try SourceOrganizationPlanner.makePlan(
                sourceFolder: fixture.photos,
                selectedItems: [],
                familyContextItems: [],
                configuration: configuration(levels: [.decision]),
                knownOriginFolderPathBytesByFileID: [:],
                isCancelled: { true }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testSessionStoreRescanKeepsOrganizationUndoAndRestoresLayout() async throws {
        let fixture = try makeFixture(named: "SessionRoundTrip")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceDirectory = try directory("Trips", under: fixture.photos)
        let source = sourceDirectory.appendingPathComponent("A.png")
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try png.write(to: source)
        let backup = fixture.root.appendingPathComponent(
            "Backup",
            isDirectory: true
        )
        let store = SessionStore(
            persistence: SessionPersistence(backupDirectory: backup),
            saveTrailingDelay: 0.01,
            saveMaximumDelay: 0.02,
            operationJournalDirectory: fixture.journals
        )
        store.openFolder(fixture.photos)
        try await waitUntil {
            if case .ready = store.phase { return store.items.count == 1 }
            return false
        }
        store.rate(.yes, at: 0)
        let snapshot = try XCTUnwrap(
            store.sourceOrganizationPlanningSnapshot(scope: .all)
        )
        let organizedPlan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: snapshot.sourceFolder,
            selectedItems: snapshot.selectedItems,
            familyContextItems: snapshot.familyContextItems,
            configuration: configuration(levels: [.decision]),
            knownOriginFolderPathBytesByFileID:
                snapshot.knownOriginFolderPathBytesByFileID
        )
        let destination = fixture.photos.appendingPathComponent(
            "Organized/Yes/A.png"
        )

        store.startSourceOrganization(organizedPlan)
        try await waitUntil {
            if case .ready = store.phase {
                return !store.isFileOperationRunning
                    && FileManager.default.fileExists(atPath: destination.path)
            }
            return false
        }
        XCTAssertTrue(store.canUndo)
        XCTAssertEqual(
            store.items.first?.primaryURL.resolvingSymlinksInPath().path,
            destination.resolvingSymlinksInPath().path
        )
        let repeatedSnapshot = try XCTUnwrap(
            store.sourceOrganizationPlanningSnapshot(scope: .all)
        )
        let repeatedPlan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: repeatedSnapshot.sourceFolder,
            selectedItems: repeatedSnapshot.selectedItems,
            familyContextItems: repeatedSnapshot.familyContextItems,
            configuration: configuration(levels: [.decision]),
            knownOriginFolderPathBytesByFileID:
                repeatedSnapshot.knownOriginFolderPathBytesByFileID
        )
        XCTAssertTrue(
            repeatedPlan.collisions.isEmpty,
            repeatedPlan.collisions.map(\.message).joined(separator: " | ")
        )
        XCTAssertEqual(repeatedPlan.alreadyOrganizedItemCount, 1)

        store.undo()
        XCTAssertTrue(store.isOrganizePresented)
        try await waitUntil {
            if case .ready = store.phase {
                return !store.isFileOperationRunning
                    && FileManager.default.fileExists(atPath: source.path)
            }
            return false
        }
        XCTAssertEqual(
            store.items.first?.primaryURL.resolvingSymlinksInPath().path,
            source.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(try Data(contentsOf: source), png)
    }

    @MainActor
    func testSessionStoreRenameKeepsMetadataAndUndoRestoresName() async throws {
        let fixture = try makeFixture(named: "RenameSessionRoundTrip")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.photos.appendingPathComponent("Original.png")
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try png.write(to: source)
        let store = SessionStore(
            persistence: SessionPersistence(
                backupDirectory: fixture.root.appendingPathComponent("Backup")
            ),
            saveTrailingDelay: 0.01,
            saveMaximumDelay: 0.02,
            operationJournalDirectory: fixture.journals
        )
        store.openFolder(fixture.photos)
        try await waitUntil {
            if case .ready = store.phase { return store.items.count == 1 }
            return false
        }
        store.rate(.yes, at: 0)
        store.setStarRating(.four)
        store.setColorLabel(.purple)
        let originalID = try XCTUnwrap(store.currentItem?.id)
        store.presentSingleFileRenaming(itemID: originalID)
        let snapshot = try XCTUnwrap(
            store.sourceFileRenamingPlanningSnapshot(scope: .selected)
        )
        let plan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: snapshot.sourceFolder,
            selectedItems: snapshot.selectedItems,
            familyContextItems: snapshot.familyContextItems,
            configuration: FileRenamingPlanner.sourceConfiguration(
                customBaseName: "Renamed"
            ),
            knownOriginFolderPathBytesByFileID:
                snapshot.knownOriginFolderPathBytesByFileID
        )
        XCTAssertTrue(
            plan.canExecute,
            plan.collisions.map(\.message).joined(separator: " | ")
        )
        let destination = fixture.photos.appendingPathComponent("Renamed.png")

        store.startSourceRename(plan)
        XCTAssertTrue(store.isRenamingSource, store.organizationError ?? "")
        try await waitUntil {
            if case .ready = store.phase {
                return !store.isFileOperationRunning
                    && FileManager.default.fileExists(atPath: destination.path)
            }
            return false
        }
        XCTAssertEqual(store.currentItem?.displayName, "Renamed.png")
        XCTAssertEqual(store.currentItem?.rating, .yes)
        XCTAssertEqual(store.currentItem?.starRatingState, .stars(.four))
        XCTAssertEqual(store.currentItem?.colorLabelState, .label(.purple))
        XCTAssertTrue(store.canUndo)

        store.undo()
        XCTAssertTrue(store.isRenamePresented)
        try await waitUntil {
            if case .ready = store.phase {
                return !store.isFileOperationRunning
                    && FileManager.default.fileExists(atPath: source.path)
            }
            return false
        }
        XCTAssertEqual(store.currentItem?.displayName, "Original.png")
        XCTAssertEqual(store.currentItem?.rating, .yes)
        XCTAssertEqual(try Data(contentsOf: source), png)
    }

    @MainActor
    func testSelectedMetadataRenameExpandsSeparateRAWJPEGPair() async throws {
        let fixture = try makeFixture(named: "RenameScopePairExpansion")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try mediaFile("A.NEF", under: fixture.photos)
        _ = try mediaFile("A.JPG", under: fixture.photos)
        let store = SessionStore(
            persistence: SessionPersistence(
                backupDirectory: fixture.root.appendingPathComponent("Backup")
            ),
            operationJournalDirectory: fixture.journals
        )
        store.openFolder(fixture.photos)
        try await waitUntil {
            if case .ready = store.phase { return store.items.count == 2 }
            return false
        }

        store.presentMetadataFileRenaming()
        let snapshot = try XCTUnwrap(
            store.sourceFileRenamingPlanningSnapshot(scope: .selected)
        )
        XCTAssertEqual(snapshot.selectedItems.count, 2)
        XCTAssertEqual(snapshot.pairedFiles.count, 1)
        XCTAssertEqual(
            Set(snapshot.selectedItems.flatMap(\.individualFiles).map {
                $0.url.pathExtension.lowercased()
            }),
            ["nef", "jpg"]
        )
    }

    @MainActor
    func testInlineRenameTargetsDisplayedFamilyDespiteOtherSelectionAndSheetMode() async throws {
        let fixture = try makeFixture(named: "InlineRenameTarget")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for name in ["A.NEF", "A.JPG", "B.JPG"] {
            _ = try mediaFile(name, under: fixture.photos)
        }
        let store = SessionStore(
            persistence: SessionPersistence(
                backupDirectory: fixture.root.appendingPathComponent("Backup")
            ),
            operationJournalDirectory: fixture.journals
        )
        store.openFolder(fixture.photos)
        try await waitUntil {
            if case .ready = store.phase { return store.items.count == 3 }
            return false
        }
        let rawIndex = try XCTUnwrap(store.items.firstIndex { $0.displayName == "A.NEF" })
        let otherIndex = try XCTUnwrap(store.items.firstIndex { $0.displayName == "B.JPG" })
        let displayedID = store.items[rawIndex].id
        store.setIndex(rawIndex)
        // Rubber-band selection may leave currentIndex outside the selection.
        store.setSelection([otherIndex])
        store.presentSingleFileRenaming(itemID: store.items[otherIndex].id)
        store.isRenamePresented = false
        let snapshot = try XCTUnwrap(
            store.sourceFileRenamingPlanningSnapshot(itemID: displayedID)
        )
        XCTAssertEqual(Set(snapshot.selectedItems.map(\.displayName)), ["A.NEF", "A.JPG"])
        let plan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: snapshot.sourceFolder,
            selectedItems: snapshot.selectedItems,
            familyContextItems: snapshot.familyContextItems,
            configuration: FileRenamingPlanner.sourceConfiguration(customBaseName: "Renamed"),
            knownOriginFolderPathBytesByFileID: snapshot.knownOriginFolderPathBytesByFileID,
            pairedFiles: snapshot.pairedFiles
        )
        XCTAssertTrue(plan.canExecute, plan.collisions.map(\.message).joined(separator: " | "))
        XCTAssertEqual(Set(plan.mappings.map { $0.source.lastPathComponent }), ["A.NEF", "A.JPG"])
        XCTAssertNil(store.sourceFileRenamingPlanningSnapshot(itemID: "missing"))
    }

    func testPriorityOrderControlsNestedFolderOrder() throws {
        let fixture = try makeFixture(named: "Priority")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceDirectory = try directory("Trips", under: fixture.photos)
        let source = try mediaFile("A.JPG", under: sourceDirectory)
        let date = try XCTUnwrap(
            Calendar(identifier: .gregorian).date(
                from: DateComponents(year: 2026, month: 8, day: 17)
            )
        )
        let item = makeItem(
            id: "Trips/A.JPG",
            url: source,
            captureDate: date,
            rating: .yes
        )

        let decisionThenDate = try plan(
            fixture: fixture,
            selected: [item],
            levels: [.decision, .dateTaken]
        )
        let dateThenDecision = try plan(
            fixture: fixture,
            selected: [item],
            levels: [.dateTaken, .decision]
        )
        let dateFolder = SourceOrganizationPlanner.dateFolderLabel(
            date,
            granularity: .day
        )

        XCTAssertEqual(
            decisionThenDate.mappings.first?.destination.path,
            fixture.photos.appendingPathComponent(
                "Organized/Yes/\(dateFolder)/A.JPG"
            ).path
        )
        XCTAssertEqual(
            dateThenDecision.mappings.first?.destination.path,
            fixture.photos.appendingPathComponent(
                "Organized/\(dateFolder)/Yes/A.JPG"
            ).path
        )
    }

    func testExistingFolderCanBeFlattenedOrPreservedAtTwoDepths() throws {
        let fixture = try makeFixture(named: "ExistingFolder")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let trip = try directory("Trips/Italy", under: fixture.photos)
        let source = try mediaFile("A.JPG", under: trip)
        let item = makeItem(
            id: "Trips/Italy/A.JPG",
            url: source,
            rating: .yes
        )

        let flattened = try plan(
            fixture: fixture,
            selected: [item],
            levels: [.decision]
        )
        let topLevel = try plan(
            fixture: fixture,
            selected: [item],
            levels: [.existingFolder, .decision],
            existingDepth: .topLevel
        )
        let fullPath = try plan(
            fixture: fixture,
            selected: [item],
            levels: [.existingFolder, .decision],
            existingDepth: .fullPath
        )

        XCTAssertEqual(
            flattened.mappings.first?.destination.path,
            fixture.photos.appendingPathComponent("Organized/Yes/A.JPG").path
        )
        XCTAssertEqual(
            topLevel.mappings.first?.destination.path,
            fixture.photos.appendingPathComponent(
                "Organized/Trips/Yes/A.JPG"
            ).path
        )
        XCTAssertEqual(
            fullPath.mappings.first?.destination.path,
            fixture.photos.appendingPathComponent(
                "Organized/Trips/Italy/Yes/A.JPG"
            ).path
        )
    }

    func testRememberedOriginPreventsRepeatedOrganizationFromNesting() throws {
        let fixture = try makeFixture(named: "RememberedOrigin")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let currentDirectory = try directory(
            "Organized/Yes/2026/",
            under: fixture.photos
        )
        let source = try mediaFile("A.JPG", under: currentDirectory)
        let item = makeItem(
            id: "Organized/Yes/2026/A.JPG",
            url: source,
            rating: .yes
        )
        let configuration = configuration(
            levels: [.dateTaken, .decision, .existingFolder],
            dateGranularity: .year,
            existingDepth: .fullPath
        )
        let result = try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: [item],
            familyContextItems: [item],
            configuration: configuration,
            knownOriginFolderPathBytesByFileID: [
                item.primaryFile.id: Data("Trips/Italy".utf8),
            ]
        )

        XCTAssertEqual(
            result.mappings.first?.destination.path,
            fixture.photos.appendingPathComponent(
                "Organized/Unknown Date/Yes/Trips/Italy/A.JPG"
            ).path
        )
        XCTAssertFalse(
            result.mappings.first?.destination.path.contains(
                "Organized/Yes/2026/Organized"
            ) ?? true
        )
    }

    func testCollisionsBlockWholePlanWithoutAddingSuffixes() throws {
        let fixture = try makeFixture(named: "Collision")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstDirectory = try directory("First", under: fixture.photos)
        let secondDirectory = try directory("Second", under: fixture.photos)
        let first = try mediaFile("A.JPG", under: firstDirectory)
        let second = try mediaFile("A.JPG", under: secondDirectory)
        let items = [
            makeItem(id: "First/A.JPG", url: first, rating: .yes),
            makeItem(id: "Second/A.JPG", url: second, rating: .yes),
        ]

        let result = try plan(
            fixture: fixture,
            selected: items,
            levels: [.decision]
        )

        XCTAssertFalse(result.canExecute)
        XCTAssertEqual(result.collisions.count, 1)
        XCTAssertEqual(result.collisions.first?.sources.count, 2)
        XCTAssertFalse(
            result.mappings.contains {
                $0.destination.lastPathComponent.contains(" 2")
            }
        )
    }

    func testExistingDestinationBlocksButExactCurrentPathIsAlreadyOrganized() throws {
        let fixture = try makeFixture(named: "ExistingDestination")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceDirectory = try directory("Trips", under: fixture.photos)
        let source = try mediaFile("A.JPG", under: sourceDirectory)
        let destinationDirectory = try directory(
            "Organized/Yes",
            under: fixture.photos
        )
        _ = try mediaFile("A.JPG", under: destinationDirectory)
        let sourceItem = makeItem(
            id: "Trips/A.JPG",
            url: source,
            rating: .yes
        )

        let blocked = try plan(
            fixture: fixture,
            selected: [sourceItem],
            levels: [.decision]
        )
        XCTAssertFalse(blocked.canExecute)
        XCTAssertEqual(blocked.collisions.count, 1)

        try FileManager.default.removeItem(at: source)
        let current = makeItem(
            id: "Organized/Yes/A.JPG",
            url: destinationDirectory.appendingPathComponent("A.JPG"),
            rating: .yes
        )
        let already = try plan(
            fixture: fixture,
            selected: [current],
            levels: [.decision],
            origins: [current.primaryFile.id: Data("Trips".utf8)]
        )
        XCTAssertTrue(already.collisions.isEmpty)
        XCTAssertEqual(already.alreadyOrganizedItemCount, 1)
        XCTAssertEqual(already.movingFileCount, 0)
        XCTAssertFalse(already.canExecute)
    }

    func testWorkerMovesPairAndXMPThenUndoRestoresOriginals() throws {
        let fixture = try makeFixture(named: "MoveAndUndo")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceDirectory = try directory("Trips", under: fixture.photos)
        let raw = try mediaFile("A.NEF", under: sourceDirectory)
        let jpeg = try mediaFile("A.JPG", under: sourceDirectory)
        let xmp = sourceDirectory.appendingPathComponent("A.xmp")
        let acr = sourceDirectory.appendingPathComponent("A.acr")
        try Data("xmp metadata".utf8).write(to: xmp)
        try Data("heavy edits".utf8).write(to: acr)
        let item = makePair(
            id: "Trips/A.NEF",
            raw: raw,
            jpeg: jpeg,
            rating: .yes
        )
        let organizedPlan = try plan(
            fixture: fixture,
            selected: [item],
            levels: [.decision]
        )

        XCTAssertEqual(organizedPlan.sidecarFileCount, 1)
        XCTAssertEqual(organizedPlan.excludedACRCompanionCount, 1)
        let result = SourceOrganizationWorker.organize(
            organizedPlan,
            journalDirectory: fixture.journals
        ) { _, _ in }
        let destination = fixture.photos.appendingPathComponent(
            "Organized/Yes",
            isDirectory: true
        )

        XCTAssertEqual(result.movedFiles, 3)
        XCTAssertEqual(result.failedItems, 0)
        XCTAssertNotNil(result.undoRecord)
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpeg.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: xmp.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("A.NEF").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("A.JPG").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("A.xmp").path
        ))
        XCTAssertEqual(try Data(contentsOf: acr), Data("heavy edits".utf8))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sourceDirectory.path),
            "legacy folders are deliberately retained even when empty"
        )

        let undo = SourceOrganizationWorker.undo(
            try XCTUnwrap(result.undoRecord),
            currentItems: [],
            journalDirectory: fixture.journals
        ) { _, _ in }
        XCTAssertEqual(undo.movedFiles, 3)
        XCTAssertEqual(undo.failedItems, 0)
        XCTAssertEqual(try Data(contentsOf: raw), Data("A.NEF".utf8))
        XCTAssertEqual(try Data(contentsOf: jpeg), Data("A.JPG".utf8))
        XCTAssertEqual(try Data(contentsOf: xmp), Data("xmp metadata".utf8))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.path),
            "undo restores files but does not delete the folders Louppe made"
        )
        XCTAssertFalse(
            FileOperationJournal.hasPendingOperations(
                directory: fixture.journals
            )
        )
    }

    func testExFATCompatibilityProbeProvesNoOverwriteMoveAndCleansUp() throws {
        let fixture = try makeFixture(named: "ExFATProbe")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try SourceOrganizationWorker
            .verifyExFATMoveCompatibilityForTesting(in: fixture.photos)

        let leftovers = try FileManager.default.contentsOfDirectory(
            at: fixture.photos,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".louppe-move-probe-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testSharedXMPSidecarBlocksPartialFamilyScope() throws {
        let fixture = try makeFixture(named: "PartialXMPFamily")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sourceDirectory = try directory("Trips", under: fixture.photos)
        let raw = try mediaFile("A.NEF", under: sourceDirectory)
        let jpeg = try mediaFile("A.JPG", under: sourceDirectory)
        try Data("shared xmp".utf8).write(
            to: sourceDirectory.appendingPathComponent("A.xmp")
        )
        let rawItem = makeItem(id: "Trips/A.NEF", url: raw, rating: .yes)
        let jpegItem = makeItem(id: "Trips/A.JPG", url: jpeg, rating: .yes)

        let result = try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: [rawItem],
            familyContextItems: [rawItem, jpegItem],
            configuration: configuration(levels: [.decision]),
            knownOriginFolderPathBytesByFileID: [:]
        )

        XCTAssertFalse(result.canExecute)
        XCTAssertTrue(result.collisions.contains {
            $0.message.contains("shared XMP sidecar")
        })
    }

    func testSchemaSixOriginBytesAreRestoredOnlyBySchemaSix() throws {
        let fixture = try makeFixture(named: "SchemaOrigin")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try mediaFile("A.JPG", under: fixture.photos)
        let item = makeItem(id: "A.JPG", url: source)
        let identity = try XCTUnwrap(item.primaryFile.scannedIdentity)
        let entry = SessionEntry(
            filename: item.primaryFile.id,
            pairedFilename: nil,
            rating: Rating.undecided.rawValue,
            ratedAt: nil,
            fileIdentity: identity,
            organizationOriginFolderPathBytes: Data("Trips/Italy".utf8)
        )
        let current = SessionFile(
            version: 6,
            sourcePath: fixture.photos.path,
            scannedAt: Date(),
            entries: [entry],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let older = SessionFile(
            version: 5,
            sourcePath: fixture.photos.path,
            scannedAt: Date(),
            entries: [entry],
            fileIDEncoding: .percentEncodedFileSystemPath
        )

        XCTAssertEqual(
            SessionRatingIndex(session: current).value(for: item.primaryFile)?
                .organizationOriginFolderPathBytes,
            Data("Trips/Italy".utf8)
        )
        XCTAssertNil(
            SessionRatingIndex(session: older).value(for: item.primaryFile)?
                .organizationOriginFolderPathBytes
        )
    }

    func testInterruptedOrganizationJournalUsesMoveRecoveryRules() throws {
        let fixture = try makeFixture(named: "Recovery")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = try mediaFile("A.JPG", under: fixture.photos)
        let destinationDirectory = try directory(
            "Organized/Yes",
            under: fixture.photos
        )
        let destination = destinationDirectory.appendingPathComponent("A.JPG")
        let writer = try FileOperationJournal.start(
            kind: .organizeSource,
            seeds: [
                .init(
                    itemID: "A.JPG",
                    source: source,
                    destination: destination,
                    expectedIdentity: try FileOperationJournal.captureIdentity(
                        at: source
                    )
                ),
            ],
            directory: fixture.journals
        )
        try writer.mark(.started, fileAt: 0)
        try DurableFileIO.atomicExclusiveRename(from: source, to: destination)
        let identity = try FileOperationJournal.captureIdentity(at: destination)
        try writer.mark(
            .completed,
            fileAt: 0,
            identityAt: destination,
            expectedIdentity: identity
        )
        XCTAssertTrue(
            FileOperationJournal.finalize(
                writer,
                operationIsConsistent: false
            )
        )

        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )
        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertEqual(report.preservedMoves, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("A.JPG".utf8))
    }

    func testInterruptedRenameRollsBackIncompletePhotoFamily() throws {
        let fixture = try makeFixture(named: "RenameRecovery")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let raw = try mediaFile("A.NEF", under: fixture.photos)
        let jpeg = try mediaFile("A.JPG", under: fixture.photos)
        let renamedRAW = fixture.photos.appendingPathComponent("New.NEF")
        let renamedJPEG = fixture.photos.appendingPathComponent("New.JPG")
        let writer = try FileOperationJournal.start(
            kind: .renameSource,
            seeds: [
                .init(
                    itemID: "family:A",
                    source: raw,
                    destination: renamedRAW,
                    expectedIdentity: try FileOperationJournal.captureIdentity(
                        at: raw
                    )
                ),
                .init(
                    itemID: "family:A",
                    source: jpeg,
                    destination: renamedJPEG,
                    expectedIdentity: try FileOperationJournal.captureIdentity(
                        at: jpeg
                    )
                ),
            ],
            directory: fixture.journals
        )
        try writer.mark(.started, fileAt: 0)
        try DurableFileIO.atomicExclusiveRename(from: raw, to: renamedRAW)
        let movedIdentity = try FileOperationJournal.captureIdentity(
            at: renamedRAW
        )
        try writer.mark(
            .completed,
            fileAt: 0,
            identityAt: renamedRAW,
            expectedIdentity: movedIdentity
        )
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))

        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )
        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertEqual(report.restoredFiles, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpeg.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedRAW.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedJPEG.path))
    }

    func testCompletedRenameJournalKindsPreserveForwardState() throws {
        for kind in [
            FileOperationJournal.Kind.renameSource,
            .restoreRename,
        ] {
            let fixture = try makeFixture(named: "Completed-\(kind.rawValue)")
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let source = try mediaFile("Before.JPG", under: fixture.photos)
            let destination = fixture.photos.appendingPathComponent("After.JPG")
            let writer = try FileOperationJournal.start(
                kind: kind,
                seeds: [
                    .init(
                        itemID: "photo",
                        source: source,
                        destination: destination,
                        expectedIdentity: try FileOperationJournal
                            .captureIdentity(at: source)
                    ),
                ],
                directory: fixture.journals
            )
            try writer.mark(.started, fileAt: 0)
            try DurableFileIO.atomicExclusiveRename(
                from: source,
                to: destination
            )
            try writer.mark(
                .completed,
                fileAt: 0,
                identityAt: destination,
                expectedIdentity: try FileOperationJournal.captureIdentity(
                    at: destination
                )
            )
            XCTAssertTrue(FileOperationJournal.finalize(
                writer,
                operationIsConsistent: false
            ))

            let report = FileOperationJournal.recoverPendingOperations(
                directory: fixture.journals
            )
            XCTAssertEqual(report.unresolvedOperations, 0)
            XCTAssertEqual(report.preservedMoves, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: destination.path
            ))
        }
    }

    func testInterruptedRestoreRenameRollsBackIncompleteFamily() throws {
        let fixture = try makeFixture(named: "RestoreRenameRecovery")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let raw = try mediaFile("New.NEF", under: fixture.photos)
        let jpeg = try mediaFile("New.JPG", under: fixture.photos)
        let restoredRAW = fixture.photos.appendingPathComponent("Old.NEF")
        let restoredJPEG = fixture.photos.appendingPathComponent("Old.JPG")
        let writer = try FileOperationJournal.start(
            kind: .restoreRename,
            seeds: [
                .init(
                    itemID: "family",
                    source: raw,
                    destination: restoredRAW,
                    expectedIdentity: try FileOperationJournal.captureIdentity(
                        at: raw
                    )
                ),
                .init(
                    itemID: "family",
                    source: jpeg,
                    destination: restoredJPEG,
                    expectedIdentity: try FileOperationJournal.captureIdentity(
                        at: jpeg
                    )
                ),
            ],
            directory: fixture.journals
        )
        try writer.mark(.started, fileAt: 0)
        try DurableFileIO.atomicExclusiveRename(from: raw, to: restoredRAW)
        try writer.mark(
            .completed,
            fileAt: 0,
            identityAt: restoredRAW,
            expectedIdentity: try FileOperationJournal.captureIdentity(
                at: restoredRAW
            )
        )
        XCTAssertTrue(FileOperationJournal.finalize(
            writer,
            operationIsConsistent: false
        ))

        let report = FileOperationJournal.recoverPendingOperations(
            directory: fixture.journals
        )
        XCTAssertEqual(report.unresolvedOperations, 0)
        XCTAssertEqual(report.restoredFiles, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpeg.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredRAW.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredJPEG.path))
    }

    private struct Fixture {
        let root: URL
        let photos: URL
        let journals: URL
    }

    private func makeFixture(named name: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Louppe-SourceOrganization-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let journals = root.appendingPathComponent("Journals", isDirectory: true)
        try FileManager.default.createDirectory(
            at: photos,
            withIntermediateDirectories: true
        )
        return Fixture(root: root, photos: photos, journals: journals)
    }

    private func directory(_ path: String, under root: URL) throws -> URL {
        let result = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(
            at: result,
            withIntermediateDirectories: true
        )
        return result
    }

    private func mediaFile(_ name: String, under directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    private func makeItem(
        id: String,
        url: URL,
        captureDate: Date? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        mediaKind: MediaKind = .photo,
        rating: Rating = .undecided
    ) -> PhotoItem {
        PhotoItem(
            id: id,
            primaryURL: url,
            pairedURL: nil,
            captureDate: captureDate,
            cameraModel: cameraModel,
            lensModel: lensModel,
            mediaKind: mediaKind,
            fileSize: 5,
            rating: rating
        )
    }

    private func makePair(
        id: String,
        raw: URL,
        jpeg: URL,
        rating: Rating
    ) -> PhotoItem {
        PhotoItem(
            id: id,
            primaryURL: raw,
            pairedURL: jpeg,
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 5,
            pairedFileSize: 5,
            rating: rating
        )
    }

    private func configuration(
        levels: [SourceOrganizationLevelKind],
        dateGranularity: SourceOrganizationDateGranularity = .day,
        existingDepth: SourceOrganizationExistingFolderDepth = .topLevel
    ) -> SourceOrganizationConfiguration {
        SourceOrganizationConfiguration(
            levels: levels.map {
                SourceOrganizationLevel(kind: $0, isEnabled: true)
            },
            dateGranularity: dateGranularity,
            existingFolderDepth: existingDepth,
            containerName: "Organized"
        )
    }

    private func plan(
        fixture: Fixture,
        selected: [PhotoItem],
        levels: [SourceOrganizationLevelKind],
        dateGranularity: SourceOrganizationDateGranularity = .day,
        existingDepth: SourceOrganizationExistingFolderDepth = .topLevel,
        origins: [String: Data] = [:]
    ) throws -> SourceOrganizationPlan {
        try SourceOrganizationPlanner.makePlan(
            sourceFolder: fixture.photos,
            selectedItems: selected,
            familyContextItems: selected,
            configuration: configuration(
                levels: levels,
                dateGranularity: dateGranularity,
                existingDepth: existingDepth
            ),
            knownOriginFolderPathBytesByFileID: origins
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(8),
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("timed out waiting for source organization")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
