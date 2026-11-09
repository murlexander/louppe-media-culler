import AppKit
import Foundation
import Darwin

func canonical(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "frontmost" where arguments.count == 1:
    guard let app = NSWorkspace.shared.frontmostApplication else { exit(1) }
    print("\(app.bundleIdentifier ?? "unknown")\t\(app.processIdentifier)")
case "pids" where arguments.count == 2:
    let destination = canonical(URL(fileURLWithPath: arguments[1]))
    for app in NSWorkspace.shared.runningApplications.sorted(by: { $0.processIdentifier < $1.processIdentifier }) {
        if let bundle = app.bundleURL, canonical(bundle) == destination, !app.isTerminated {
            print(app.processIdentifier)
        }
    }
case "quit" where arguments.count == 3:
    guard let pid = Int32(arguments[1]), pid > 0,
          let timeout = Double(arguments[2]), timeout.isFinite, timeout >= 0, timeout <= 30 else { exit(2) }
    guard let app = NSRunningApplication(processIdentifier: pid) else {
        exit(kill(pid, 0) == 0 ? 1 : 0)
    }
    if app.isTerminated { exit(0) }
    guard app.terminate() else { exit(app.isTerminated ? 0 : 1) }
    let deadline = Date().addingTimeInterval(timeout)
    while !app.isTerminated && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    exit(app.isTerminated ? 0 : 1)
default:
    fputs("Usage: app_control frontmost | pids <bundle-path> | quit <pid> <timeout-seconds>\n", stderr)
    exit(2)
}
