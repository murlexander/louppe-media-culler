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

    /// The metadata read once per file during the folder scan.
    struct ScanInfo {
        var captureDate: Date? = nil
        var cameraModel: String? = nil
        var lensModel: String? = nil
        var aperture: Double? = nil
        var shutterSpeed: Double? = nil
        var iso: Double? = nil
    }

    /// Reads the metadata used by filtering and sorting in a single pass during
    /// the scan, so interactive changes never have to re-open every file.
    static func scanInfo(for url: URL) -> ScanInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ScanInfo()
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
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
            captureDate: dateString.flatMap { exifDateFormatter.date(from: $0) },
            cameraModel: tiff?[kCGImagePropertyTIFFModel] as? String,
            lensModel: exif?[kCGImagePropertyExifLensModel] as? String,
            aperture: aperture,
            shutterSpeed: shutterSpeed,
            iso: iso
        )
    }

    /// Full field list for the metadata panel.
    static func fields(for item: PhotoItem) -> [MetadataField] {
#if DEBUG
        MetadataExtractorTestProbe.shared.record(item.contentRevision)
#endif
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
            add("Captured", AppDateFormat.dayAndTime(date))
        }
        add("Camera", tiff[kCGImagePropertyTIFFModel] as? String)
        add("Lens", exif[kCGImagePropertyExifLensModel] as? String)

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

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()
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
