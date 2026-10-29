import XCTest
import AppKit
import SwiftUI
@testable import Louppe

@MainActor
final class AccessibilityTests: XCTestCase {
    func testHistogramSpeaksSourceAndMeasuredAreas() {
        let analysis = HistogramAnalysis(bins: [1, 2], sampleCount: 100,
                                         shadowCount: 5, highlightCount: 20)
        let value = HistogramAccessibility.value(analysis: analysis, source: .renderedPreview)
        XCTAssertTrue(value.contains("Rendered image estimate"))
        // Numbers follow the Mac's locale (for example 5,0 % in Denmark).
        XCTAssertTrue(value.contains("5"), value)
        XCTAssertTrue(value.contains("20"), value)
        XCTAssertTrue(HistogramAccessibility.value(analysis: analysis, source: .rawDecode).contains("RAW decode"))
    }

    func testTextPreviewSupportsDoubleSizeAndRetainsMarkdown() throws {
        let text = try AttributedString(markdown: "# Heading\n\n**Bold** [link](https://example.com)",
                                        options: .init(interpretedSyntax: .full))
        let standard = NativeTextPreview.render(text)
        let large = NativeTextPreview.render(text, scale: 2)
        XCTAssertEqual(standard.string, large.string)
        for offset in 0..<standard.length {
            if standard.string.utf16[standard.string.utf16.index(standard.string.utf16.startIndex, offsetBy: offset)] == 10 {
                continue // Synthetic block separators have no font attributes.
            }
            let base = try XCTUnwrap(standard.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
            let scaled = try XCTUnwrap(large.attribute(.font, at: offset, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(scaled.pointSize, base.pointSize * 2, accuracy: 0.01)
            XCTAssertEqual(standard.attribute(.link, at: offset, effectiveRange: nil) as? URL,
                           large.attribute(.link, at: offset, effectiveRange: nil) as? URL)
        }
    }

    func testAccentPaletteMeetsTextContrastInEveryAppearance() throws {
        _ = NSApplication.shared
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let isDark = name == .darkAqua || name == .accessibilityHighContrastDarkAqua
            let appearance = try XCTUnwrap(NSAppearance(named: isDark ? .darkAqua : .aqua))
            let foreground = NSColor.louppeAccentColor(for: name).usingColorSpace(.sRGB)
            var background: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            }
            let first = luminance(try XCTUnwrap(foreground))
            let second = luminance(try XCTUnwrap(background))
            XCTAssertGreaterThanOrEqual((max(first, second) + 0.05) / (min(first, second) + 0.05), 4.5,
                                       "\(name.rawValue): foreground \(String(describing: foreground)), background \(String(describing: background))")
        }
    }

    private func luminance(_ color: NSColor) -> Double {
        let linear = [color.redComponent, color.greenComponent, color.blueComponent].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        return Double(linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722)
    }

    func testFilledAccentKeepsWhiteNativeTextReadableInEveryAppearance() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let fill = try XCTUnwrap(NSColor.louppeFilledAccentColor(for: appearance).usingColorSpace(.sRGB))
            XCTAssertGreaterThanOrEqual(1.05 / (luminance(fill) + 0.05), 4.5, appearance.rawValue)
        }
    }

    func testDecisionGlyphsMeetNonTextContrastInBothAppearances() throws {
        _ = NSApplication.shared
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for (symbol, fill) in [(RatingBadge.yesSymbolColor, RatingBadge.yesFillColor),
                                   (RatingBadge.noSymbolColor, RatingBadge.noFillColor)] {
                var mark: NSColor?
                var background: NSColor?
                appearance.performAsCurrentDrawingAppearance {
                    mark = symbol.usingColorSpace(.sRGB)
                    background = fill.usingColorSpace(.sRGB)
                }
                let first = luminance(try XCTUnwrap(mark))
                let second = luminance(try XCTUnwrap(background))
                XCTAssertGreaterThanOrEqual((max(first, second) + 0.05) / (min(first, second) + 0.05), 3,
                                           "Decision glyph contrast in \(name.rawValue)")
            }
        }
    }

    func testMediaTileDescriptionIncludesNonvisualState() {
        let item = mixedPair()

        XCTAssertEqual(
            MediaTileAccessibility.value(
                for: item,
                isCurrent: true,
                isSelected: true
            ),
            "RAW and JPEG photo, Mixed decision, No stars, No color label, Current item, Selected"
        )
    }

    func testUnavailableRatingActionsAreOmittedFromVoiceOver() {
        XCTAssertEqual(
            MediaTileAccessibility.ratingActions(canRate: true),
            [.yes, .no, .clear]
        )
        XCTAssertTrue(
            MediaTileAccessibility.ratingActions(canRate: false).isEmpty
        )
        XCTAssertTrue(
            MediaTileAccessibility.actionHint(canRate: true)
                .contains("stars")
        )
        XCTAssertFalse(
            MediaTileAccessibility.actionHint(canRate: false)
                .contains("stars")
        )
    }

    func testExplicitTileRatingUpdatesPairAndUndoRestoresConflict() {
        let store = SessionStore()
        store.items = [mixedPair()]
        // Rebuild the same stable file-ID map populated by a folder scan.
        store.sort = PhotoSort(key: .name, ascending: true)
        store.phase = .ready

        store.rate(.yes, at: 0)

        XCTAssertEqual(
            store.items[0].ratingSnapshots.map(\.rating),
            [.yes, .yes]
        )
        XCTAssertFalse(store.items[0].hasMixedRatings)

        store.undo()

        XCTAssertEqual(
            store.items[0].ratingSnapshots.map(\.rating),
            [.yes, .no]
        )
        XCTAssertTrue(store.items[0].hasMixedRatings)
    }

    private func mixedPair() -> PhotoItem {
        let raw = PhotoFile(
            id: "SHOT.NEF",
            url: URL(fileURLWithPath: "/tmp/SHOT.NEF"),
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 10,
            rating: .yes
        )
        let jpeg = PhotoFile(
            id: "SHOT.JPG",
            url: URL(fileURLWithPath: "/tmp/SHOT.JPG"),
            captureDate: nil,
            cameraModel: nil,
            lensModel: nil,
            fileSize: 5,
            rating: .no
        )
        return PhotoItem(primaryFile: raw, pairedFile: jpeg)
    }
}
