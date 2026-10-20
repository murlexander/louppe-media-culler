import Foundation
import XCTest
@testable import Louppe

final class FileRenamingTests: XCTestCase {
    func testDatePartUsesMacShortDateStyleAndSafeSeparators() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        let expected = formatter.string(from: date)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[/\s\p{Cc}\p{Cf}:]+"#,
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let generated = try baseName(parts: [.captureDate], date: date)

        XCTAssertEqual(generated, expected)
        XCTAssertFalse(generated.contains("/"))
        XCTAssertFalse(generated.contains(":"))
    }

    func testPreferredDatePunctuationAndOrderSurviveFilenameSanitizing() {
        let examples = [
            ("2026.10.20", "2026.10.20"),
            ("20.10.2026", "20.10.2026"),
            ("20/10/2026", "20-10-2026"),
            ("10/20/26", "10-20-26"),
            ("20 Oct 2026", "20-Oct-2026"),
            ("2026年10月20日", "2026年10月20日"),
            ("٢٠‏/١٠‏/٢٠٢٦", "٢٠-١٠-٢٠٢٦"),
            (" 20 : / 10\n2026 ", "20-10-2026"),
        ]
        for (date, expected) in examples {
            XCTAssertEqual(
                FileRenamingPlanner.safeGeneratedPart(date), expected, date
            )
        }
    }

    func testDateChangeKeepsMissingMetadataAndCaptureTimeBehavior() throws {
        XCTAssertEqual(
            try baseName(parts: [.captureDate, .captureTime], date: nil),
            "Unknown-Date_Unknown-Time"
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 20, hour: 14, minute: 32, second: 17
        )))
        XCTAssertEqual(
            try baseName(parts: [.captureTime], date: date), "14-32-17"
        )
    }

    func testMovingPartsInEitherDirectionPreservesFlagsAndRelativeOrder() {
        var configuration = FileRenamingConfiguration.initial
        let original = configuration.parts

        XCTAssertTrue(configuration.movePart(.captureDate, to: .camera))
        XCTAssertEqual(configuration.parts.map(\.kind), [
            .captureTime, .camera, .captureDate, .lens, .originalName, .sequence,
        ])
        XCTAssertTrue(configuration.movePart(.captureDate, to: .captureTime))
        XCTAssertEqual(configuration.parts, original)

        // Disabled parts use the same ordering behavior without becoming enabled.
        XCTAssertTrue(configuration.movePart(.lens, offset: -1))
        XCTAssertEqual(configuration.parts.map(\.kind), [
            .captureDate, .captureTime, .lens, .camera, .originalName, .sequence,
        ])
        let enabledByKind = Dictionary(uniqueKeysWithValues: original.map {
            ($0.kind, $0.isEnabled)
        })
        XCTAssertTrue(configuration.parts.allSatisfy {
            $0.isEnabled == enabledByKind[$0.kind]
        })
    }

    func testInvalidMovesDoNotChangeConfiguration() {
        var configuration = FileRenamingConfiguration(parts: [
            FileRenamingPart(kind: .captureDate, isEnabled: true),
            FileRenamingPart(kind: .sequence, isEnabled: false),
        ])
        let original = configuration
        XCTAssertFalse(configuration.movePart(.captureDate, to: .captureDate))
        XCTAssertFalse(configuration.movePart(.captureDate, to: .lens))
        XCTAssertFalse(configuration.movePart(.lens, to: .captureDate))
        XCTAssertFalse(configuration.movePart(.captureDate, offset: -1))
        XCTAssertFalse(configuration.movePart(.sequence, offset: 1))
        XCTAssertFalse(configuration.movePart(.sequence, offset: Int.max))
        XCTAssertFalse(configuration.movePart(.lens, offset: 1))
        XCTAssertEqual(configuration, original)
    }

    func testReorderingChangesOnlyEnabledFilenamePartsOrder() throws {
        var configuration = FileRenamingConfiguration(parts: [
            FileRenamingPart(kind: .camera, isEnabled: true),
            FileRenamingPart(kind: .lens, isEnabled: false),
            FileRenamingPart(kind: .originalName, isEnabled: true),
            FileRenamingPart(kind: .sequence, isEnabled: true),
        ])
        XCTAssertTrue(configuration.movePart(.sequence, to: .camera))
        let generated = try FileRenamingPlanner.baseName(
            for: item(date: nil),
            naming: .metadata(configuration),
            sequence: 7,
            sequenceWidth: 3
        )
        XCTAssertEqual(generated, "007_FUJIFILM-X-T4_XT40001")
        XCTAssertEqual(configuration.enabledParts.map(\.kind), [
            .sequence, .camera, .originalName,
        ])
        XCTAssertEqual(
            FileRenamingPlanner.filenameComponent(
                baseName: try XCTUnwrap(generated),
                preservingExtensionOf: Data("XT40001.JpG".utf8)
            ),
            Data("007_FUJIFILM-X-T4_XT40001.JpG".utf8)
        )
    }

    private func baseName(
        parts: [FileRenamingPartKind], date: Date?
    ) throws -> String {
        try XCTUnwrap(FileRenamingPlanner.baseName(
            for: item(date: date),
            naming: .metadata(FileRenamingConfiguration(parts: parts.map {
                FileRenamingPart(kind: $0, isEnabled: true)
            })),
            sequence: 7,
            sequenceWidth: 3
        ))
    }

    private func item(date: Date?) -> PhotoItem {
        PhotoItem(
            id: "XT40001.JpG",
            primaryURL: URL(fileURLWithPath: "/tmp/XT40001.JpG"),
            pairedURL: nil,
            captureDate: date,
            cameraModel: "FUJIFILM X-T4",
            lensModel: "XF23mmF2 R WR",
            mediaKind: .photo,
            fileSize: 5,
            rating: .undecided
        )
    }
}
