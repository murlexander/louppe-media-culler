import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

/// One min/max envelope column, normalized to full-scale PCM. Keeping the
/// signed bounds preserves phase and makes a left/right imbalance visible
/// without retaining decoded audio samples.
struct AudioLevelEnvelope: Equatable, Sendable {
    let minimum: Float
    let maximum: Float
    /// Root-mean-square amplitude for this short time slice. The waveform
    /// keeps using the signed bounds, while the live meter uses RMS so a
    /// single stray sample does not look like sustained loudness.
    let rootMeanSquare: Float
}

/// The compact, read-only result shown in the Info panel. `peak` is a sample
/// peak in dBFS terms; it intentionally does not claim inter-sample true peak.
struct AudioLevelChannel: Equatable, Sendable {
    let envelope: [AudioLevelEnvelope]
    let peak: Float

    var samplePeakDecibels: Double? {
        AudioLevelProcessor.decibels(forSamplePeak: peak)
    }

    func loudnessDecibels(at normalizedPosition: Double) -> Double? {
        guard !envelope.isEmpty else { return nil }
        let position = min(max(normalizedPosition, 0), 1)
        let index = min(
            envelope.count - 1,
            Int((position * Double(envelope.count)).rounded(.down))
        )
        return AudioLevelProcessor.decibels(
            forAmplitude: envelope[index].rootMeanSquare
        )
    }
}

struct AudioLevelAnalysis: Equatable, Sendable {
    let channels: [AudioLevelChannel]

    var isMono: Bool { channels.count == 1 }
}

/// Pure PCM aggregation shared by the reader and focused regression tests.
/// Each channel is deliberately independent: stereo is never mixed down.
enum AudioLevelProcessor {
    static let defaultEnvelopeBinCount = 84
    static let temporalBinsPerSecond = 20
    static let minimumTemporalBinCount = 256
    static let maximumTemporalBinCount = 6_000

    static func decibels(forSamplePeak peak: Float) -> Double? {
        decibels(forAmplitude: peak)
    }

    static func decibels(forAmplitude amplitude: Float) -> Double? {
        guard amplitude.isFinite, amplitude > 0 else { return nil }
        return 20 * log10(Double(min(amplitude, 1)))
    }

    static func temporalBinCount(for duration: TimeInterval?) -> Int {
        guard let duration, duration.isFinite, duration > 0 else {
            return defaultEnvelopeBinCount
        }
        let requested = Int(
            min(
                duration * Double(temporalBinsPerSecond),
                Double(maximumTemporalBinCount)
            ).rounded(.up)
        )
        return min(
            max(requested, minimumTemporalBinCount),
            maximumTemporalBinCount
        )
    }

    static func analyze(
        channels: [[Float]],
        binCount: Int = defaultEnvelopeBinCount
    ) -> AudioLevelAnalysis? {
        guard !channels.isEmpty,
              let frames = channels.map(\.count).max(),
              frames > 0
        else { return nil }
        var accumulator = AudioLevelAccumulator(
            channelCount: channels.count,
            binCount: binCount
        )
        for frame in 0..<frames {
            let values = channels.map { channel in
                channel.indices.contains(frame) ? channel[frame] : 0
            }
            accumulator.append(
                values: values,
                normalizedPosition: Double(frame) / Double(frames)
            )
        }
        return accumulator.analysis
    }
}

private struct AudioLevelAccumulator {
    private let binCount: Int
    private var minimums: [[Float]]
    private var maximums: [[Float]]
    private var sumSquares: [[Double]]
    private var sampleCounts: [[Int]]
    private var peaks: [Float]
    private var hasSamples = false

    init(channelCount: Int, binCount: Int) {
        self.binCount = max(1, binCount)
        minimums = Array(
            repeating: Array(repeating: 0, count: max(1, binCount)),
            count: channelCount
        )
        maximums = Array(
            repeating: Array(repeating: 0, count: max(1, binCount)),
            count: channelCount
        )
        sumSquares = Array(
            repeating: Array(repeating: 0, count: max(1, binCount)),
            count: channelCount
        )
        sampleCounts = Array(
            repeating: Array(repeating: 0, count: max(1, binCount)),
            count: channelCount
        )
        peaks = Array(repeating: 0, count: channelCount)
    }

    mutating func append(values: [Float], normalizedPosition: Double) {
        guard values.count == peaks.count else { return }
        let boundedPosition = min(max(normalizedPosition, 0), 1)
        let bin = min(
            binCount - 1,
            Int((boundedPosition * Double(binCount)).rounded(.down))
        )
        for channel in values.indices {
            let value = Self.sanitized(values[channel])
            minimums[channel][bin] = min(minimums[channel][bin], value)
            maximums[channel][bin] = max(maximums[channel][bin], value)
            sumSquares[channel][bin] += Double(value * value)
            sampleCounts[channel][bin] += 1
            peaks[channel] = max(peaks[channel], abs(value))
        }
        hasSamples = true
    }

    mutating func append(
        interleavedSamples: [Float],
        channelCount: Int,
        frame: Int,
        normalizedPosition: Double
    ) {
        guard channelCount == peaks.count else { return }
        let boundedPosition = min(max(normalizedPosition, 0), 1)
        let bin = min(
            binCount - 1,
            Int((boundedPosition * Double(binCount)).rounded(.down))
        )
        let offset = frame * channelCount
        guard offset >= 0,
              offset + channelCount <= interleavedSamples.count
        else { return }
        for channel in 0..<channelCount {
            let value = Self.sanitized(interleavedSamples[offset + channel])
            minimums[channel][bin] = min(minimums[channel][bin], value)
            maximums[channel][bin] = max(maximums[channel][bin], value)
            sumSquares[channel][bin] += Double(value * value)
            sampleCounts[channel][bin] += 1
            peaks[channel] = max(peaks[channel], abs(value))
        }
        hasSamples = true
    }

    var analysis: AudioLevelAnalysis? {
        guard hasSamples else { return nil }
        return AudioLevelAnalysis(channels: minimums.indices.map { channel in
            AudioLevelChannel(
                envelope: minimums[channel].indices.map { index in
                    AudioLevelEnvelope(
                        minimum: minimums[channel][index],
                        maximum: maximums[channel][index],
                        rootMeanSquare: sampleCounts[channel][index] > 0
                            ? Float(sqrt(
                                sumSquares[channel][index]
                                    / Double(sampleCounts[channel][index])
                            ))
                            : 0
                    )
                },
                peak: peaks[channel]
            )
        })
    }

    private static func sanitized(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, -1), 1)
    }
}

private final class AudioLevelDecodeResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AudioLevelAnalysis?

    func store(_ value: AudioLevelAnalysis?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> AudioLevelAnalysis? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Bounded, coalesced whole-clip audio analysis. It retains only a small
/// numeric LRU keyed by scan-time content identity; no decoded audio or file
/// metadata is written to disk or to the original media.
final class AudioLevelPipeline: @unchecked Sendable {
    static let shared = AudioLevelPipeline()
    static let resultCacheLimit = 64
    /// 64 maximum-resolution stereo results. Multichannel recordings consume
    /// proportionally more of the same numeric budget and therefore evict
    /// older results sooner.
    static let resultEnvelopeLimit = 768_000

    private final class PendingAnalysis {
        var waiters: [UUID: CheckedContinuation<AudioLevelAnalysis?, Never>]
        let operation: BlockOperation
        let readAccess: MediaOperationReadAccess

        init(
            waiters: [UUID: CheckedContinuation<AudioLevelAnalysis?, Never>],
            operation: BlockOperation,
            readAccess: MediaOperationReadAccess
        ) {
            self.waiters = waiters
            self.operation = operation
            self.readAccess = readAccess
        }
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "louppe.audio-levels"
        // Full-clip PCM decoding competes with playback and thumbnails, so
        // only one analysis may run at a time.
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private let lock = NSLock()
    private var cache: [String: AudioLevelAnalysis] = [:]
    private var cacheOrder: [String] = []
    private var cachedEnvelopeCount = 0
    private var inFlight: [String: PendingAnalysis] = [:]

    typealias Decoder = @Sendable (
        URL, TimeInterval?, @escaping @Sendable () -> Bool
    ) -> AudioLevelAnalysis?
    private let decoder: Decoder

    init(decoder: @escaping Decoder = { url, duration, isCancelled in
        AudioLevelPipeline.decode(url: url, duration: duration, isCancelled: isCancelled)
    }) {
        self.decoder = decoder
    }

    func analysis(for item: PhotoItem, sourceAccess: MediaReadAccess? = nil) async -> AudioLevelAnalysis? {
        guard (item.isVideo || item.isAudio), item.isPlayableMedia else {
            return nil
        }
        let key = ImagePipeline.cacheKey(for: item)
        let revision = MediaSourceRevision(item)
        let duration = item.duration
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                if let cached = cache[key] {
                    touch(key)
                    lock.unlock()
                    continuation.resume(returning: cached)
                    return
                }
                if let pending = inFlight[key] {
                    pending.readAccess.retainIfNeeded(sourceAccess)
                    pending.waiters[requestID] = continuation
                    lock.unlock()
                    return
                }

                let operation = BlockOperation()
                let readAccess = MediaOperationReadAccess(sourceAccess)
                operation.addExecutionBlock { [weak self, weak operation] in
                    defer { readAccess.finish() }
                    guard let self, let operation, !operation.isCancelled
                    else { return }
                    let result = revision.read {
                        self.decoder(revision.url, duration, { operation.isCancelled })
                    }
                    self.finish(key: key, operation: operation, result: result)
                }
                operation.qualityOfService = .utility
                inFlight[key] = PendingAnalysis(
                    waiters: [requestID: continuation],
                    operation: operation, readAccess: readAccess
                )
                lock.unlock()
                queue.addOperation(operation)
            }
        } onCancel: { [weak self] in
            self?.cancelWaiter(requestID, for: key)
        }
    }

    private static func decode(
        url: URL,
        duration: TimeInterval?,
        isCancelled: () -> Bool
    ) -> AudioLevelAnalysis? {
        let result = AudioLevelDecodeResultBox()
        let completed = DispatchSemaphore(value: 0)
        let task = Task.detached(priority: .utility) {
            result.store(await decodeAsync(url: url, duration: duration))
            completed.signal()
        }
        while completed.wait(timeout: .now() + 0.05) == .timedOut {
            if isCancelled() {
                task.cancel()
                // Keep the serial queue slot until the detached reader exits;
                // releasing it here can overlap two whole-clip decodes.
            }
        }
        return isCancelled() ? nil : result.load()
    }

    private static func decodeAsync(
        url: URL,
        duration: TimeInterval?
    ) async -> AudioLevelAnalysis? {
        guard !Task.isCancelled else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              !Task.isCancelled,
              let reader = try? AVAssetReader(asset: asset)
        else { return nil }
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
            ]
        )
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var accumulator: AudioLevelAccumulator?
        var channelCount: Int?
        while reader.status == .reading,
              let sampleBuffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  stream.mChannelsPerFrame > 0,
                  stream.mChannelsPerFrame <= 32,
                  stream.mSampleRate.isFinite,
                  stream.mSampleRate > 0,
                  let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
            else { continue }

            let currentChannelCount = Int(stream.mChannelsPerFrame)
            guard channelCount == nil || channelCount == currentChannelCount else {
                reader.cancelReading()
                return nil
            }
            channelCount = currentChannelCount
            if accumulator == nil {
                accumulator = AudioLevelAccumulator(
                    channelCount: currentChannelCount,
                    binCount: AudioLevelProcessor.temporalBinCount(
                        for: duration
                    )
                )
            }

            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount > 0,
                  byteCount.isMultiple(of: MemoryLayout<Float>.stride)
            else { continue }
            var samples = Array(
                repeating: Float.zero,
                count: byteCount / MemoryLayout<Float>.stride
            )
            let copied = samples.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: baseAddress
                )
            }
            guard copied == kCMBlockBufferNoErr else { continue }

            let frames = min(
                CMSampleBufferGetNumSamples(sampleBuffer),
                samples.count / currentChannelCount
            )
            let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            for frame in 0..<frames {
                if frame.isMultiple(of: 4_096), Task.isCancelled {
                    reader.cancelReading()
                    return nil
                }
                let position: Double
                if let duration, duration.isFinite, duration > 0 {
                    position = (start + Double(frame) / stream.mSampleRate) / duration
                } else {
                    position = 0
                }
                accumulator?.append(
                    interleavedSamples: samples,
                    channelCount: currentChannelCount,
                    frame: frame,
                    normalizedPosition: position
                )
            }
        }
        guard reader.status == .completed else { return nil }
        return accumulator?.analysis
    }

    private func finish(key: String, operation: BlockOperation, result: AudioLevelAnalysis?) {
        lock.lock()
        guard let pending = inFlight[key], pending.operation === operation else {
            lock.unlock()
            return
        }
        inFlight.removeValue(forKey: key)
        if let result, !operation.isCancelled {
            if let previous = cache[key] {
                cachedEnvelopeCount -= Self.envelopeCount(in: previous)
            }
            cache[key] = result
            cachedEnvelopeCount += Self.envelopeCount(in: result)
            touch(key)
            while cacheOrder.count > Self.resultCacheLimit
                    || cachedEnvelopeCount > Self.resultEnvelopeLimit {
                let removed = cacheOrder.removeFirst()
                if let removedResult = cache.removeValue(forKey: removed) {
                    cachedEnvelopeCount -= Self.envelopeCount(
                        in: removedResult
                    )
                }
            }
        }
        let waiters = pending.waiters.values
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func cancelWaiter(_ requestID: UUID, for key: String) {
        lock.lock()
        guard let pending = inFlight[key],
              let waiter = pending.waiters.removeValue(forKey: requestID)
        else {
            lock.unlock()
            return
        }
        if pending.waiters.isEmpty {
            // Cancel even an executing whole-clip reader. Its operation keeps
            // the serial slot until the detached task confirms completion.
            inFlight.removeValue(forKey: key)
            pending.operation.cancel()
        }
        lock.unlock()
        waiter.resume(returning: nil)
    }

    private func touch(_ key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    private static func envelopeCount(in analysis: AudioLevelAnalysis) -> Int {
        analysis.channels.reduce(0) { $0 + $1.envelope.count }
    }
}
