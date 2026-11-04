import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main struct AuditMediaRepro {
    static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/louppe-audit-2026-09-29/media-repro/fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("photo.png")
        let other = root.appendingPathComponent("replacement.png")
        try writeImage([0, 0, 0, 255], to: original)
        let oldItem = photo(at: original)
        try writeImage([255, 255, 255, 255], to: other)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: other, to: original)
        print("LIVE_IDENTITY_DIFFERS=\(oldItem.primaryFile.scannedIdentity != (try FileOperationJournal.captureIdentity(at: original)))")
        let pipeline = ImagePipeline(testingDiskCacheRoot: root.appendingPathComponent("cache"))
        let image = await pipeline.thumbnail(for: oldItem)
        print("OLD_REVISION_THUMB_PIXEL=\(try pixel(image!.cgImage(forProposedRect: nil, context: nil, hints: nil)!))")
        let full = await pipeline.fullImage(for: oldItem)
        print("OLD_REVISION_FULL_PIXEL=\(try pixel(full!.cgImage(forProposedRect: nil, context: nil, hints: nil)!))")
        let histogram = await HistogramPipeline.shared.analysis(for: oldItem)
        print("OLD_REVISION_HIST_HIGHLIGHTS=\(histogram!.highlightCount), SHADOWS=\(histogram!.shadowCount)")
        await pipeline.waitForPendingDiskWrites()
        try writeImage([0, 0, 0, 255], to: original)
        let cached = await pipeline.thumbnail(for: oldItem)
        print("OLD_REVISION_CACHED_AFTER_BLACK_REWRITE=\(try pixel(cached!.cgImage(forProposedRect: nil, context: nil, hints: nil)!))")
        let partialWhite = try makeImage([3, 3, 3, 3])
        let semi = ClippingWarningProcessor.analyze(partialWhite)!
        let warned = ClippingWarningProcessor.overlay(on: partialWhite)!
        print("TRANSLUCENT_WHITE_HIST_SHADOW=\(semi.shadowCount), HIGHLIGHT=\(semi.highlightCount), BIN3=\(semi.bins[3])")
        print("TRANSLUCENT_WHITE_OVERLAY_PREMULTIPLIED_PIXEL=\(try pixel(warned))")
        let longURL = root.appendingPathComponent("long.wav")
        let shortURL = root.appendingPathComponent("short.wav")
        try writeSilentWAV(to: longURL, seconds: 3600)
        try writeSilentWAV(to: shortURL, seconds: 1)
        let long = audio(at: longURL, seconds: 3600)
        let short = audio(at: shortURL, seconds: 1)
        let start = Date()
        let abandoned = Task { await AudioLevelPipeline.shared.analysis(for: long) }
        try await Task.sleep(for: .milliseconds(100))
        abandoned.cancel()
        let cancellationStart = Date()
        let abandonedResult = await abandoned.value
        print("AUDIO_CANCEL_RETURNED_NIL=\(abandonedResult == nil) AFTER=\(Date().timeIntervalSince(cancellationStart))s")
        let selectedStart = Date()
        let selected = await AudioLevelPipeline.shared.analysis(for: short)
        print("NEXT_ONE_SECOND_AUDIO_ANALYSIS=\(selected != nil) WAIT=\(Date().timeIntervalSince(selectedStart))s TOTAL=\(Date().timeIntervalSince(start))s")
        let cachedStart = Date()
        _ = await AudioLevelPipeline.shared.analysis(for: long)
        print("ABANDONED_LONG_ANALYSIS_CACHE_HIT=\(Date().timeIntervalSince(cachedStart))s")
    }
    static func photo(at url: URL) -> PhotoItem {
        PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, fileSize: 1)
    }
    static func audio(at url: URL, seconds: Double) -> PhotoItem {
        PhotoItem(id: url.lastPathComponent, primaryURL: url, pairedURL: nil, captureDate: nil, cameraModel: nil, lensModel: nil, mediaKind: .audio, duration: seconds, audioIsPlayable: true, fileSize: 1)
    }
    static func makeImage(_ bytes: [UInt8]) throws -> CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    static func writeImage(_ bytes: [UInt8], to url: URL) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, try makeImage(bytes), nil)
        precondition(CGImageDestinationFinalize(dest))
    }
    static func pixel(_ image: CGImage) throws -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: 4)
        bytes.withUnsafeMutableBytes { buf in
            let context = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
    static func writeSilentWAV(to url: URL, seconds: UInt32) throws {
        let sampleRate: UInt32 = 48_000
        let byteCount = seconds * sampleRate * 4
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        data.append(contentsOf: "RIFF".utf8); put(36 + byteCount); data.append(contentsOf: "WAVEfmt ".utf8)
        put(UInt32(16)); put(UInt16(1)); put(UInt16(2)); put(sampleRate); put(sampleRate * 4); put(UInt16(4)); put(UInt16(16))
        data.append(contentsOf: "data".utf8); put(byteCount)
        try data.write(to: url)
        let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: UInt64(44 + byteCount)); try handle.close()
    }
}
