import Foundation
import ImageIO
import Darwin

/// Captured alongside the cache key, so workers cannot read a replacement file
/// and publish its bytes under the folder scan's earlier content revision.
/// Cache hits remain filesystem-free. Only uncached source reads validate.
struct MediaSourceRevision: Sendable {
    let url: URL
    private let identity: FileOperationJournal.FileIdentity?

    init(_ item: PhotoItem) {
        url = item.primaryURL
        identity = item.primaryFile.scannedIdentity
    }

    func matchesCurrentFile() -> Bool {
        // Synthetic/legacy items have no scan identity; preserve their API.
        guard let identity else { return true }
        var current = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &current)
        }
        guard result == 0,
              current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              UInt64(current.st_dev) == identity.systemNumber,
              UInt64(current.st_ino) == identity.fileNumber,
              identity.logicalSize.map({ $0 == Int64(current.st_size) }) ?? true
        else { return false }
        func matches(_ expected: FileOperationJournal.FileIdentity.Timestamp?,
                     _ actual: timespec) -> Bool {
            expected.map {
                $0.seconds == Int64(actual.tv_sec)
                    && $0.nanoseconds == Int64(actual.tv_nsec)
            } ?? true
        }
        return matches(identity.modificationTime, current.st_mtimespec)
            && matches(identity.statusChangeTime, current.st_ctimespec)
            && matches(identity.birthTime, current.st_birthtimespec)
    }

    func read<Result>(_ body: () -> Result?) -> Result? {
        guard matchesCurrentFile() else { return nil }
        let result = body()
        guard matchesCurrentFile() else { return nil }
        return result
    }

    static let changedMessage =
        L10n.text("This file changed since the folder was scanned. Rescan the folder to use the current file.")
}


enum MetadataExtractor {
    /// Bump when scan/Fuji/movie/audio interpretation changes. Old observations
    /// then rebuild without affecting sidecar or preview cache schemas.
    static let archiveSchemaVersion = 2

    /// The metadata read once per file during the folder scan.
    struct ScanInfo: Sendable {
        var captureDate: Date? = nil
        var captureDateEvidence: CaptureDateEvidence? = nil
        var cameraModel: String? = nil
        var lensModel: String? = nil
        var aperture: Double? = nil
        var shutterSpeed: Double? = nil
        var iso: Double? = nil
        var filmSimulation: FujiFilmSimulation? = nil
        /// Missing tags after a successful header read are reusable. An I/O or
        /// decoder failure is only an attempted observation and must be retried.
        var extractionSucceeded: Bool = true
    }

    /// Read-only opening details use already prepared observations. Never
    /// reopen ImageIO/AVAsset here or wait for unrelated metadata workers.
    static func openingFields(for item: PhotoItem) -> [MetadataField] {
        if item.isText || item.isVideo || item.isAudio { return fields(for: item) }
        var result: [MetadataField] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            result.append(MetadataField(id: label, label: label, value: value))
        }
        add("Filename", item.displayName)
        add("Paired file", item.pairedURL?.lastPathComponent)
        if let date = item.captureDate {
            let formatted = AppDateFormat.dayAndTime(date)
            let estimated = item.captureDateEvidence?.source != .exifOriginal
                && item.captureDateEvidence?.source != .photosLibrary
            add("Captured", estimated ? L10n.text("\(formatted) · estimated") : formatted)
        }
        add("Time zone", item.captureDateEvidence?.timeZoneDescription)
        add("Camera", item.cameraModel)
        add("Lens", item.lensModel)
        add("Film simulation", item.filmSimulation?.label)
        add("Aperture", MediaNumeric.aperture(item.aperture).map { String(format: "f/%.1f", $0) })
        add("Shutter", MediaNumeric.shutterSpeed(item.shutterSpeed).map(formatShutter))
        add("ISO", MediaNumeric.iso(item.iso).map { String(format: "%.0f", $0) })
        if item.pairedURL != nil {
            add("Primary size", formattedFileSize(item.fileSize))
            add("Paired size", formattedFileSize(item.pairedFileSize))
            add("Total size", formattedFileSize(item.totalFileSize))
        } else { add("File size", formattedFileSize(item.fileSize)) }
        add("Type", item.fileTypeLabel)
        return result
    }

    /// Reads the metadata used by filtering and sorting in a single pass during
    /// the scan, so interactive changes never have to re-open every file.
    static func scanInfo(for url: URL) -> ScanInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ScanInfo(extractionSucceeded: false)
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateEvidence = captureDateEvidence(exif: exif ?? [:], tiff: tiff ?? [:])
        let aperture = MediaNumeric.aperture(
            finiteNumericValue(exif?[kCGImagePropertyExifFNumber])
        )
        let shutterSpeed = MediaNumeric.shutterSpeed(
            finiteNumericValue(exif?[kCGImagePropertyExifExposureTime])
        )
        let iso = MediaNumeric.iso(
            firstNumericValue(exif?[kCGImagePropertyExifISOSpeedRatings])
        )
        return ScanInfo(
            captureDate: dateEvidence?.date,
            captureDateEvidence: dateEvidence,
            cameraModel: tiff?[kCGImagePropertyTIFFModel] as? String,
            lensModel: exif?[kCGImagePropertyExifLensModel] as? String,
            aperture: aperture,
            shutterSpeed: shutterSpeed,
            iso: iso,
            filmSimulation: FujiFilmSimulationReader.read(url: url, properties: props)
        )
    }

    /// Full field list for the metadata panel.
    static func fields(for item: PhotoItem) -> [MetadataField] {
#if DEBUG
        MetadataExtractorTestProbe.shared.record(item.contentRevision)
#endif
        if item.primaryFile.photosMedia != nil {
            var fields = [MetadataField(id: "Filename", label: "Filename", value: item.displayName),
                MetadataField(id: "Type", label: "Type", value: item.fileTypeLabel),
                MetadataField(id: "Availability", label: "Availability",
                    value: L10n.text("Original EXIF, size and quality checks unavailable during preview review."))]
            if let date = item.captureDate {
                fields.append(MetadataField(id: "Captured", label: "Captured", value: AppDateFormat.dayAndTime(date)))
            }
            return fields
        }
        if item.isText {
            return [
                MetadataField(id: "Filename", label: "Filename", value: item.displayName),
                MetadataField(id: "Format", label: "Format", value: item.fileTypeLabel),
                MetadataField(id: "Size", label: "Size", value: ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)),
            ]
        }
        if item.isVideo { return videoFields(for: item) }
        if item.isAudio { return audioFields(for: item) }
        var fields: [MetadataField] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append(MetadataField(id: label, label: label, value: value))
        }

        add("Filename", item.displayName)
        if let paired = item.pairedURL {
            add("Paired file", paired.lastPathComponent)
        }

        let revision = MediaSourceRevision(item)
        guard revision.matchesCurrentFile() else { return changedFileFields(for: item) }
        var props: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(item.primaryURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            props = p
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        if let date = item.captureDate {
            let formattedDate = AppDateFormat.dayAndTime(date)
            let isEstimated = item.captureDateEvidence?.source != .exifOriginal
                && item.captureDateEvidence?.source != .photosLibrary
            add("Captured", isEstimated ? L10n.text("\(formattedDate) · estimated") : formattedDate)
        }
        if let evidence = item.captureDateEvidence {
            add("Time zone", evidence.timeZoneDescription)
        }
        add("Camera", tiff[kCGImagePropertyTIFFModel] as? String)
        add("Lens", exif[kCGImagePropertyExifLensModel] as? String)
        add("Film simulation", item.filmSimulation?.label)

        if let focal = MediaNumeric.focalLength(
            finiteNumericValue(exif[kCGImagePropertyExifFocalLength])
        ) {
            add("Focal length", String(format: "%.0f mm", focal))
        }
        if let fNumber = MediaNumeric.aperture(
            finiteNumericValue(exif[kCGImagePropertyExifFNumber])
        ) {
            add("Aperture", String(format: "f/%.1f", fNumber))
        }
        if let exposure = MediaNumeric.shutterSpeed(
            finiteNumericValue(exif[kCGImagePropertyExifExposureTime])
        ) {
            add("Shutter", formatShutter(exposure))
        }
        if let iso = MediaNumeric.iso(
            firstNumericValue(exif[kCGImagePropertyExifISOSpeedRatings])
        ) {
            add("ISO", String(format: "%.0f", iso))
        }
        if let bias = MediaNumeric.exposureCompensation(
            finiteNumericValue(exif[kCGImagePropertyExifExposureBiasValue])
        ) {
            add(
                "Exposure comp.",
                bias == 0 ? "0 EV" : String(format: "%+.1f EV", bias)
            )
        }
        if let wb = exif[kCGImagePropertyExifWhiteBalance] as? Int {
            add("White balance", wb == 0 ? L10n.text("Auto") : L10n.text("Manual"))
        }
        if let widthValue = finiteNumericValue(
            props[kCGImagePropertyPixelWidth]
        ),
           let heightValue = finiteNumericValue(
               props[kCGImagePropertyPixelHeight]
           ),
           let width = MediaNumeric.pixelDimension(CGFloat(widthValue)),
           let height = MediaNumeric.pixelDimension(CGFloat(heightValue)) {
            add("Dimensions", "\(width) × \(height)")
        }
        if item.pairedURL != nil {
            add("Primary size", formattedFileSize(item.fileSize))
            add("Paired size", formattedFileSize(item.pairedFileSize))
            add("Total size", formattedFileSize(item.totalFileSize))
        } else {
            add("File size", formattedFileSize(item.fileSize))
        }
        add("Type", item.fileTypeLabel)

        if let lat = MediaNumeric.latitude(
            finiteNumericValue(gps[kCGImagePropertyGPSLatitude])
        ),
           let lon = MediaNumeric.longitude(
               finiteNumericValue(gps[kCGImagePropertyGPSLongitude])
           ) {
            let requestedLatRef =
                (gps[kCGImagePropertyGPSLatitudeRef] as? String)?
                .uppercased()
            let requestedLonRef =
                (gps[kCGImagePropertyGPSLongitudeRef] as? String)?
                .uppercased()
            let latRef = requestedLatRef.flatMap {
                ["N", "S"].contains($0) ? $0 : nil
            } ?? (lat < 0 ? "S" : "N")
            let lonRef = requestedLonRef.flatMap {
                ["E", "W"].contains($0) ? $0 : nil
            } ?? (lon < 0 ? "W" : "E")
            add("GPS", String(format: "%.5f°%@, %.5f°%@", lat, latRef, lon, lonRef))
        }
        guard revision.matchesCurrentFile() else { return changedFileFields(for: item) }
        return fields
    }

    private static func changedFileFields(for item: PhotoItem) -> [MetadataField] {
        [
            MetadataField(id: "Filename", label: "Filename", value: item.displayName),
            MetadataField(id: "File changed", label: "File changed", value: MediaSourceRevision.changedMessage),
        ]
    }

    private static func videoFields(for item: PhotoItem) -> [MetadataField] {
        var fields: [MetadataField] = [
            MetadataField(id: "Filename", label: "Filename", value: item.displayName),
        ]
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append(MetadataField(id: label, label: label, value: value))
        }
        if let date = item.captureDate { add("Captured", AppDateFormat.dayAndTime(date)) }
        add("Duration", MediaDurationFormat.display(item.duration))
        if let size = item.videoDimensions,
           let width = MediaNumeric.pixelDimension(size.width),
           let height = MediaNumeric.pixelDimension(size.height) {
            add("Dimensions", "\(width) × \(height)")
        }
        add("Codec", item.videoCodec)
        if let frameRate = MediaNumeric.frameRate(
            item.videoFrameRate
        ) {
            add("Frame rate", String(format: "%.2f fps", frameRate).replacingOccurrences(of: ".00 ", with: " "))
        }
        add("File size", formattedFileSize(item.fileSize))
        add("Type", item.fileTypeLabel)
        return fields
    }

    private static func audioFields(for item: PhotoItem) -> [MetadataField] {
        var fields: [MetadataField] = [
            MetadataField(id: "Filename", label: "Filename", value: item.displayName),
        ]
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields.append(MetadataField(id: label, label: label, value: value))
        }
        if let date = item.captureDate { add("Recorded", AppDateFormat.dayAndTime(date)) }
        add("Duration", MediaDurationFormat.display(item.duration))
        add("Codec", item.audioCodec)
        add("File size", formattedFileSize(item.fileSize))
        add("Type", item.fileTypeLabel)
        return fields
    }

    private static func formattedFileSize(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    static func formatShutter(_ seconds: Double) -> String {
        guard let seconds = MediaNumeric.shutterSpeed(seconds) else {
            return "—"
        }
        if seconds >= 1 {
            return String(format: "%.1fs", seconds)
        }
        guard let denominator = MediaNumeric.roundedPositiveInt(1 / seconds)
        else { return "—" }
        return "1/\(denominator)s"
    }

    static func finiteNumericValue(_ value: Any?) -> Double? {
        let parsed: Double?
        if let number = value as? NSNumber {
            parsed = number.doubleValue
        } else if let string = value as? String {
            parsed = Double(string)
        } else {
            parsed = nil
        }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    /// ISO is normally an array in EXIF, but some encoders store a scalar.
    /// Accept both shapes so filtering, sorting, and the Info panel agree.
    private static func firstNumericValue(_ value: Any?) -> Double? {
        if let values = value as? [Any] {
            return values.lazy.compactMap(finiteNumericValue).first
        }
        return finiteNumericValue(value)
    }

    /// ImageIO exposes each date's companion subsecond and offset separately.
    /// Parse only matching companions; a digitized offset cannot qualify an
    /// original capture date. Invalid originals may fall back to another tag.
    static func captureDateEvidence(
        exif: [CFString: Any],
        tiff: [CFString: Any],
        assumedTimeZone: TimeZone = .current
    ) -> CaptureDateEvidence? {
        let candidates: [(Any?, Any?, Any?, CaptureDateEvidence.Source)] = [
            (exif[kCGImagePropertyExifDateTimeOriginal],
             exif[kCGImagePropertyExifSubsecTimeOriginal],
             exif[kCGImagePropertyExifOffsetTimeOriginal], .exifOriginal),
            (exif[kCGImagePropertyExifDateTimeDigitized],
             exif[kCGImagePropertyExifSubsecTimeDigitized],
             exif[kCGImagePropertyExifOffsetTimeDigitized], .exifDigitized),
            (tiff[kCGImagePropertyTIFFDateTime],
             exif[kCGImagePropertyExifSubsecTime],
             exif[kCGImagePropertyExifOffsetTime], .tiff),
        ]
        for (rawDate, rawSubsecond, rawOffset, source) in candidates {
            guard let rawDate = rawDate as? String else { continue }
            let dateString = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
            let bytes = Array(dateString.utf8)
            guard bytes.count == 19,
                  bytes[4] == 58, bytes[7] == 58, bytes[10] == 32,
                  bytes[13] == 58, bytes[16] == 58 else { continue }
            func number(_ range: Range<Int>) -> Int? {
                let digits = bytes[range]
                guard digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
                return digits.reduce(0) { $0 * 10 + Int($1 - 48) }
            }
            guard let year = number(0..<4), let month = number(5..<7),
                  let day = number(8..<10), let hour = number(11..<13),
                  let minute = number(14..<16), let second = number(17..<19),
                  year > 0, (1...12).contains(month), (1...31).contains(day),
                  (0...23).contains(hour), (0...59).contains(minute),
                  (0...59).contains(second) else { continue }
            let offset = parsedUTCOffset(rawOffset)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = offset?.zone ?? assumedTimeZone
            let components = DateComponents(
                year: year, month: month, day: day,
                hour: hour, minute: minute, second: second
            )
            guard let wholeDate = calendar.date(from: components),
                  calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: wholeDate
                  ) == components else { continue }
            let subseconds = (rawSubsecond as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let digits = subseconds.flatMap { value -> String? in
                guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) })
                else { return nil }
                return value
            }
            // Double retains finite precision; keep the original digits for
            // evidence even if the final Date cannot represent every digit.
            let fraction = digits.flatMap { Double("0." + String($0.prefix(9))) } ?? 0
            return CaptureDateEvidence(
                date: wholeDate.addingTimeInterval(fraction), source: source,
                rawDateTime: dateString, subsecondDigits: digits,
                utcOffset: offset?.text,
                assumedTimeZoneIdentifier: offset == nil ? assumedTimeZone.identifier : nil
            )
        }
        return nil
    }

    private static func parsedUTCOffset(_ raw: Any?) -> (zone: TimeZone, text: String)? {
        guard let raw = raw as? String else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Array(text.utf8)
        guard bytes.count == 6, bytes[0] == 43 || bytes[0] == 45,
              bytes[3] == 58,
              [bytes[1], bytes[2], bytes[4], bytes[5]].allSatisfy({ (48...57).contains($0) })
        else { return nil }
        let hours = Int(bytes[1] - 48) * 10 + Int(bytes[2] - 48)
        let minutes = Int(bytes[4] - 48) * 10 + Int(bytes[5] - 48)
        guard hours <= 14, minutes < 60, hours < 14 || minutes == 0 else { return nil }
        let seconds = (hours * 3_600 + minutes * 60) * (bytes[0] == 45 ? -1 : 1)
        guard let zone = TimeZone(secondsFromGMT: seconds) else { return nil }
        return (zone, text)
    }

}

#if DEBUG
/// Counts exact metadata-field reads for unique content revisions in hosted
/// regression tests. The release app has no probe or counting overhead.
final class MetadataExtractorTestProbe: @unchecked Sendable {
    static let shared = MetadataExtractorTestProbe()

    private let lock = NSLock()
    private var callCounts: [PhotoContentRevision: Int] = [:]

    private init() {}

    func record(_ revision: PhotoContentRevision) {
        lock.lock()
        callCounts[revision, default: 0] += 1
        lock.unlock()
    }

    func callCount(for revision: PhotoContentRevision) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCounts[revision, default: 0]
    }
}
#endif
