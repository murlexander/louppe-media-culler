import Foundation
import ImageIO

/// Small scan-time values, retained per physical file. Unknown future codes
/// share one bucket rather than growing a facet for every untrusted tag value.
enum FujiFilmSimulation: String, CaseIterable, Hashable, Sendable {
    case provia, studioPortrait, studioPortraitEnhanced, astia
    case studioPortraitSharp, velvia, studioPortraitEx, velviaF4
    case proNegStd, proNegHi, classicChrome, eterna, classicNegative
    case eternaBleachBypass, nostalgicNeg, realaACE
    case monochrome, monochromeRed, monochromeYellow, monochromeGreen, sepia
    case acros, acrosRed, acrosYellow, acrosGreen
    case unknown, notRecorded

    var label: String {
        switch self {
        case .provia: return "PROVIA / Standard"
        case .studioPortrait: return "F1 / Studio Portrait"
        case .studioPortraitEnhanced: return "F1a / Studio Portrait Enhanced"
        case .astia: return "ASTIA / Soft"
        case .studioPortraitSharp: return "F1c / Studio Portrait Sharp"
        case .velvia: return "Velvia / Vivid"
        case .studioPortraitEx: return "F3 / Studio Portrait Ex"
        case .velviaF4: return "F4 / Velvia"
        case .proNegStd: return "PRO Neg. Std"
        case .proNegHi: return "PRO Neg. Hi"
        case .classicChrome: return "CLASSIC CHROME"
        case .eterna: return "ETERNA / Cinema"
        case .classicNegative: return "CLASSIC Neg."
        case .eternaBleachBypass: return "ETERNA Bleach Bypass"
        case .nostalgicNeg: return "NOSTALGIC Neg."
        case .realaACE: return "REALA ACE"
        case .monochrome: return "MONOCHROME"
        case .monochromeRed: return "MONOCHROME + R"
        case .monochromeYellow: return "MONOCHROME + Ye"
        case .monochromeGreen: return "MONOCHROME + G"
        case .sepia: return "SEPIA"
        case .acros: return "ACROS"
        case .acrosRed: return "ACROS + R"
        case .acrosYellow: return "ACROS + Ye"
        case .acrosGreen: return "ACROS + G"
        case .unknown: return L10n.text("Unknown film simulation")
        case .notRecorded: return L10n.text("Not recorded")
        }
    }

    /// Tag definitions verified against ExifTool's FujiFilm.pm (0x1401,
    /// 0x1003). A monochrome Saturation overrides any color FilmMode.
    static func resolve(filmMode: UInt16?, saturation: UInt16?) -> Self {
        switch saturation {
        case 0x300: return .monochrome
        case 0x301: return .monochromeRed
        case 0x302: return .monochromeYellow
        case 0x303: return .monochromeGreen
        case 0x310: return .sepia
        case 0x500: return .acros
        case 0x501: return .acrosRed
        case 0x502: return .acrosYellow
        case 0x503: return .acrosGreen
        // Never call a new monochrome variant a color simulation.
        case let value? where (0x300...0x3ff).contains(value)
            || (0x500...0x5ff).contains(value): return .unknown
        default: break
        }
        switch filmMode {
        case 0: return .provia
        case 0x100: return .studioPortrait
        case 0x110: return .studioPortraitEnhanced
        case 0x120: return .astia
        case 0x130: return .studioPortraitSharp
        case 0x200: return .velvia
        case 0x300: return .studioPortraitEx
        case 0x400: return .velviaF4
        case 0x500: return .proNegStd
        case 0x501: return .proNegHi
        case 0x600: return .classicChrome
        case 0x700: return .eterna
        case 0x800: return .classicNegative
        case 0x900: return .eternaBleachBypass
        case 0xa00: return .nostalgicNeg
        case 0xb00: return .realaACE
        case nil: return .notRecorded
        default: return .unknown
        }
    }
}

/// Reads only the Fuji film tags; never writes originals or decodes pixels.
/// ImageIO does not publish named Fuji tag constants. Prefer its raw MakerNote
/// or exact numeric fields, then inspect the bounded EXIF container ourselves.
enum FujiFilmSimulationReader {
    private static let maximumMetadataBytes = 1_048_576

    static func read(url: URL, properties: [CFString: Any]) -> FujiFilmSimulation? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        if let note = exif?[kCGImagePropertyExifMakerNote] as? Data,
           note.count <= maximumMetadataBytes,
           let result = makerNote(note) { return result }
        let fuji = properties[kCGImagePropertyMakerFujiDictionary] as? [String: Any]
        if let fuji {
            func tag(_ names: [String]) -> UInt16? {
                for name in names {
                    if let number = fuji[name] as? NSNumber {
                        let value = number.doubleValue
                        if value.isFinite, value.rounded() == value,
                           (0...Double(UInt16.max)).contains(value) {
                            return UInt16(value)
                        }
                    }
                }
                return nil
            }
            let film = tag(["FilmMode", "5121", "0x1401"])
            let saturation = tag(["Saturation", "4099", "0x1003"])
            if film != nil || saturation != nil {
                let resolved = FujiFilmSimulation.resolve(filmMode: film, saturation: saturation)
                // ImageIO can omit Saturation while exposing a color FilmMode.
                // Consult the complete note before missing its monochrome
                // override. Missing tags retain the numeric evidence; malformed
                // or unknown notes must not silently become a color simulation.
                if resolved != .notRecorded {
                    if saturation == nil,
                       let complete = readContainer(url: url), complete != .notRecorded {
                        return complete
                    }
                    return resolved
                }
            }
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String ?? "").uppercased()
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String ?? "").uppercased()
        guard make.contains("FUJI") || model.contains("FUJI") || fuji != nil
                || url.pathExtension.lowercased() == "raf" else { return nil }
        return readContainer(url: url) ?? .notRecorded
    }

    /// Fuji's IFD is always little-endian, even in big-endian EXIF. Its offset
    /// is relative to the eight-byte FUJIFILM signature, not the TIFF header.
    static func makerNote(_ data: Data) -> FujiFilmSimulation? {
        guard data.count <= maximumMetadataBytes else { return .unknown }
        let bytes = Array(data)
        guard bytes.starts(with: Array("FUJIFILM".utf8)) else { return nil }
        guard bytes.count <= maximumMetadataBytes,
              let start = integer(bytes, at: 8, size: 4, little: true), start >= 12,
              let count = integer(bytes, at: start, size: 2, little: true),
              count <= 1_024, start <= bytes.count - 2,
              count <= (bytes.count - start - 2) / 12 else { return .unknown }
        var film: UInt16?
        var saturation: UInt16?
        for index in 0..<count {
            let entry = start + 2 + index * 12
            guard let tag = integer(bytes, at: entry, size: 2, little: true),
                  tag == 0x1401 || tag == 0x1003 else { continue }
            guard integer(bytes, at: entry + 2, size: 2, little: true) == 3,
                  integer(bytes, at: entry + 4, size: 4, little: true) == 1,
                  let value = integer(bytes, at: entry + 8, size: 2, little: true)
            else { return .unknown }
            // Duplicate relevant tags are ambiguous rather than last-wins.
            if tag == 0x1401 {
                guard film == nil else { return .unknown }
                film = UInt16(value)
            } else {
                guard saturation == nil else { return .unknown }
                saturation = UInt16(value)
            }
        }
        return FujiFilmSimulation.resolve(filmMode: film, saturation: saturation)
    }

    private static func integer(_ bytes: [UInt8], at offset: Int,
                                size: Int, little: Bool) -> Int? {
        guard offset >= 0, offset <= bytes.count, size <= bytes.count - offset else { return nil }
        var result = 0
        for index in 0..<size {
            let byte = bytes[offset + (little ? size - 1 - index : index)]
            result = (result << 8) | Int(byte)
        }
        return result
    }

    /// Fixed-depth IFD0 -> ExifIFD -> MakerNote traversal. No recursive IFDs,
    /// offsets outside the captured bytes, or allocations based on tag counts.
    static func exifTIFF(_ data: Data) -> FujiFilmSimulation? {
        guard data.count <= maximumMetadataBytes else { return nil }
        let bytes = Array(data)
        guard bytes.count >= 8 else { return nil }
        let little: Bool
        if bytes[0...1].elementsEqual([0x49, 0x49]) { little = true }
        else if bytes[0...1].elementsEqual([0x4d, 0x4d]) { little = false }
        else { return nil }
        guard integer(bytes, at: 2, size: 2, little: little) == 42,
              let first = integer(bytes, at: 4, size: 4, little: little), first >= 8 else { return nil }
        func entry(_ tag: Int, at start: Int) -> Int? {
            guard let count = integer(bytes, at: start, size: 2, little: little),
                  count <= 1_024, start <= bytes.count - 2,
                  count <= (bytes.count - start - 2) / 12 else { return nil }
            var found: Int?
            for index in 0..<count {
                let position = start + 2 + index * 12
                if integer(bytes, at: position, size: 2, little: little) == tag {
                    guard found == nil else { return nil }
                    found = position
                }
            }
            return found
        }
        guard let exif = entry(0x8769, at: first),
              integer(bytes, at: exif + 2, size: 2, little: little) == 4,
              integer(bytes, at: exif + 4, size: 4, little: little) == 1,
              let exifStart = integer(bytes, at: exif + 8, size: 4, little: little),
              let note = entry(0x927c, at: exifStart),
              integer(bytes, at: note + 2, size: 2, little: little) == 7,
              let length = integer(bytes, at: note + 4, size: 4, little: little), length > 4,
              let offset = integer(bytes, at: note + 8, size: 4, little: little),
              offset <= bytes.count, length <= bytes.count - offset else { return nil }
        return makerNote(Data(bytes[offset..<(offset + length)]))
    }

    private static func readContainer(url: URL) -> FujiFilmSimulation? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data? {
            guard count >= 0, count <= maximumMetadataBytes else { return nil }
            do {
                try handle.seek(toOffset: offset)
                let result = try handle.read(upToCount: count) ?? Data()
                return result.count == count ? result : nil
            } catch { return nil }
        }
        guard let header = read(0, 16) else { return nil }
        var jpegStart: UInt64 = 0
        var jpegLimit = UInt64(maximumMetadataBytes)
        if header.starts(with: Array("FUJIFILMCCD-RAW".utf8)) {
            guard let raf = read(84, 8) else { return nil }
            let bytes = Array(raf)
            guard let offset = integer(bytes, at: 0, size: 4, little: false),
                  let length = integer(bytes, at: 4, size: 4, little: false), length >= 4 else { return nil }
            jpegStart = UInt64(offset)
            jpegLimit = jpegStart + UInt64(min(length, maximumMetadataBytes))
        } else if header.starts(with: [0x49, 0x49]) || header.starts(with: [0x4d, 0x4d]) {
            // TIFF/RAF metadata is bounded independently of original image size.
            try? handle.seek(toOffset: 0)
            guard let prefix = try? handle.read(upToCount: maximumMetadataBytes) else { return nil }
            return exifTIFF(prefix)
        }
        guard read(jpegStart, 2) == Data([0xff, 0xd8]) else { return nil }
        var position = jpegStart + 2
        for _ in 0..<256 {
            guard position + 4 <= jpegLimit, let markerData = read(position, 4) else { return nil }
            let marker = Array(markerData)
            guard marker[0] == 0xff else { return nil }
            if marker[1] == 0xff { position += 1; continue }
            if marker[1] == 0xda || marker[1] == 0xd9 { return nil }
            if marker[1] == 0x01 || (0xd0...0xd7).contains(marker[1]) { position += 2; continue }
            let length = Int(marker[2]) * 256 + Int(marker[3])
            guard length >= 2, position + 2 + UInt64(length) <= jpegLimit else { return nil }
            if marker[1] == 0xe1, let segment = read(position + 4, length - 2),
               segment.starts(with: [0x45, 0x78, 0x69, 0x66, 0, 0]),
               let result = exifTIFF(Data(segment.dropFirst(6))) { return result }
            position += UInt64(length) + 2
        }
        return nil
    }
}
