import Foundation
import AVFoundation

/// NotificationCenter's opaque observer token is not Sendable, while a
/// main-actor class's deinitializer is nonisolated. Keep each token behind a
/// lock-protected Sendable owner so cleanup is valid from either boundary.
private final class NotificationObserverBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    func replace(with newToken: NSObjectProtocol) {
        lock.lock()
        let oldToken = token
        token = newToken
        lock.unlock()
        if let oldToken { NotificationCenter.default.removeObserver(oldToken) }
    }

    func remove() {
        lock.lock()
        let oldToken = token
        token = nil
        lock.unlock()
        if let oldToken { NotificationCenter.default.removeObserver(oldToken) }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }
}

/// Owns AVPlayer's opaque periodic-time token outside main-actor isolation so
/// it can always be removed safely during controller teardown.
private final class PlayerTimeObserverBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var player: AVPlayer?
    private var token: Any?

    func store(player: AVPlayer, token: Any) {
        lock.lock()
        let oldPlayer = self.player
        let oldToken = self.token
        self.player = player
        self.token = token
        lock.unlock()
        if let oldToken { oldPlayer?.removeTimeObserver(oldToken) }
    }

    func remove() {
        lock.lock()
        let oldPlayer = player
        let oldToken = token
        player = nil
        token = nil
        lock.unlock()
        if let oldToken { oldPlayer?.removeTimeObserver(oldToken) }
    }

    deinit { remove() }
}

/// One native player per session. Grid and Gallery attach different native
/// views to it, preserving position when the user switches view modes while
/// ensuring audio and video can never play over one another.
@MainActor
final class VideoPlaybackController: ObservableObject {
    let player = AVPlayer()

    static let availablePlaybackRates: [Double] = [1, 1.5, 2, 2.5]
    private static let maximumRememberedPositions = 128

    @Published private(set) var itemID: String?
    @Published private(set) var contentRevision: PhotoContentRevision?
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var playbackRate = 1.0
    @Published private(set) var currentTimeSeconds = 0.0

    private let endObserver = NotificationObserverBox()
    private let failureObserver = NotificationObserverBox()
    private let periodicTimeObserver = PlayerTimeObserverBox()
    private var timeControlObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    /// A content revision can recur after A → B → A navigation. Advancing a
    /// separate generation prevents a Task queued by the first A player item
    /// from mutating the replacement A item when it eventually reaches the
    /// main actor.
    private var playbackGeneration: UInt64 = 0
    /// Positions belong to the scan-time content identity, rather than the
    /// presentation ID. A replacement at the same path must start fresh.
    private var resumePositions: [PhotoContentRevision: ResumePosition] = [:]
    private var resumePositionGeneration: UInt64 = 0

    private struct ResumePosition {
        let seconds: TimeInterval
        let generation: UInt64
    }

    init() {
        player.actionAtItemEnd = .pause
        player.defaultRate = Float(playbackRate)
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.timeControlStatus == .playing
            }
        }
        rateObservation = player.observe(\.rate, options: [.initial, .new]) {
            [weak self] player, _ in
            let observedRate = Double(player.rate)
            Task { @MainActor in
                self?.synchronizePlaybackRate(with: observedRate)
            }
        }
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in
                self?.currentTimeSeconds = seconds.isFinite
                    ? max(0, seconds)
                    : 0
            }
        }
        periodicTimeObserver.store(player: player, token: token)
    }

    deinit {
        endObserver.remove()
        failureObserver.remove()
        periodicTimeObserver.remove()
    }

    func prepare(_ item: PhotoItem) {
        guard item.isVideo || item.isAudio else { return }
        let requestedRevision = item.contentRevision
        if contentRevision == requestedRevision,
           player.currentItem != nil { return }
        stop()
        itemID = item.id
        contentRevision = requestedRevision
        errorMessage = nil
        guard item.isPlayableMedia else {
            errorMessage = item.isAudio
                ? L10n.text("This audio format or codec isn't supported by macOS.")
                : L10n.text("This video's format or codec isn't supported by macOS.")
            return
        }

        let sourceRevision = MediaSourceRevision(item)
        // One bounded lstat preserves immediate prepare/play behavior. Media
        // decoding and the asynchronous readiness recheck remain off-main.
        guard sourceRevision.matchesCurrentFile() else {
            errorMessage = MediaSourceRevision.changedMessage
            return
        }
        let playerItem = AVPlayerItem(url: item.primaryURL)
        // AVPlayerView's native Play button uses the default rate; speed is
        // one shared review preference for videos and audio recordings.
        player.defaultRate = Float(playbackRate)
        player.replaceCurrentItem(with: playerItem)
        if let resumePosition = resumePositions[requestedRevision]?.seconds,
           resumePosition > 0 {
            currentTimeSeconds = resumePosition
            player.seek(
                to: CMTime(seconds: resumePosition, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        observe(
            playerItem,
            contentRevision: requestedRevision,
            generation: playbackGeneration,
            sourceRevision: sourceRevision
        )
    }

    func toggle(_ item: PhotoItem) {
        prepare(item)
        guard player.currentItem != nil, errorMessage == nil else { return }
        if isPlaying {
            pause()
        } else {
            if let duration = player.currentItem?.duration.seconds,
               duration.isFinite,
               player.currentTime().seconds >= duration - 0.05 {
                player.seek(to: .zero)
                forgetResumePosition(for: item.contentRevision)
            }
            player.defaultRate = Float(playbackRate)
            player.playImmediately(atRate: Float(playbackRate))
            isPlaying = true
        }
    }

    func setPlaybackRate(_ rate: Double) {
        guard Self.availablePlaybackRates.contains(rate) else { return }
        playbackRate = rate
        player.defaultRate = Float(rate)
        if isPlaying { player.rate = Float(rate) }
    }

    @discardableResult
    func adjustPlaybackRate(forward: Bool) -> Bool {
        guard let currentIndex = Self.availablePlaybackRates.firstIndex(
            of: playbackRate
        ) else { return false }
        let nextIndex = min(
            max(currentIndex + (forward ? 1 : -1), 0),
            Self.availablePlaybackRates.count - 1
        )
        setPlaybackRate(Self.availablePlaybackRates[nextIndex])
        return true
    }

    /// AVPlayerView owns useful native transport shortcuts, including speed
    /// changes. Mirror its actual positive rate back into the selected speed
    /// so the Info panel follows the player instead of remaining at 1×.
    func synchronizePlaybackRate(with observedRate: Double) {
        guard observedRate.isFinite, observedRate > 0,
              let matchingRate = Self.availablePlaybackRates.min(by: {
                  abs($0 - observedRate) < abs($1 - observedRate)
              }),
              abs(matchingRate - observedRate) < 0.01,
              matchingRate != playbackRate
        else { return }
        playbackRate = matchingRate
        player.defaultRate = Float(matchingRate)
    }

    func normalizedPlaybackPosition(for duration: TimeInterval?) -> Double {
        guard let duration, duration.isFinite, duration > 0 else { return 0 }
        return min(max(currentTimeSeconds / duration, 0), 1)
    }

    /// Moves through the current Gallery video or audio in a predictable step.
    /// Seeking deliberately neither starts nor pauses playback, so a paused
    /// clip remains paused while it is inspected frame by frame.
    @discardableResult
    func seek(_ item: PhotoItem, by offset: TimeInterval) -> Bool {
        guard item.isPlayableMedia else { return false }
        prepare(item)
        guard player.currentItem != nil, errorMessage == nil else {
            return false
        }

        let playerDuration = player.currentItem?.duration.seconds
        let duration = item.duration ?? playerDuration
        let target = Self.seekTarget(
            from: player.currentTime().seconds,
            by: offset,
            duration: duration
        )
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTimeSeconds = target
        remember(target, for: item.contentRevision, duration: duration)
        return true
    }

    /// Moves the Gallery scrubber to an exact point without changing whether
    /// playback is running. Keeping this in the shared controller also keeps
    /// resume-on-navigation behavior identical to keyboard seeking.
    @discardableResult
    func seek(_ item: PhotoItem, to seconds: TimeInterval) -> Bool {
        guard item.isPlayableMedia else { return false }
        prepare(item)
        guard player.currentItem != nil, errorMessage == nil else {
            return false
        }
        let playerDuration = player.currentItem?.duration.seconds
        let duration = item.duration ?? playerDuration
        let target = Self.seekTarget(
            from: 0,
            by: seconds,
            duration: duration
        )
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTimeSeconds = target
        remember(target, for: item.contentRevision, duration: duration)
        return true
    }

    /// Kept pure for exact boundary tests. Some newly prepared player items do
    /// not expose a finite duration immediately, so an unknown duration still
    /// permits a forward seek and lets AVFoundation establish the final bound.
    static func seekTarget(
        from currentTime: TimeInterval,
        by offset: TimeInterval,
        duration: TimeInterval?
    ) -> TimeInterval {
        let current = currentTime.isFinite ? max(0, currentTime) : 0
        let target = max(0, current + offset)
        guard let duration, duration.isFinite, duration >= 0 else {
            return target
        }
        return min(target, duration)
    }

    func pause() {
        player.pause()
        isPlaying = false
        rememberCurrentPosition()
    }

    func stop() {
        playbackGeneration &+= 1
        pause()
        removeObservers()
        player.replaceCurrentItem(with: nil)
        currentTimeSeconds = 0
        itemID = nil
        contentRevision = nil
        errorMessage = nil
    }

    /// Positions are intentionally an in-memory review aid rather than sidecar
    /// metadata. Closing or reopening a folder starts a fresh review session.
    func resetRememberedPositions() {
        stop()
        resumePositions.removeAll(keepingCapacity: false)
        resumePositionGeneration = 0
    }

    func isActive(_ item: PhotoItem) -> Bool {
        represents(item) && player.currentItem != nil
    }

    func represents(_ item: PhotoItem) -> Bool {
        itemID == item.id && contentRevision == item.contentRevision
    }

#if DEBUG
    /// Focused tests inspect the in-memory review aid without exposing it to
    /// production UI or persistence code.
    func rememberedPosition(for item: PhotoItem) -> TimeInterval? {
        resumePositions[item.contentRevision]?.seconds
    }
#endif

    private func observe(
        _ playerItem: AVPlayerItem,
        contentRevision observedRevision: PhotoContentRevision,
        generation observedGeneration: UInt64,
        sourceRevision: MediaSourceRevision
    ) {
        removeObservers()
        endObserver.replace(with: NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.playbackGeneration == observedGeneration,
                      self?.contentRevision == observedRevision else { return }
                self?.isPlaying = false
                self?.currentTimeSeconds = 0
                self?.forgetResumePosition(for: observedRevision)
            }
        })
        failureObserver.replace(with: NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                guard self?.playbackGeneration == observedGeneration,
                      self?.contentRevision == observedRevision else { return }
                self?.isPlaying = false
                self?.errorMessage = message ?? L10n.text("This media file couldn't be played.")
            }
        })
        itemStatusObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let status = item.status
            guard status == .failed || status == .readyToPlay else { return }
            let message = item.error?.localizedDescription ?? L10n.text("This media file couldn't be played.")
            Task { @MainActor in
                if status == .readyToPlay {
                    let matches = await Task.detached(priority: .userInitiated) {
                        sourceRevision.matchesCurrentFile()
                    }.value
                    guard self?.playbackGeneration == observedGeneration,
                          self?.contentRevision == observedRevision else { return }
                    if !matches {
                        self?.player.pause()
                        self?.player.replaceCurrentItem(with: nil)
                        self?.isPlaying = false
                        self?.errorMessage = MediaSourceRevision.changedMessage
                    }
                    return
                }
                guard self?.playbackGeneration == observedGeneration,
                      self?.contentRevision == observedRevision else { return }
                self?.isPlaying = false
                self?.errorMessage = message
            }
        }
    }

    private func removeObservers() {
        endObserver.remove()
        failureObserver.remove()
        itemStatusObservation = nil
    }

    private func rememberCurrentPosition() {
        guard let contentRevision else { return }
        let duration = player.currentItem?.duration.seconds
        let currentTime = player.currentTime().seconds
        // AVPlayer seeks asynchronously. If the reviewer presses an arrow and
        // immediately changes item, `currentTime()` can still report the old
        // zero position; retain the just-recorded target rather than erasing
        // the resume point on the way out.
        if currentTime.isFinite,
           currentTime <= 0.05,
           resumePositions[contentRevision] != nil {
            return
        }
        remember(
            currentTime,
            for: contentRevision,
            duration: duration
        )
    }

    private func remember(
        _ seconds: TimeInterval,
        for contentRevision: PhotoContentRevision,
        duration: TimeInterval?
    ) {
        guard seconds.isFinite, seconds > 0.05 else {
            forgetResumePosition(for: contentRevision)
            return
        }
        if let duration, duration.isFinite, seconds >= duration - 0.05 {
            forgetResumePosition(for: contentRevision)
            return
        }
        resumePositionGeneration &+= 1
        resumePositions[contentRevision] = ResumePosition(
            seconds: seconds,
            generation: resumePositionGeneration
        )
        guard resumePositions.count > Self.maximumRememberedPositions,
              let oldest = resumePositions.min(by: {
                  $0.value.generation < $1.value.generation
              })?.key
        else { return }
        resumePositions.removeValue(forKey: oldest)
    }

    private func forgetResumePosition(for contentRevision: PhotoContentRevision) {
        resumePositions.removeValue(forKey: contentRevision)
    }
}
