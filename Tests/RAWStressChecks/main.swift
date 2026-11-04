// Fresh-process ImageIO/RawCamera stress probe. Reads disposable fixtures only.
// swiftc -O Tests/RAWStressChecks/main.swift -o /private/tmp/louppe-raw-probe
// raw-probe FOLDER WORKERS PASSES default|false [properties|mixed]
// `mixed` rotates properties, 320 px thumbnails and 1,024 px Core Image RAW
// previews across workers, like Louppe's concurrent metadata/thumbnail/RAW lanes.
// Run under `timeout`; a timeout or crash is a failed run, not a sample.
import CoreImage
import Foundation
import ImageIO
import Dispatch

final class State: @unchecked Sendable {
    let lock = NSLock()
    var next = 0
    var failures: [String: Int] = [:]
    var completed: [String: Int] = [:]
    func claim(limit: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard next < limit else { return nil }
        defer { next += 1 }; return next
    }
    func finish(_ kind: String, success: Bool) {
        lock.lock(); defer { lock.unlock() }
        completed[kind, default: 0] += 1
        if !success { failures[kind, default: 0] += 1 }
    }
}
let args = CommandLine.arguments
precondition((5...6).contains(args.count), "folder workers passes properties-cache(default|false) [properties|mixed]")
let folder = URL(fileURLWithPath: args[1], isDirectory: true)
let workers = Int(args[2])!
let passes = Int(args[3])!
let mode = args.count == 6 ? args[5] : "properties"
precondition((1...8).contains(workers) && (1...64).contains(passes))
precondition(["properties", "mixed"].contains(mode))
let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    .filter { ["raf", "dng", "nef", "arw", "cr2", "cr3"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
precondition(!files.isEmpty)
let context = CIContext()
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func properties(_ url: URL) -> Bool {
    let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    let options: CFDictionary? = args[4] == "false" ? [kCGImageSourceShouldCache: false] as CFDictionary : nil
    return source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, options) } != nil
}

func thumbnail(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return false }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                    kCGImageSourceThumbnailMaxPixelSize: 320,
                                    kCGImageSourceShouldCacheImmediately: true]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
}

func rawPreview(_ url: URL) -> Bool {
    guard let filter = CIRAWFilter(imageURL: url) else { return false }
    let longest = max(filter.nativeSize.width, filter.nativeSize.height)
    guard longest > 0 else { return false }
    filter.scaleFactor = Float(min(1, 1_024 / longest))
    guard let image = filter.outputImage else { return false }
    return context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: colorSpace) != nil
}

let state = State()
let start = ContinuousClock.now
DispatchQueue.concurrentPerform(iterations: workers) { worker in
    while let slot = state.claim(limit: files.count * passes) {
        autoreleasepool {
            let url = files[slot % files.count]
            let kind = mode == "properties" ? "properties" : ["properties", "thumbnail", "raw-preview"][(slot + worker) % 3]
            let success: Bool
            switch kind {
            case "thumbnail": success = thumbnail(url)
            case "raw-preview": success = rawPreview(url)
            default: success = properties(url)
            }
            state.finish(kind, success: success)
        }
    }
}
let elapsed = start.duration(to: .now).components
let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
let output: [String: Any] = ["folder": folder.path, "files": files.count, "mode": mode,
    "workers": workers, "passes": passes, "propertiesCache": args[4],
    "completed": state.completed, "failures": state.failures, "seconds": seconds]
print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
exit(state.failures.values.reduce(0, +) == 0 ? 0 : 1)
