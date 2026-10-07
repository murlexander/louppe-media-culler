import AppKit
import DiskArbitration
import SwiftUI
import XCTest
@testable import Louppe

@MainActor
final class ConnectedDrivesTests: XCTestCase {
    func testOnlyKnownPhysicalExternalOrRemovableMediaAreSuggested() {
        XCTAssertTrue(eligible(internal: false, removable: false, transport: "USB"))
        XCTAssertTrue(eligible(internal: true, removable: true, transport: "Secure Digital"))
        XCTAssertTrue(eligible(internal: false, removable: false, transport: "PCI-Express"))
        XCTAssertFalse(eligible(internal: true, removable: false, transport: "Apple Fabric"))
        XCTAssertFalse(eligible(internal: false, removable: true, transport: "Disk Image"))
        XCTAssertFalse(eligible(internal: false, removable: false, transport: "USB", model: "Disk Image"))
        XCTAssertFalse(eligible(local: false, internal: false, removable: true, transport: "USB"))
        XCTAssertFalse(eligible(local: nil, internal: false, removable: true, transport: "USB"))
        XCTAssertFalse(eligible(internal: nil, removable: nil, transport: "USB"))
        XCTAssertFalse(eligible(internal: false, removable: true, transport: nil))
    }

    func testDiskArbitrationIdentityUsesMountedVolumeAndMediaUUIDs() throws {
        let mount = URL(fileURLWithPath: "/Volumes/Camera Card")
        let volume = try XCTUnwrap(CFUUIDCreate(kCFAllocatorDefault))
        let media = try XCTUnwrap(CFUUIDCreate(kCFAllocatorDefault))
        let identity = try XCTUnwrap(ConnectedDrive.ID.diskArbitrationIdentity(
            description: [
                kDADiskDescriptionVolumePathKey as String: mount,
                kDADiskDescriptionVolumeUUIDKey as String: volume,
                kDADiskDescriptionMediaUUIDKey as String: media,
            ], bsdName: "disk4s1", enumeratedURL: mount
        ))
        XCTAssertEqual(identity.volumeUUID, CFUUIDCreateString(kCFAllocatorDefault, volume) as String?)
        XCTAssertEqual(identity.mediaUUID, CFUUIDCreateString(kCFAllocatorDefault, media) as String?)
        XCTAssertEqual(identity.bsdName, "disk4s1")
        XCTAssertEqual(identity.mountURL, mount)
    }

    func testDiskArbitrationIdentityAcceptsOneKnownUUIDAndWholeMediaFallback() throws {
        let mount = URL(fileURLWithPath: "/Volumes/Camera Card")
        let uuid = try XCTUnwrap(CFUUIDCreate(kCFAllocatorDefault))
        let mounted = [kDADiskDescriptionVolumePathKey as String: mount] as [String: Any]
        let volumeOnly = ConnectedDrive.ID.diskArbitrationIdentity(
            description: mounted.merging([kDADiskDescriptionVolumeUUIDKey as String: uuid]) { _, new in new },
            bsdName: "disk4s1", enumeratedURL: mount
        )
        XCTAssertNotNil(volumeOnly)
        XCTAssertNil(volumeOnly?.mediaUUID)
        let mediaOnly = ConnectedDrive.ID.diskArbitrationIdentity(
            description: mounted,
            wholeDescription: [kDADiskDescriptionMediaUUIDKey as String: uuid],
            bsdName: "disk4s1", enumeratedURL: mount
        )
        XCTAssertNotNil(mediaOnly)
        XCTAssertNil(mediaOnly?.volumeUUID)
        XCTAssertEqual(mediaOnly?.mediaUUID, CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?)
    }

    func testDiskArbitrationIdentityRejectsMissingInvalidOrUnmountedMetadata() throws {
        let mount = URL(fileURLWithPath: "/Volumes/Camera Card")
        let uuid = try XCTUnwrap(CFUUIDCreate(kCFAllocatorDefault))
        var description: [String: Any] = [kDADiskDescriptionVolumePathKey as String: mount]
        XCTAssertNil(ConnectedDrive.ID.diskArbitrationIdentity(
            description: description, bsdName: "disk4s1", enumeratedURL: mount
        ))
        description[kDADiskDescriptionVolumeUUIDKey as String] = "not a DA UUID"
        XCTAssertNil(ConnectedDrive.ID.diskArbitrationIdentity(
            description: description, bsdName: "disk4s1", enumeratedURL: mount
        ))
        description[kDADiskDescriptionVolumeUUIDKey as String] = uuid
        XCTAssertNil(ConnectedDrive.ID.diskArbitrationIdentity(
            description: description, bsdName: "", enumeratedURL: mount
        ))
        description[kDADiskDescriptionVolumePathKey as String] = nil
        XCTAssertNil(ConnectedDrive.ID.diskArbitrationIdentity(
            description: description, bsdName: "disk4s1", enumeratedURL: mount
        ))
        description[kDADiskDescriptionVolumePathKey as String] = URL(fileURLWithPath: "/Volumes/Replacement")
        XCTAssertNil(ConnectedDrive.ID.diskArbitrationIdentity(
            description: description, bsdName: "disk4s1", enumeratedURL: mount
        ))
        description[kDADiskDescriptionVolumePathKey as String] = URL(string: "https://example.invalid/card")!
        XCTAssertNil(ConnectedDrive.ID.diskArbitrationIdentity(
            description: description, bsdName: "disk4s1", enumeratedURL: mount
        ))
    }

    func testCapacityKeepsMissingInvalidAndZeroValuesDistinct() {
        XCTAssertEqual(drive(available: nil, total: nil).capacityDescription, "Capacity unavailable")
        XCTAssertTrue(drive(available: nil).capacityDescription.contains("Available space unknown"))
        XCTAssertTrue(drive(available: 0).capacityDescription.contains("available of"))
        XCTAssertFalse(drive(available: 0).capacityDescription.contains("unknown"))
        XCTAssertTrue(drive(available: -1).capacityDescription.contains("Available space unknown"))
        XCTAssertTrue(drive(available: 20, total: 10).capacityDescription.contains("Available space unknown"))
        XCTAssertTrue(drive(available: 10, total: nil).capacityDescription.contains("Capacity unknown"))
        XCTAssertEqual(drive(available: nil, total: 0).capacityDescription, "Capacity unavailable")
        XCTAssertTrue(drive(available: 32_000_000_000, total: 128_000_000_000)
            .capacityDescription.contains("32 GB available of 128 GB"))
    }

    func testFullSnapshotKeepsEveryDistinctDriveBeyondFiveAndOpensLastDrive() async throws {
        let allDrives = (0..<12).map { index in
            ConnectedDrive(
                id: .init(
                    volumeUUID: "fixture-volume-\(index)",
                    mediaUUID: "fixture-media-\(index)",
                    bsdName: "disk\(20 + index)s1",
                    mountURL: URL(fileURLWithPath: "/Volumes/Card-\(index)")
                ),
                // Separate volumes may share their user-visible label.
                name: index.isMultiple(of: 2) ? "Camera Card" : "Travel SSD",
                availableBytes: index.isMultiple(of: 3) ? nil : 32_000_000_000,
                totalBytes: 128_000_000_000,
                isRemovable: index.isMultiple(of: 2)
            )
        }
        let model = ConnectedDrivesStore { allDrives }
        model.start()
        defer { model.stop() }
        try await eventually { model.drives.count == allDrives.count }
        XCTAssertEqual(Set(model.drives.map(\.id)), Set(allDrives.map(\.id)))
        XCTAssertEqual(model.drives.filter { $0.name == "Camera Card" }.count, 6)
        let lastDrive = try XCTUnwrap(allDrives.last)
        let directory = await model.directoryForOpening(lastDrive)
        XCTAssertEqual(directory, lastDrive.url)
        XCTAssertEqual(model.drives.count, 12, "activation revalidation must preserve the full list")
    }

    func testUnmountImmediatelyRemovesRowAndLateSnapshotCannotRestoreIt() async throws {
        let reader = ControlledDriveReader()
        let model = ConnectedDrivesStore { await reader.read() }
        let card = drive()
        model.start()
        defer { model.stop() }
        try await respond(reader, request: 0, with: [card])
        try await eventually { model.drives == [card] }
        model.refresh()
        try await waitForRequest(reader, 1)
        model.mountedVolumesChanged(unmountedURL: card.url)
        XCTAssertTrue(model.drives.isEmpty)
        await reader.complete(1, with: [card])
        try await respond(reader, request: 2, with: [])
        try await eventually { model.drives.isEmpty }
        let unavailable = await model.directoryForOpening(card)
        XCTAssertNil(unavailable)
    }

    func testStopAndRestartDiscardsSuspendedRefreshAndLoadsAgain() async throws {
        let reader = ControlledDriveReader()
        let model = ConnectedDrivesStore { await reader.read() }
        let oldCard = drive(uuid: "old")
        let newCard = drive(uuid: "new")
        model.start()
        defer { model.stop() }
        try await waitForRequest(reader, 0)
        model.stop()
        model.start()
        await reader.complete(0, with: [oldCard])
        try await waitForRequest(reader, 1)
        XCTAssertTrue(model.drives.isEmpty)
        await reader.complete(1, with: [newCard])
        try await eventually { model.drives == [newCard] }
    }

    func testReplacementAtSameMountPathDoesNotOpenOldCard() async throws {
        let reader = ControlledDriveReader()
        let model = ConnectedDrivesStore { await reader.read() }
        let oldCard = drive(uuid: "old-card")
        let replacement = drive(uuid: "new-card")
        model.start()
        defer { model.stop() }
        try await respond(reader, request: 0, with: [oldCard])
        try await eventually { model.drives == [oldCard] }
        let open = Task { await model.directoryForOpening(oldCard) }
        try await respond(reader, request: 1, with: [replacement])
        let directory = await open.value
        XCTAssertNil(directory)
        XCTAssertEqual(model.drives, [replacement])
        XCTAssertNotNil(model.statusMessage)
    }

    func testReplacementMediaWithSameVolumeUUIDBSDNameAndPathRejectsStaleClick() async throws {
        let reader = ControlledDriveReader()
        let model = ConnectedDrivesStore { await reader.read() }
        let oldCard = drive(uuid: "cloned-volume", mediaUUID: "old-media")
        let replacement = drive(uuid: "cloned-volume", mediaUUID: "new-media")
        XCTAssertEqual(oldCard.id.bsdName, replacement.id.bsdName)
        XCTAssertEqual(oldCard.url, replacement.url)
        model.start()
        defer { model.stop() }
        try await respond(reader, request: 0, with: [oldCard])
        try await eventually { model.drives == [oldCard] }
        let open = Task { await model.directoryForOpening(oldCard) }
        try await respond(reader, request: 1, with: [replacement])
        let directory = await open.value
        XCTAssertNil(directory)
        XCTAssertEqual(model.drives, [replacement])
        XCTAssertNotNil(model.statusMessage)
    }

    func testLateRefreshCannotReplaceNewerValidatedSnapshot() async throws {
        let reader = ControlledDriveReader()
        let model = ConnectedDrivesStore { await reader.read() }
        let old = drive(available: 100)
        let fresh = drive(available: 50)
        model.start()
        defer { model.stop() }
        try await respond(reader, request: 0, with: [old])
        try await eventually { model.drives == [old] }
        model.refresh()
        try await waitForRequest(reader, 1)
        let open = Task { await model.directoryForOpening(old) }
        try await respond(reader, request: 2, with: [fresh])
        let directory = await open.value
        XCTAssertEqual(directory, old.url)
        XCTAssertEqual(model.drives, [fresh])
        await reader.complete(1, with: [old])
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.drives, [fresh])
    }

    func testMountChangeDuringClickInvalidatesOpening() async throws {
        let reader = ControlledDriveReader()
        let model = ConnectedDrivesStore { await reader.read() }
        let card = drive()
        model.start()
        defer { model.stop() }
        try await respond(reader, request: 0, with: [card])
        try await eventually { model.drives == [card] }
        let open = Task { await model.directoryForOpening(card) }
        try await waitForRequest(reader, 1)
        model.mountedVolumesChanged(unmountedURL: card.url)
        await reader.complete(1, with: [card])
        let directory = await open.value
        XCTAssertNil(directory)
        XCTAssertTrue(model.drives.isEmpty)
        try await respond(reader, request: 2, with: [])
    }

    func testStopAndRestartDoesNotLetOldClickClearNewClick() async throws {
        let reader = ControlledDriveReader()
        let model = ConnectedDrivesStore { await reader.read() }
        let card = drive()
        model.start()
        defer { model.stop() }
        try await respond(reader, request: 0, with: [card])
        try await eventually { model.drives == [card] }
        let oldOpen = Task { await model.directoryForOpening(card) }
        try await waitForRequest(reader, 1)
        model.stop()
        XCTAssertNil(model.openingDriveID)
        model.start()
        try await respond(reader, request: 2, with: [card])
        try await eventually { model.drives == [card] }
        let newOpen = Task { await model.directoryForOpening(card) }
        try await waitForRequest(reader, 3)
        await reader.complete(1, with: [card])
        let oldResult = await oldOpen.value
        XCTAssertNil(oldResult)
        XCTAssertEqual(model.openingDriveID, card.id)
        await reader.complete(3, with: [card])
        let newResult = await newOpen.value
        XCTAssertEqual(newResult, card.url)
        XCTAssertNil(model.openingDriveID)
    }

    func testHostedDriveRowsExposeCapacityAndNativeChooseAction() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let card = drive()
        let unknown = drive(uuid: "ssd", name: "Travel SSD", available: nil, total: nil)
        let model = ConnectedDrivesStore { [card, unknown] }
        model.start()
        defer { model.stop() }
        try await eventually { model.drives.count == 2 }
        var chosen: URL?
        let content = ConnectedDrivesView(drives: model) { chosen = $0 }
            .padding(24)
            .frame(width: 420, height: 220)
            .background(Color.appBackground)
            .accessibilityElement(children: .contain)
        let host = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 420, height: 220),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Connected Drives — Test Preview"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI may omit its in-process AX tree in an XCTest runner even
        // while the native hosted window is visible to system accessibility.
        // A test-only pause allows computer-use inspection without app flags.
        if let seconds = ProcessInfo.processInfo.environment["LOUPPE_DRIVE_PREVIEW_SECONDS"]
            .flatMap(Double.init), seconds > 0 {
            try await Task.sleep(for: .seconds(min(seconds, 60)))
        }
        guard !(host.accessibilityChildren() ?? []).isEmpty else {
            throw XCTSkip("SwiftUI's XCTest host has no in-process accessibility children; verify the native test preview with computer use.")
        }
        var cardButton: (any NSAccessibilityProtocol)?
        try await eventually {
            cardButton = self.accessibilityElements(host).first {
                ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == "Choose a media folder on Camera Card"
            }
            return cardButton != nil
        }
        XCTAssertEqual(cardButton?.accessibilityValue() as? String, card.capacityDescription)
        let unknownButton = accessibilityElements(host).first {
            ($0.accessibilityLabel() ?? $0.accessibilityTitle()) == "Choose a media folder on Travel SSD"
        }
        XCTAssertEqual(unknownButton?.accessibilityValue() as? String, "Capacity unavailable")
        XCTAssertTrue(cardButton?.accessibilityPerformPress() == true)
        try await eventually { chosen == card.url }
    }

    private func accessibilityElements(_ root: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 20, let accessible = root as? any NSAccessibilityProtocol else { return [] }
        let children = accessible.accessibilityChildren() ?? []
        return [accessible] + children.flatMap { accessibilityElements($0, depth: depth + 1) }
    }

    private func eligible(
        local: Bool? = true, internal isInternal: Bool?, removable: Bool?,
        transport: String?, model: String? = nil
    ) -> Bool {
        ConnectedDriveEligibility(
            isLocal: local, isInternal: isInternal, isRemovable: removable,
            deviceProtocol: transport, deviceModel: model
        ).isEligible
    }

    private func drive(
        uuid: String = "camera-card", mediaUUID: String? = "camera-media",
        name: String = "Camera Card",        available: Int64? = 32_000_000_000, total: Int64? = 128_000_000_000
    ) -> ConnectedDrive {
        ConnectedDrive(
            id: .init(volumeUUID: uuid, mediaUUID: mediaUUID,
                      bsdName: "disk4s1", mountURL: URL(fileURLWithPath: "/Volumes/Camera Card")),
            name: name, availableBytes: available, totalBytes: total, isRemovable: true
        )
    }

    private func respond(
        _ reader: ControlledDriveReader, request: Int, with drives: [ConnectedDrive]
    ) async throws {
        try await waitForRequest(reader, request)
        await reader.complete(request, with: drives)
    }

    private func waitForRequest(_ reader: ControlledDriveReader, _ request: Int) async throws {
        let deadline = Date().addingTimeInterval(3)
        while await !reader.hasRequest(request) {
            guard Date() < deadline else { throw TestFailure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { throw TestFailure.timeout }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum TestFailure: Error { case timeout }
}

private actor ControlledDriveReader {
    private var nextRequest = 0
    private var continuations: [Int: CheckedContinuation<[ConnectedDrive], Never>] = [:]

    func read() async -> [ConnectedDrive] {
        let request = nextRequest
        nextRequest += 1
        return await withCheckedContinuation { continuations[request] = $0 }
    }

    func hasRequest(_ request: Int) -> Bool { continuations[request] != nil }

    func complete(_ request: Int, with drives: [ConnectedDrive]) {
        continuations.removeValue(forKey: request)?.resume(returning: drives)
    }
}
