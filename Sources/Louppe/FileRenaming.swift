import Foundation

enum FileRenamingPartKind: String, CaseIterable, Hashable, Identifiable,
    Sendable {
    case captureDate
    case captureTime
    case camera
    case lens
    case originalName
    case sequence

    var id: Self { self }

    var label: String {
        switch self {
        case .captureDate: return L10n.text("Date taken")
        case .captureTime: return L10n.text("Time taken")
        case .camera: return L10n.text("Camera")
        case .lens: return L10n.text("Lens")
        case .originalName: return L10n.text("Original name")
        case .sequence: return L10n.text("Sequence")
        }
    }
}

struct FileRenamingPart: Equatable, Hashable, Identifiable, Sendable {
    let kind: FileRenamingPartKind
    var isEnabled: Bool
    var id: FileRenamingPartKind { kind }
}

struct FileRenamingConfiguration: Equatable, Sendable {
    var parts: [FileRenamingPart]

    static var initial: Self {
        Self(parts: [
            FileRenamingPart(kind: .captureDate, isEnabled: true),
            FileRenamingPart(kind: .captureTime, isEnabled: true),
            FileRenamingPart(kind: .camera, isEnabled: false),
            FileRenamingPart(kind: .lens, isEnabled: false),
            FileRenamingPart(kind: .originalName, isEnabled: false),
            FileRenamingPart(kind: .sequence, isEnabled: true),
        ])
    }

    var enabledParts: [FileRenamingPart] {
        parts.filter(\.isEnabled)
    }
}

enum FileRenamingPresentationMode: Equatable, Sendable {
    case single(itemID: String)
    case metadata
}

enum FileRenamingPlanner {
    static func sourceConfiguration(
        customBaseName: String
    ) -> SourceOrganizationConfiguration {
        SourceOrganizationConfiguration(
            levels: [],
            dateGranularity: .day,
            existingFolderDepth: .topLevel,
            containerName: "",
            destinationMode: .keepExistingFolders,
            fileNaming: .customBaseName(customBaseName)
        )
    }

    static func sourceConfiguration(
        metadata: FileRenamingConfiguration
    ) -> SourceOrganizationConfiguration {
        SourceOrganizationConfiguration(
            levels: [],
            dateGranularity: .day,
            existingFolderDepth: .topLevel,
            containerName: "",
            destinationMode: .keepExistingFolders,
            fileNaming: .metadata(metadata)
        )
    }

    static func validationMessage(forCustomBaseName value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return L10n.text("Enter a filename.")
        }
        if trimmed == "." || trimmed == ".." {
            return L10n.text("That name is reserved by macOS.")
        }
        if trimmed.hasPrefix(".") {
            return L10n.text("A filename cannot begin with a dot because macOS would hide it.")
        }
        if trimmed.contains("/") || trimmed.contains(":")
            || trimmed.contains("\0") {
            return L10n.text("A filename cannot contain /, :, or a null character.")
        }
        if trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) {
            return L10n.text("A filename cannot contain control characters.")
        }
        if trimmed.utf8.count > 180 {
            return L10n.text("Keep the filename to 180 UTF-8 bytes or fewer.")
        }
        if trimmed == SessionConstants.sidecarName
            || trimmed.hasPrefix(".louppe-") {
            return L10n.text("Choose a name that is not reserved by Louppe.")
        }
        return nil
    }

    static func sequenceWidth(for count: Int) -> Int {
        max(3, String(max(count, 1)).count)
    }

    /// Sequence numbers are independent of the visible sort. Oldest capture
    /// first, then the byte-stable session ID, makes previews repeatable.
    static func sequenceByItemID(_ items: [PhotoItem]) -> [String: Int] {
        let ordered = items.sorted { lhs, rhs in
            switch (lhs.captureDate, rhs.captureDate) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.id < rhs.id
            }
        }
        return Dictionary(
            uniqueKeysWithValues: ordered.enumerated().map {
                ($0.element.id, $0.offset + 1)
            }
        )
    }

    static func baseName(
        for item: PhotoItem,
        naming: SourceFileNaming,
        sequence: Int,
        sequenceWidth: Int
    ) throws -> String? {
        switch naming {
        case .unchanged:
            return nil
        case .customBaseName(let value):
            if let reason = validationMessage(forCustomBaseName: value) {
                throw SourceOrganizationPlanner.PlannerError.invalidFileName(
                    reason
                )
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .metadata(let configuration):
            guard !configuration.enabledParts.isEmpty else {
                throw SourceOrganizationPlanner.PlannerError.noFilenameParts
            }
            let values = configuration.enabledParts.map { part in
                renderedPart(
                    part.kind,
                    for: item,
                    sequence: sequence,
                    sequenceWidth: sequenceWidth
                )
            }
            let generated = truncateFilenameBase(values.joined(separator: "_"))
            if generated.hasPrefix(".") {
                throw SourceOrganizationPlanner.PlannerError.invalidFileName(
                    L10n.text("The generated filename would begin with a dot and be hidden by macOS. Add another part before it.")
                )
            }
            return generated
        }
    }

    static func filenameComponent(
        baseName: String,
        preservingExtensionOf original: Data
    ) -> Data {
        let suffix = extensionBytes(of: original)
        return Data(baseName.utf8) + suffix
    }

    static func stemBytes(of filename: Data) -> Data {
        guard let dot = filename.lastIndex(of: UInt8(ascii: ".")),
              dot != filename.startIndex else { return filename }
        return filename[..<dot]
    }

    static func extensionBytes(of filename: Data) -> Data {
        guard let dot = filename.lastIndex(of: UInt8(ascii: ".")),
              dot != filename.startIndex else { return Data() }
        return filename[dot...]
    }

    private static func renderedPart(
        _ kind: FileRenamingPartKind,
        for item: PhotoItem,
        sequence: Int,
        sequenceWidth: Int
    ) -> String {
        switch kind {
        case .captureDate:
            guard let date = item.captureDate else { return "Unknown-Date" }
            let components = localDateComponents(date)
            return String(
                format: "%04d-%02d-%02d",
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            )
        case .captureTime:
            guard let date = item.captureDate else { return "Unknown-Time" }
            let components = localDateComponents(date)
            return String(
                format: "%02d-%02d-%02d",
                components.hour ?? 0,
                components.minute ?? 0,
                components.second ?? 0
            )
        case .camera:
            return safeGeneratedPart(item.cameraModel ?? "Unknown-Camera")
        case .lens:
            return safeGeneratedPart(item.lensModel ?? "Unknown-Lens")
        case .originalName:
            let original = (item.displayName as NSString)
                .deletingPathExtension
            return safeGeneratedPart(
                original.isEmpty ? "Unknown-Name" : original
            )
        case .sequence:
            return String(format: "%0*d", sequenceWidth, sequence)
        }
    }

    private static func localDateComponents(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
    }

    private static func safeGeneratedPart(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var output = ""
        var lastWasSeparator = false
        for scalar in trimmed.unicodeScalars {
            let shouldReplace = scalar == "/" || scalar == ":"
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
            if shouldReplace {
                if !lastWasSeparator && !output.isEmpty {
                    output.append("-")
                    lastWasSeparator = true
                }
            } else {
                output.unicodeScalars.append(scalar)
                lastWasSeparator = false
            }
        }
        while output.last == "-" { output.removeLast() }
        if output.isEmpty || output == "." || output == ".." {
            return "Unknown"
        }
        return output
    }

    private static func truncateFilenameBase(_ value: String) -> String {
        guard value.utf8.count > 180 else { return value }
        var result = ""
        var bytes = 0
        for character in value {
            let count = String(character).utf8.count
            guard bytes + count <= 180 else { break }
            result.append(character)
            bytes += count
        }
        return result.isEmpty ? "Unknown" : result
    }
}
