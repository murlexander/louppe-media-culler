import XCTest
import CryptoKit
import AppKit
import SwiftUI
import ImageIO
#if !APP_STORE
import Sparkle
#endif
@testable import Louppe

final class LocalizationTests: XCTestCase {
    func testLaunchedMacOSLanguagePreference() {
        if let expected = ProcessInfo.processInfo.environment["LOUPPE_TEST_LANGUAGE"] {
            XCTAssertEqual(L10n.language, expected)
        } else {
            XCTAssertTrue(L10n.supportedLanguages.contains(L10n.language))
        }
    }

    func testPluralCountsUseAppLanguageRulesAndGroupedNumbers() {
        let counts = [0, 1, 2, 3, 11, 100, 17015]
        let arabicNumbers = counts.map { $0.formatted(.number.locale(Locale(identifier: "ar"))) }
        let expected: [String: [String]] = [
            "en": ["0 items", "1 item", "2 items", "3 items", "11 items", "100 items", "17,015 items"],
            "es": ["0 elementos", "1 elemento", "2 elementos", "3 elementos", "11 elementos", "100 elementos", "17.015 elementos"],
            "zh-Hans": ["0 项", "1 项", "2 项", "3 项", "11 项", "100 项", "17,015 项"],
            "hi": ["0 आइटम", "1 आइटम", "2 आइटम", "3 आइटम", "11 आइटम", "100 आइटम", "17,015 आइटम"],
            "pt": ["0 item", "1 item", "2 itens", "3 itens", "11 itens", "100 itens", "17.015 itens"],
            "ar": ["\(arabicNumbers[0]) عناصر", "عنصر واحد", "عنصران", "\(arabicNumbers[3]) عناصر",
                   "\(arabicNumbers[4]) عنصرًا", "\(arabicNumbers[5]) عنصر", "\(arabicNumbers[6]) عنصرًا"]
        ]
        for language in L10n.supportedLanguages {
            for (index, count) in counts.enumerated() {
                XCTAssertEqual(withoutDirectionIsolates(L10n.renderPlural("%lld items", counts: [count], language: language)),
                               expected[language]?[index], "\(language): \(count)")
            }
        }
        XCTAssertEqual(L10n.plural("%lld items", 17015),
                       L10n.renderPlural("%lld items", counts: [17015], language: L10n.language))
        XCTAssertEqual(L10n.number(17015), 17015.formatted(.number.locale(L10n.locale)))
    }

    func testEveryPackagedPluralEntryUsesItsLanguageBundleAndAllIntegerForms() throws {
        let counts = [0, 1, 2, 3, 11, 100, 17015]
        let english = try pluralCatalog("en")
        XCTAssertGreaterThanOrEqual(english.count, 104)
        for language in L10n.supportedLanguages {
            let catalog = try pluralCatalog(language)
            XCTAssertEqual(Set(catalog.keys), Set(english.keys), language)
            for (key, entry) in catalog {
                let format = try XCTUnwrap(entry["NSStringLocalizedFormatKey"] as? String)
                // Also proves SwiftPM packaged stringsdict and Bundle returns
                // the plural-aware format instead of its English lookup key.
                XCTAssertEqual(L10n.pluralFormat(forKey: key, language: language), format, "\(language): \(key)")
                let names = entry.keys.filter { $0 != "NSStringLocalizedFormatKey" }.sorted()
                for name in names {
                    let rule = try XCTUnwrap(entry[name] as? [String: String])
                    XCTAssertEqual(rule["NSStringFormatSpecTypeKey"], "NSStringPluralRuleType")
                    XCTAssertEqual(rule["NSStringFormatValueTypeKey"], "lld")
                    let required = language == "ar" ? ["zero", "one", "two", "few", "many", "other"]
                        : language == "zh-Hans" ? ["other"] : ["one", "other"]
                    for category in required { XCTAssertNotNil(rule[category], "\(language): \(key): \(category)") }
                }
                for offset in counts.indices {
                    // Vary each count independently, including the four-count routing summary.
                    let selected = names.indices.map { counts[(offset + 2 * $0) % counts.count] }
                    var expected = format
                    let locale = Locale(identifier: language)
                    var values: [any CVarArg] = []
                    for (index, name) in names.enumerated() {
                        let n = selected[index]
                        let rule = try XCTUnwrap(entry[name] as? [String: String])
                        let category = pluralCategory(n, language: language)
                        let phrase = try XCTUnwrap(rule[category] ?? rule["other"])
                        expected = expected.replacingOccurrences(of: "%\(2 * index + 1)$#@\(name)@", with: phrase)
                        values += [Int64(n), n.formatted(.number.locale(locale))]
                    }
                    let arguments = ["A {1} %lld #@count1@ مرحبًا.JPG", "RAW", "EXTRA"]
                    values += arguments.map { $0 as any CVarArg }
                    expected = String(format: expected, locale: locale, arguments: values)
                    XCTAssertEqual(L10n.renderPlural(key, counts: selected, arguments: arguments, language: language),
                                   expected, "\(language): \(key): \(selected)")
                    let rendered = L10n.renderPlural(key, counts: selected, arguments: arguments, language: language)
                    for token in ["XMP", "RAW", "JPEG", ".acr", "Lightroom", "⌘Z"] where key.contains(token) {
                        XCTAssertTrue(rendered.contains(token), "\(language): \(key): \(selected): lost \(token)")
                    }
                }
            }
        }
    }

    func testMissingPluralKeyKeepsCountsAndLiteralArguments() {
        // Future call sites can precede their catalogs; interleaved raw/display
        // arguments must never be consumed as the wrong printf type.
        XCTAssertEqual(L10n.renderPlural("%lld uncatalogued items · %lld files", counts: [3, 17015], language: "en"),
                       "3 uncatalogued items · 17,015 files")
        XCTAssertEqual(L10n.renderPlural("%lld uncatalogued items in %@", counts: [17015],
                                        arguments: ["A {1} %lld.JPG"], language: "en"),
                       "17,015 uncatalogued items in A {1} %lld.JPG")
        XCTAssertEqual(L10n.renderPlural("%@ of %lld uncatalogued items (100%%)", counts: [17015],
                                        arguments: ["3"], language: "en"), "3 of 17,015 uncatalogued items (100%)")
        XCTAssertEqual(L10n.renderPlural("%lld items", counts: [17015], language: "xx"), "17,015 items")
    }

    func testPluralWholeSentenceKeepsLiteralArgumentsAndIndependentAgreement() {
        XCTAssertEqual(L10n.renderPlural("%lld items changed after this folder was scanned%@. ", counts: [1],
                                        arguments: [" (A {1} %lld.JPG)"], language: "en"),
                       "1 item has changed after this folder was scanned (A {1} %lld.JPG). ")
        XCTAssertEqual(L10n.renderPlural("%lld photos selected · %lld files", counts: [1, 17015], language: "en"),
                       "1 photo selected · 17,015 files")
        XCTAssertEqual(withoutDirectionIsolates(L10n.renderPlural("%lld photos selected · %lld files", counts: [2, 3], language: "ar")),
                       "المحدد: صورتان · \(3.formatted(.number.locale(Locale(identifier: "ar")))) ملفات")
        XCTAssertEqual(L10n.renderPlural(
            "%lld files (about %@) will be moved to the Trash. The matching %@ files will stay in the folder.",
            counts: [1], arguments: ["5 MB", "RAW"], language: "en"),
            "1 file (about 5 MB) will be moved to the Trash. The matching RAW file will stay in the folder.")
        XCTAssertEqual(L10n.renderPlural("%lld stars", counts: [2], language: "ar"), "نجمتان")
        XCTAssertEqual(L10n.renderPlural("Set %lld Stars", counts: [2], language: "ar"), "تعيين نجمتين")
    }

    func testFileOperationMessagesKeepIndependentAgreementAndLiteralNames() {
        let name = "A {1} %lld #@count1@ مرحبًا.JPG"
        for (items, files, expected) in [(1, 2, "1 item · 2 media files"),
                                          (2, 1, "2 items · 1 media file"),
                                          (17015, 1, "17,015 items · 1 media file")] {
            XCTAssertEqual(L10n.renderPlural("%lld items · %lld media files", counts: [items, files], language: "en"), expected)
        }
        for (files, folders, expected) in [(1, 2, "Copied file: 1. Destination folders: 2."),
                                            (2, 1, "Copied files: 2. Destination folder: 1.")] {
            XCTAssertEqual(L10n.renderPlural("Copied files: %lld. Destination folders: %lld.",
                                            counts: [files, folders], language: "en"), expected)
        }
        XCTAssertEqual(withoutDirectionIsolates(L10n.renderPlural("Moved files: %lld. Destination: %@", counts: [1],
                                        arguments: [name], language: "en")), "Moved file: 1. Destination: \(name)")
        XCTAssertEqual(withoutDirectionIsolates(L10n.renderPlural("Into %lld folders inside “%@”", counts: [17015],
                                        arguments: [name], language: "en")), "Into 17,015 folders inside “\(name)”")
        XCTAssertEqual(withoutDirectionIsolates(L10n.renderPlural("%lld items match more than one route: %@.", counts: [1],
                                        arguments: [name], language: "en")), "1 item matches more than one route: \(name).")
        let safety = "Recognized XMP sidecars and grouped RAW+JPEG files follow their media. Nothing is overwritten."
        for (items, folders, expected) in [(1, 2, "1 item will move out of 2 existing folders. "),
                                            (2, 1, "2 items will move out of 1 existing folder. ")] {
            XCTAssertEqual(L10n.renderPlural(
                "%lld items will move out of %lld existing folders. Recognized XMP sidecars and grouped RAW+JPEG files follow their media. Nothing is overwritten.",
                counts: [items, folders], language: "en"), expected + safety)
        }
        XCTAssertEqual(L10n.renderPlural(
            "%lld items will move out of %lld existing folders. Recognized XMP sidecars and grouped RAW+JPEG files follow their media. Nothing is overwritten.",
            counts: [1, 2], language: "hi"),
            "1 आइटम को 2 मौजूदा फ़ोल्डरों से बाहर ले जाया जाएगा। पहचानी गई XMP साइडकार और समूहित RAW+JPEG फ़ाइलें अपने मीडिया के साथ जाएँगी। कुछ भी अधिलेखित नहीं होगा।")
        let key = "%lld existing · %lld to create · %lld to update · %lld application packets copied unchanged"
        XCTAssertEqual(L10n.renderPlural(key, counts: [1, 17015, 0, 2], language: "en"),
                       "1 existing · 17,015 to create · 0 to update · 2 application packets copied unchanged")
        XCTAssertEqual(L10n.renderPlural(key, counts: [2, 0, 17015, 1], language: "es"),
                       "2 existentes · 0 por crear · 17.015 por actualizar · 1 paquete de aplicación copiado sin cambios")
    }

    func testFileAndSidecarProgressUseTotalForAgreementAndGroupedDone() {
        for count in [0, 1, 2, 3, 11, 100, 17015] {
            XCTAssertEqual(L10n.renderPlural("%@ of %lld files", counts: [count],
                                            arguments: ["17,015"], language: "en"),
                           "17,015 of \(count.formatted(.number.locale(Locale(identifier: "en")))) \(count == 1 ? "file" : "files")")
            XCTAssertEqual(L10n.renderPlural("%@ of %lld sidecar families", counts: [count],
                                            arguments: ["17,015"], language: "en"),
                           "17,015 of \(count.formatted(.number.locale(Locale(identifier: "en")))) sidecar \(count == 1 ? "family" : "families")")
        }
        // Hindi uses the singular category for zero; it must still display zero.
        XCTAssertEqual(L10n.renderPlural("%@ of %lld sidecar families", counts: [0], arguments: ["0"], language: "hi"),
                       "0 साइडकार समूह में से 0")
        XCTAssertEqual(withoutDirectionIsolates(L10n.renderPlural("%@ of %lld sidecar families", counts: [2],
                                                               arguments: ["٠"], language: "ar")),
                       "٠ من مجموعتي ملفات مصاحبة")
    }

    func testFileOperationArabicDualAndSafetyWording() {
        XCTAssertEqual(L10n.renderPlural("Rename %lld files?", counts: [2], language: "ar"), "إعادة تسمية ملفين؟")
        XCTAssertEqual(L10n.renderPlural("%lld media files", counts: [2], language: "ar"), "ملفا وسائط")
        XCTAssertEqual(L10n.renderPlural("%lld folders", counts: [2], language: "ar"), "مجلدان")
        XCTAssertEqual(L10n.renderPlural("Resolve %lld filename conflicts before renaming.", counts: [2], language: "ar"),
                       "حلّ تعارضين في الأسماء قبل إعادة التسمية.")
        XCTAssertEqual(L10n.renderPlural(
            "%lld Lightroom .acr companions will stay untouched beside originals. Louppe never reads or changes Lightroom heavy-edit data.",
            counts: [2], language: "ar"),
            "سيبقى ملفا Lightroom .acr مرافقان دون تغيير بجانب الملفات الأصلية. لا يقرأ Louppe بيانات التحرير المتقدم في Lightroom ولا يغيّرها أبدًا.")
    }

    func testSourcePluralKeysHaveCatalogEntries() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources/Louppe"), includingPropertiesForKeys: nil))
        let expression = try NSRegularExpression(pattern: #"L10n\.plural\(\s*"([^"]+)""#)
        let catalog = try pluralCatalog("en")
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let range = try XCTUnwrap(Range(match.range(at: 1), in: source))
                XCTAssertNotNil(catalog[String(source[range])], "\(file.lastPathComponent): \(source[range])")
            }
        }
    }

    private func withoutDirectionIsolates(_ value: String) -> String {
        // NSString inserts bidi isolation around substituted numbers on some
        // macOS versions. The catalog matrix above verifies those bytes too.
        value.replacingOccurrences(of: "\u{2068}", with: "")
            .replacingOccurrences(of: "\u{2069}", with: "")
    }

    private func pluralCategory(_ count: Int, language: String) -> String {
        if language == "zh-Hans" { return "other" }
        if language == "ar" {
            if count == 0 { return "zero" }
            if count == 1 { return "one" }
            if count == 2 { return "two" }
            if (3...10).contains(count % 100) { return "few" }
            if (11...99).contains(count % 100) { return "many" }
            return "other"
        }
        if (language == "hi" || language == "pt"), count == 0 { return "one" }
        return count == 1 ? "one" : "other"
    }

    private func pluralCatalog(_ language: String) throws -> [String: [String: Any]] {
        let path = try XCTUnwrap(L10n.resourceBundle.path(forResource: "Localizable", ofType: "stringsdict",
                                                       inDirectory: nil, forLocalization: language))
        return try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: [String: Any]])
    }

    func testLanguagePreferencesAndRegionalVariants() {
        XCTAssertEqual(L10n.language(for: ["es-MX", "en-US"]), "es")
        XCTAssertEqual(L10n.language(for: ["zh-CN"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["zh-SG"]), "zh-Hans")
        XCTAssertEqual(L10n.language(for: ["zh-Hant", "pt-BR"]), "pt")
        XCTAssertEqual(L10n.language(for: ["zh-TW"]), "en")
        XCTAssertEqual(L10n.language(for: ["hi-IN"]), "hi")
        XCTAssertEqual(L10n.language(for: ["ar-SA"]), "ar")
        XCTAssertEqual(L10n.language(for: ["fr-FR", "es-ES"]), "es")
        XCTAssertEqual(L10n.language(for: ["en-GB", "ar"]), "en")
        XCTAssertEqual(L10n.language(for: ["de-DE"]), "en")
    }

    func testCompleteCatalogsPreserveSafetyArgumentsAndFormats() throws {
        let english = try catalog("en")
        XCTAssertGreaterThan(english.count, 1000)
        for language in L10n.supportedLanguages {
            let translated = try catalog(language)
            XCTAssertEqual(Set(translated.keys), Set(english.keys), language)
            for (key, value) in translated {
                XCTAssertFalse(value.isEmpty, "\(language): \(key)")
                XCTAssertTrue(L10n.isValidTemplate(value, for: key), "\(language): \(key): \(value)")
                XCTAssertEqual(L10n.placeholders(in: key), L10n.placeholders(in: value), "\(language): \(key)")
                if key.contains("⌘Z") { XCTAssertTrue(value.contains("⌘Z"), "\(language): \(key)") }
                if key.contains(".acr") { XCTAssertTrue(value.contains(".acr"), "\(language): \(key)") }
                if key.contains("xmp:Label") { XCTAssertTrue(value.contains("xmp:Label"), "\(language): \(key)") }
                for token in ["%.1f", "%.0f", "%.2f"] where key.contains(token) {
                    XCTAssertTrue(value.contains(token), "\(language): \(key)")
                }
            }
        }
    }

    func testEveryCatalogMessageRendersWithoutTemplateDebris() throws {
        for language in L10n.supportedLanguages {
            for (key, value) in try catalog(language) {
                let slots = L10n.placeholders(in: key)
                let arguments = (0..<(slots.keys.max().map { $0 + 1 } ?? 0)).map { "VALUE-\($0)-END" }
                let message = L10n.Message(key: key, arguments: arguments)
                let rendered = L10n.render(message, language: language)
                XCTAssertFalse(rendered.contains("{"), "\(language): \(key): \(rendered)")
                XCTAssertFalse(rendered.contains("}"), "\(language): \(key): \(rendered)")
                // Assert the catalog itself was used, so fallback cannot hide defects.
                var expected = value
                for (index, argument) in arguments.enumerated() {
                    expected = expected.replacingOccurrences(of: "{\(index)}", with: argument)
                }
                XCTAssertEqual(rendered, expected, "\(language): \(key)")
                for (index, count) in slots {
                    XCTAssertEqual(rendered.components(separatedBy: arguments[index]).count - 1, count,
                                   "\(language): \(key): slot \(index)")
                }
            }
        }
    }

    func testDamagedTemplatesFallBackBeforeInsertingLiteralUserText() {
        let filename = "A {1} } \u{2067}ملف.JPG"
        let message: L10n.Message = "Item \(filename) of \(16)"
        let expected = "Item \(filename) of 16"
        for damaged in ["{0} } {1} {مراجعة }", "{0} {1}}", "{{0}} {1}",
                        "{0} {1} {oops}", "{0}", "{0} {1} {1}", "{0} {2}", ""] {
            XCTAssertFalse(L10n.isValidTemplate(damaged, for: message.key), damaged)
            XCTAssertEqual(L10n.render(message, translation: damaged), expected, damaged)
        }
        XCTAssertFalse(L10n.isValidTemplate("{999999999999999999999999999999}", for: "Fit"))
        XCTAssertFalse(L10n.isValidTemplate("Fit }", for: "Fit"))
        XCTAssertEqual(L10n.render(message, translation: "{1} من {0}"), "16 من \(filename)")
        XCTAssertEqual(L10n.render("Fit", translation: "Fit }"), "Fit")
    }

    func testArabicCountersAndPhotographicLabels() {
        let reviewed: L10n.Message = "  ·  \(7)/\(16) reviewed"
        let showing: L10n.Message = "Showing \(7) of \(16)"
        XCTAssertEqual(L10n.render(reviewed, language: "ar"), "  ·  تمت مراجعة 7 من 16")
        for message in [reviewed, showing] {
            let value = L10n.render(message, language: "ar")
            XCTAssertFalse(value.contains("{"))
            XCTAssertFalse(value.contains("}"))
            XCTAssertTrue(value.contains("7"))
            XCTAssertTrue(value.contains("16"))
        }
        XCTAssertEqual(L10n.render("Exposure", language: "zh-Hans"), "曝光")
        XCTAssertEqual(L10n.render("Camera", language: "zh-Hans"), "相机")
        XCTAssertEqual(L10n.render("File size", language: "ar"), "حجم الملف")
        XCTAssertEqual(L10n.render("Focal length", language: "ar"), "البعد البؤري")
    }

    func testUnchangedEnglishTextIsLimitedToBrandsUnitsAndSharedWords() throws {
        let technical: Set<String> = ["Adobe Bridge", "Adobe Lightroom Classic", "Capture One",
                                      // Printed Mac modifier names, also used by localized keyboards.
                                      "Command", "Shift",
                                      "{0} XMP", "{0} fps", "{0} dBFS", "{0} {1} RAW + JPEG",
                                      // Labels and values are already localized; only punctuation is shared.
                                      "{0}: {1}", "{0} · {1}"]
        let shared: [String: Set<String>] = [
            "es": ["Audio", "Color", "Color: {0}", "General", "Manual", "Mono", "No", "OK", "audio", "{0} s", "s"],
            "pt": ["1 item", "Codec", "Manual", "Mono", "OK", "Picture in Picture", "Volume", "item", "{0} s", "s"]
        ]
        for language in L10n.supportedLanguages where language != "en" {
            let allowed = technical.union(shared[language] ?? [])
            for (key, value) in try catalog(language) where key == value {
                XCTAssertTrue(allowed.contains(key), "Unexpected English fallback in \(language): \(key)")
            }
        }
    }

    func testArabicNumericRangesKeepTheirReadingOrder() {
        XCTAssertEqual(L10n.render("4–5 Stars", language: "ar"), "\u{2066}4–5\u{2069} نجوم")
        XCTAssertTrue(L10n.render("1/8000–60 seconds. Enter a fraction such as 1/30 or seconds such as 2.5. Press Return to apply.", language: "ar")
            .contains("\u{2066}1/8000–60\u{2069}"))
        XCTAssertTrue(L10n.render("sRGB luminance 0–5 / 250–255; rendered preview.", language: "ar")
            .contains("\u{2066}0–5 / 250–255\u{2069}"))
    }

    func testNumericLimitsAndTimeFormatsRemainIntact() throws {
        let contracts: [String: [String]] = [
            "1/8000–60 seconds. Enter a fraction such as 1/30 or seconds such as 2.5. Press Return to apply.": ["1/8000–60", "1/30", "2.5"],
            "0.1–100%. Press Return to apply.": ["0.1–100%"],
            "The XMP packet exceeds Louppe's 64 MiB safety limit.": ["64 MiB"],
            "This file is larger than the 1 MB text preview limit. Open it in another app to read it.": ["1 MB"],
            "Use m:ss or h:mm:ss": ["m:ss", "h:mm:ss"]
        ]
        for language in L10n.supportedLanguages {
            let values = try catalog(language)
            for (key, tokens) in contracts {
                let value = try XCTUnwrap(values[key])
                for token in tokens { XCTAssertTrue(value.contains(token), "\(language): \(key): \(token)") }
            }
            let iso = try XCTUnwrap(values["ISO 100–1,000,000. Press Return to apply."])
            XCTAssertTrue(iso.contains("100–1,000,000") || iso.contains("100–1.000.000"), language)
        }
    }

    func testSourceLiteralsHaveEnglishCatalogEntries() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [repository.appendingPathComponent("Scripts/check_localization_sources.py").path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "A literal L10n call is missing from the English catalog")
    }

    func testCatalogsKeepProductNamesAndSafetyTokens() throws {
        let tokens = ["RAW", "JPEG", "XMP", ".acr", "xmp:Label", "⌘Z", "ISO",
                      "Capture One", "Adobe Bridge", "Lightroom", "Core Image", "UTF-8", "APFS", "ExFAT"]
        for language in L10n.supportedLanguages {
            for (key, value) in try catalog(language) {
                for token in tokens {
                    let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: token) + "(?![A-Za-z])"
                    guard key.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
                    XCTAssertNotNil(value.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                                    "\(language): \(key): \(token)")
                }
            }
        }
    }

    func testNativeFinderServiceUsesCatalogLabelsWithoutChangingItsRoute() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LouppeServices-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = root.appendingPathComponent("Info.plist")
        let service: [String: Any] = [
            "NSMenuItem": ["default": "Open in Louppe"], "NSMessage": "openMediaFolder",
            "NSPortName": "Louppe", "NSSendFileTypes": ["public.folder"],
            "NSRequiredContext": ["NSApplicationIdentifier": "com.apple.finder"]
        ]
        try PropertyListSerialization.data(fromPropertyList: ["NSServices": [service]], format: .xml, options: 0).write(to: plist)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [repository.appendingPathComponent("Scripts/localize_services.sh").path,
                             plist.path, repository.appendingPathComponent("Sources/Louppe/Resources").path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let result = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        let services = try XCTUnwrap(result["NSServices"] as? [[String: Any]])
        let localized = try XCTUnwrap(services.first)
        let labels = try XCTUnwrap(localized["NSMenuItem"] as? [String: String])
        for language in L10n.supportedLanguages {
            XCTAssertEqual(labels[language == "en" ? "default" : language], L10n.render("Open in Louppe", language: language))
        }
        for key in ["NSMessage", "NSPortName", "NSSendFileTypes", "NSRequiredContext"] {
            XCTAssertEqual(localized[key] as? NSObject, service[key] as? NSObject, key)
        }
    }

    func testEachRequestedLanguageLoadsItsOwnBundledText() {
        let expected = ["es": "Copiar", "zh-Hans": "复制", "hi": "कॉपी करें", "pt": "Copiar", "ar": "نسخ"]
        for (language, copy) in expected {
            XCTAssertEqual(L10n.render("Copy", language: language), copy)
        }
    }

    func testInterpolationDoesNotTranslateOrReinterpretFilenames() {
        let filename = "No {1} — ملف.JPG"
        let size = "12 MB"
        let message: L10n.Message = "\(filename) (about \(size)) will be moved to the Trash. The matching \("RAW") files will stay in the folder."
        for language in L10n.supportedLanguages {
            let rendered = L10n.render(message, language: language)
            XCTAssertTrue(rendered.contains(filename), language)
            XCTAssertTrue(rendered.contains(size), language)
            XCTAssertTrue(rendered.contains("RAW"), language)
            XCTAssertFalse(rendered.contains("{0}"), language)
        }
    }

    func testEnglishFallbackForUnknownLanguageAndMissingKey() {
        let message: L10n.Message = "New untranslated warning for \("{0}.JPG")"
        XCTAssertEqual(L10n.render(message, language: "fr"), "New untranslated warning for {0}.JPG")
        XCTAssertEqual(L10n.render(message, language: "ar"), "New untranslated warning for {0}.JPG")
    }

    func testStoredMetadataAndFilenameRecipeWordsStayEnglish() {
        XCTAssertEqual(PhotoColorLabel.red.displayName, "Red")
        XCTAssertEqual(PhotoColorLabel.purple.rawValue, "purple")
        XCTAssertEqual(MediaKind.photo.label, "Photos")
        XCTAssertEqual(SessionConstants.sidecarName, ".louppe_session.json")
        XCTAssertEqual(Rating.yes.rawValue, "yes")
    }

    @MainActor
    func testFolderAndVideoFilterIdentitiesStayStable() {
        let store = SessionStore(automaticallyRecoversInterruptedOperations: false)
        store.items = [PhotoItem(primaryFile: PhotoFile(
            id: "root.JPG", url: URL(fileURLWithPath: "/tmp/root.JPG"),
            captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1,
            rating: .undecided
        ))]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        XCTAssertEqual(store.availableSubfolders, ["None"])
        XCTAssertEqual(store.subfolderCounts["None"], 1)
        XCTAssertEqual(store.availableCameras, ["Unknown"])
        XCTAssertEqual(store.availableLenses, ["Unknown"])
        store.filter.excludedSubfolders = ["None"]
        XCTAssertTrue(store.visibleIndices.isEmpty)
    }

    @MainActor
    func testArabicMirrorsLeadingLayoutAndKeepsShortcutOrder() throws {
        let english = measuredLayout(language: "en")
        let arabic = measuredLayout(language: "ar")
        XCTAssertLessThan(english.first, english.second)
        XCTAssertGreaterThan(arabic.first, arabic.second)
        XCTAssertEqual(arabic.shortcutDirection, .leftToRight)
        XCTAssertEqual(english.shortcutDirection, .leftToRight)
    }

    @MainActor
    func testLocalizedPresentationFixtures() throws {
        guard let directory = ProcessInfo.processInfo.environment["LOUPPE_LOCALIZATION_SNAPSHOTS"] else { return }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("LouppeLocalizedUI-\(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let suite = "LouppeLocalizedUI.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let photo = fixture.appendingPathComponent("Example {1}.JPG")
        let context = try XCTUnwrap(CGContext(data: nil, width: 240, height: 160, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Example", kCGImagePropertyTIFFModel: "QA Camera"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifExposureTime: 0.008,
                                           kCGImagePropertyExifISOSpeedRatings: [400], kCGImagePropertyExifFocalLength: 50,
                                           kCGImagePropertyExifDateTimeOriginal: "2026:10:14 10:00:00"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let store = SessionStore(automaticallyRecoversInterruptedOperations: false)
        store.items = [PhotoItem(primaryFile: PhotoFile(
            id: "Example {1}.JPG", url: photo,
            captureDate: nil, cameraModel: "Example Camera", lensModel: "50 mm", fileSize: 12000000,
            rating: .yes
        ))]
        store.phase = .ready
        store.rebuildDerivedDataForTesting()
        #if APP_STORE
        let settings = AnyView(LouppeSettingsView(store: store))
        #else
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let settings = AnyView(LouppeSettingsView(store: store, updater: updater.updater))
        #endif
        let scenes: [(String, AnyView, CGSize)] = [
            ("settings", settings, CGSize(width: 520, height: 600)),
            ("palette", AnyView(ActionPaletteView(store: store)), CGSize(width: 560, height: 480)),
            ("export", AnyView(ExportView(store: store)), CGSize(width: 640, height: 620)),
            ("filter", AnyView(FilterView(store: store)), CGSize(width: 340, height: 560)),
            ("info", AnyView(MetadataPanel(store: store, item: store.items[0])), CGSize(width: 300, height: 650)),
            ("help", AnyView(LouppeHelpView()), CGSize(width: 640, height: 600)),
            ("zoom", AnyView(PhotoZoomControl(store: store)), CGSize(width: 500, height: 80))
        ]
        for (name, view, size) in scenes {
            let host = NSHostingView(rootView: view.localizedInterface().defaultAppStorage(defaults).preferredColorScheme(.dark))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            // A native fixture window, with no production application identity.
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            defer { window.close() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            XCTAssertGreaterThan(host.bounds.width, 0, name)
            XCTAssertLessThanOrEqual(host.bounds.width, size.width + 1, name)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let destination = URL(fileURLWithPath: directory).appendingPathComponent(L10n.language)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try png.write(to: destination.appendingPathComponent(name + ".png"))
        }
    }

    // These contracts run again in isolated processes for every app language.
    // Expected backup names match the pre-localization on-disk protocol.
    func testBackupAndLockKeepExistingIdentityAndRecoverRatings() async throws {
        let root = try localizationFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos")
        let backups = root.appendingPathComponent("Backups")
        let file = photos.appendingPathComponent("A.JPG")
        try Data("original".utf8).write(to: file)
        let identity = try SessionPersistence.SourceFolderIdentity.capture(at: photos)
        let volume = identity.volumeUUIDString.map { "uuid:\($0)" }
            ?? "legacy:\(identity.volumeRootPath):\(identity.systemNumber)"
        let input = "\(volume)|\(identity.fileNumber)|\(identity.birthTime.seconds)|\(identity.birthTime.nanoseconds)"
        let digest = SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let backup = backups.appendingPathComponent("folder-\(digest).json")
        let lock = FileManager.default.temporaryDirectory
            .appendingPathComponent("Louppe/SessionLocks/folder-\(digest).lock")
        defer { try? FileManager.default.removeItem(at: lock) }
        let persistence = SessionPersistence(backupDirectory: backups)
        let session = SessionFile(
            version: SessionConstants.currentSchemaVersion,
            sourcePath: photos.path,
            scannedAt: Date(),
            entries: [SessionEntry(
                filename: "A.JPG", pairedFilename: nil, rating: "yes", ratedAt: nil,
                fileIdentity: try FileOperationJournal.captureIdentity(at: file)
            )],
            fileIDEncoding: .percentEncodedFileSystemPath
        )
        let saved = await persistence.save(session, for: photos, sequence: 1)
        XCTAssertEqual(saved, .savedToSidecar)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        try FileManager.default.removeItem(at: SessionPersistence.sidecarURL(for: photos))
        let recovered = await SessionPersistence(backupDirectory: backups).read(for: photos)
        XCTAssertEqual(recovered.session?.entries.first?.rating, "yes")
        XCTAssertEqual(recovered.session?.entries.first?.filename, "A.JPG")
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    }

    func testExportGroupingRetainsXMPFamilyAndGeneratedPacket() async throws {
        let root = try localizationFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Photos/A.JPG")
        try Data("original".utf8).write(to: file)
        let photo = PhotoItem(primaryFile: PhotoFile(
            id: "A.JPG", url: file, captureDate: nil, cameraModel: nil,
            lensModel: nil, fileSize: 8,
            scannedIdentity: try FileOperationJournal.captureIdentity(at: file), rating: .yes
        ))
        let xmp = try await XMPExportPlanner.prepare(
            selected: [photo], familyContextItems: [photo], profile: .universal,
            visibleDecisionKeywords: false, allowExternalLabelReplacement: false
        )
        let family = try XCTUnwrap(xmp.families.first)
        XCTAssertNotNil(family.finalPacket)
        let destination = root.appendingPathComponent("Destination")
        let plan = try ExportWorker.makePlan(for: [photo], in: destination, xmpPlan: xmp)
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items.first?.itemID, "xmp:\(family.id)")
        XCTAssertEqual(Set(plan.items.flatMap(\.files).map { $0.target.lastPathComponent }), ["A.JPG", "A.xmp"])
        let ordinary = try ExportWorker.makePlan(for: [photo], in: destination)
        XCTAssertEqual(ordinary.items.first?.itemID, "item:A.JPG")
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    }

    func testUndoJournalIdentityAndOriginalBytesRemainStable() throws {
        let root = try localizationFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos")
        let file = photos.appendingPathComponent("A.JPG")
        try Data("original".utf8).write(to: file)
        let photo = PhotoItem(primaryFile: PhotoFile(
            id: "A.JPG", url: file, captureDate: nil, cameraModel: nil,
            lensModel: nil, fileSize: 8,
            scannedIdentity: try FileOperationJournal.captureIdentity(at: file), rating: .yes
        ))
        let plan = try SourceOrganizationPlanner.makePlan(
            sourceFolder: photos, selectedItems: [photo], familyContextItems: [photo],
            configuration: FileRenamingPlanner.sourceConfiguration(customBaseName: "Renamed"),
            knownOriginFolderPathBytesByFileID: [:]
        )
        XCTAssertTrue(plan.canExecute)
        let journals = root.appendingPathComponent("Journals")
        let result = SourceOrganizationWorker.organize(plan, journalDirectory: journals) { _, _ in }
        XCTAssertEqual(result.movedFiles, 1, result.failureMessage ?? "")
        let undo = try XCTUnwrap(result.undoRecord)
        XCTAssertEqual(undo.reversePlan.items.first?.itemID, "undo:\(try XCTUnwrap(plan.workerPlan.items.first?.itemID))")
        let restored = SourceOrganizationWorker.undo(undo, currentItems: [], journalDirectory: journals) { _, _ in }
        XCTAssertEqual(restored.movedFiles, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    }

    private func localizationFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LouppeLocalization-\(UUID().uuidString)")
        for name in ["Photos", "Destination"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name), withIntermediateDirectories: true
            )
        }
        return root
    }

    private func catalog(_ language: String) throws -> [String: String] {
        let path = try XCTUnwrap(L10n.resourceBundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: String])
    }

    @MainActor
    private func measuredLayout(language: String) -> (first: CGFloat, second: CGFloat, shortcutDirection: LayoutDirection) {
        let first = NSView(frame: .zero)
        let second = NSView(frame: .zero)
        var direction: LayoutDirection = .rightToLeft
        let content = HStack(spacing: 20) {
            LayoutProbe(view: first).frame(width: 40, height: 20)
            LayoutProbe(view: second).frame(width: 40, height: 20)
            DirectionProbe { direction = $0 }
                .environment(\.layoutDirection, .leftToRight)
                .frame(width: 40, height: 20)
        }.localizedInterface(language: language)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        host.layoutSubtreeIfNeeded()
        return (first.convert(first.bounds, to: host).midX, second.convert(second.bounds, to: host).midX, direction)
    }
}

private struct LayoutProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct DirectionProbe: NSViewRepresentable {
    @Environment(\.layoutDirection) private var direction
    let record: (LayoutDirection) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { record(direction) }
}
