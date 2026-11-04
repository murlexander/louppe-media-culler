import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

final class CaptureDateEvidenceTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testOriginalSubsecondsAndUTCOffsetUseMatchingCompanions() throws {
        let evidence = try XCTUnwrap(MetadataExtractor.captureDateEvidence(
            exif: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:12 09:30:00",
                kCGImagePropertyExifSubsecTimeOriginal: "1250",
                kCGImagePropertyExifOffsetTimeOriginal: "+09:00",
                kCGImagePropertyExifDateTimeDigitized: "2026:10:12 09:30:01",
                kCGImagePropertyExifSubsecTimeDigitized: "900",
                kCGImagePropertyExifOffsetTimeDigitized: "-04:00",
            ], tiff: [:], assumedTimeZone: utc
        ))
        let expected = try XCTUnwrap(MetadataExtractor.captureDateEvidence(
            exif: [kCGImagePropertyExifDateTimeOriginal: "2026:10:12 00:30:00"],
            tiff: [:], assumedTimeZone: utc
        ))
        XCTAssertEqual(evidence.date.timeIntervalSince(expected.date), 0.125, accuracy: 0.000001)
        XCTAssertEqual(evidence.source, .exifOriginal)
        XCTAssertEqual(evidence.subsecondDigits, "1250")
        XCTAssertEqual(evidence.utcOffset, "+09:00")
        XCTAssertNil(evidence.assumedTimeZoneIdentifier)
        XCTAssertEqual(evidence.recordedDateTime, "2026:10:12 09:30:00.1250 +09:00")
    }

    func testDigitizedAndTIFFFallbackRetainTheirOwnProvenance() throws {
        let digitized = try XCTUnwrap(MetadataExtractor.captureDateEvidence(
            exif: [
                kCGImagePropertyExifDateTimeOriginal: "2026:02:30 12:00:00",
                kCGImagePropertyExifSubsecTimeOriginal: "999",
                kCGImagePropertyExifOffsetTimeOriginal: "+09:00",
                kCGImagePropertyExifDateTimeDigitized: "2026:10:12 12:00:00",
                kCGImagePropertyExifSubsecTimeDigitized: "25",
                kCGImagePropertyExifOffsetTimeDigitized: "-04:00",
            ], tiff: [:], assumedTimeZone: utc
        ))
        XCTAssertEqual(digitized.source, .exifDigitized)
        XCTAssertEqual(digitized.subsecondDigits, "25")
        XCTAssertEqual(digitized.utcOffset, "-04:00")
        let tiff = try XCTUnwrap(MetadataExtractor.captureDateEvidence(
            exif: [
                kCGImagePropertyExifSubsecTime: "5",
                kCGImagePropertyExifOffsetTime: "+01:00",
            ], tiff: [kCGImagePropertyTIFFDateTime: "2026:10:12 12:00:00"],
            assumedTimeZone: utc
        ))
        XCTAssertEqual(tiff.source, .tiff)
        XCTAssertEqual(tiff.subsecondDigits, "5")
        XCTAssertEqual(tiff.utcOffset, "+01:00")
    }

    func testMissingOrInvalidPrecisionIsHonestAndDoesNotBorrowOtherDateOffsets() throws {
        let local = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let evidence = try XCTUnwrap(MetadataExtractor.captureDateEvidence(
            exif: [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:12 12:00:00",
                kCGImagePropertyExifSubsecTimeOriginal: "invalid",
                kCGImagePropertyExifOffsetTimeOriginal: "+24:99",
                kCGImagePropertyExifOffsetTimeDigitized: "+09:00",
            ], tiff: [:], assumedTimeZone: local
        ))
        XCTAssertNil(evidence.subsecondDigits)
        XCTAssertNil(evidence.utcOffset)
        XCTAssertEqual(evidence.assumedTimeZoneIdentifier, local.identifier)
        XCTAssertTrue(evidence.precisionDescription?.contains("Whole seconds") == true)
        XCTAssertTrue(evidence.timeZoneDescription?.contains("assumed America/Toronto") == true)
        XCTAssertNil(MetadataExtractor.captureDateEvidence(exif: [:], tiff: [:]))
        XCTAssertNil(MetadataExtractor.captureDateEvidence(
            exif: [kCGImagePropertyExifDateTimeOriginal: "2026:10:12 25:00:00"],
            tiff: [:]
        ))
    }

    func testRealJPEGScanAndInfoPreserveSubsecondsAndOffsetEvidence() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("capture.JPG")
        try jpegBytes(camera: "Camera A").write(to: url)
        let original = try Data(contentsOf: url)
        let items = try FolderScanner.scan(root, progress: { _ in })
        let item = try XCTUnwrap(items.first)
        let evidence = try XCTUnwrap(item.captureDateEvidence)
        XCTAssertEqual(evidence.source, .exifOriginal)
        XCTAssertEqual(evidence.subsecondDigits, "125")
        XCTAssertEqual(evidence.utcOffset, "+09:00")
        let fields = MetadataExtractor.fields(for: item)
        XCTAssertEqual(fields.first { $0.label == "Captured" }?.value,
                       AppDateFormat.dayAndTime(evidence.date))
        XCTAssertEqual(fields.first { $0.label == "Time zone" }?.value, "UTC+09:00")
        XCTAssertTrue(fields.filter { ["Date source", "Recorded date/time", "Date precision"].contains($0.label) }.isEmpty)
        XCTAssertEqual(evidence.recordedDateTime, "2026:10:12 09:30:00.125 +09:00")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(item.rating, .undecided)
    }

    func testFallbackCaptureDatesAreMarkedEstimatedWithoutDiagnosticRows() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(CaptureDateEvidence.Source, [CFString: Any], String?)] = [
            (.exifDigitized, [kCGImagePropertyExifDateTimeDigitized: "2026:10:12 09:30:00",
                             kCGImagePropertyExifOffsetTimeDigitized: "+01:00"], nil),
            (.tiff, [kCGImagePropertyExifOffsetTime: "+01:00"], "2026:10:12 09:30:00"),
            (.fileCreation, [:], nil),
        ]
        for (index, entry) in cases.enumerated() {
            let url = root.appendingPathComponent("fallback-\(index).JPG")
            let bytes = try jpegBytes(camera: "Camera", exif: entry.1, tiffDate: entry.2)
            try bytes.write(to: url)
            let item = try XCTUnwrap(FolderScanner.scan(root, progress: { _ in }).first { $0.primaryURL == url })
            let evidence = try XCTUnwrap(item.captureDateEvidence)
            XCTAssertEqual(evidence.source, entry.0)
            let fields = MetadataExtractor.fields(for: item)
            let formattedDate = AppDateFormat.dayAndTime(evidence.date)
            XCTAssertEqual(fields.first { $0.label == "Captured" }?.value,
                           L10n.text("\(formattedDate) · estimated"))
            XCTAssertTrue(fields.filter { ["Date source", "Recorded date/time", "Date precision"].contains($0.label) }.isEmpty)
            XCTAssertEqual(fields.first { $0.label == "Time zone" }?.value, evidence.timeZoneDescription)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testScannedDatesCanGroupMixedCamerasWithoutClaimingOneShutterPress() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try jpegBytes(camera: "Camera A").write(to: root.appendingPathComponent("A.JPG"))
        try jpegBytes(camera: "Camera B").write(to: root.appendingPathComponent("B.JPG"))
        let items = try FolderScanner.scan(root, progress: { _ in })
        XCTAssertEqual(Set(items.compactMap(\.cameraModel)), ["Camera A", "Camera B"])
        let inputs = items.map {
            DuplicateBurstAnalysis.Input(
                id: $0.id, mediaKind: $0.mediaKind, captureDate: $0.captureDate,
                captureDateEvidence: $0.captureDateEvidence, exactFiles: [], visualFiles: []
            )
        }
        let result = try DuplicateBurstAnalysis.analyze(inputs, mode: .captureBursts)
        let groups = result.groups(for: .captureBursts, visualDistance: 8, burstInterval: 2)
        XCTAssertEqual(groups.map(\.itemIDs), [["A.JPG", "B.JPG"]])
        XCTAssertNil(groups.first?.captureDateNote)
    }

    func testPairedImportFallbackBecomesEXIFEvidenceOnlyAfterJPEGMetadataLoads() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("capture.RAF")
        let jpeg = root.appendingPathComponent("capture.JPG")
        try Data("disposable unsupported raw fixture".utf8).write(to: raw)
        try jpegBytes(camera: "Camera B").write(to: jpeg)
        let originalRAW = try Data(contentsOf: raw)
        let originalJPEG = try Data(contentsOf: jpeg)
        let together = try FolderScanner.scan(root, pairingMode: .together, progress: { _ in })
        let pair = try XCTUnwrap(together.first)
        XCTAssertEqual(together.count, 1)
        XCTAssertEqual(pair.captureDateEvidence?.source, .fileCreation)
        let partner = try XCTUnwrap(pair.pairedFile)
        XCTAssertFalse(partner.metadataIsLoaded)
        XCTAssertEqual(partner.captureDateEvidence?.source, .fileCreation)
        XCTAssertTrue(partner.captureDateEvidence?.sourceDescription.contains("inferred") == true)
        let split = try FolderScanner.projectPairingMode(.separate, from: together, root: root)
        let loadedJPEG = try XCTUnwrap(split.items.first { $0.primaryURL == jpeg })
        XCTAssertEqual(loadedJPEG.captureDateEvidence?.source, .exifOriginal)
        XCTAssertEqual(loadedJPEG.captureDateEvidence?.subsecondDigits, "125")
        XCTAssertEqual(loadedJPEG.captureDateEvidence?.utcOffset, "+09:00")
        XCTAssertEqual(try Data(contentsOf: raw), originalRAW)
        XCTAssertEqual(try Data(contentsOf: jpeg), originalJPEG)
        XCTAssertEqual(loadedJPEG.rating, .undecided)
    }

    private func temporaryFolder() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("LouppeCaptureEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func jpegBytes(camera: String, exif: [CFString: Any]? = nil,
                           tiffDate: String? = nil) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ))
        var tiff: [CFString: Any] = [kCGImagePropertyTIFFModel: camera]
        if let tiffDate { tiff[kCGImagePropertyTIFFDateTime] = tiffDate }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyExifDictionary: exif ?? [
                kCGImagePropertyExifDateTimeOriginal: "2026:10:12 09:30:00",
                kCGImagePropertyExifSubsecTimeOriginal: "125",
                kCGImagePropertyExifOffsetTimeOriginal: "+09:00",
            ],
            kCGImagePropertyTIFFDictionary: tiff,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
