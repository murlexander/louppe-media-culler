import Foundation
import XCTest
@testable import Louppe

/// The printable-ASCII search path must give the general matcher's exact
/// answer for every folded or unfolded text and query.
final class SearchMatchEquivalenceTests: XCTestCase {
    func testASCIIFastPathMatchesGeneralMatcherOnCorpus() {
        let corpus = searchCorpus()
        let texts = corpus.flatMap { [$0, PhotoItem.normalizeForSearch($0)] }
        var queries = corpus + [
            "", " ", "   \t ", "a", "A", "img", "IMG 2023", "dsc_", "_0", ".jpg", "jpeg raw",
            "cafe", "CAFÉ", "café", "naïve", "ss", "straße", "e", "é", "e\u{301}", "東京", "東",
            "фото", "😀", "~", "!", "a b c", "1 2", "2023.07", "(1)", "[raw]", "x\u{7F}", "\u{7F}",
            "tab\there", "nbsp\u{00A0}x", "line\r\nbreak", "z", "Zz", "-", "+", "photos", "videos",
        ]
        var random = EquivalenceRandom(seed: 0xA5)
        for _ in 0..<600 {
            let source = texts[Int(random.next() % UInt64(texts.count))]
            let characters = Array(source)
            guard !characters.isEmpty else { continue }
            let start = Int(random.next() % UInt64(characters.count))
            let length = 1 + Int(random.next() % 6)
            queries.append(String(characters[start..<min(characters.count, start + length)]))
        }
        queries += (0..<400).map { _ in randomASCII(random: &random, length: 1 + Int(random.next() % 7)) }
        for _ in 0..<300 {
            let a = queries[Int(random.next() % UInt64(queries.count))]
            let b = queries[Int(random.next() % UInt64(queries.count))]
            queries.append("\(a) \(b)")
        }

        var fastPathUses = 0
        for query in queries {
            var filter = PhotoFilter()
            filter.searchText = query
            let prepared = PreparedPhotoFilter(filter)
            if PreparedPhotoFilter.printableASCIIBytes(of: prepared.searchTokens) != nil { fastPathUses += 1 }
            for text in texts {
                XCTAssertEqual(prepared.matchesSearch(text), referenceSearch(text, prepared.searchTokens),
                               "query \(query.debugDescription) text \(text.debugDescription)")
            }
        }
        XCTAssertGreaterThan(fastPathUses, queries.count / 3, "the corpus must exercise the fast path")
    }

    func testASCIIFastPathMatchesGeneralMatcherOnRandomStrings() {
        var random = EquivalenceRandom(seed: 0x5EA7C)
        let alphabet: [Character] = Array("abcxyzABC019 _-.,~!") + ["é", "e\u{301}", "ß", "ø", "東", "😀", "\u{7F}", "\t", "\u{00A0}"]
        func randomText(length: Int, asciiOnly: Bool) -> String {
            String((0..<length).map { _ in
                let pool = asciiOnly ? 19 : alphabet.count
                return alphabet[Int(random.next() % UInt64(pool))]
            })
        }
        for round in 0..<3000 {
            let text = PhotoItem.normalizeForSearch(randomText(length: Int(random.next() % 40),
                                                              asciiOnly: round % 3 != 0))
            var filter = PhotoFilter()
            filter.searchText = randomText(length: Int(random.next() % 6), asciiOnly: round % 4 != 1)
                + " " + randomText(length: Int(random.next() % 4), asciiOnly: true)
            let prepared = PreparedPhotoFilter(filter)
            XCTAssertEqual(prepared.matchesSearch(text), referenceSearch(text, prepared.searchTokens),
                           "query \(filter.searchText.debugDescription) text \(text.debugDescription)")
        }
    }

    /// The general matcher exactly as it was written before the fast path.
    private func referenceSearch(_ text: String, _ tokens: [Substring]) -> Bool {
        for token in tokens where !text.contains(token) {
            return false
        }
        return true
    }

    private func searchCorpus() -> [String] {
        [
            "DSC_0001.JPG JPEG Photos Trip 1 Camera 3 Lens 2 2023.07.11",
            "IMG_1234.HEIC HEIF Photos", "Café au lait.jpg", "naïve résumé", "Straße", "STRASSE",
            "東京タワー.JPG", "фото_001.jpg", "😀 party.mov MOV Videos", "e\u{301}clair.jpg", "éclair.jpg",
            "a-b_c (1) [raw].NEF RAW + JPEG", "tab\there", "nbsp\u{00A0}x", "line\r\nbreak", "x\u{7F}y",
            "Ø ø Å å Æ", "İstanbul ıi", "ǅ ǆ", "ﬁle ﬂow", "½ ⅓", "Ⅻ", "x²", "zero\u{200B}width",
            "", " ", "~!@#$%^&*()_+{}|:\"<>?", "UPPER lower MiXeD", "2023.07.11 2024.01.01",
        ]
    }

    private func randomASCII(random: inout EquivalenceRandom, length: Int) -> String {
        String((0..<length).map { _ in Character(Unicode.Scalar(UInt8(0x20 + random.next() % 0x5F))) })
    }
}
