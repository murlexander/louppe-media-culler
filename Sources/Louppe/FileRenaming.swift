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

    /// Moves the complete part, including its enabled state. The destination
    /// is its original row index, so dropping downward places it after that row.
    @discardableResult
    mutating func movePart(
        _ kind: FileRenamingPartKind,
        to destination: FileRenamingPartKind
    ) -> Bool {
        guard let sourceIndex = parts.firstIndex(where: { $0.kind == kind }),
              let destinationIndex = parts.firstIndex(where: {
                  $0.kind == destination
              }), sourceIndex != destinationIndex else { return false }
        let part = parts.remove(at: sourceIndex)
        parts.insert(part, at: destinationIndex)
        return true
    }

    @discardableResult
    mutating func movePart(
        _ kind: FileRenamingPartKind,
        offset: Int
    ) -> Bool {
        guard let index = parts.firstIndex(where: { $0.kind == kind }) else {
            return false
        }
        let (destinationIndex, overflow) = index.addingReportingOverflow(offset)
        guard !overflow, parts.indices.contains(destinationIndex) else {
            return false
        }
        return movePart(kind, to: parts[destinationIndex].kind)
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

    /// Metadata names without the Sequence part number only the files whose
    /// generated names would clash. Custom names stay explicit and block.
    static func numbersConflictingNames(_ naming: SourceFileNaming) -> Bool {
        guard case .metadata(let configuration) = naming else { return false }
        return !configuration.enabledParts.contains { $0.kind == .sequence }
    }

    /// `base_001`: the planner's part separator and the Sequence padding.
    /// The base is shortened, never the number, to stay within 180 bytes.
    static func numberedBaseName(
        _ base: String,
        number: Int,
        width: Int
    ) -> String {
        let suffix = "_" + String(format: "%0*d", width, number)
        return truncateFilenameBase(
            base,
            limit: max(1, 180 - suffix.utf8.count)
        ) + suffix
    }

    /// One physical file considered for conflict numbering. Keys are stems
    /// compared as the destination volume compares filenames.
    struct ConflictNumberingFile: Sendable {
        /// Files of one unit keep one number: a RAW+JPEG pair, or files that
        /// already share a stem in one folder (one XMP family).
        let unit: Int
        let directory: XMPExactFileSystemPath
        let currentStemKey: String
        let generatedStemKey: String
        let generatedBaseName: String
    }

    struct ConflictNumber: Equatable, Sendable {
        let number: Int
        let width: Int
    }

    /// Numbers every unit whose generated stem is shared with another unit
    /// or with an untouched entry in the same folder. Units are numbered per
    /// conflicting stem in `unitOrder`, skipping numbers already present on
    /// disk; a unit already holding a free number of its group keeps it, so
    /// repeating a rename changes nothing. Unique names receive no number.
    static func conflictNumbers(
        files: [ConflictNumberingFile],
        unitOrder: [Int],
        stemKey: (String) -> String,
        entryStemKeys: (XMPExactFileSystemPath) -> [String]
    ) -> [Int: ConflictNumber] {
        struct StemKey: Hashable {
            let directory: XMPExactFileSystemPath
            let stem: String
        }
        let rankByUnit = Dictionary(
            unitOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        func rank(_ unit: Int) -> Int { rankByUnit[unit] ?? Int.max }
        func ordered(_ lhs: Int, _ rhs: Int) -> Bool {
            rank(lhs) != rank(rhs) ? rank(lhs) < rank(rhs) : lhs < rhs
        }

        // Units whose generated stems meet in one folder form one group.
        var groupParent: [Int: Int] = [:]
        func find(_ unit: Int) -> Int {
            var root = unit
            while let parent = groupParent[root], parent != root {
                root = parent
            }
            groupParent[unit] = root
            return root
        }
        var unitByGeneratedKey: [StemKey: Int] = [:]
        for file in files {
            if groupParent[file.unit] == nil {
                groupParent[file.unit] = file.unit
            }
            let key = StemKey(
                directory: file.directory, stem: file.generatedStemKey
            )
            if let other = unitByGeneratedKey[key] {
                let left = find(other)
                let right = find(file.unit)
                if left != right { groupParent[right] = left }
            } else {
                unitByGeneratedKey[key] = file.unit
            }
        }

        var groupUnits: [Int: Set<Int>] = [:]
        var groupKeys: [Int: Set<StemKey>] = [:]
        var filesByUnit: [Int: [ConflictNumberingFile]] = [:]
        var currentOwnerByKey: [StemKey: Int] = [:]
        for file in files {
            let group = find(file.unit)
            let generated = StemKey(
                directory: file.directory, stem: file.generatedStemKey
            )
            groupUnits[group, default: []].insert(file.unit)
            groupKeys[group, default: []].insert(generated)
            filesByUnit[file.unit, default: []].append(file)
            currentOwnerByKey[StemKey(
                directory: file.directory, stem: file.currentStemKey
            )] = file.unit
        }

        // `stem_<digits>` splits into its stem and number.
        func numbered(_ stem: String) -> (stem: String, number: Int)? {
            guard let separator = stem.lastIndex(of: "_") else { return nil }
            let digits = stem[stem.index(after: separator)...]
            guard !digits.isEmpty, digits.count <= 9,
                  digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(digits) else { return nil }
            return (String(stem[..<separator]), value)
        }

        struct DirectoryEntries {
            var stems = Set<String>()
            /// Numbers already used after each stem, with the entry's stem.
            var numbered: [String: [(entry: String, number: Int)]] = [:]
        }
        var entriesByDirectory: [XMPExactFileSystemPath: DirectoryEntries] = [:]
        func entries(_ directory: XMPExactFileSystemPath) -> DirectoryEntries {
            if let cached = entriesByDirectory[directory] { return cached }
            var listed = DirectoryEntries()
            for stem in entryStemKeys(directory) {
                listed.stems.insert(stem)
                if let parts = numbered(stem) {
                    listed.numbered[parts.stem, default: []]
                        .append((stem, parts.number))
                }
            }
            entriesByDirectory[directory] = listed
            return listed
        }

        // A stem conflicts with disk only through an entry that no unit of
        // its own group owns already (its current stem or XMP family).
        var numberedGroups: [Int] = []
        var plannedNumbers: [StemKey: Set<Int>] = [:]
        func plan(_ stem: String, in directory: XMPExactFileSystemPath) {
            guard let parts = numbered(stem) else { return }
            plannedNumbers[
                StemKey(directory: directory, stem: parts.stem), default: []
            ].insert(parts.number)
        }
        for (group, keys) in groupKeys {
            let units = groupUnits[group] ?? []
            let conflictsOnDisk = keys.contains { key in
                if let owner = currentOwnerByKey[key], units.contains(owner) {
                    return false
                }
                return entries(key.directory).stems.contains(key.stem)
            }
            if units.count > 1 || conflictsOnDisk {
                numberedGroups.append(group)
            } else {
                for key in keys { plan(key.stem, in: key.directory) }
            }
        }
        numberedGroups.sort { lhs, rhs in
            let left = groupUnits[lhs]?.min(by: ordered) ?? lhs
            let right = groupUnits[rhs]?.min(by: ordered) ?? rhs
            return ordered(left, right)
        }

        var result: [Int: ConflictNumber] = [:]
        for group in numberedGroups {
            let units = (groupUnits[group] ?? []).sorted(by: ordered)
            let groupFiles = units.flatMap { filesByUnit[$0] ?? [] }
            var width = sequenceWidth(for: units.count)
            var numberByUnit: [Int: Int] = [:]
            while true {
                // Numbering can shorten a long base. Reserve the names that
                // will actually be emitted, including names from other groups.
                let numberedKeys = Set(groupFiles.compactMap { file -> StemKey? in
                    let rendered = stemKey(numberedBaseName(
                        file.generatedBaseName, number: 1, width: width
                    ))
                    guard let parts = numbered(rendered) else { return nil }
                    return StemKey(directory: file.directory, stem: parts.stem)
                })
                var occupied = Set<Int>()
                var claimByUnit: [Int: Int] = [:]
                for key in numberedKeys {
                    let used = entries(key.directory).numbered[key.stem] ?? []
                    for (entry, value) in used {
                        let owner = currentOwnerByKey[StemKey(
                            directory: key.directory, stem: entry
                        )]
                        if let owner, units.contains(owner) {
                            claimByUnit[owner] = min(
                                claimByUnit[owner] ?? value, value
                            )
                        } else {
                            // Another family's current name, including one this
                            // rename moves away: the worker never swaps names.
                            occupied.insert(value)
                        }
                    }
                    occupied.formUnion(plannedNumbers[key] ?? [])
                }
                numberByUnit = [:]
                var taken = Set<Int>()
                for unit in units {
                    guard let claim = claimByUnit[unit],
                          !occupied.contains(claim),
                          taken.insert(claim).inserted else { continue }
                    numberByUnit[unit] = claim
                }
                var next = 1
                for unit in units where numberByUnit[unit] == nil {
                    while occupied.contains(next) || taken.contains(next) {
                        next += 1
                    }
                    numberByUnit[unit] = next
                    taken.insert(next)
                }
                let requiredWidth = sequenceWidth(for: taken.max() ?? units.count)
                guard requiredWidth > width else { break }
                // Crossing 999, 9999, … shortens the base again. Recheck disk
                // and planned names at that width before accepting any number.
                width = requiredWidth
            }
            for unit in units {
                guard let value = numberByUnit[unit] else { continue }
                result[unit] = ConflictNumber(number: value, width: width)
                for file in filesByUnit[unit] ?? [] {
                    plan(stemKey(numberedBaseName(
                        file.generatedBaseName, number: value, width: width
                    )), in: file.directory)
                }
            }
        }
        return result
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
            // The shared style formatter also honors the Mac's custom date
            // format. Only filename-unsafe separators need replacement.
            return safeGeneratedPart(AppDateFormat.day(date))
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

    static func safeGeneratedPart(_ value: String) -> String {
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

    private static func truncateFilenameBase(
        _ value: String,
        limit: Int = 180
    ) -> String {
        guard value.utf8.count > limit else { return value }
        var result = ""
        var bytes = 0
        for character in value {
            let count = String(character).utf8.count
            guard bytes + count <= limit else { break }
            result.append(character)
            bytes += count
        }
        return result.isEmpty ? "Unknown" : result
    }
}
