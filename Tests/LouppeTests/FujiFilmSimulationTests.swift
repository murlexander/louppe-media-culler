import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

final class FujiFilmSimulationTests: XCTestCase {
    func testRAFEmbeddedEXIFMatchesJPEGForColorAndAcrosVariants() throws {
        let root = try FujiJPEGFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(UInt16?, UInt16?, FujiFilmSimulation)] = [
            (0, nil, .provia), (0x600, nil, .classicChrome),
            (0x800, nil, .classicNegative), (nil, 0x500, .acros),
            (nil, 0x501, .acrosRed), (nil, 0x502, .acrosYellow),
            (nil, 0x503, .acrosGreen)
        ]
        for (index, entry) in cases.enumerated() {
            for little in [true, false] {
                let jpeg = try FujiJPEGFixture.jpeg(
                    note: FujiJPEGFixture.note(film: entry.0, saturation: entry.1), little: little)
                // RAF's big-endian header points to its own embedded JPEG.
                // Deliberate padding checks offsets are relative to that JPEG.
                var raf = Data(repeating: 0, count: 160)
                let signature = Array("FUJIFILMCCD-RAW".utf8)
                raf.replaceSubrange(0..<signature.count, with: signature)
                raf.replaceSubrange(84..<88, with: [0, 0, 0, 160])
                let length = UInt32(jpeg.count).bigEndian
                withUnsafeBytes(of: length) { raf.replaceSubrange(88..<92, with: $0) }
                raf.append(jpeg)
                for (ext, bytes) in [("JPG", jpeg), ("RAF", raf)] {
                    let url = root.appendingPathComponent("\(index)-\(little).\(ext)")
                    try bytes.write(to: url)
                    let properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary:
                        [kCGImagePropertyTIFFMake: "FUJIFILM"]]
                    XCTAssertEqual(FujiFilmSimulationReader.read(url: url, properties: properties), entry.2)
                    XCTAssertEqual(try Data(contentsOf: url), bytes)
                }
            }
        }
    }

    func testColorModesAndEveryMonochromeVariant() {
        let colors: [(UInt16, FujiFilmSimulation)] = [
            (0, .provia), (0x120, .astia), (0x200, .velvia),
            (0x500, .proNegStd), (0x501, .proNegHi), (0x600, .classicChrome),
            (0x700, .eterna), (0x800, .classicNegative), (0x900, .eternaBleachBypass),
            (0xa00, .nostalgicNeg), (0xb00, .realaACE)
        ]
        for (code, expected) in colors {
            XCTAssertEqual(FujiFilmSimulationReader.makerNote(FujiJPEGFixture.note(film: code)), expected)
        }
        let monochromes: [(UInt16, FujiFilmSimulation)] = [
            (0x300, .monochrome), (0x301, .monochromeRed), (0x302, .monochromeYellow),
            (0x303, .monochromeGreen), (0x310, .sepia), (0x500, .acros),
            (0x501, .acrosRed), (0x502, .acrosYellow), (0x503, .acrosGreen)
        ]
        for (code, expected) in monochromes {
            // Real X-T5 evidence also has Acros in Saturation without FilmMode.
            XCTAssertEqual(FujiFilmSimulationReader.makerNote(FujiJPEGFixture.note(saturation: code)), expected)
            XCTAssertEqual(FujiFilmSimulationReader.makerNote(FujiJPEGFixture.note(film: 0, saturation: code)), expected)
        }
        XCTAssertEqual(FujiFilmSimulationReader.makerNote(FujiJPEGFixture.note(film: 0xffff)), .unknown)
        XCTAssertEqual(FujiFilmSimulationReader.makerNote(FujiJPEGFixture.note(film: 0, saturation: 0x504)), .unknown)
        XCTAssertEqual(FujiFilmSimulationReader.makerNote(FujiJPEGFixture.note()), .notRecorded)
    }

    func testPartialImageIOFilmModeRetainsContainerMonochromeOverride() throws {
        let root = try FujiJPEGFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial: [CFString: Any] = [kCGImagePropertyMakerFujiDictionary: ["FilmMode": 0]]
        let complete: [CFString: Any] = [kCGImagePropertyMakerFujiDictionary:
            ["FilmMode": 0, "Saturation": 0]]
        let cases: [(Data, FujiFilmSimulation)] = [
            (FujiJPEGFixture.note(film: 0, saturation: 0x502), .acrosYellow),
            (FujiJPEGFixture.note(entries: [(0x1401, 0), (0x1401, 0x600)]), .unknown),
            (FujiJPEGFixture.note(), .provia)
        ]
        for (index, entry) in cases.enumerated() {
            let jpeg = try FujiJPEGFixture.jpeg(note: entry.0)
            for (ext, bytes) in [("JPG", jpeg), ("RAF", FujiJPEGFixture.raf(jpeg: jpeg))] {
                let url = root.appendingPathComponent("partial-\(index).\(ext)")
                try bytes.write(to: url)
                XCTAssertEqual(FujiFilmSimulationReader.read(url: url, properties: partial), entry.1)
                XCTAssertEqual(FujiFilmSimulationReader.read(url: url, properties: complete), .provia,
                               "Complete ImageIO tags keep precedence over the fallback container")
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
        let missing = root.appendingPathComponent("unavailable.RAF")
        XCTAssertEqual(FujiFilmSimulationReader.read(url: missing, properties: partial), .provia,
                       "Numeric evidence remains usable when no container result is available")
    }

    func testMalformedMakerNotesAndTIFFOffsetsAreBounded() {
        let valid = FujiJPEGFixture.note(film: 0x600)
        for length in 0..<valid.count - 4 {
            XCTAssertNotEqual(FujiFilmSimulationReader.makerNote(Data(valid.prefix(length))), .classicChrome)
        }
        var offset = valid
        offset.replaceSubrange(8..<12, with: [255, 255, 255, 255])
        XCTAssertEqual(FujiFilmSimulationReader.makerNote(offset), .unknown)
        var count = valid
        count.replaceSubrange(12..<14, with: [255, 255])
        XCTAssertEqual(FujiFilmSimulationReader.makerNote(count), .unknown)
        var wrongType = valid
        wrongType.replaceSubrange(16..<18, with: [4, 0])
        XCTAssertEqual(FujiFilmSimulationReader.makerNote(wrongType), .unknown)
        var wrongCount = valid
        wrongCount.replaceSubrange(18..<22, with: [255, 255, 255, 255])
        XCTAssertEqual(FujiFilmSimulationReader.makerNote(wrongCount), .unknown)
        XCTAssertEqual(FujiFilmSimulationReader.makerNote(
            FujiJPEGFixture.note(entries: [(0x1401, 0), (0x1401, 0x600)])), .unknown)
        for little in [true, false] {
            let tiff = FujiJPEGFixture.tiff(note: valid, little: little)
            XCTAssertEqual(FujiFilmSimulationReader.exifTIFF(tiff), .classicChrome)
            for length in 0..<tiff.count - 4 {
                XCTAssertNotEqual(FujiFilmSimulationReader.exifTIFF(Data(tiff.prefix(length))), .classicChrome)
            }
            var invalid = tiff
            invalid.replaceSubrange(4..<8, with: [255, 255, 255, 255])
            XCTAssertNil(FujiFilmSimulationReader.exifTIFF(invalid))
        }
        XCTAssertNil(FujiFilmSimulationReader.makerNote(Data("NOTFUJIF".utf8)))
        XCTAssertNil(FujiFilmSimulationReader.exifTIFF(Data(repeating: 0, count: 1_048_577)))
    }

    func testRealJPEGBracketScanInfoAndMissingMetadataLeaveBytesUntouched() throws {
        let root = try FujiJPEGFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(String, Data, FujiFilmSimulation)] = [
            ("color-1.JPG", FujiJPEGFixture.note(film: 0), .provia),
            ("color-2.JPG", FujiJPEGFixture.note(film: 0x600), .classicChrome),
            ("mono.JPG", FujiJPEGFixture.note(saturation: 0x502), .acrosYellow),
            ("future.JPG", FujiJPEGFixture.note(film: 0x7fff), .unknown),
            ("missing.JPG", FujiJPEGFixture.note(), .notRecorded)
        ]
        var originals: [String: Data] = [:]
        for (index, entry) in cases.enumerated() {
            let bytes = try FujiJPEGFixture.jpeg(note: entry.1, little: index.isMultiple(of: 2))
            originals[entry.0] = bytes
            try bytes.write(to: root.appendingPathComponent(entry.0))
        }
        let items = try FolderScanner.scan(root, progress: { _ in })
        XCTAssertEqual(items.count, cases.count)
        for (name, _, expected) in cases {
            let item = try XCTUnwrap(items.first { $0.displayName == name })
            XCTAssertEqual(item.filmSimulation, expected)
            XCTAssertEqual(item.primaryFile.filmSimulation, expected)
            XCTAssertEqual(item.cameraModel, "X-T4")
            XCTAssertEqual(MetadataExtractor.fields(for: item).first { $0.label == "Film simulation" }?.value, expected.label)
            XCTAssertEqual(try Data(contentsOf: item.primaryURL), originals[name])
        }
        let summary = PhotoSelectionSummary(items: items)
        XCTAssertTrue(summary.filmSimulations.contains("ACROS + Ye"))
        XCTAssertTrue(summary.filmSimulations.contains("CLASSIC CHROME"))
    }

    func testPrimaryMetadataAndLazyJPEGSplitRetainIndependentSimulationAndDecisions() throws {
        let root = try FujiJPEGFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("bracket.RAF")
        let jpeg = root.appendingPathComponent("bracket.JPG")
        try Data("disposable unsupported raw".utf8).write(to: raw)
        let original = try FujiJPEGFixture.jpeg(note: FujiJPEGFixture.note(saturation: 0x501))
        try original.write(to: jpeg)
        let together = try FolderScanner.scan(root, pairingMode: .together, progress: { _ in })
        let pair = try XCTUnwrap(together.first)
        XCTAssertEqual(together.count, 1)
        XCTAssertNil(pair.filmSimulation)
        XCTAssertNil(pair.pairedFile?.filmSimulation)
        XCTAssertEqual(pair.pairedFile?.metadataIsLoaded, false)
        pair.primaryFile.setRating(.yes, ratedAt: Date(timeIntervalSince1970: 1))
        pair.pairedFile?.setRating(.no, ratedAt: Date(timeIntervalSince1970: 2))
        let separated = try FolderScanner.projectPairingMode(.separate, from: together, root: root)
        XCTAssertEqual(separated.enrichedFileCount, 1)
        let loaded = try XCTUnwrap(separated.items.first { $0.primaryURL == jpeg })
        XCTAssertEqual(loaded.filmSimulation, .acrosRed)
        XCTAssertEqual(loaded.rating, .no)
        let regrouped = try FolderScanner.projectPairingMode(.together, from: separated.items, root: root)
        XCTAssertNil(regrouped.items.first?.filmSimulation)
        XCTAssertEqual(regrouped.items.first?.pairedFile?.filmSimulation, .acrosRed)
        XCTAssertEqual(regrouped.items.first?.ratingState, .mixed)
        let splitAgain = try FolderScanner.projectPairingMode(.separate, from: regrouped.items, root: root,
            metadataReaderForTesting: { _ in throw NSError(domain: "unexpected reread", code: 1) })
        XCTAssertEqual(splitAgain.enrichedFileCount, 0)
        XCTAssertEqual(splitAgain.items.first { $0.primaryURL == jpeg }?.filmSimulation, .acrosRed)
        XCTAssertEqual(try Data(contentsOf: jpeg), original)
    }

    func testSamePathReplacementCannotRelabelOldInfoOrLazyJPEG() throws {
        let root = try FujiJPEGFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("capture.JPG")
        try FujiJPEGFixture.jpeg(note: FujiJPEGFixture.note(film: 0x600)).write(to: url)
        let old = try XCTUnwrap(FolderScanner.scan(root, progress: { _ in }).first)
        let replacement = root.appendingPathComponent("new.JPG")
        try FujiJPEGFixture.jpeg(note: FujiJPEGFixture.note(saturation: 0x500)).write(to: replacement)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        XCTAssertEqual(old.filmSimulation, .classicChrome)
        XCTAssertEqual(MetadataExtractor.fields(for: old).last?.label, "File changed")
        let new = try XCTUnwrap(FolderScanner.scan(root, progress: { _ in }).first)
        XCTAssertEqual(new.filmSimulation, .acros)
        XCTAssertNotEqual(new.contentRevision, old.contentRevision)

        let raw = root.appendingPathComponent("capture.RAF")
        try Data("unsupported fixture".utf8).write(to: raw)
        let pair = try FolderScanner.scan(root, pairingMode: .together, progress: { _ in })
        try FileManager.default.removeItem(at: url)
        try FujiJPEGFixture.jpeg(note: FujiJPEGFixture.note(film: 0x200)).write(to: url)
        XCTAssertThrowsError(try FolderScanner.projectPairingMode(.separate, from: pair, root: root))
        XCTAssertNil(pair.first?.pairedFile?.filmSimulation)
    }
}

@MainActor
final class FujiFilmSimulationFilterTests: XCTestCase {
    /// Opt-in read-only corpus check against independently extracted values.
    /// Manifest: [{"path":"/absolute/photo.RAF","simulation":"acrosYellow"}].
    func testRealJPEGAndRAFCorpusAgainstIndependentManifest() throws {
        guard let path = ProcessInfo.processInfo.environment["LOUPPE_FUJI_VALIDATION_MANIFEST"] else {
            throw XCTSkip("Set LOUPPE_FUJI_VALIDATION_MANIFEST for real Fuji JPEG/RAF validation")
        }
        struct Expected: Decodable { let path: String; let simulation: String }
        let rows = try JSONDecoder().decode([Expected].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let expected = try rows.map { (path: $0.path, simulation: try XCTUnwrap(FujiFilmSimulation(rawValue: $0.simulation))) }
        XCTAssertFalse(expected.isEmpty)
        XCTAssertTrue(expected.contains { URL(fileURLWithPath: $0.path).pathExtension.lowercased() == "raf" })
        XCTAssertTrue(expected.contains { ["jpg", "jpeg"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) })
        let byPath = Dictionary(uniqueKeysWithValues: expected.map { (URL(fileURLWithPath: $0.path).standardizedFileURL.path, $0.simulation) })
        let folders = Set(expected.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent() })
        for folder in folders {
            let items = try FolderScanner.scan(folder, pairingMode: .separate, progress: { _ in })
            let indexed = Dictionary(uniqueKeysWithValues: items.map { ($0.primaryURL.standardizedFileURL.path, $0) })
            for row in expected where URL(fileURLWithPath: row.path).deletingLastPathComponent() == folder {
                let url = URL(fileURLWithPath: row.path)
                let item = try XCTUnwrap(indexed[url.standardizedFileURL.path])
                XCTAssertEqual(item.filmSimulation, row.simulation, url.lastPathComponent)
                XCTAssertEqual(MetadataExtractor.fields(for: item).first { $0.label == "Film simulation" }?.value,
                               row.simulation.label, url.lastPathComponent)
                XCTAssertEqual(FujiFilmSimulationReader.read(url: url, properties: [kCGImagePropertyTIFFDictionary:
                    [kCGImagePropertyTIFFMake: "FUJIFILM"]]), row.simulation, "Container fallback: \(url.lastPathComponent)")
            }
            let together = try FolderScanner.scan(folder, pairingMode: .together, progress: { _ in })
            for item in together {
                if let value = byPath[item.primaryURL.standardizedFileURL.path] {
                    XCTAssertEqual(item.filmSimulation, value, "Paired primary: \(item.displayName)")
                }
            }
            let split = try FolderScanner.projectPairingMode(.separate, from: together, root: folder)
            for item in split.items {
                if let value = byPath[item.primaryURL.standardizedFileURL.path] {
                    XCTAssertEqual(item.filmSimulation, value, "Separated: \(item.displayName)")
                }
            }
            let suite = "LouppeFujiCorpus-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = SessionStore(reviewDefaults: defaults)
            store.items = items
            store.phase = .ready
            store.rebuildDerivedDataForTesting(sourceFolder: folder)
            for simulation in Set(expected.filter { URL(fileURLWithPath: $0.path).deletingLastPathComponent() == folder }.map(\.simulation)) {
                XCTAssertTrue(store.availableFilmSimulations.contains(simulation))
                store.filter.excludedFilmSimulations = Set(store.availableFilmSimulations).subtracting([simulation])
                XCTAssertFalse(store.visibleIndices.isEmpty)
                XCTAssertTrue(store.visibleIndices.allSatisfy { store.items[$0].filmSimulation == simulation })
            }
        }
    }

    func testFacetMultiSelectIntersectionSelectionResetAndReplacement() throws {
        let root = try FujiJPEGFixture.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let sources: [(String, Data, FujiFilmSimulation)] = [
            ("a.JPG", FujiJPEGFixture.note(film: 0), .provia),
            ("b.JPG", FujiJPEGFixture.note(film: 0x600), .classicChrome),
            ("c.JPG", FujiJPEGFixture.note(saturation: 0x500), .acros),
            ("d.JPG", FujiJPEGFixture.note(film: 0xfffe), .unknown),
            ("e.JPG", FujiJPEGFixture.note(), .notRecorded)
        ]
        for (name, note, _) in sources {
            try FujiJPEGFixture.jpeg(note: note).write(to: root.appendingPathComponent(name))
        }
        let suite = "LouppeFujiTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var quality = CameraQualityWarningPreferences()
        quality.isEnabled = false
        quality.save(to: defaults)
        let store = SessionStore(reviewDefaults: defaults)
        store.items = try FolderScanner.scan(root, progress: { _ in })
        store.phase = .ready
        store.rebuildDerivedDataForTesting(sourceFolder: root)
        XCTAssertEqual(Set(store.availableFilmSimulations), Set(sources.map { $0.2 }))
        XCTAssertEqual(store.filmSimulationCounts[.acros], 1)
        XCTAssertEqual(store.filmSimulationCounts[.unknown], 1)
        XCTAssertEqual(store.filmSimulationCounts[.notRecorded], 1)
        store.setSelection([0, 2])
        let originalDecisions = store.items.flatMap(\.individualFiles).map(\.metadataSnapshot)
        store.filter.excludedFilmSimulations = [.provia, .unknown, .notRecorded]
        XCTAssertEqual(Set(store.visibleIndices.map { store.items[$0] }.map(\.displayName)), ["b.JPG", "c.JPG"])
        XCTAssertEqual(store.selectedIndices, [2])
        XCTAssertEqual(store.currentItem?.displayName, "c.JPG")
        store.items[1].setRating(.no, ratedAt: nil)
        store.filter.excludedDecisionStates = [.no]
        XCTAssertEqual(store.visibleIndices.map { store.items[$0] }.map(\.displayName), ["c.JPG"])
        store.filter.excludedDecisionStates = []
        store.filter.excludedFilmSimulations = [.provia, .classicChrome, .acros, .unknown]
        XCTAssertEqual(store.visibleIndices.map { store.items[$0] }.map(\.displayName), ["e.JPG"])
        store.filter.excludedFilmSimulations.insert(.notRecorded)
        XCTAssertTrue(store.visibleIndices.isEmpty)
        XCTAssertNil(store.currentItem)
        XCTAssertTrue(store.effectiveSelection.isEmpty)
        store.rate(.yes)
        XCTAssertFalse(store.items.contains { $0.rating == .yes })
        store.resetFilter()
        XCTAssertEqual(store.visibleIndices.count, 5)
        XCTAssertTrue(store.filter.excludedFilmSimulations.isEmpty)
        // Filtering must remain independent of files after indexing.
        for (name, _, _) in sources { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        store.filter.excludedFilmSimulations = [.classicChrome, .acros, .unknown, .notRecorded]
        XCTAssertEqual(store.visibleIndices.map { store.items[$0] }.map(\.displayName), ["a.JPG"])
        XCTAssertEqual(store.items[0].primaryFile.metadataSnapshot, originalDecisions[0])
        let replacement = PhotoItem(id: "a.JPG", primaryURL: root.appendingPathComponent("a.JPG"),
            pairedURL: nil, captureDate: nil, cameraModel: "X-T4", lensModel: nil,
            filmSimulation: .acros, fileSize: 0)
        store.items = [replacement]
        store.rebuildDerivedDataForTesting(sourceFolder: root)
        XCTAssertEqual(store.filmSimulationCounts, [.acros: 1])
        XCTAssertTrue(store.visibleIndices.isEmpty, "Same-ID metadata replacement must use the new simulation.")
        store.resetFilter()
        XCTAssertEqual(store.visibleIndices.map { store.items[$0] }.first?.filmSimulation, .acros)
    }
}

/// Tiny disposable JPEGs with real EXIF IFD structure and Fuji MakerNotes.
/// Pixel bytes are generated locally; no personal photograph is a test asset.
private enum FujiJPEGFixture {
    static func folder() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("LouppeFuji-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func note(film: UInt16? = nil, saturation: UInt16? = nil) -> Data {
        var entries: [(UInt16, UInt16)] = []
        if let saturation { entries.append((0x1003, saturation)) }
        if let film { entries.append((0x1401, film)) }
        return note(entries: entries)
    }

    static func raf(jpeg: Data) -> Data {
        var raf = Data(repeating: 0, count: 160)
        let signature = Array("FUJIFILMCCD-RAW".utf8)
        raf.replaceSubrange(0..<signature.count, with: signature)
        raf.replaceSubrange(84..<88, with: [0, 0, 0, 160])
        let length = UInt32(jpeg.count).bigEndian
        withUnsafeBytes(of: length) { raf.replaceSubrange(88..<92, with: $0) }
        raf.append(jpeg)
        return raf
    }

    static func note(entries: [(UInt16, UInt16)]) -> Data {
        var bytes = Array("FUJIFILM".utf8)
        bytes += number(12, size: 4, little: true)
        bytes += number(entries.count, size: 2, little: true)
        for (tag, value) in entries {
            bytes += number(Int(tag), size: 2, little: true)
            bytes += number(3, size: 2, little: true)
            bytes += number(1, size: 4, little: true)
            bytes += number(Int(value), size: 2, little: true) + [0, 0]
        }
        bytes += [0, 0, 0, 0]
        return Data(bytes)
    }

    static func tiff(note: Data, little: Bool) -> Data {
        let make = Array("FUJIFILM\0".utf8)
        let model = Array("X-T4\0".utf8)
        let makeOffset = 50
        let modelOffset = makeOffset + make.count
        let exifOffset = modelOffset + model.count
        let noteOffset = exifOffset + 18
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) -> [UInt8] {
            number(tag, size: 2, little: little) + number(type, size: 2, little: little)
                + number(count, size: 4, little: little) + number(value, size: 4, little: little)
        }
        var bytes: [UInt8] = little ? [0x49, 0x49] : [0x4d, 0x4d]
        bytes += number(42, size: 2, little: little) + number(8, size: 4, little: little)
        bytes += number(3, size: 2, little: little)
        bytes += entry(0x010f, 2, make.count, makeOffset)
        bytes += entry(0x0110, 2, model.count, modelOffset)
        bytes += entry(0x8769, 4, 1, exifOffset)
        bytes += [0, 0, 0, 0] + make + model
        bytes += number(1, size: 2, little: little)
        bytes += entry(0x927c, 7, note.count, noteOffset)
        bytes += [0, 0, 0, 0]
        bytes += note
        return Data(bytes)
    }

    static func jpeg(note: Data, little: Bool = true) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let pixels = data as Data
        let segment = Data([0x45, 0x78, 0x69, 0x66, 0, 0]) + tiff(note: note, little: little)
        return Data([0xff, 0xd8, 0xff, 0xe1])
            + Data(number(segment.count + 2, size: 2, little: false))
            + segment + pixels.dropFirst(2)
    }

    private static func number(_ value: Int, size: Int, little: Bool) -> [UInt8] {
        (0..<size).map { index in
            UInt8(truncatingIfNeeded: value >> ((little ? index : size - 1 - index) * 8))
        }
    }
}
