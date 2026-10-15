import Foundation
import Darwin
@testable import Louppe

func runProbe(_ scenario: String) async throws {
    let root = URL(fileURLWithPath: "/private/tmp/louppe-audit-2026-09-29/xmp-identity-\(scenario)-\(UUID().uuidString)")
    let folder = root.appendingPathComponent("Source")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let media = folder.appendingPathComponent("PHOTO.NEF")
    try Data("original media".utf8).write(to: media)
    let identity = try FileOperationJournal.captureIdentity(at: media)
    let item = PhotoItem(primaryFile: PhotoFile(
        id: "PHOTO.NEF", url: media, captureDate: nil, cameraModel: nil,
        lensModel: nil, fileSize: 14, scannedIdentity: identity,
        rating: .yes, starRating: .five, colorLabel: .red
    ))
    let input = try XMPPublicationInput(items: [item], profile: .universal, visibleDecisionKeywords: false)
    guard let plan = await XMPPublicationPlanner.preflight(input,isCancelled: { false },progress: { _,_ in }) else { fatalError("No plan") }
    precondition(plan.publishableCount == 1)
    if scenario == "file-replacement" {
        try Data("unrelated replacement media".utf8).write(to: media,options: .atomic)
    } else {
        try FileManager.default.moveItem(at: folder,to: root.appendingPathComponent("ArchivedSource"))
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: false)
        try Data("unrelated media in new folder".utf8).write(to: media)
    }
    let changed = try FileOperationJournal.captureIdentity(at: media)
    precondition(changed != identity)
    let result = await XMPPublicationWorker.publish(plan,cancelFlag: XMPPublicationCancelFlag(),progress: { _,_ in })
    let sidecar = folder.appendingPathComponent("PHOTO.xmp")
    let packet = try Data(contentsOf: sidecar)
    let decision = try XMPFieldMapping.readProperty(namespace: XMPFieldMapping.louppeNamespace,path: "Decision",packet: packet)
    print("scenario=\(scenario) mediaIdentityChanged=true created=\(result.created) failed=\(result.failed) conflicts=\(result.conflicts) sidecarDecision=\(decision)")
}
Task {
    do {
        try await runProbe("file-replacement")
        try await runProbe("folder-replacement")
        exit(0)
    } catch {
        print("probe failed: \(error)")
        exit(1)
    }
}
dispatchMain()
