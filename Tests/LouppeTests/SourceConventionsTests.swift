import Foundation
import XCTest

final class SourceConventionsTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testDeprecatedControlStylesStayWithinBaseline() throws {
        // 2026-11-09: lower a count whenever an existing occurrence is modernized.
        let baseline: [String: Int] = [
            "Sources/Louppe/Views/MediaTrackSelectionControls.swift": 1,
            "Sources/Louppe/Views/MetadataEditingControls.swift": 1,
            "Sources/Louppe/Views/OrganizeSourceView.swift": 2,
            "Sources/Louppe/Views/ReviewShortcutsSettingsView.swift": 1,
            "Sources/Louppe/Views/SortView.swift": 1,
            "Sources/Louppe/Views/WelcomeView.swift": 1,
        ]
        let pattern = #"\.pickerStyle\s*\(\s*\.menu\s*\)|\.menuStyle\s*\(\s*\.(?:borderedButton|borderlessButton)\s*\)|\b(?:BorderedButtonMenuStyle|BorderlessButtonMenuStyle)\b"#
        let deprecated = try NSRegularExpression(pattern: pattern)
        let preferred = "Outside grouped Forms, use Menu { Picker(…).pickerStyle(.inline) }.menuStyle(.button).buttonStyle(.borderless) as in ArchiveNavigationViews.swift; inside grouped Forms, use automatic picker styling."
        var observed: [String: Int] = [:]
        for file in try swiftFiles(in: "Sources") {
            let source = try String(contentsOf: file, encoding: .utf8)
            let count = deprecated.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
            let path = relativePath(file)
            if count > 0 { observed[path] = count }
            XCTAssertLessThanOrEqual(count, baseline[path, default: 0], "\(path): \(count) deprecated styles exceed baseline \(baseline[path, default: 0]). \(preferred)")
        }
        for path in baseline.keys.sorted() {
            XCTAssertGreaterThanOrEqual(observed[path, default: 0], baseline[path, default: 0],
                "\(path): deprecated styles decreased to \(observed[path, default: 0]); lower this baseline entry (or remove it at zero). \(preferred)")
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
