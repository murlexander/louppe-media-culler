import AppKit
import ApplicationServices
import CoreGraphics

let workspace = NSWorkspace.shared
let frontmost = workspace.frontmostApplication
let session = CGSessionCopyCurrentDictionary() as? [String: Any]
let locked = session.map { ($0["CGSSessionScreenIsLocked"] as? Bool ?? false) ? "yes" : "no" } ?? "unknown"
print("Screen locked: \(locked)")
print("Frontmost: \(frontmost?.localizedName ?? "unknown") (\(frontmost?.bundleIdentifier ?? "unknown")), pid \(frontmost?.processIdentifier ?? 0)")
print("Accessibility trusted: \(AXIsProcessTrusted() ? "yes" : "no")")
print("Screen capture preflight: \(CGPreflightScreenCaptureAccess() ? "yes" : "no")")
print("Permissions reflect the terminal/agent host of this child probe; no permissions requested.")
let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
print(String(format: "Seconds since user input: %.1f (synthetic events also reset this)", idle))
let apps = workspace.runningApplications.filter {
    $0.bundleIdentifier?.hasPrefix("com.alexandermarkin.louppe") == true
}.sorted { $0.processIdentifier < $1.processIdentifier }
print("Running Louppe-family processes: \(apps.count)")
for app in apps {
    print("  pid \(app.processIdentifier) | \(app.bundleIdentifier ?? "unknown") | bundle \(app.bundleURL?.path ?? "unknown") | executable \(app.executableURL?.path ?? "unknown") | frontmost \(app.processIdentifier == frontmost?.processIdentifier ? "yes" : "no")")
}
