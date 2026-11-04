import Foundation
import XCTest
@testable import Louppe

final class XMPSecurityTests: XCTestCase {
    private let metadata = XMPPublicationMetadata(
        decision: .yes, stars: .three, colorLabel: .purple, profile: .universal
    )

    private func packet(_ contents: String) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:t="https://example.invalid/test/">
        \(contents)
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
    }

    func testDeepPacketsFailWithoutCrashingAndNextPacketStillWorks() throws {
        let xml = packet(String(repeating: "<t:n>", count: 100_000)
            + String(repeating: "</t:n>", count: 100_000))
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
            let data = try XCTUnwrap(xml.data(using: encoding))
            XCTAssertThrowsError(try XMPFieldMapping.merge(packet: data, metadata: metadata)) { error in
                XCTAssertTrue(error.localizedDescription.contains("too complex"), "\(error)")
            }
            let valid = try XMPFieldMapping.merge(packet: nil, metadata: metadata)
            try XMPFieldMapping.verify(packet: valid, metadata: metadata)
        }
    }

    func testWideTreeAndExcessiveAttributesAreBounded() {
        for body in [
            "<t:list><rdf:Bag>" + String(repeating: "<rdf:li>x</rdf:li>", count: 130_000) + "</rdf:Bag></t:list>",
            "<t:value " + (0..<1025).map { "t:a\($0)=\"x\"" }.joined(separator: " ") + "/>"
        ] {
            XCTAssertThrowsError(try XMPFieldMapping.merge(packet: Data(packet(body).utf8), metadata: metadata)) { error in
                XCTAssertTrue(error.localizedDescription.contains("too complex"), "\(error)")
            }
        }
    }

    func testNormalUnicodeAndLargeKeywordListsRemainReadable() throws {
        let body = "<t:list><rdf:Bag>" + (0..<5000).map {
            "<rdf:li>Photo \($0) — København 📷 &amp; family</rdf:li>"
        }.joined() + "</rdf:Bag></t:list>"
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
            let data = try XCTUnwrap(packet(body).data(using: encoding))
            let merged = try XMPFieldMapping.merge(packet: data, metadata: metadata)
            try XMPFieldMapping.verify(packet: merged, metadata: metadata)
            XCTAssertTrue(String(decoding: merged, as: UTF8.self).contains("København"))
        }
    }

    func testDoctypeAndMalformedUTF16FailWithoutPoisoningParser() throws {
        let hostile = "<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]>" + packet("<t:value>&secret;</t:value>")
        for encoding in [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian] {
            XCTAssertThrowsError(try XMPFieldMapping.merge(packet: hostile.data(using: encoding), metadata: metadata))
        }
        var malformed = Data([0xff, 0xfe])
        malformed.append(packet("<t:value>ok</t:value>").data(using: .utf16LittleEndian)!)
        malformed.append(0x00)
        XCTAssertThrowsError(try XMPFieldMapping.merge(packet: malformed, metadata: metadata))
        try XMPFieldMapping.verify(packet: XMPFieldMapping.merge(packet: nil, metadata: metadata), metadata: metadata)
    }

    private let testNamespace = "https://example.invalid/test/"
    private let encodings: [String.Encoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian]

    /// Every bridge entry point must reject while parsing, not later as a
    /// missing property or failed verification of a partially parsed tree.
    private func assertRejectedEverywhere(
        _ data: Data,
        _ label: String,
        message: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let attempts: [(String, () throws -> Void)] = [
            ("merge", { _ = try XMPFieldMapping.merge(packet: data, metadata: self.metadata) }),
            ("verify", { try XMPFieldMapping.verify(packet: data, metadata: self.metadata) }),
            ("read", {
                _ = try XMPFieldMapping.readProperty(namespace: self.testNamespace, path: "value", packet: data)
            }),
            ("inspect", { _ = try XMPFieldMapping.inspectExistingChanges(packet: data, metadata: self.metadata) }),
        ]
        for (entry, attempt) in attempts {
            XCTAssertThrowsError(try attempt(), "\(label): \(entry)", file: file, line: line) { error in
                guard case .invalidPacket(let text) = error as? XMPFieldMappingError else {
                    return XCTFail("\(label): \(entry) must fail while parsing: \(error)", file: file, line: line)
                }
                if let message {
                    XCTAssertTrue(text.contains(message), "\(label): \(entry): \(text)", file: file, line: line)
                }
            }
        }
    }

    private func assertParserStillWorks(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(
            try XMPFieldMapping.verify(
                packet: XMPFieldMapping.merge(packet: nil, metadata: metadata), metadata: metadata
            ),
            file: file, line: line
        )
    }

    /// Joins template pieces split at `@@` around raw bytes.
    private func packetData(_ template: String, inserting bytes: [UInt8]) -> Data {
        var data = Data()
        for (index, part) in template.components(separatedBy: "@@").enumerated() {
            if index > 0 { data.append(contentsOf: bytes) }
            data.append(Data(part.utf8))
        }
        return data
    }

    func testEntityExpansionAndExternalDocumentTypesFailAtEveryEntryPoint() throws {
        var laughs = "<!DOCTYPE x [<!ENTITY lol0 \"lol\">"
        for level in 1...9 {
            laughs += "<!ENTITY lol\(level) \"" + String(repeating: "&lol\(level - 1);", count: 10) + "\">"
        }
        laughs += "]>"
        let cases = [
            ("billion laughs", laughs + packet("<t:value>&lol9;</t:value>")),
            ("parameter entities",
             "<!DOCTYPE x [<!ENTITY % pe \"<!ENTITY inner 'x'>\"> %pe;]>" + packet("<t:value>&inner;</t:value>")),
            ("external DTD", "<!DOCTYPE x SYSTEM \"file:///etc/passwd\">" + packet("<t:value>ok</t:value>")),
            ("public DTD",
             "<!DOCTYPE x PUBLIC \"-//Louppe//Hostile//EN\" \"http://127.0.0.1:9/x.dtd\">"
                + packet("<t:value>ok</t:value>")),
            ("undeclared text entity", packet("<t:value>&undeclared;</t:value>")),
            ("undeclared attribute entity", packet("<t:value t:a=\"&undeclared;\"/>")),
        ]
        for (label, xml) in cases {
            for encoding in encodings {
                assertRejectedEverywhere(try XCTUnwrap(xml.data(using: encoding)), "\(label) \(encoding)")
            }
        }
        assertParserStillWorks()
    }

    /// XMPCore deliberately repairs invalid 8-bit input as Latin-1/CP1252 and
    /// replaces raw ASCII controls with spaces. Output must stay valid UTF-8.
    func testMalformedUTF8IsRepairedOrRejectedButNeverEmittedRaw() throws {
        let sequences: [[UInt8]] = [
            [0xFF], [0x80], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xE2, 0x82],
            [0xF4, 0x90, 0x80, 0x80], [0xF8, 0x88, 0x80, 0x80, 0x80], [0x00], [0x01], [0x7F],
        ]
        let templates = [
            ("text", packet("<t:value>A@@B</t:value>")),
            ("attribute", packet("<t:value t:a=\"A@@B\"/>")),
            ("name", packet("<t:va@@lue>AB</t:va@@lue>")),
        ]
        for (position, template) in templates {
            for bytes in sequences {
                let label = "\(bytes) in \(position)"
                do {
                    let merged = try XMPFieldMapping.merge(
                        packet: packetData(template, inserting: bytes), metadata: metadata
                    )
                    let text = try XCTUnwrap(String(data: merged, encoding: .utf8), "\(label): invalid UTF-8 output")
                    XCTAssertFalse(text.unicodeScalars.contains {
                        $0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r"
                    }, label)
                    try XMPFieldMapping.verify(packet: merged, metadata: metadata)
                } catch let error as XMPFieldMappingError {
                    guard case .invalidPacket = error else { return XCTFail("\(label): \(error)") }
                }
            }
        }
        assertParserStillWorks()
    }

    func testOversizedInputAndAmplifiedRepairAreBounded() throws {
        var oversized = Data(packet("<t:value>").utf8)
        oversized.append(Data(repeating: 0x41, count: XMPFieldMapping.maximumPacketBytes))
        assertRejectedEverywhere(oversized, "input above 64 MiB", message: "64 MiB")

        // Each 0x80 byte is repaired to a three-byte UTF-8 euro sign: 24 MiB
        // of input decodes to 72 MiB, above the 64 MiB decoded-text budget.
        let amplified = packetData(
            packet("<t:value>@@</t:value>"), inserting: Array(repeating: 0x80, count: 24 * 1024 * 1024)
        )
        assertRejectedEverywhere(amplified, "amplified Latin-1 repair", message: "too complex")

        let largeValue = String(repeating: "v", count: 4 * 1024 * 1024)
        let large = Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:t="\(testNamespace)" t:value="\(largeValue)"/></rdf:RDF></x:xmpmeta>
        """.utf8)
        let merged = try XMPFieldMapping.merge(packet: large, metadata: metadata)
        XCTAssertEqual(
            try XMPFieldMapping.readProperty(namespace: testNamespace, path: "value", packet: merged), largeValue
        )
        assertParserStillWorks()
    }

    func testNamespaceDeclarationsAndURIsAreBounded() throws {
        // The wrapper declares x, rdf and t. Reusing one URI keeps this test
        // from consuming the process-wide registration budget.
        func declarations(_ count: Int) -> String {
            (0..<count).map { "xmlns:n\($0)=\"urn:louppe-test:shared\"" }.joined(separator: " ")
        }
        XCTAssertNoThrow(try XMPFieldMapping.merge(
            packet: Data(packet("<t:value \(declarations(1021))>ok</t:value>").utf8), metadata: metadata
        ))
        assertRejectedEverywhere(
            Data(packet("<t:value \(declarations(1022))>ok</t:value>").utf8),
            "1,025 declarations", message: "too complex"
        )

        func uri(_ length: Int) -> String {
            let stem = "urn:louppe-test:long:"
            return stem + String(repeating: "u", count: length - stem.utf8.count)
        }
        XCTAssertNoThrow(try XMPFieldMapping.merge(
            packet: Data(packet("<t:value xmlns:l=\"\(uri(1024))\">ok</t:value>").utf8), metadata: metadata
        ))
        for encoding in encodings {
            assertRejectedEverywhere(
                try XCTUnwrap(packet("<t:value xmlns:l=\"\(uri(1025))\">ok</t:value>").data(using: encoding)),
                "1,025-byte namespace URI \(encoding)", message: "too complex"
            )
        }

        // XMPCore retains each new prefix too. Fixed URIs keep reruns from
        // consuming the process budget; rejected names are never reserved.
        func prefix(_ length: Int) -> String { "p" + String(repeating: "x", count: length - 1) }
        XCTAssertNoThrow(try XMPFieldMapping.merge(
            packet: Data(packet("<t:value xmlns:\(prefix(64))=\"urn:louppe-test:prefix-cap\">ok</t:value>").utf8),
            metadata: metadata
        ))
        for (label, length) in [("65-byte", 65), ("2 MiB", 2 * 1024 * 1024)] {
            for encoding in encodings {
                let xml = packet("<t:value xmlns:\(prefix(length))=\"urn:louppe-test:prefix-\(length)\">ok</t:value>")
                assertRejectedEverywhere(
                    try XCTUnwrap(xml.data(using: encoding)),
                    "\(label) namespace prefix \(encoding)", message: "too complex"
                )
            }
        }
        assertParserStillWorks()
    }

    /// XMPCore keeps parsed namespaces for the life of the process. The budget
    /// is process-wide, so these exhaust it in child test processes.
    func testParsedNamespaceRegistrationCountIsBoundedForTheProcess() throws {
        if let mode = ProcessInfo.processInfo.environment[Self.registryChildFlag] {
            return mode == "count" ? try exhaustNamespaceRegistry(byBytes: false) : ()
        }
        try runRegistryChild(mode: "count", test: "testParsedNamespaceRegistrationCountIsBoundedForTheProcess")
    }

    func testParsedNamespaceRetainedBytesAreBoundedForTheProcess() throws {
        if let mode = ProcessInfo.processInfo.environment[Self.registryChildFlag] {
            return mode == "bytes" ? try exhaustNamespaceRegistry(byBytes: true) : ()
        }
        try runRegistryChild(mode: "bytes", test: "testParsedNamespaceRetainedBytesAreBoundedForTheProcess")
    }

    private static let registryChildFlag = "LOUPPE_XMP_NAMESPACE_REGISTRY_CHILD"

    private func runRegistryChild(mode: String, test: String) throws {
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("louppe-xmp-registry-\(UUID().uuidString).log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: log) }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "LouppeTests.XMPSecurityTests/\(test)", Bundle(for: Self.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("XCTest") }
        environment[Self.registryChildFlag] = mode
        child.environment = environment
        child.standardOutput = output
        child.standardError = output
        try child.run()
        let deadline = Date().addingTimeInterval(300)
        while child.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if child.isRunning { child.terminate() }
        child.waitUntilExit()
        let transcript = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertEqual(child.terminationStatus, 0, transcript)
        XCTAssertTrue(transcript.contains("Executed 1 test, with 0 failures"), transcript)
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/XMP/\(name)"))
    }

    private func exhaustNamespaceRegistry(byBytes: Bool) throws {
        let capacityMessage = "Quit and reopen Louppe"
        let baseline = Data(packet("<t:value>ok</t:value>").utf8)
        _ = try XMPFieldMapping.merge(packet: baseline, metadata: metadata)
        // A vendor namespace first read before exhaustion stays readable.
        _ = try XMPFieldMapping.inspectExistingChanges(packet: fixture("darktable.xmp"), metadata: metadata)

        // Count: 512 short names per packet. Bytes: 256 names of 1,000-byte
        // URIs and 64-byte prefixes, about 1,080 retained bytes each.
        let perRound = byBytes ? 256 : 512
        func uri(_ round: Int, _ index: Int) -> String {
            let stem = "urn:louppe-registry:\(round):\(index):"
            return byBytes ? stem + String(repeating: "u", count: 1000 - stem.utf8.count) : stem
        }
        func fresh(_ round: Int) -> Data {
            let declarations = (0..<perRound).map { index in
                let prefix = byBytes ? "b\(index)" + String(repeating: "x", count: 62 - "\(index)".count) : "a\(index)"
                return "xmlns:\(prefix)=\"\(uri(round, index))\""
            }
            return Data(packet("<t:value \(declarations.joined(separator: " "))>ok</t:value>").utf8)
        }
        var acceptedRounds = 0
        for round in 0..<12 {
            do {
                _ = try XMPFieldMapping.merge(packet: fresh(round), metadata: metadata)
                acceptedRounds += 1
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(capacityMessage), "\(error)")
                break
            }
        }
        // Count: 4,096 registrations fit seven rounds plus the test and
        // darktable namespaces. Bytes: 1 MiB fits about 970 long names.
        XCTAssertEqual(acceptedRounds, byBytes ? 3 : 7)

        try XMPFieldMapping.verify(packet: XMPFieldMapping.merge(packet: baseline, metadata: metadata), metadata: metadata)
        XCTAssertNoThrow(try XMPFieldMapping.merge(
            packet: Data(packet("<t:value xmlns:q=\"\(uri(0, 0))\">ok</t:value>").utf8),
            metadata: metadata
        ))
        // Built-in Adobe namespaces and those already read remain available.
        for name in ["adobe-bridge.xmp", "lightroom-classic.xmp", "darktable.xmp"] {
            XCTAssertNoThrow(
                try XMPFieldMapping.inspectExistingChanges(packet: fixture(name), metadata: metadata), name
            )
        }
        if byBytes {
            // About 1.9 KB remain: another long name no longer fits, while a
            // short vendor namespace still does.
            assertRejectedEverywhere(
                Data(packet("<t:value xmlns:z=\"\(uri(99, 0))\">ok</t:value>").utf8),
                "long namespace after the byte budget", message: capacityMessage
            )
            XCTAssertNoThrow(try XMPFieldMapping.inspectExistingChanges(
                packet: fixture("capture-one.xmp"), metadata: metadata
            ))
        } else {
            // Capture One's namespace was never read in this process.
            assertRejectedEverywhere(
                try fixture("capture-one.xmp"), "unread vendor namespace after the budget", message: capacityMessage
            )
            assertRejectedEverywhere(
                Data(packet("<t:value xmlns:z=\"urn:louppe-registry:after\">ok</t:value>").utf8),
                "new namespace after the budget", message: capacityMessage
            )
        }
        // Individually malformed packets keep the ordinary message.
        assertRejectedEverywhere(
            Data(packet("<t:value xmlns:\(String(repeating: "p", count: 65))=\"\(uri(0, 0))\">ok</t:value>").utf8),
            "oversized prefix after the budget", message: "too complex"
        )
    }
}
