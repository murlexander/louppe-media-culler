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

    func testInlineValuePickersBelongToValueMenu() throws {
        for file in try swiftFiles(in: "Sources/Louppe")
        where relativePath(file) != "Sources/Louppe/Views/Design/ValueMenu.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(try inlineValueMenuCount(in: source), 0, relativePath(file))
        }
    }

    func testValueMenuMatcherIgnoresActionMenusAndUnrelatedPickers() throws {
        XCTAssertEqual(try inlineValueMenuCount(in: """
            Menu { Picker("Sort", selection: $key) { Text("Name").tag(0) }
                .pickerStyle(.inline).labelsHidden()
            } label: { Text("Name") }
            """), 1)
        XCTAssertEqual(try inlineValueMenuCount(in: """
            Menu("Pinned") { ForEach(pins) { pin in Button(pin.title) { open(pin) } } }
            Picker("Mode", selection: $mode) { Text("Gallery").tag(0) }.pickerStyle(.inline)
            Menu { Button("Parent") { open(parent) } } label: { Text("Folder") }
            // Menu { Picker("Ignored") {}.pickerStyle(.inline) }
            let text = "Menu { Picker {}.pickerStyle(.inline) }"
            """), 0)
        XCTAssertEqual(try inlineValueMenuCount(in: """
            Menu("Value") {
                Picker("Value", selection: Binding(get: { value }, set: { value = $0 })) {
                    ForEach(options) { Text($0.title).tag($0) }
                }.pickerStyle(.inline)
            }
            """), 1)
    }

    private func inlineValueMenuCount(in source: String) throws -> Int {
        // Balance each Menu's content closure, so a later standalone inline
        // Picker cannot turn an action menu into a false positive.
        let nonCode = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|//[^\n]*|(?s:/\*.*?\*/)"#)
        let code = nonCode.stringByReplacingMatches(in: source,
            range: NSRange(source.startIndex..., in: source), withTemplate: " ") as NSString
        let menus = try NSRegularExpression(pattern: #"\bMenu\s*(?:\([^{}]*\))?\s*\{"#)
        let picker = try NSRegularExpression(pattern: #"\bPicker\s*\("#)
        let inline = try NSRegularExpression(pattern: #"\.pickerStyle\s*\(\s*\.inline\s*\)"#)
        return menus.matches(in: code as String, range: NSRange(location: 0, length: code.length)).filter { menu in
            let start = NSMaxRange(menu.range)
            var depth = 1
            var end = start
            while end < code.length, depth > 0 {
                if code.character(at: end) == 123 { depth += 1 }
                if code.character(at: end) == 125 { depth -= 1 }
                end += 1
            }
            let range = NSRange(location: start, length: end - start)
            return picker.firstMatch(in: code as String, range: range) != nil
                && inline.firstMatch(in: code as String, range: range) != nil
        }.count
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
        XCTAssertEqual(try bareEnglishCountCount(in: #"Text("\(count) media files"); Text("2 items")"#), 2)
        XCTAssertEqual(try bareEnglishCountCount(in: #"L10n.text("\(count) media files"); L10n.text("2 items"); Text("\(name) files remain")"#), 0)
        XCTAssertEqual(try bareEnglishCountCount(in: #"let a = "\(rating.count) stars"; L10n.text("\(rating.count) stars")"#), 1)
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

    func testPopoversUseTheSharedSurface() throws {
        // Popover content applies louppePopoverSurface(); Sort and Filter get it from their scaffold.
        let scaffold = try String(contentsOf: repositoryRoot.appendingPathComponent(
            "Sources/Louppe/Views/Design/CompactToolbarPopover.swift"), encoding: .utf8)
        XCTAssertTrue(scaffold.contains(".louppePopoverSurface()"))
        XCTAssertFalse(scaffold.contains("appBackground"))
        let expression = try NSRegularExpression(
            pattern: #"\.popover\s*\([^{]*\{(.*?)\n\s*\}"#, options: .dotMatchesLineSeparators)
        var popovers = 0
        for file in try swiftFiles(in: "Sources/Louppe") {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                popovers += 1
                let content = try XCTUnwrap(Range(match.range(at: 1), in: source).map { String(source[$0]) })
                XCTAssertTrue(["louppePopoverSurface()", "SortView(", "FilterView("].contains { content.contains($0) },
                              "\(relativePath(file)): \(content)")
                XCTAssertFalse(content.contains("appBackground"), relativePath(file))
            }
        }
        XCTAssertGreaterThanOrEqual(popovers, 4)
    }

    private func bareEnglishCountCount(in source: String) throws -> Int {
        // Capture the optional L10n call with the whole literal, rather than matching its inner quote again.
        let expression = try NSRegularExpression(pattern:
            #"(?:(L10n\s*\.\s*(?:text|label)\s*\(\s*))?"(?:1 [A-Za-z]+(?: [^"\\\n]*)?|(?:[0-9]+|\\\([^"\\\n]*\)) (?:items?|files?|folders?|media files?|stars?))""#)
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
