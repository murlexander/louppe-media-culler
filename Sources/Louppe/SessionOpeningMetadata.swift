import Foundation

/// One independently validated observation. Parent coalesces these on its
/// existing publication timer and rejects obsolete scan generations first.
struct OpeningMetadataUpdate: Sendable {
    let item: PhotoItem
}

/// One per opening. A distant current-photo jump can promote its unclaimed
/// metadata slot without changing inventory order or creating another worker.
final class OpeningMetadataInterest: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String?

    func setCurrentPhysicalFileID(_ id: String?) {
        lock.lock()
        current = id
        lock.unlock()
    }

    var currentPhysicalFileID: String? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}


/// One coalescing buffer per opening generation. Scanner workers never enqueue
/// a UI task per file. Each complete inventory item contributes at most one slot.
final class SessionOpeningMetadataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: OpeningMetadataUpdate] = [:]

    func append(_ update: OpeningMetadataUpdate) {
        lock.withLock { pending[update.item.id] = update }
    }

    func take() -> [OpeningMetadataUpdate] {
        lock.withLock {
            let result = Array(pending.values)
            pending.removeAll(keepingCapacity: true)
            return result
        }
    }
}
