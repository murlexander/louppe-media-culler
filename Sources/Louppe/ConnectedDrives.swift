import AppKit
import DiskArbitration
import Foundation

/// A read-only snapshot of a mounted physical drive. Its mount identity prevents
/// a newly inserted card at the same pathname from inheriting an old button.
struct ConnectedDrive: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable {
        let volumeUUID: String?
        let mediaUUID: String?
        let bsdName: String
        let mountURL: URL

        /// Before folder access, use DA's mounted identity rather than reading
        /// filesystem metadata. Unknown identity leaves the normal chooser available.
        static func diskArbitrationIdentity(
            description: [String: Any],
            wholeDescription: [String: Any] = [:],
            bsdName: String,
            enumeratedURL: URL
        ) -> Self? {
            guard !bsdName.isEmpty,
                  enumeratedURL.isFileURL,
                  let mountedURL = description[kDADiskDescriptionVolumePathKey as String] as? URL,
                  mountedURL.isFileURL,
                  mountedURL.standardizedFileURL == enumeratedURL.standardizedFileURL else {
                return nil
            }
            let volumeUUID = uuidString(description[kDADiskDescriptionVolumeUUIDKey as String])
            let mediaUUID = uuidString(description[kDADiskDescriptionMediaUUIDKey as String])
                ?? uuidString(wholeDescription[kDADiskDescriptionMediaUUIDKey as String])
            guard volumeUUID != nil || mediaUUID != nil else { return nil }
            return Self(
                volumeUUID: volumeUUID, mediaUUID: mediaUUID,
                bsdName: bsdName, mountURL: mountedURL.standardizedFileURL
            )
        }

        private static func uuidString(_ value: Any?) -> String? {
            guard let value,
                  CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID(),
                  let string = CFUUIDCreateString(kCFAllocatorDefault, (value as! CFUUID)) else {
                return nil
            }
            return string as String
        }
    }

    let id: ID
    let name: String
    let availableBytes: Int64?
    let totalBytes: Int64?
    let isRemovable: Bool

    var url: URL { id.mountURL }

    var capacityDescription: String {
        let available = availableBytes.flatMap { $0 >= 0 ? $0 : nil }
        let total = totalBytes.flatMap { $0 > 0 ? $0 : nil }
        // An inconsistent filesystem answer is unknown, never invented zero.
        if let available, let total, available <= total {
            return L10n.text("\(Self.format(available)) available of \(Self.format(total))")
        }
        if let total { return L10n.text("\(Self.format(total)) total · Available space unknown") }
        if let available { return L10n.text("\(Self.format(available)) available · Capacity unknown") }
        return L10n.text("Capacity unavailable")
    }

    private static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: bytes)
    }
}

/// Eligibility is separate from I/O so uncertainty never turns an internal,
/// network, or virtual volume into a suggested source drive.
struct ConnectedDriveEligibility: Sendable {
    let isLocal: Bool?
    let isInternal: Bool?
    let isRemovable: Bool?
    let deviceProtocol: String?
    let deviceModel: String?

    var isEligible: Bool {
        guard isLocal == true,
              isInternal == false || isRemovable == true,
              let deviceProtocol else { return false }
        let transport = deviceProtocol.lowercased()
        let model = deviceModel?.lowercased() ?? ""
        guard !transport.contains("virtual"), !transport.contains("image"),
              !model.contains("disk image") else { return false }
        // Known physical transports include internal card readers; DA's
        // removable flag above distinguishes their card from the system disk.
        return ["usb", "secure digital", "sd", "firewire", "thunderbolt",
                "pci-express", "pci", "sata", "ata", "scsi", "sas", "nvme"]
            .contains(transport)
    }
}

/// One serial worker, no recursive scan and no task per volume. All Disk
/// Arbitration and filesystem resource reads stay outside the main actor.
actor ConnectedDriveReader {
    func mountedDrives() -> [ConnectedDrive] {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let volumes = FileManager().mountedVolumeURLs(
                includingResourceValuesForKeys: nil,
                options: [.skipHiddenVolumes]
              ) else { return [] }
        var result: [ConnectedDrive] = []
        for url in volumes {
            guard let disk = DADiskCreateFromVolumePath(
                kCFAllocatorDefault, session, url as CFURL
            ), let description = DADiskCopyDescription(disk) as? [String: Any] else {
                continue
            }
            let wholeDescription = DADiskCopyWholeDisk(disk)
                .flatMap { DADiskCopyDescription($0) as? [String: Any] } ?? [:]
            func value(_ key: CFString) -> Any? {
                description[key as String] ?? wholeDescription[key as String]
            }
            let eligibility = ConnectedDriveEligibility(
                isLocal: (value(kDADiskDescriptionVolumeNetworkKey) as? Bool).map { !$0 },
                isInternal: value(kDADiskDescriptionDeviceInternalKey) as? Bool,
                isRemovable: value(kDADiskDescriptionMediaRemovableKey) as? Bool,
                deviceProtocol: value(kDADiskDescriptionDeviceProtocolKey) as? String,
                deviceModel: value(kDADiskDescriptionDeviceModelKey) as? String
            )
            guard eligibility.isEligible,
                  let bsdName = DADiskGetBSDName(disk),
                  let identity = ConnectedDrive.ID.diskArbitrationIdentity(
                    description: description, wholeDescription: wholeDescription,
                    bsdName: String(cString: bsdName), enumeratedURL: url
                  ) else { continue }
            // Only capacity is read before the picker, after physical eligibility
            // and DA identity checks. A fresh URL avoids cached capacity values.
            let freshURL = URL(fileURLWithPath: identity.mountURL.path, isDirectory: true)
            let values = try? freshURL.resourceValues(forKeys: [
                .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
            ])
            // Discard a replacement or unmount that occurred during capacity I/O.
            guard let currentDisk = DADiskCreateFromVolumePath(
                kCFAllocatorDefault, session, freshURL as CFURL
            ), let currentDescription = DADiskCopyDescription(currentDisk) as? [String: Any],
               let currentBSDName = DADiskGetBSDName(currentDisk),
               ConnectedDrive.ID.diskArbitrationIdentity(
                description: currentDescription,
                wholeDescription: DADiskCopyWholeDisk(currentDisk)
                    .flatMap { DADiskCopyDescription($0) as? [String: Any] } ?? [:],
                bsdName: String(cString: currentBSDName), enumeratedURL: freshURL
               ) == identity else { continue }
            let name = value(kDADiskDescriptionVolumeNameKey) as? String
                ?? url.lastPathComponent
            result.append(ConnectedDrive(
                id: identity,
                name: name,
                availableBytes: values?.volumeAvailableCapacity.map(Int64.init),
                totalBytes: values?.volumeTotalCapacity.map(Int64.init),
                isRemovable: eligibility.isRemovable == true
            ))
        }
        return result.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame
                ? $0.url.path < $1.url.path : comparison == .orderedAscending
        }
    }
}

/// Visible only on the start screen. Mount changes invalidate pending snapshots
/// and clicks; capacity polling stops as soon as a review session opens.
@MainActor
final class ConnectedDrivesStore: NSObject, ObservableObject {
    typealias Loader = @Sendable () async -> [ConnectedDrive]

    @Published private(set) var drives: [ConnectedDrive] = []
    @Published private(set) var openingDriveID: ConnectedDrive.ID?
    @Published private(set) var statusMessage: String?

    private let loader: Loader
    private let workspaceNotifications: NotificationCenter
    private var isActive = false
    private var topologyRevision: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var needsRefresh = false
    private var requestSequence: UInt64 = 0
    private var appliedSequence: UInt64 = 0
    private var openingRequest: UUID?

    init(loader: Loader? = nil) {
        let reader = ConnectedDriveReader()
        self.loader = loader ?? { await reader.mountedDrives() }
        workspaceNotifications = NSWorkspace.shared.notificationCenter
        super.init()
    }

    deinit {
        refreshTask?.cancel()
        pollTask?.cancel()
        workspaceNotifications.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard !isActive else { return }
        isActive = true
        topologyRevision &+= 1
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            workspaceNotifications.addObserver(
                self, selector: #selector(volumeChanged(_:)), name: name, object: nil
            )
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationActivated),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        isActive = false
        topologyRevision &+= 1
        needsRefresh = false
        pollTask?.cancel()
        pollTask = nil
        workspaceNotifications.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        drives = []
        statusMessage = nil
        openingRequest = nil
        openingDriveID = nil
    }

    func refresh() {
        guard isActive else { return }
        needsRefresh = true
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            while self.isActive, self.needsRefresh {
                self.needsRefresh = false
                let revision = self.topologyRevision
                self.requestSequence &+= 1
                let sequence = self.requestSequence
                let snapshot = await self.loader()
                guard self.isActive else { break }
                if self.topologyRevision == revision {
                    self.apply(snapshot, sequence: sequence)
                }
            }
            self.refreshTask = nil
        }
    }

    /// Recheck against a fresh mounted-volume snapshot before presenting the
    /// chooser. Opening still goes through SessionStore's normal user-selected
    /// folder and security-scoped bookmark flow.
    func directoryForOpening(_ drive: ConnectedDrive) async -> URL? {
        guard isActive, openingDriveID == nil,
              drives.contains(where: { $0.id == drive.id }) else { return nil }
        let request = UUID()
        openingRequest = request
        openingDriveID = drive.id
        statusMessage = nil
        defer {
            if openingRequest == request {
                openingRequest = nil
                openingDriveID = nil
            }
        }
        let revision = topologyRevision
        requestSequence &+= 1
        let sequence = requestSequence
        let snapshot = await loader()
        guard isActive, openingRequest == request else { return nil }
        guard revision == topologyRevision else {
            statusMessage = L10n.text("Drive availability changed. Choose a connected drive again.")
            refresh()
            return nil
        }
        apply(snapshot, sequence: sequence)
        guard let current = snapshot.first(where: { $0.id == drive.id }),
              drives.contains(where: { $0.id == drive.id }) else {
            statusMessage = L10n.text("“\(drive.name)” is no longer available. Reconnect it and try again.")
            return nil
        }
        return current.url
    }

    private func apply(_ snapshot: [ConnectedDrive], sequence: UInt64) {
        guard sequence >= appliedSequence else { return }
        appliedSequence = sequence
        drives = snapshot
    }

    /// This synchronous state boundary also makes late-enumeration and mount
    /// replacement races testable without a physical card reader.
    func mountedVolumesChanged(unmountedURL: URL? = nil) {
        guard isActive else { return }
        topologyRevision &+= 1
        statusMessage = nil
        if let unmountedURL {
            drives.removeAll { $0.url == unmountedURL }
        }
        refresh()
    }

    @objc private func volumeChanged(_ notification: Notification) {
        let unmounted = notification.name == NSWorkspace.didUnmountNotification
            ? notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL : nil
        mountedVolumesChanged(unmountedURL: unmounted)
    }

    @objc private func applicationActivated() { refresh() }
}
