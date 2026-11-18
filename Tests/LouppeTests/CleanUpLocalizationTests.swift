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

    private let breakdownKey = "Includes %lld No and %lld Unmarked items. Stars and color labels do not protect these items. Mixed RAW + JPEG decisions stay in the folder."

    /// No and Unmarked inflect independently: swap singular and plural.
    func testNoAndUnmarkedBreakdownInflectsEachCountIndependently() {
        let unmarked: [String: String] = ["en": "Unmarked", "es": "sin marcar", "pt": "sem marcação",
                                          "zh-Hans": "未标记", "hi": "अचिह्नित", "ar": "بلا تحديد"]
        for language in L10n.supportedLanguages {
            for counts in [[1, 3], [3, 1], [0, 21], [1_000_000, 2]] {
                let text = L10n.renderPlural(breakdownKey, counts: counts, language: language)
                XCTAssertNotEqual(text, breakdownKey, language)
                XCTAssertTrue(text.contains(try! XCTUnwrap(unmarked[language])), "\(language) \(counts)")
                XCTAssertFalse(text.contains("%"), language)
                XCTAssertFalse(text.lowercased().contains("undecided"), language)
                XCTAssertTrue(text.contains("RAW + JPEG"), language)
            }
        }
        XCTAssertEqual(L10n.renderPlural(breakdownKey, counts: [1, 3], language: "en"),
                       "Includes 1 No item and 3 Unmarked items. Stars and color labels do not protect these items. Mixed RAW + JPEG decisions stay in the folder.")
        XCTAssertEqual(L10n.renderPlural(breakdownKey, counts: [3, 1], language: "en"),
                       "Includes 3 No items and 1 Unmarked item. Stars and color labels do not protect these items. Mixed RAW + JPEG decisions stay in the folder.")
        let arabic = L10n.renderPlural(breakdownKey, counts: [2, 1], language: "ar")
        XCTAssertTrue(arabic.contains("عنصرين بقرار «لا»"), "Arabic dual for No")
        XCTAssertTrue(arabic.contains("عنصر واحد بلا تحديد"), "Arabic singular for Unmarked")
        let dualUnmarked = L10n.renderPlural(breakdownKey, counts: [11, 2], language: "ar")
        XCTAssertTrue(dualUnmarked.contains("عنصرين بلا تحديد"))
        XCTAssertTrue(dualUnmarked.contains("عنصرًا بقرار «لا»"), "Arabic many for 11")
        XCTAssertTrue(L10n.renderPlural(breakdownKey, counts: [1, 2], language: "es").contains("1 elemento No y 2 elementos sin marcar"))
    }

    func testTrashTitleAndMenuNameNoAndUnmarked() {
        for language in L10n.supportedLanguages {
            for count in [1, 2, 5, 11, 100] {
                let title = L10n.renderPlural("Trash %lld No or Unmarked items?", counts: [count], language: language)
                XCTAssertNotEqual(title, "Trash %lld No or Unmarked items?", language)
                XCTAssertFalse(title.contains("%"), language)
            }
            XCTAssertNotEqual(L10n.render("Trash No + Unmarked…", language: language), language == "en" ? "" : "Trash No + Unmarked…")
        }
        XCTAssertEqual(L10n.renderPlural("Trash %lld No or Unmarked items?", counts: [1], language: "en"), "Trash 1 No or Unmarked item?")
        XCTAssertEqual(L10n.renderPlural("Trash %lld No or Unmarked items?", counts: [2], language: "ar"),
                       "نقل عنصرين بقرار «لا» أو بلا تحديد إلى سلة المهملات؟")
    }
}
