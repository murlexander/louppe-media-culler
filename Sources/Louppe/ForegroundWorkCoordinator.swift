import Foundation

/// A scheduling hint between existing bounded work units, never an I/O lane or
/// save/recovery authority. One timer serves all suspended admissions; interaction
/// does not publish observable UI state or enqueue a task per scroll event.
final class ForegroundWorkCoordinator: @unchecked Sendable {
    static let shared = ForegroundWorkCoordinator()

    final class Demand: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: ForegroundWorkCoordinator?

        fileprivate init(owner: ForegroundWorkCoordinator) { self.owner = owner }

        func finish() {
            let owner = lock.withLock {
                let owner = self.owner
                self.owner = nil
                return owner
            }
            owner?.endForegroundDemand()
        }

        deinit { finish() }
    }

    private struct Waiter {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private let quietInterval: Duration
    private let maximumDeferral: Duration
    private let waitingLimit: Int
    private let timer: DispatchSourceTimer
    private var quietUntil = ContinuousClock.now
    private var foregroundDemands = 0
    private var waiters: [UUID: Waiter] = [:]

    init(quietInterval: Duration = .milliseconds(180),
         maximumDeferral: Duration = .milliseconds(750), waitingLimit: Int = 128) {
        precondition(quietInterval >= .zero && maximumDeferral > .zero && waitingLimit > 0)
        self.quietInterval = quietInterval
        self.maximumDeferral = maximumDeferral
        self.waitingLimit = waitingLimit
        timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "louppe.background-admission", qos: .userInitiated))
        timer.schedule(deadline: .distantFuture)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.activate()
    }

    deinit { timer.cancel() }

    func noteInteraction() {
        lock.withLock {
            quietUntil = ContinuousClock.now.advanced(by: quietInterval)
            scheduleLocked()
        }
    }

    func beginForegroundDemand() -> Demand {
        lock.withLock {
            foregroundDemands += 1
            scheduleLocked()
        }
        return Demand(owner: self)
    }

    private func endForegroundDemand() {
        lock.withLock { foregroundDemands -= 1 }
        drain()
    }

    /// Capture deferredSince once per pending unit, then reschedule on false.
    /// Synchronous workers must keep their own cancellation and pacing policy;
    /// this method never sleeps, spins, or reads the filesystem.
    func shouldAdmitBackgroundWork(deferredSince: ContinuousClock.Instant) -> Bool {
        lock.withLock {
            let now = ContinuousClock.now
            return now >= deferredSince.advanced(by: maximumDeferral)
                || (foregroundDemands == 0 && now >= quietUntil)
        }
    }

    /// Cancellation retires only this admission. A fixed per-call deadline
    /// guarantees progress under sustained navigation or slow foreground I/O.
    /// Overflow bypasses the hint; existing workers still own resource bounds.
    func waitForBackgroundAdmission() async -> Bool {
        let id = UUID()
        let deadline = ContinuousClock.now.advanced(by: maximumDeferral)
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(returning: false)
                    return
                }
                let now = ContinuousClock.now
                if now >= deadline || (foregroundDemands == 0 && now >= quietUntil)
                    || waiters.count >= waitingLimit {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                waiters[id] = Waiter(deadline: deadline, continuation: continuation)
                scheduleLocked()
                lock.unlock()
            }
        } onCancel: { [self] in
            let waiter = lock.withLock {
                let waiter = waiters.removeValue(forKey: id)
                scheduleLocked()
                return waiter
            }
            waiter?.continuation.resume(returning: false)
        }
        return admitted && !Task.isCancelled
    }

    private func drain() {
        let ready: [Waiter] = lock.withLock {
            let now = ContinuousClock.now
            let quiet = foregroundDemands == 0 && now >= quietUntil
            let ids = waiters.compactMap { quiet || now >= $0.value.deadline ? $0.key : nil }
            let ready = ids.compactMap { waiters.removeValue(forKey: $0) }
            scheduleLocked()
            return ready
        }
        for waiter in ready { waiter.continuation.resume(returning: true) }
    }

    /// Called under lock. Updating this one-shot deadline replaces the previous
    /// wakeup rather than retaining a closure for every interaction pulse.
    private func scheduleLocked() {
        guard let deadline = waiters.values.lazy.map(\.deadline).min() else {
            timer.schedule(deadline: .distantFuture)
            return
        }
        let next = foregroundDemands == 0 ? min(deadline, quietUntil) : deadline
        let delay = max(.zero, ContinuousClock.now.duration(to: next)).components
        let seconds = Double(delay.seconds) + Double(delay.attoseconds) / 1e18
        timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(2))
    }

    #if DEBUG
    var waitingCountForTesting: Int { lock.withLock { waiters.count } }
    var foregroundDemandCountForTesting: Int { lock.withLock { foregroundDemands } }
    #endif
}
