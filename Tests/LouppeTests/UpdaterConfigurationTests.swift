import CryptoKit
import Foundation
import XCTest
@testable import Louppe

final class UpdaterConfigurationTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testPublishedFeedVerifiesWithPackagedPublicKey() throws {
        let script = try String(contentsOf: root.appendingPathComponent("build_app.sh"), encoding: .utf8)
        let start = try XCTUnwrap(script.range(of: "    <key>SUFeedURL</key>"))
        let end = try XCTUnwrap(script.range(of: "\nPLIST", range: start.lowerBound..<script.endIndex))
        let xml = "<plist version=\"1.0\"><dict>" + script[start.lowerBound..<end.lowerBound] + "</dict></plist>"
        let settings = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(xml.utf8), format: nil) as? [String: Any])
        let publicKey = try XCTUnwrap(settings["SUPublicEDKey"] as? String)
        let docs = try String(contentsOf: root.appendingPathComponent("Docs/UPDATES.md"), encoding: .utf8)
        XCTAssertTrue(docs.contains("```text\n\(publicKey)\n```"), "Release instructions must preserve the packaged trust key")
        XCTAssertEqual(settings["SUFeedURL"] as? String,
                       "https://raw.githubusercontent.com/murlexander/louppe-media-culler/main/appcast.xml")
        for key in ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUVerifyUpdateBeforeExtraction", "SURequireSignedFeed"] {
            XCTAssertEqual(settings[key] as? Bool, true, key)
        }
        XCTAssertEqual(settings["SUScheduledCheckInterval"] as? Double, 86400)

        // Verify using only the public key; release-owner Keychain access is
        // unnecessary for a read-only check of the committed signed feed.
        let feed = try Data(contentsOf: root.appendingPathComponent("appcast.xml"))
        let text = try XCTUnwrap(String(data: feed, encoding: .utf8))
        let expression = try NSRegularExpression(pattern: #"<!-- sparkle-signatures:\nedSignature: (\S+)\nlength: ([0-9]+)\n-->"#)
        let match = try XCTUnwrap(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let signature = try XCTUnwrap(Data(base64Encoded: String(text[try XCTUnwrap(Range(match.range(at: 1), in: text))])))
        let length = try XCTUnwrap(Int(text[try XCTUnwrap(Range(match.range(at: 2), in: text))]))
        let marker = try XCTUnwrap(Range(match.range, in: text)).lowerBound
        XCTAssertEqual(length, text[..<marker].utf8.count, "The signature must cover all feed content")
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: publicKey)))
        XCTAssertTrue(key.isValidSignature(signature, for: feed.prefix(length)), "The committed feed was modified after signing")
    }
}
