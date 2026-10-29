// Fresh-process ImageIO metadata stress probe. Reads disposable fixtures only.
// swiftc -O Tests/RAWStressChecks/main.swift -o /private/tmp/louppe-raw-probe
import Foundation
import ImageIO
import Dispatch

final class State: @unchecked Sendable {
    let lock = NSLock()
    var next = 0
    var failures = 0
    var completed = 0
    func claim(limit: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard next < limit else { return nil }
        defer { next += 1 }; return next
    }
    func finish(success: Bool) {
        lock.lock(); defer { lock.unlock() }
        completed += 1
        if !success { failures += 1 }
    }
}
let args = CommandLine.arguments
precondition(args.count == 5, "folder workers passes properties-cache(default|false)")
let folder = URL(fileURLWithPath: args[1], isDirectory: true)
let workers = Int(args[2])!
let passes = Int(args[3])!
precondition((1...8).contains(workers) && (1...64).contains(passes))
let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    .filter { ["raf", "dng", "nef", "arw", "cr2", "cr3"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
precondition(!files.isEmpty)
let state = State()
let start = ContinuousClock.now
DispatchQueue.concurrentPerform(iterations: workers) { _ in
    while let slot = state.claim(limit: files.count * passes) {
        autoreleasepool {
            let url = files[slot % files.count]
            let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary)
            let options: CFDictionary? = args[4] == "false"
                ? [kCGImageSourceShouldCache: false] as CFDictionary : nil
            let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, options) }
            state.finish(success: properties != nil)
        }
    }
}
let elapsed = start.duration(to: .now).components
let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
let output: [String: Any] = ["folder": folder.path, "files": files.count,
    "workers": workers, "passes": passes, "propertiesCache": args[4],
    "completed": state.completed, "failures": state.failures, "seconds": seconds]
print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
exit(state.failures == 0 ? 0 : 1)
