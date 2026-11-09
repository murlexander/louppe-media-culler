import Foundation
import XCTest
@testable import Louppe

/// Metadata renames without Sequence number only the files whose generated
/// names would clash, per clashing name, oldest capture first.
final class FileRenamingConflictNumberingTests: XCTestCase {
    private var root: URL!
    private var photos: URL!
    private var journals: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Louppe-ConflictNumbering-\(UUID().uuidString)", isDirectory: true
        )
        photos = root.appendingPathComponent("Photos", isDirectory: true)
        journals = root.appendingPathComponent("Journals", isDirectory: true)
        try FileManager.default.createDirectory(
            at: photos, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDateOnlyNumbersEachDayIndependentlyAndLeavesUniqueNames() throws {
        let day1 = try noon(2026, 2, 20)
        let day2 = try noon(2026, 2, 21)
        let day3 = try noon(2026, 2, 22)
        let items = [
            try item("C.JPG", date: day1.addingTimeInterval(120)),
            try item("A.JPG", date: day1),
            try item("B.PNG", date: day1.addingTimeInterval(60)),
            try item("E.JPG", date: day2.addingTimeInterval(5)),
            try item("D.HEIC", date: day2),
            try item("F.JPG", date: day3),
        ]

        let plan = try makePlan(items, parts: [.captureDate])

        XCTAssertTrue(plan.canExecute, messages(plan))
        let first = stem(day1), second = stem(day2), third = stem(day3)
        XCTAssertEqual(destinations(plan), [
            "A.JPG": "\(first)_001.JPG",
            "B.PNG": "\(first)_002.PNG",
            "C.JPG": "\(first)_003.JPG",
            "D.HEIC": "\(second)_001.HEIC",
            "E.JPG": "\(second)_002.JPG",
            "F.JPG": "\(third).JPG",
        ])
        XCTAssertEqual(plan.autoNumberedFileCount, 5)
    }

    func testPairsAndSidecarsShareOneNumber() throws {
        let date = try noon(2026, 3, 1)
        let raw = try file("P.NEF")
        let jpeg = try file("P.JPG")
        try Data("pair edits".utf8).write(
            to: photos.appendingPathComponent("P.xmp")
        )
        // The default projection shows a pair as two separate items.
        let rawItem = makeItem(id: "P.NEF", url: raw, date: date)
        let jpegItem = makeItem(id: "P.JPG", url: jpeg, date: date.addingTimeInterval(1))
        let single = try item("Q.JPG", date: date.addingTimeInterval(30))
        let pair = SourceOrganizationPairedFiles(
            rawFileID: rawItem.primaryFile.id,
            jpegFileID: jpegItem.primaryFile.id
        )
        let items = [single, jpegItem, rawItem]

        let plan = try makePlan(items, parts: [.captureDate], pairs: [pair])

        XCTAssertTrue(plan.canExecute, messages(plan))
        let day = stem(date)
        XCTAssertEqual(destinations(plan, includeSidecars: true), [
            "P.NEF": "\(day)_001.NEF",
            "P.JPG": "\(day)_001.JPG",
            "P.xmp": "\(day)_001.xmp",
            "Q.JPG": "\(day)_002.JPG",
        ])
        XCTAssertEqual(plan.autoNumberedFileCount, 3)
    }

    func testFilesAlreadySharingAStemKeepSharingIt() throws {
        let date = try noon(2026, 3, 2)
        try Data("shared".utf8).write(
            to: photos.appendingPathComponent("S.xmp")
        )
        let items = [
            try item("S.PNG", date: date),
            try item("S.JPEG", date: date.addingTimeInterval(1)),
            try item("T.JPEG", date: date.addingTimeInterval(2)),
        ]

        let plan = try makePlan(items, parts: [.captureDate])

        XCTAssertTrue(plan.canExecute, messages(plan))
        let day = stem(date)
        XCTAssertEqual(destinations(plan, includeSidecars: true), [
            "S.PNG": "\(day)_001.PNG",
            "S.JPEG": "\(day)_001.JPEG",
            "S.xmp": "\(day)_001.xmp",
            "T.JPEG": "\(day)_002.JPEG",
        ])
    }

    func testNumbersSkipUntouchedFilesOnDiskCaseInsensitively() throws {
        // Untouched names already using the generated stem.
        try Data("old".utf8).write(to: photos.appendingPathComponent("SONY_001.tif"))
        try Data("old".utf8).write(to: photos.appendingPathComponent("sony_003.JPG"))
        let items = [
            try item("A.JPG", camera: "Sony"),
            try item("B.JPG", camera: "Sony"),
        ]

        let plan = try makePlan(items, parts: [.camera])

        XCTAssertTrue(plan.canExecute, messages(plan))
        XCTAssertEqual(destinations(plan), [
            "A.JPG": "Sony_002.JPG",
            "B.JPG": "Sony_004.JPG",
        ])
    }

    func testSingleFileClashingWithUntouchedFileIsNumbered() throws {
        try Data("old".utf8).write(to: photos.appendingPathComponent("Leica.jpg"))
        let items = [try item("A.JPG", camera: "Leica")]

        let plan = try makePlan(items, parts: [.camera])

        XCTAssertTrue(plan.canExecute, messages(plan))
        XCTAssertEqual(destinations(plan), ["A.JPG": "Leica_001.JPG"])
        XCTAssertEqual(plan.autoNumberedFileCount, 1)
    }

    func testSequencePartAndCustomNamesStillBlockClashes() throws {
        try Data("old".utf8).write(to: photos.appendingPathComponent("Nikon_001.JPG"))
        let items = [try item("A.JPG", camera: "Nikon")]

        let sequenced = try makePlan(items, parts: [.camera, .sequence])
        XCTAssertFalse(sequenced.canExecute)
        XCTAssertEqual(sequenced.autoNumberedFileCount, 0)

        try Data("old".utf8).write(to: photos.appendingPathComponent("Taken.JPG"))
        let custom = try SourceOrganizationPlanner.makePlan(
            sourceFolder: photos,
            selectedItems: items,
            familyContextItems: items,
            configuration: FileRenamingPlanner.sourceConfiguration(
                customBaseName: "Taken"
            ),
            knownOriginFolderPathBytesByFileID: [:]
        )
        XCTAssertFalse(custom.canExecute)
        XCTAssertTrue(custom.collisions.contains {
            $0.message.contains("already exists")
        })
    }

    func testNumberedRenameRunsUndoesAndRepeatsWithoutChanges() throws {
        let date = try noon(2026, 4, 5)
        let raw = try file("IMG_2.CR3")
        let jpeg = try file("IMG_2.JPG")
        let xmp = photos.appendingPathComponent("IMG_2.xmp")
        try Data("edits".utf8).write(to: xmp)
        let pairItem = PhotoItem(
            id: "IMG_2.CR3",
            primaryURL: raw,
            pairedURL: jpeg,
            captureDate: date.addingTimeInterval(10),
            cameraModel: nil,
            lensModel: nil,
            fileSize: 9,
            pairedFileSize: 9,
            rating: .undecided
        )
        let first = try item("IMG_1.JPG", date: date)
        let unique = try item("IMG_9.JPG", date: date.addingTimeInterval(86_400))
        let items = [pairItem, unique, first]

        let plan = try makePlan(items, parts: [.captureDate])
        XCTAssertTrue(plan.canExecute, messages(plan))

        let result = SourceOrganizationWorker.organize(
            plan, journalDirectory: journals
        ) { _, _ in }
        XCTAssertEqual(result.failedItems, 0, result.failureMessage ?? "")
        XCTAssertEqual(result.movedFiles, 5)
        let day = stem(date)
        let next = stem(date.addingTimeInterval(86_400))
        XCTAssertEqual(try names(), [
            "\(day)_001.JPG", "\(day)_002.CR3", "\(day)_002.JPG",
            "\(day)_002.xmp", "\(next).JPG",
        ].sorted())
        XCTAssertEqual(
            try Data(contentsOf: photos.appendingPathComponent("\(day)_002.CR3")),
            Data("IMG_2.CR3".utf8)
        )

        // Planning the same rename again over the result changes nothing.
        let renamedPair = PhotoItem(
            id: "\(day)_002.CR3",
            primaryURL: photos.appendingPathComponent("\(day)_002.CR3"),
            pairedURL: photos.appendingPathComponent("\(day)_002.JPG"),
            captureDate: date.addingTimeInterval(10),
            cameraModel: nil,
            lensModel: nil,
            fileSize: 9,
            pairedFileSize: 9,
            rating: .undecided
        )
        let renamed = [
            renamedPair,
            makeItem(id: "\(next).JPG", url: photos.appendingPathComponent("\(next).JPG"),
                     date: date.addingTimeInterval(86_400)),
            makeItem(id: "\(day)_001.JPG", url: photos.appendingPathComponent("\(day)_001.JPG"),
                     date: date),
        ]
        let repeated = try makePlan(renamed, parts: [.captureDate])
        XCTAssertTrue(repeated.collisions.isEmpty, messages(repeated))
        XCTAssertEqual(repeated.movingFileCount, 0)

        let undo = SourceOrganizationWorker.undo(
            try XCTUnwrap(result.undoRecord),
            currentItems: [],
            journalDirectory: journals
        ) { _, _ in }
        XCTAssertEqual(undo.failedItems, 0, undo.failureMessage ?? "")
        XCTAssertEqual(undo.movedFiles, 5)
        XCTAssertEqual(try names(), [
            "IMG_1.JPG", "IMG_2.CR3", "IMG_2.JPG", "IMG_2.xmp", "IMG_9.JPG",
        ])
        XCTAssertEqual(try Data(contentsOf: xmp), Data("edits".utf8))
    }

    // MARK: - Helpers

    private func makePlan(
        _ items: [PhotoItem],
        parts: [FileRenamingPartKind],
        pairs: [SourceOrganizationPairedFiles] = []
    ) throws -> SourceOrganizationPlan {
        try SourceOrganizationPlanner.makePlan(
            sourceFolder: photos,
            selectedItems: items,
            familyContextItems: items,
            configuration: FileRenamingPlanner.sourceConfiguration(
                metadata: FileRenamingConfiguration(parts: parts.map {
                    FileRenamingPart(kind: $0, isEnabled: true)
                })
            ),
            knownOriginFolderPathBytesByFileID: [:],
            pairedFiles: pairs
        )
    }

    private func noon(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return try XCTUnwrap(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: 12
        )))
    }

    private func stem(_ date: Date) -> String {
        FileRenamingPlanner.safeGeneratedPart(AppDateFormat.day(date))
    }

    private func file(_ name: String) throws -> URL {
        let url = photos.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    private func item(
        _ name: String, date: Date? = nil, camera: String? = nil
    ) throws -> PhotoItem {
        makeItem(id: name, url: try file(name), date: date, camera: camera)
    }

    private func makeItem(
        id: String, url: URL, date: Date?, camera: String? = nil
    ) -> PhotoItem {
        PhotoItem(
            id: id,
            primaryURL: url,
            pairedURL: nil,
            captureDate: date,
            cameraModel: camera,
            lensModel: nil,
            mediaKind: .photo,
            fileSize: 5,
            rating: .undecided
        )
    }

    private func destinations(
        _ plan: SourceOrganizationPlan, includeSidecars: Bool = false
    ) -> [String: String] {
        Dictionary(uniqueKeysWithValues: plan.mappings.filter {
            includeSidecars || $0.isMedia
        }.map {
            ($0.source.lastPathComponent, $0.destination.lastPathComponent)
        })
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: photos.path)
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    private func messages(_ plan: SourceOrganizationPlan) -> String {
        plan.collisions.map(\.message).joined(separator: " | ")
    }
}
