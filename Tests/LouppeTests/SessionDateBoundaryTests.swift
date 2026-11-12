import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

final class SessionDateBoundaryTests: XCTestCase {
    func testRealJPEGDatesUseWholeLocalDaysAcrossBothDSTTransitions() throws {
        for (zone, month, day, hours) in [
            ("Europe/Copenhagen", 3, 29, 23), ("Europe/Copenhagen", 10, 25, 25),
            ("America/New_York", 3, 8, 23), ("America/New_York", 11, 1, 25),
        ] {
            let calendar = try calendar(zone)
            let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
            XCTAssertEqual(end.timeIntervalSince(start), Double(hours * 3600))
            let items = try scannedDates([start.addingTimeInterval(-1), start, end.addingTimeInterval(-1), end],
                                         calendar: calendar)
            var filter = PhotoFilter()
            filter.dateEnabled = true
            filter.dateFrom = start
            filter.dateTo = start
            XCTAssertEqual(items.filter(PreparedPhotoFilter(filter, calendar: calendar).matches).map(\.id),
                           ["1.JPG", "2.JPG"], "\(zone), \(month)/\(day)")
            filter.dateMode = .specificDates
            filter.excludedDates = [start]
            XCTAssertEqual(items.filter(PreparedPhotoFilter(filter, calendar: calendar).matches).map(\.id),
                           ["0.JPG", "3.JPG"], "\(zone), \(month)/\(day)")
        }
    }

    func testRealJPEGDatesUseLocalYearBoundariesOnBothSidesOfUTC() throws {
        for zone in ["Pacific/Kiritimati", "America/Los_Angeles"] {
            let calendar = try calendar(zone)
            let boundary = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 1)))
            let items = try scannedDates([boundary.addingTimeInterval(-1), boundary], calendar: calendar)
            let prior = CaptureYear(era: 1, year: 2026)
            let next = CaptureYear(era: 1, year: 2027)
            XCTAssertEqual(items.map(\.captureYear), [prior, next])
            let facets = SessionOpeningFacets(items: items)
            XCTAssertEqual(facets.captureYearCounts, [prior: 1, next: 1])
            var filter = PhotoFilter()
            filter.dateEnabled = true
            filter.dateMode = .specificYears
            filter.excludedYears = [prior]
            XCTAssertEqual(items.filter(PreparedPhotoFilter(filter, calendar: calendar).matches).map(\.id), ["1.JPG"])
        }
    }

    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return calendar
    }

    /// Real EXIF bytes go through discovery and metadata extraction. Re-cache
    /// their calendar fields explicitly to test zones without changing the Mac.
    private func scannedDates(_ dates: [Date], calendar: Calendar) throws -> [PhotoItem] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Louppe-DateBoundary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        var originals: [String: Data] = [:]
        for (index, date) in dates.enumerated() {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: formatter.string(from: date),
                kCGImagePropertyExifOffsetTimeOriginal: "+00:00",
            ]] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let name = "\(index).JPG"
            originals[name] = data as Data
            try (data as Data).write(to: root.appendingPathComponent(name))
        }
        let scanned = try FolderScanner.scan(root) { _ in }.sorted { $0.id < $1.id }
        XCTAssertEqual(scanned.map(\.captureDate), dates.map(Optional.some))
        for item in scanned {
            XCTAssertEqual(try Data(contentsOf: item.primaryURL), originals[item.id])
        }
        return scanned.map { item in
            PhotoItem(primaryFile: PhotoFile(id: item.id, url: item.primaryURL,
                captureDate: item.captureDate, cameraModel: nil, lensModel: nil,
                fileSize: item.fileSize, calendar: calendar))
        }
    }
}
