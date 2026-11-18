import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The native drag source for originals. It allows only Copy in every
/// context, so Finder copies even on the same volume and the Trash (which
/// requires Delete) refuses the drop. It never moves, deletes or writes files.
@MainActor
final class OriginalFileDragSource: NSObject, NSDraggingSource {
    /// The one live outbound session. Louppe's own window refuses it as a
    /// folder drop instead of trying to open a photo as a folder.
    private(set) static weak var active: OriginalFileDragSource?
    static var hasActiveSession: Bool { active != nil }

    let targets: OriginalFileTargets
    /// Keeps the source folder's read scope alive until the drag ends.
    private var readToken: MediaReadAccess.Token?

    init(targets: OriginalFileTargets, readAccess: MediaReadAccess?) {
        self.targets = targets
        readToken = readAccess?.begin()
        super.init()
    }

    /// The whole contract: Copy, inside or outside Louppe.
    nonisolated static func operationMask(for context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication, .withinApplication: return .copy
        @unknown default: return .copy
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        Self.operationMask(for: context)
    }

    /// Command/Option cannot widen the mask into Move or Link.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        finish()
    }

    fileprivate func activate() { Self.active = self }

    /// Releases the read scope; called by AppKit at the end of the session.
    func finish() {
        if Self.active === self { Self.active = nil }
        readToken = nil
        retainedForSession = nil
    }

    /// AppKit keeps the source only weakly in some paths; hold it until the end.
    fileprivate var retainedForSession: OriginalFileDragSource?
}

/// What one pointer surface can drag, resolved in memory at mouse-down.
struct OriginalFileDragPlan {
    let targets: OriginalFileTargets
    /// Source-view rectangle of the grabbed media, used for the drag image.
    let mediaFrame: CGRect
    /// Pixels already on screen for the grabbed item, if any.
    let leaderImage: NSImage?
    let readAccess: MediaReadAccess?
    /// Item thumbnails already in memory, by item index (never decoded here).
    let cachedImage: @MainActor (Int) -> NSImage?
    /// Rechecked at the drag threshold: same source, revision and mode.
    let isStillValid: @MainActor () -> Bool
}

/// Builds the pasteboard items: one file URL per physical original and a
/// bounded number of drag images regardless of selection size.
@MainActor
enum OriginalFileDragItems {
    static let maximumImages = 4
    static let maximumImageSide: CGFloat = 160
    static let stackOffset: CGFloat = 6

    static func make(for plan: OriginalFileDragPlan, targets: OriginalFileTargets,
                     grabPoint: CGPoint) -> [NSDraggingItem] {
        let leaderFrame = frame(for: plan.mediaFrame, grabPoint: grabPoint)
        // The leader first, then its neighbours in payload order.
        var imaged = [targets.leaderFileIndex]
        for fileIndex in targets.files.indices where imaged.count < maximumImages {
            if fileIndex != targets.leaderFileIndex { imaged.append(fileIndex) }
        }
        let leaderItem = targets.files[targets.leaderFileIndex].itemIndex
        var items = targets.files.map { file in
            // Every file shares the leader's frame; only the stack has pixels.
            let item = NSDraggingItem(pasteboardWriter: file.url as NSURL)
            item.draggingFrame = leaderFrame
            return item
        }
        for (rank, fileIndex) in imaged.enumerated() {
            let itemIndex = targets.files[fileIndex].itemIndex
            let image = (itemIndex == leaderItem ? plan.leaderImage : nil)
                ?? plan.cachedImage(itemIndex)
                ?? genericIcon
            let offset = CGFloat(rank) * stackOffset
            items[fileIndex].setDraggingFrame(leaderFrame.offsetBy(dx: offset, dy: offset), contents: image)
        }
        return items
    }

    /// The media rectangle scaled to a bounded drag image, keeping the
    /// grabbed point at the same relative position under the pointer.
    static func frame(for media: CGRect, grabPoint: CGPoint) -> CGRect {
        guard media.width > 0, media.height > 0 else {
            return CGRect(x: grabPoint.x - 32, y: grabPoint.y - 32, width: 64, height: 64)
        }
        let scale = min(1, maximumImageSide / max(media.width, media.height))
        let size = CGSize(width: media.width * scale, height: media.height * scale)
        let relativeX = min(max((grabPoint.x - media.minX) / media.width, 0), 1)
        let relativeY = min(max((grabPoint.y - media.minY) / media.height, 0), 1)
        return CGRect(x: grabPoint.x - relativeX * size.width,
                      y: grabPoint.y - relativeY * size.height,
                      width: size.width, height: size.height)
    }

    /// One shared icon for files without pixels in memory; no per-file lookup.
    static let genericIcon: NSImage = NSWorkspace.shared.icon(for: .image)
}

/// Starts the native session. Tests replace the starter so real pointer
/// routing can be verified offscreen without a global drag loop.
@MainActor
enum OriginalFileDragStarter {
    #if LOUPPE_TEST_SEAMS
    static var override: ((NSView, [NSDraggingItem], NSEvent, OriginalFileDragSource) -> Void)?
    #endif

    #if LOUPPE_TEST_SEAMS
    static var didPreventWindowOrdering: (() -> Void)?
    #endif

    static func begin(from view: NSView, items: [NSDraggingItem], event: NSEvent,
                      source: OriginalFileDragSource) {
        source.retainedForSession = source
        source.activate()
        // The source views delay window ordering on mouse-down; a drag keeps
        // an inactive Louppe window behind its drop target, as Finder does.
        NSApp.preventWindowOrdering()
        #if LOUPPE_TEST_SEAMS
        didPreventWindowOrdering?()
        #endif
        #if LOUPPE_TEST_SEAMS
        if let override { override(view, items, event, source); return }
        #endif
        let session = view.beginDraggingSession(with: items, event: event, source: source)
        if source.targets.files.indices.contains(source.targets.leaderFileIndex) {
            session.draggingLeaderIndex = source.targets.leaderFileIndex
        }
        session.animatesToStartingPositionsOnCancelOrFail =
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// Pointer arming shared by Grid media, Browser tiles and Gallery Fit/Phone
/// photos. Mouse-down only records the event and a deferred resolver, so a
/// plain click resolves nothing and reads no files. Past 8 points the
/// originals are resolved and one cancellable off-main identity sweep runs
/// on bounded lanes. The session begins on the next drag event or, if the
/// pointer is held still, as soon as the sweep ends. At most one sweep reads
/// files at a time and it ends with its gesture: a cancelled sweep stops at
/// the next file, but a read blocked on a stalled volume can't be
/// interrupted, so a newer gesture waits for it before reading anything.
/// Only the newest waiting gesture survives.
@MainActor
final class OriginalFileDragArm {
    typealias Resolver = @MainActor () -> OriginalFileDragPlan?
    static let thresholdSquared: CGFloat = 8 * 8
    private static var activeSweep: OriginalFileSweepCancellation?
    /// The latest sweep's off-main work, including its wait for the one
    /// before; it ends only after that sweep's reads have returned.
    private static var sweepIO: Task<OriginalFileTargets?, Never>?

    /// Starting a session after release would drop at the pointer at once,
    /// so a completed sweep starts one only while the button is still down.
    static var isPointerHeld: @MainActor () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

    #if LOUPPE_TEST_SEAMS
    /// Replaces the per-file identity check; counts reads in tests.
    static var presenceCheckForTesting: (@Sendable (OriginalFileTarget) -> Bool)?
    #endif

    private var downPoint: CGPoint = .zero
    private var latestEvent: NSEvent?
    private var latestPoint: CGPoint = .zero
    private weak var sourceView: NSView?
    private var resolver: Resolver?
    private var plan: OriginalFileDragPlan?
    private var available: OriginalFileTargets?
    private var checkFinished = false
    private var check: Task<Void, Never>?
    private var sweep: OriginalFileSweepCancellation?
    private(set) var isArmed = false
    /// True once a session started from this gesture; mouse-up is then ignored.
    private(set) var didStart = false

    func arm(event: NSEvent, at point: CGPoint, resolve: Resolver?) {
        disarm()
        didStart = false
        guard let resolve else { return }
        downPoint = point
        latestEvent = event
        latestPoint = point
        resolver = resolve
        isArmed = true
    }

    func disarm() {
        sweep?.cancel()
        sweep = nil
        check?.cancel()
        check = nil
        latestEvent = nil
        sourceView = nil
        resolver = nil
        plan = nil
        available = nil
        checkFinished = false
        isArmed = false
    }

    private func beginSweep(for plan: OriginalFileDragPlan) {
        Self.activeSweep?.cancel()
        let cancellation = OriginalFileSweepCancellation()
        Self.activeSweep = cancellation
        sweep = cancellation
        let targets = plan.targets
        let token = plan.readAccess?.begin()
        var isPresent: (@Sendable (OriginalFileTarget) -> Bool)? = nil
        #if LOUPPE_TEST_SEAMS
        if let presenceCheckForTesting = Self.presenceCheckForTesting { isPresent = presenceCheckForTesting }
        #endif
        let check = isPresent
        let previous = Self.sweepIO
        let io = Task.detached(priority: .userInitiated) { () -> OriginalFileTargets? in
            // Earlier reads may still be blocked; never stack a second sweep.
            _ = await previous?.value
            return withExtendedLifetime(token) {
                guard !cancellation.isCancelled else { return nil }
                return targets.existing(isCancelled: { cancellation.isCancelled }, isPresent: check)
            }
        }
        Self.sweepIO = io
        self.check = Task { [weak self] in
            let present = await io.value
            if Self.activeSweep === cancellation { Self.activeSweep = nil }
            if Self.sweepIO == io { Self.sweepIO = nil }
            guard let self, !Task.isCancelled, !cancellation.isCancelled, self.isArmed else { return }
            self.available = present
            self.checkFinished = true
            guard present != nil else { self.isArmed = false; return }
            // A pointer held still after the threshold still gets its drag.
            if Self.isPointerHeld(), let view = self.sourceView { self.start(in: view) }
        }
    }

    /// Returns true when this drag event started a session.
    @discardableResult
    func dragged(_ event: NSEvent, to point: CGPoint, in view: NSView) -> Bool {
        guard isArmed, !didStart else { return false }
        let dx = point.x - downPoint.x
        let dy = point.y - downPoint.y
        guard dx * dx + dy * dy >= Self.thresholdSquared else { return false }
        latestEvent = event
        latestPoint = point
        sourceView = view
        guard plan != nil else {
            // First crossing: resolve now, never on mouse-down.
            guard let resolved = resolver?() else { disarm(); return false }
            plan = resolved
            beginSweep(for: resolved)
            return false
        }
        guard checkFinished else { return false }
        return start(in: view)
    }

    @discardableResult
    private func start(in view: NSView) -> Bool {
        guard isArmed, !didStart, let plan, let event = latestEvent else { return false }
        guard let targets = available, plan.isStillValid() else {
            disarm()
            return false
        }
        // The most recent drag event places the image under the pointer.
        let items = OriginalFileDragItems.make(for: plan, targets: targets, grabPoint: latestPoint)
        let source = OriginalFileDragSource(targets: targets, readAccess: plan.readAccess)
        didStart = true
        disarm()
        OriginalFileDragStarter.begin(from: view, items: items, event: event, source: source)
        return true
    }

    func mouseUp() {
        disarm()
    }

    #if LOUPPE_TEST_SEAMS
    func waitForExistenceCheckForTesting() async {
        await check?.value
    }
    var hasPendingSweepForTesting: Bool { sweep != nil }
    #endif
}

/// Supplies Gallery's fitted photo surface with its drag plan. Absent while
/// zoomed, for Photos sources and before the session is Ready.
struct OriginalFileDragProvider {
    let plan: @MainActor (_ mediaFrame: CGRect, _ leaderImage: NSImage?) -> OriginalFileDragPlan?
}

private struct OriginalFileDragProviderKey: EnvironmentKey {
    static let defaultValue: OriginalFileDragProvider? = nil
}

extension EnvironmentValues {
    var originalFileDragProvider: OriginalFileDragProvider? {
        get { self[OriginalFileDragProviderKey.self] }
        set { self[OriginalFileDragProviderKey.self] = newValue }
    }
}

extension SessionStore {
    /// A drag plan for the item at `index`, or nil when it cannot drag.
    func originalFileDragPlan(index: Int, revision: PhotoContentRevision, mediaFrame: CGRect,
                              leaderImage: NSImage? = nil,
                              additionalCheck: @escaping @MainActor () -> Bool = { true })
        -> OriginalFileDragPlan? {
        guard canDragOriginal(at: index),
              let targets = originalFileTargets(for: .item(index: index, revision: revision))
        else { return nil }
        let source = sourceFolder
        return OriginalFileDragPlan(
            targets: targets,
            mediaFrame: mediaFrame,
            leaderImage: leaderImage,
            readAccess: mediaReadAccess,
            cachedImage: { [weak self] itemIndex in
                guard let self, self.items.indices.contains(itemIndex) else { return nil }
                return ImagePipeline.shared.cachedThumbnail(for: self.items[itemIndex])
            },
            isStillValid: { [weak self] in
                guard let self else { return false }
                return self.sourceFolder == source
                    && self.canDragOriginal(at: index)
                    && self.items[index].contentRevision == revision
                    && additionalCheck()
            }
        )
    }
}
