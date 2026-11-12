import Foundation
import XCTest

final class SourceConventionsTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testNoDeprecatedControlStyles() throws {
        // Use native automatic pickers in grouped Forms, or a borderless button Menu elsewhere.
        let pattern = #"\.pickerStyle\s*\(\s*\.menu\s*\)|\.menuStyle\s*\(\s*\.(?:borderedButton|borderlessButton)\s*\)|\b(?:BorderedButtonMenuStyle|BorderlessButtonMenuStyle)\b"#
        try assertNoMatches(pattern, in: "Sources")
    }

    func testNoSystemAccentColor() throws {
        // Use Color.louppeAccent (or louppeFilledAccent for native white ink).
        try assertNoMatches(#"\baccentColor\b"#)
    }

    func testHandWrittenColorsStayInPalette() throws {
        // Use semantic system colors or named colors from Design/Palette.swift.
        let pattern = ##"\bColor\s*(?:\.\s*init\s*)?\(\s*(?:red\s*:|\.sRGB(?:Linear)?\b|hue\s*:)|\bNSColor\s*(?:\.\s*init\s*)?\(\s*(?:red|srgbRed|calibratedRed|deviceRed)\s*:|#colorLiteral\b|\b(?:Color|NSColor)\s*(?:\.\s*init\s*)?\(\s*(?:hex\w*\s*:|"#[0-9A-Fa-f]{3,8}")"##
        try assertNoMatches(pattern, excluding: "Sources/Louppe/Views/Design/Palette.swift")
    }

    func testBareEnglishCountsAreLocalized() throws {
        // Use L10n.text for UI count phrases; generated filename recipes remain language independent.
        for file in try swiftFiles(in: "Sources/Louppe") {
            var source = try String(contentsOf: file, encoding: .utf8)
            if relativePath(file) == "Sources/Louppe/SourceOrganization.swift" {
                // This exact persisted folder-name recipe is not presentation text.
                source = source.replacingOccurrences(
                    of: #"return rating == .one ? "1 Star" : "\(rating.count) Stars""#, with: "")
            }
            XCTAssertEqual(try bareEnglishCountCount(in: source), 0, relativePath(file))
        }
    }

    func testBareEnglishCountMatcherDistinguishesLocalizedCalls() throws {
        XCTAssertEqual(try bareEnglishCountCount(in: #"let a = "1 file"; let b = Text("1 item"); let c = "1 Star""#), 3)
        XCTAssertEqual(try bareEnglishCountCount(in: #"L10n.text("1 file"); L10n.label( "1 item"); L10n.text("1 item found")"#), 0)
        XCTAssertEqual(try bareEnglishCountCount(in: #"L10n.text(  "1 file"); let a = "1 item"; let b = "1/30 second""#), 1)
    }

    func testCompactPopoverWidthStaysInItsScaffold() throws {
        // Use CompactToolbarPopover instead of repeating its fixed width.
        let scaffold = "Sources/Louppe/Views/Design/CompactToolbarPopover.swift"
        let pattern = #"\.frame\s*\(\s*width\s*:\s*340\b"#
        try assertNoMatches(pattern, excluding: scaffold)
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent(scaffold), encoding: .utf8)
        let expression = try NSRegularExpression(pattern: pattern)
        XCTAssertEqual(expression.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)), 1)
    }

    private func bareEnglishCountCount(in source: String) throws -> Int {
        // Capture the optional L10n call with the whole literal, rather than matching its inner quote again.
        let expression = try NSRegularExpression(pattern:
            #"(?:(L10n\s*\.\s*(?:text|label)\s*\(\s*))?"1 [A-Za-z]+(?: [^"\\\n]*)?""#)
        return expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
            .filter { $0.range(at: 1).location == NSNotFound }.count
    }

    private func assertNoMatches(
        _ pattern: String, in directory: String = "Sources/Louppe", excluding excludedPath: String? = nil
    ) throws {
        let expression = try NSRegularExpression(pattern: pattern)
        for file in try swiftFiles(in: directory) where relativePath(file) != excludedPath {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(expression.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)),
                           0, relativePath(file))
        }
    }

    func testWindowRaisingTestsRequireForegroundGate() throws {
        let pattern = #"\b(?:makeKeyAndOrderFront|orderFrontRegardless)\s*\(|\bNSApp\s*\.\s*activate\s*\(|\bNSApplication\s*\.\s*shared\s*\.\s*activate\s*\(|\bactivate\s*\(\s*ignoringOtherApps\s*:|\bsetActivationPolicy\s*\(\s*\.regular|\bLouppeApplicationDelegate\s*\("#
        let raising = try NSRegularExpression(pattern: pattern)
        for file in try swiftFiles(in: "Tests") {
            guard !["ForegroundUI.swift", "SourceConventionsTests.swift"].contains(file.lastPathComponent) else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            guard raising.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil else { continue }
            XCTAssertTrue(source.contains("requireForegroundUI("),
                "\(relativePath(file)): window-raising tests must call requireForegroundUI() before every raising path, including paths through shared helpers.")
        }
    }

    private func swiftFiles(in directory: String) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: repositoryRoot.appendingPathComponent(directory),
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))
        return try enumerator.compactMap { entry -> URL? in
            guard let url = entry as? URL, url.pathExtension == "swift",
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    private func relativePath(_ file: URL) -> String {
        String(file.path.dropFirst(repositoryRoot.path.count + 1))
    }
}
