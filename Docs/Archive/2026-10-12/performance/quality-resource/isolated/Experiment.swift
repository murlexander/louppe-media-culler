import Foundation
import CoreGraphics
import Combine
import Darwin

struct HistogramAnalysis: Equatable, Sendable {
    static let nearBlackUpperBound: UInt8 = 5
    static let nearWhiteLowerBound: UInt8 = 250
    static let highPercentageThreshold = 10.0

    let bins: [Int]
    let sampleCount: Int
    let shadowCount: Int
    let highlightCount: Int
    let width: Int
    let height: Int

    init(bins: [Int], sampleCount: Int, shadowCount: Int, highlightCount: Int,
         width: Int = 0, height: Int = 0) {
        self.bins = bins
        self.sampleCount = sampleCount
        self.shadowCount = shadowCount
        self.highlightCount = highlightCount
        self.width = width
        self.height = height
    }

    var shadowPercentage: Double {
        percentage(for: shadowCount)
    }

    var highlightPercentage: Double {
        percentage(for: highlightCount)
    }

    static func isHighPercentage(_ value: Double) -> Bool {
        value > highPercentageThreshold
    }

    private func percentage(for count: Int) -> Double {
        guard sampleCount > 0 else { return 0 }
        return Double(count) * 100 / Double(sampleCount)
    }
}


enum BaselineClippingWarningProcessor {
    static func luminance(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
        // Integer Rec. 709 coefficients, summing to 256.
        let redContribution = 54 * Int(red)
        let greenContribution = 183 * Int(green)
        let blueContribution = 19 * Int(blue)
        let weighted =
            redContribution + greenContribution + blueContribution + 128
        return UInt8(min(weighted >> 8, 255))
    }

    static func isWarning(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        let value = luminance(red: red, green: green, blue: blue)
        return value <= HistogramAnalysis.nearBlackUpperBound
            || value >= HistogramAnalysis.nearWhiteLowerBound
    }

    static func analyze(_ image: CGImage) -> HistogramAnalysis? {
        guard let buffer = rgbaBuffer(for: image) else { return nil }
        var bins = Array(repeating: 0, count: 256)
        var sampleCount = 0
        var shadowCount = 0
        var highlightCount = 0
        let pixelCount = buffer.width * buffer.height

        buffer.bytes.withUnsafeBytes { rawBytes in
            guard let bytes = rawBytes.bindMemory(to: UInt8.self).baseAddress
            else { return }
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                let alpha = bytes[offset + 3]
                guard alpha > 0 else { continue }
                let value = luminance(
                    red: straight(bytes[offset], alpha: alpha),
                    green: straight(bytes[offset + 1], alpha: alpha),
                    blue: straight(bytes[offset + 2], alpha: alpha)
                )
                sampleCount += 1
                bins[Int(value)] += 1
                if value <= HistogramAnalysis.nearBlackUpperBound {
                    shadowCount += 1
                }
                if value >= HistogramAnalysis.nearWhiteLowerBound {
                    highlightCount += 1
                }
            }
        }

        return HistogramAnalysis(
            bins: bins,
            sampleCount: sampleCount,
            shadowCount: shadowCount,
            highlightCount: highlightCount,
            width: buffer.width, height: buffer.height
        )
    }

    static func overlay(on image: CGImage) -> CGImage? {
        guard var buffer = rgbaBuffer(for: image) else { return nil }
        let pixelCount = buffer.width * buffer.height

        buffer.bytes.withUnsafeMutableBytes { rawBytes in
            guard let bytes = rawBytes.bindMemory(to: UInt8.self).baseAddress
            else { return }
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                let alpha = bytes[offset + 3]
                guard alpha > 0 else { continue }
                let red = straight(bytes[offset], alpha: alpha)
                let green = straight(bytes[offset + 1], alpha: alpha)
                let blue = straight(bytes[offset + 2], alpha: alpha)
                guard isWarning(red: red, green: green, blue: blue) else { continue }
                // Blend straight color, then restore valid premultiplied RGBA.
                // Transparent pixels and their alpha stay untouched.
                bytes[offset] = premultiplied(blend(red, with: 255), alpha: alpha)
                bytes[offset + 1] = premultiplied(blend(green, with: 0), alpha: alpha)
                bytes[offset + 2] = premultiplied(blend(blue, with: 0), alpha: alpha)
            }
        }

        return buffer.makeImage()
    }

    private static func straight(_ component: UInt8, alpha: UInt8) -> UInt8 {
        UInt8(min(255, (Int(component) * 255 + Int(alpha) / 2) / Int(alpha)))
    }

    private static func premultiplied(_ component: UInt8, alpha: UInt8) -> UInt8 {
        UInt8((Int(component) * Int(alpha) + 127) / 255)
    }

    private static func blend(_ original: UInt8, with warning: UInt8) -> UInt8 {
        let originalContribution = 28 * Int(original)
        let warningContribution = 72 * Int(warning)
        return UInt8(
            (originalContribution + warningContribution + 50) / 100
        )
    }

    private struct RGBABuffer {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        var bytes: [UInt8]

        func makeImage() -> CGImage? {
            bytes.withUnsafeBytes { rawBytes in
                guard let baseAddress = rawBytes.baseAddress,
                      let context = CGContext(
                        data: UnsafeMutableRawPointer(mutating: baseAddress),
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bytesPerRow: bytesPerRow,
                        space: Self.colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      )
                else { return nil }
                return context.makeImage()
            }
        }

        static let colorSpace =
            CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
    }

    private static func rgbaBuffer(for image: CGImage) -> RGBABuffer? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var bytes = Array(
            repeating: UInt8(0),
            count: bytesPerRow * height
        )
        let rendered = bytes.withUnsafeMutableBytes { rawBytes -> Bool in
            guard let baseAddress = rawBytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: RGBABuffer.colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard rendered else { return nil }
        return RGBABuffer(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytes: bytes
        )
    }
}


enum OpaqueFastClippingWarningProcessor {
    static func luminance(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
        // Integer Rec. 709 coefficients, summing to 256.
        let redContribution = 54 * Int(red)
        let greenContribution = 183 * Int(green)
        let blueContribution = 19 * Int(blue)
        let weighted =
            redContribution + greenContribution + blueContribution + 128
        return UInt8(min(weighted >> 8, 255))
    }

    static func isWarning(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        let value = luminance(red: red, green: green, blue: blue)
        return value <= HistogramAnalysis.nearBlackUpperBound
            || value >= HistogramAnalysis.nearWhiteLowerBound
    }

    static func analyze(_ image: CGImage) -> HistogramAnalysis? {
        guard let buffer = rgbaBuffer(for: image) else { return nil }
        var bins = Array(repeating: 0, count: 256)
        var sampleCount = 0
        var shadowCount = 0
        var highlightCount = 0
        let pixelCount = buffer.width * buffer.height

        buffer.bytes.withUnsafeBytes { rawBytes in
            guard let bytes = rawBytes.bindMemory(to: UInt8.self).baseAddress
            else { return }
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                let alpha = bytes[offset + 3]
                guard alpha > 0 else { continue }
                let value: UInt8
                if alpha == 255 {
                    value = luminance(
                        red: bytes[offset],
                        green: bytes[offset + 1],
                        blue: bytes[offset + 2]
                    )
                } else {
                    value = luminance(
                        red: straight(bytes[offset], alpha: alpha),
                        green: straight(bytes[offset + 1], alpha: alpha),
                        blue: straight(bytes[offset + 2], alpha: alpha)
                    )
                }
                sampleCount += 1
                bins[Int(value)] += 1
                if value <= HistogramAnalysis.nearBlackUpperBound {
                    shadowCount += 1
                }
                if value >= HistogramAnalysis.nearWhiteLowerBound {
                    highlightCount += 1
                }
            }
        }

        return HistogramAnalysis(
            bins: bins,
            sampleCount: sampleCount,
            shadowCount: shadowCount,
            highlightCount: highlightCount,
            width: buffer.width, height: buffer.height
        )
    }

    static func overlay(on image: CGImage) -> CGImage? {
        guard var buffer = rgbaBuffer(for: image) else { return nil }
        let pixelCount = buffer.width * buffer.height

        buffer.bytes.withUnsafeMutableBytes { rawBytes in
            guard let bytes = rawBytes.bindMemory(to: UInt8.self).baseAddress
            else { return }
            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                let alpha = bytes[offset + 3]
                guard alpha > 0 else { continue }
                let red = straight(bytes[offset], alpha: alpha)
                let green = straight(bytes[offset + 1], alpha: alpha)
                let blue = straight(bytes[offset + 2], alpha: alpha)
                guard isWarning(red: red, green: green, blue: blue) else { continue }
                // Blend straight color, then restore valid premultiplied RGBA.
                // Transparent pixels and their alpha stay untouched.
                bytes[offset] = premultiplied(blend(red, with: 255), alpha: alpha)
                bytes[offset + 1] = premultiplied(blend(green, with: 0), alpha: alpha)
                bytes[offset + 2] = premultiplied(blend(blue, with: 0), alpha: alpha)
            }
        }

        return buffer.makeImage()
    }

    private static func straight(_ component: UInt8, alpha: UInt8) -> UInt8 {
        UInt8(min(255, (Int(component) * 255 + Int(alpha) / 2) / Int(alpha)))
    }

    private static func premultiplied(_ component: UInt8, alpha: UInt8) -> UInt8 {
        UInt8((Int(component) * Int(alpha) + 127) / 255)
    }

    private static func blend(_ original: UInt8, with warning: UInt8) -> UInt8 {
        let originalContribution = 28 * Int(original)
        let warningContribution = 72 * Int(warning)
        return UInt8(
            (originalContribution + warningContribution + 50) / 100
        )
    }

    private struct RGBABuffer {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        var bytes: [UInt8]

        func makeImage() -> CGImage? {
            bytes.withUnsafeBytes { rawBytes in
                guard let baseAddress = rawBytes.baseAddress,
                      let context = CGContext(
                        data: UnsafeMutableRawPointer(mutating: baseAddress),
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bytesPerRow: bytesPerRow,
                        space: Self.colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      )
                else { return nil }
                return context.makeImage()
            }
        }

        static let colorSpace =
            CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
    }

    private static func rgbaBuffer(for image: CGImage) -> RGBABuffer? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var bytes = Array(
            repeating: UInt8(0),
            count: bytesPerRow * height
        )
        let rendered = bytes.withUnsafeMutableBytes { rawBytes -> Bool in
            guard let baseAddress = rawBytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: RGBABuffer.colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard rendered else { return nil }
        return RGBABuffer(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            bytes: bytes
        )
    }
}


struct ResourceSample: Codable {
    let suite: String
    let variant: String
    let count: Int
    let iteration: Int
    let wallMilliseconds: Double
    let processCPUMilliseconds: Double
    let checksum: UInt64
    let willChangeEvents: Int
    let dictionaryEvents: Int
}

struct ResourceReport: Codable {
    let provenance: [String: String]
    let limitations: [String]
    let correctnessChecks: [String]
    let samples: [ResourceSample]
}

private func processCPUSeconds() -> Double {
    var usage = rusage()
    precondition(getrusage(RUSAGE_SELF, &usage) == 0)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

@MainActor
private func sample(suite: String, variant: String, count: Int, iteration: Int,
                    operation: () -> (UInt64, Int, Int)) -> ResourceSample {
    let cpuBefore = processCPUSeconds()
    let wallBefore = DispatchTime.now().uptimeNanoseconds
    let result = operation()
    let wallAfter = DispatchTime.now().uptimeNanoseconds
    let cpuAfter = processCPUSeconds()
    return ResourceSample(suite: suite, variant: variant, count: count, iteration: iteration,
                          wallMilliseconds: Double(wallAfter - wallBefore) / 1_000_000,
                          processCPUMilliseconds: (cpuAfter - cpuBefore) * 1_000,
                          checksum: result.0, willChangeEvents: result.1, dictionaryEvents: result.2)
}

private enum FixtureKind: String, CaseIterable {
    case opaque, mixed, partial, transparent
}

private func fixture(_ kind: FixtureKind, side: Int) -> CGImage {
    let pixels = side * side
    var bytes = [UInt8](repeating: 0, count: pixels * 4)
    let levels: [UInt8] = [0, 5, 6, 249, 250, 255, 127, 64]
    let alphas: [UInt8] = [0, 1, 2, 17, 64, 128, 254, 255]
    for pixel in 0..<pixels {
        let alpha: UInt8
        switch kind {
        case .opaque: alpha = 255
        case .mixed: alpha = alphas[pixel % alphas.count]
        case .partial: alpha = UInt8(1 + pixel % 254)
        case .transparent: alpha = 0
        }
        let gray = levels[(pixel / alphas.count) % levels.count]
        let red = pixel % 11 == 0 ? UInt8(255) : gray
        let green = pixel % 13 == 0 ? UInt8(255) : gray
        let blue = pixel % 17 == 0 ? UInt8(255) : gray
        bytes[pixel * 4] = UInt8((Int(red) * Int(alpha) + 127) / 255)
        bytes[pixel * 4 + 1] = UInt8((Int(green) * Int(alpha) + 127) / 255)
        bytes[pixel * 4 + 2] = UInt8((Int(blue) * Int(alpha) + 127) / 255)
        bytes[pixel * 4 + 3] = alpha
    }
    let data = Data(bytes) as CFData
    let provider = CGDataProvider(data: data)!
    return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: side * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                    .union(.byteOrder32Big),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func histogramChecksum(_ value: HistogramAnalysis) -> UInt64 {
    var sum = UInt64(value.sampleCount + value.shadowCount + value.highlightCount + value.width + value.height)
    for (index, count) in value.bins.enumerated() { sum &+= UInt64(index + 1) &* UInt64(count) }
    return sum
}

/// Synthetic values intentionally avoid media I/O and app dependencies.
private struct SyntheticRevision: Equatable {
    let pathIdentity: String
    let modificationTimeBits: UInt64
    let fileSize: Int64
    let volumeRoot: String
    let volumeUUID: String
    let systemNumber: UInt64
    let fileNumber: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64
    let birthSeconds: Int64
    let birthNanoseconds: Int64
}

private struct SyntheticEvidence: Equatable {
    let revision: SyntheticRevision
    let sampleCount: Int
    let shadowCount: Int
    let highlightCount: Int
    let width: Int
    let height: Int
    let source: Int
    let rawFallback: Bool
}

@MainActor
private final class EventProbe {
    var willChange = 0
    var dictionary = 0
}

@MainActor
private final class PublishedEvidence: ObservableObject {
    @Published var evidence: [String: SyntheticEvidence] = [:]
}

@MainActor
private final class PrivateEvidence: @MainActor ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private var evidence: [String: SyntheticEvidence] = [:]

    func insert(_ entries: [(String, SyntheticEvidence)], batchSize: Int) {
        for start in stride(from: 0, to: entries.count, by: batchSize) {
            objectWillChange.send()
            for index in start..<min(start + batchSize, entries.count) {
                evidence[entries[index].0] = entries[index].1
            }
        }
    }

    var snapshot: [String: SyntheticEvidence] { evidence }
    func checksum(lastID: String) -> UInt64 {
        UInt64(evidence.count) &+ UInt64(evidence[lastID]?.sampleCount ?? 0)
    }
}

private enum DictionaryVariant: String, CaseIterable {
    case publishedUnobserved = "published.unobserved"
    case publishedObserved = "published.observed"
    case privateSingle = "private.publish-every-item"
    case privateBatchTwo = "private.publish-every-two"
}

@MainActor
private func dictionaryWork(_ variant: DictionaryVariant, entries: [(String, SyntheticEvidence)]) -> (UInt64, Int, Int) {
    let probe = EventProbe()
    switch variant {
    case .publishedUnobserved, .publishedObserved:
        let owner = PublishedEvidence()
        var subscriptions: [AnyCancellable] = []
        if variant == .publishedObserved {
            subscriptions.append(owner.objectWillChange.sink { _ in probe.willChange += 1 })
            subscriptions.append(owner.$evidence.sink { _ in probe.dictionary += 1 })
            probe.dictionary = 0 // Exclude the publisher's initial value.
        }
        for (id, value) in entries { owner.evidence[id] = value }
        let checksum = UInt64(owner.evidence.count) &+ UInt64(owner.evidence[entries.last!.0]?.sampleCount ?? 0)
        withExtendedLifetime(subscriptions) {}
        return (checksum, probe.willChange, probe.dictionary)
    case .privateSingle, .privateBatchTwo:
        let owner = PrivateEvidence()
        let subscription = owner.objectWillChange.sink { _ in probe.willChange += 1 }
        owner.insert(entries, batchSize: variant == .privateSingle ? 1 : 2)
        let checksum = owner.checksum(lastID: entries.last!.0)
        withExtendedLifetime(subscription) {}
        return (checksum, probe.willChange, probe.dictionary)
    }
}

private func evidenceEntries(_ count: Int) -> [(String, SyntheticEvidence)] {
    (0..<count).map { index in
        let id = "Photo_\(index).JPG"
        let revision = SyntheticRevision(
            pathIdentity: "/private/tmp/QualityFixture/\(id)", modificationTimeBits: 123,
            fileSize: 4_000_000, volumeRoot: "/", volumeUUID: "11111111-2222-3333-4444-555555555555",
            systemNumber: 1, fileNumber: UInt64(index + 1),
            modificationSeconds: 100, modificationNanoseconds: 1,
            statusChangeSeconds: 101, statusChangeNanoseconds: 2,
            birthSeconds: 99, birthNanoseconds: 3
        )
        return (id, SyntheticEvidence(revision: revision, sampleCount: 1_048_576,
                                      shadowCount: index % 10_000, highlightCount: index % 20_000,
                                      width: 1024, height: 1024, source: 0, rawFallback: false))
    }
}

@main
private struct Experiment {
    @MainActor
    static func main() throws {
        let provenance: [String: String] = [
        "candidateChange": "Only analyze: alpha == 255 reads RGB directly; every other operation is unchanged.",
        "dictionaryPayload": "SyntheticEvidence preserves evidence scalar fields; SyntheticRevision approximates the real revision payload. This is a Combine/COW mechanism experiment, not SessionStore.",
        "histogramSourcePath": "/Users/developer/Documents/code/louppe/app/Sources/Louppe/HistogramPipeline.swift",
        "histogramSourceSHA256": "e774458040fe5e5d6ee4b41d3c724c9b30f2bc6335dcfca9a6faaab1e7954194",
        "histogramTypeSHA256": "7db2357b783b91253c31560c2db8f5efda79ec859594b0fc7c04050432da86dd",
        "histogramTypeStartLine": "44",
        "processorSHA256": "19cefa98844dc98ef2f492bc0b4edeac795166ce595f1fb82123f6177d6512d5",
        "processorStartLine": "89",
        "qualityCueSourceSHA256": "610105ed579d347ac0aecfec6c180f138d314ebc80f28dbd4be5821bf79df508",
        "sessionStoreSourceSHA256": "aeea131453e243f2485ed190703ee5049433ce8ef5fa2de9c0f386725b2a110c",
        ]
        let repetitions = min(30, max(3, Int(ProcessInfo.processInfo.environment["LOUPPE_RESOURCE_SAMPLES"] ?? "7") ?? 7))
        var samples: [ResourceSample] = []
        var checks: [String] = []
        for kind in FixtureKind.allCases {
            let image = fixture(kind, side: 1024)
            let baseline = BaselineClippingWarningProcessor.analyze(image)!
            let candidate = OpaqueFastClippingWarningProcessor.analyze(image)!
            precondition(baseline == candidate, "Full histogram differs for \(kind.rawValue)")
            precondition(baseline.bins.reduce(0, +) == baseline.sampleCount)
            precondition(baseline.width == 1024 && baseline.height == 1024)
            if kind == .opaque || kind == .partial { precondition(baseline.sampleCount == 1024 * 1024) }
            if kind == .transparent { precondition(baseline.sampleCount == 0) }
            if kind == .mixed { precondition(baseline.sampleCount == 1024 * 1024 * 7 / 8) }
            checks.append("\(kind.rawValue): full HistogramAnalysis equality (256 bins, counts, dimensions); expected alpha coverage")
            for _ in 0..<2 {
                _ = BaselineClippingWarningProcessor.analyze(image)
                _ = OpaqueFastClippingWarningProcessor.analyze(image)
            }
            for iteration in 0..<repetitions {
                let order = iteration.isMultiple(of: 2) ? ["baseline", "opaque-fast"] : ["opaque-fast", "baseline"]
                for variant in order {
                    samples.append(sample(suite: "histogram.\(kind.rawValue)", variant: variant,
                                          count: image.width * image.height, iteration: iteration) {
                        let result = variant == "baseline"
                            ? BaselineClippingWarningProcessor.analyze(image)!
                            : OpaqueFastClippingWarningProcessor.analyze(image)!
                        return (histogramChecksum(result), 0, 0)
                    })
                }
            }
        }
        for count in [1_000, 2_000, 10_000] {
            let entries = evidenceEntries(count)
            let expected = Dictionary(uniqueKeysWithValues: entries)
            let published = PublishedEvidence()
            let correctnessSubscription = published.$evidence.sink { _ in }
            for (id, value) in entries { published.evidence[id] = value }
            precondition(published.evidence == expected)
            withExtendedLifetime(correctnessSubscription) {}
            for batchSize in [1, 2] {
                let owner = PrivateEvidence()
                owner.insert(entries, batchSize: batchSize)
                precondition(owner.snapshot == expected, "Private batch \(batchSize) lost evidence")
            }
            checks.append("dictionary \(count): complete published/private dictionary equality; every key, revision, scalar field retained")
            for variant in DictionaryVariant.allCases {
                _ = dictionaryWork(variant, entries: entries)
                _ = dictionaryWork(variant, entries: entries)
            }
            for iteration in 0..<repetitions {
                let variants = DictionaryVariant.allCases
                let offset = iteration % variants.count
                let order = Array(variants[offset...]) + Array(variants[..<offset])
                for variant in order {
                    let result = sample(suite: "evidence-dictionary", variant: variant.rawValue,
                                        count: count, iteration: iteration) {
                        dictionaryWork(variant, entries: entries)
                    }
                    precondition(result.checksum == UInt64(count + 1_048_576))
                    if variant == .publishedObserved {
                        precondition(result.willChangeEvents == count && result.dictionaryEvents == count)
                    } else if variant == .privateSingle {
                        precondition(result.willChangeEvents == count && result.dictionaryEvents == 0)
                    } else if variant == .privateBatchTwo {
                        precondition(result.willChangeEvents == (count + 1) / 2 && result.dictionaryEvents == 0)
                    }
                    samples.append(result)
                }
            }
        }
        let report = ResourceReport(provenance: provenance, limitations: [
            "No RAW/ImageIO/CIRAWFilter decode, disk IO, SessionStore scheduling, real SwiftUI rendering, or app navigation is measured.",
            "Pixel measurements include production CGContext buffer conversion and scalar histogram analysis of fixed premultiplied 1024-square sRGB images.",
            "Synthetic pixel fixtures exercise alpha and luminance boundaries; they do not establish speedups across a representative photography collection.",
            "Only opaque RGB unpremultiplication is changed. Partial and transparent behavior use the production implementation.",
            "getrusage reports this process CPU (user + system), including its library worker threads, not whole-system CPU, energy, battery drain, GPU burden, or thermal behavior.",
            "Dictionary payload is a documented synthetic approximation. Published.observed includes synchronous Combine subscribers; subscribers do not retain dictionary snapshots.",
            "Private per-item publication separates dictionary-storage effects from batching. Batch-of-two matches the existing scheduler batch width, not a validated UI implementation.",
            "Fixtures, correctness comparisons, and two warmups per variant are outside measurement. Samples alternate/rotate variant order, run sequentially, and include full raw observations.",
            "Run after other Louppe benchmarks finish. Avoid claiming absolute resource savings from these isolated experiments."
        ], correctnessChecks: checks, samples: samples)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let output = try encoder.encode(report)
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
