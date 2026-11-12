import XCTest
@testable import Louppe

final class CleanUpLocalizationTests: XCTestCase {
    func testSingularFileAndItemPhrasesUseEveryCatalogIncludingArabic() {
        let expected: [String: [String]] = [
            "en": ["1 file", "1 item"],
            "ar": ["ملف واحد", "عنصر واحد"],
            "es": ["1 archivo", "1 elemento"],
            "hi": ["1 फ़ाइल", "1 आइटम"],
            "pt": ["1 arquivo", "1 item"],
            "zh-Hans": ["1 个文件", "1 个项目"],
        ]
        for language in L10n.supportedLanguages {
            XCTAssertEqual(L10n.render("1 file", language: language), expected[language]?[0], language)
            XCTAssertEqual(L10n.render("1 item", language: language), expected[language]?[1], language)
        }
    }

    func testCountPhrasesComposeWithExistingTrashWarningsWithoutLosingSafetyText() {
        for language in L10n.supportedLanguages {
            let files = L10n.render("1 file", language: language)
            let space = "12 MB"
            let warning = L10n.render("\(files) will be moved to the Trash (a RAW+JPEG pair counts as two), totaling about \(space). Undo with ⌘Z before closing this session, while files remain in Trash. Emptying Trash permanently deletes them and may free that space.", language: language)
            XCTAssertTrue(warning.contains(files), language)
            XCTAssertTrue(warning.contains(space), language)
            XCTAssertTrue(warning.contains("⌘Z"), language)
            XCTAssertFalse(warning.contains("{"), language)
            let items = L10n.render("1 item", language: language)
            XCTAssertTrue(L10n.render("Trash \(items)?", language: language).contains(items), language)
        }
    }
}
