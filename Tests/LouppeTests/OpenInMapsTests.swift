import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Louppe

@MainActor
final class OpenInMapsTests: XCTestCase {
    private var opened: [PhotoGPSCoordinate] = []

    override func setUp() async throws {
        try await super.setUp()
        opened = []
        MapsLauncher.openOverride = { [weak self] in self?.opened.append($0) }
    }

    override func tearDown() async throws {
        MapsLauncher.openOverride = nil
        try await super.tearDown()
    }

    func testReferencesDecideTheSignAndInvalidValuesFail() {
        func coordinate(_ lat: Double?, _ latRef: String?, _ lon: Double?, _ lonRef: String?) -> PhotoGPSCoordinate? {
            PhotoGPSCoordinate(latitude: lat, latitudeRef: latRef, longitude: lon, longitudeRef: lonRef)
        }
        XCTAssertEqual(coordinate(48.8584, "N", 2.2945, "E"), PhotoGPSCoordinate(latitude: 48.8584, longitude: 2.2945))
        XCTAssertEqual(coordinate(33.8568, "S", 151.2153, "E"), PhotoGPSCoordinate(latitude: -33.8568, longitude: 151.2153))
        XCTAssertEqual(coordinate(-33.8568, "S", -70.1, "W"), PhotoGPSCoordinate(latitude: -33.8568, longitude: -70.1),
                       "An already signed value with a matching reference keeps one sign")
        XCTAssertEqual(coordinate(-12.5, "N", 70.1, "w"), PhotoGPSCoordinate(latitude: 12.5, longitude: -70.1),
                       "A valid reference wins, in either case")
        XCTAssertEqual(coordinate(-12.5, nil, 70.1, "?"), PhotoGPSCoordinate(latitude: -12.5, longitude: 70.1),
                       "Missing or malformed references keep the number's sign")
        let origin = coordinate(0, "S", -0.0, nil)
        XCTAssertEqual(origin, PhotoGPSCoordinate(latitude: 0, longitude: 0), "0,0 is a real position")
        XCTAssertEqual(origin?.latitude.sign, .plus, "Signed zero is normalized")
        XCTAssertEqual(origin?.longitude.sign, .plus)
        XCTAssertNotNil(coordinate(90, "N", 180, "W"), "Inclusive endpoints")
        XCTAssertNil(coordinate(90.0001, "N", 0, "E"))
        XCTAssertNil(coordinate(0, "N", 180.0001, "E"))
        XCTAssertNil(coordinate(nil, "N", 10, "E"), "Missing component")
        XCTAssertNil(coordinate(.nan, "N", 10, "E"))
        XCTAssertNil(coordinate(10, "N", .infinity, "E"))
        XCTAssertNil(MetadataExtractor.gpsCoordinate(from: [kCGImagePropertyGPSLatitude: "north", kCGImagePropertyGPSLongitude: 2]))
        XCTAssertEqual(MetadataExtractor.gpsCoordinate(from: [
            kCGImagePropertyGPSLatitude: "48.858370123", kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 2.294481234, kCGImagePropertyGPSLongitudeRef: "E",
        ]), PhotoGPSCoordinate(latitude: 48.858370123, longitude: 2.294481234), "Numeric strings are accepted")
        let precise = PhotoGPSCoordinate(latitude: -33.856812345, longitude: 151.215298765)
        XCTAssertEqual(precise.displayString, "33.85681°S, 151.21530°E", "Display rounds; the handoff keeps full precision")
    }

    func testImageIOFixtureCarriesTypedCoordinateBesideTheReadout() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try writeJPEG(root, "GPS.JPG", gps: (33.856812345, "S", 151.215298765, "E"))
        let item = PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil,
                             captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
        let field = try XCTUnwrap(MetadataExtractor.fields(for: item).first { $0.label == "GPS" })
        XCTAssertEqual(field.value, "33.85681°S, 151.21530°E")
        let coordinate = try XCTUnwrap(field.coordinate)
        XCTAssertEqual(coordinate.latitude, -33.856812345, accuracy: 1e-5)
        XCTAssertEqual(coordinate.longitude, 151.215298765, accuracy: 1e-5)

        let plain = try writeJPEG(root, "Plain.JPG", gps: nil)
        let plainItem = PhotoItem(id: plain.lastPathComponent, primaryURL: plain, pairedURL: nil,
                                  captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
        XCTAssertFalse(MetadataExtractor.fields(for: plainItem).contains { $0.coordinate != nil })
    }

    func testVoidFixAndZeroZeroKeepTheReadoutButOfferNoMapsAction() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        func gpsField(_ name: String, _ gps: (Double, String, Double, String), status: String? = nil) throws -> MetadataField {
            let url = try writeJPEG(root, name, gps: gps, status: status)
            let item = PhotoItem(id: name, primaryURL: url, pairedURL: nil,
                                 captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
            return try XCTUnwrap(MetadataExtractor.fields(for: item).first { $0.label == "GPS" }, "\(name) keeps its readout")
        }
        let void = try gpsField("Void.JPG", (48.85837, "N", 2.29448, "E"), status: "V")
        XCTAssertEqual(void.value, "48.85837°N, 2.29448°E")
        XCTAssertNil(void.coordinate, "GPSStatus V marks the fix void")
        let origin = try gpsField("Zero.JPG", (0, "N", 0, "E"))
        XCTAssertEqual(origin.value, "0.00000°N, 0.00000°E")
        XCTAssertNil(origin.coordinate, "0,0 is the placeholder of a camera without a fix")
        let active = try gpsField("Active.JPG", (48.85837, "N", 2.29448, "E"), status: "A")
        XCTAssertNotNil(active.coordinate)
        let equator = try gpsField("Equator.JPG", (0, "N", 2.29448, "E"))
        XCTAssertNotNil(equator.coordinate, "Only both-zero is withheld")
    }

    func testInfoShowsTheActionOnlyForValidGPSAndOpensOnlyOnClick() async throws {
        let fixture = try SelectionInteractionFixture()
        defer { fixture.remove() }
        let store = try fixture.readyStore(count: 3)
        let url = try writeJPEG(fixture.root, "GPS.JPG", gps: (48.858370123, "N", 2.294481234, "E"))
        store.items[0] = PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil,
                                   captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
        store.rebuildDerivedDataForTesting()
        store.viewMode = .gallery
        store.setIndex(0)
        let host = NSHostingView(rootView: AnyView(MetadataPanel(store: store, item: store.items[0])
            .environment(\.accessibilityEnabled, true)))
        let window = SelectionInteractionFixture.mount(host, size: CGSize(width: 280, height: 700))
        defer { store.beginTerminationPreparation(); window.contentView = nil; window.close() }
        try await waitUntil { self.mapsButton(in: host) != nil }
        XCTAssertTrue(opened.isEmpty, "Rendering, appearing and accessibility reads open nothing")

        let button = try XCTUnwrap(mapsButton(in: host))
        try SelectionInteractionFixture.click(button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil),
                                              window: window)
        try await SelectionInteractionFixture.settle(host)
        let extracted = try XCTUnwrap(MetadataExtractor.fields(for: store.items[0]).compactMap(\.coordinate).first)
        XCTAssertEqual(opened, [extracted], "One explicit click hands Maps the extracted value, not the readout text")
        XCTAssertEqual(extracted.latitude, 48.858370123, accuracy: 1e-5)

        // Another photo without GPS: no action once its detail arrives.
        host.rootView = AnyView(MetadataPanel(store: store, item: store.items[1])
            .environment(\.accessibilityEnabled, true))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNil(mapsButton(in: host))

        // A multi-selection summary reads no EXIF and offers no action.
        store.setSelection([0, 1])
        host.rootView = AnyView(MetadataPanel(store: store, item: store.items[0])
            .environment(\.accessibilityEnabled, true))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(mapsButton(in: host))
        XCTAssertEqual(opened.count, 1)
    }

    // MARK: - Helpers

    /// The test-seam marker behind the native Open in Maps push button.
    private func mapsButton(in host: NSView) -> NSView? {
        host.layoutSubtreeIfNeeded()
        return SelectionInteractionFixture.descendants(host).first {
            $0 is OpenInMapsTestMarker.MarkerView && $0.window != nil && $0.bounds.height > 10
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OpenInMaps-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real ImageIO-written JPEG, so the production extraction path reads it.
    private func writeJPEG(_ root: URL, _ name: String,
                           gps: (Double, String, Double, String)?, status: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifISOSpeedRatings: [200]],
        ]
        if let gps {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: gps.0, kCGImagePropertyGPSLatitudeRef: gps.1,
                kCGImagePropertyGPSLongitude: gps.2, kCGImagePropertyGPSLongitudeRef: gps.3,
            ]
            if let status {
                var dictionary = properties[kCGImagePropertyGPSDictionary] as! [CFString: Any]
                dictionary[kCGImagePropertyGPSStatus] = status
                properties[kCGImagePropertyGPSDictionary] = dictionary
            }
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
