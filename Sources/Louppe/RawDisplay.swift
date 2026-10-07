import Foundation
import CoreImage
import OSLog

/// Presentation is independent of the linear RAW histogram analysis.
enum RawDisplayMode: String, CaseIterable, Sendable {
    case fast
    case raw

    static let preferenceKey = "review.rawDisplayMode"
    var title: String { self == .fast ? L10n.text("Fast") : "RAW" }

    func rendersRAW(for item: PhotoItem) -> Bool {
        self == .raw && item.isRaw && item.mediaKind == .photo
    }
}

enum PhotoRepresentation: Equatable, Sendable {
    case preview
    case loadingRAW
    case raw
    case unavailable

    var label: String {
        switch self {
        case .preview: return L10n.text("Preview")
        case .loadingRAW: return "RAW…"
        case .raw: return "RAW"
        case .unavailable: return L10n.text("Unavailable")
        }
    }

    /// Never claim the viewport is RAW while any visible camera-preview tile
    /// remains. Missing margins outside the viewport do not affect the label.
    static func viewport(
        hasSource: Bool,
        usesTiles: Bool,
        visibleTilesReady: Bool,
        hasPreview: Bool,
        previewIsRAW: Bool,
        failed: Bool
    ) -> Self {
        if hasSource && usesTiles && visibleTilesReady { return .raw }
        if hasPreview { return previewIsRAW ? .raw : .preview }
        return failed ? .unavailable : .loadingRAW
    }
}

/// App-wide presentation choice. Default leaves Apple's decoder selection intact.
enum AppleRawDecoder: String, CaseIterable, Sendable {
    case appleDefault
    case raw9

    static let preferenceKey = "review.appleRawDecoder"
    var title: String { self == .appleDefault ? L10n.text("Apple Default") : "RAW 9" }
    static var supportsRAW9: Bool {
        if #available(macOS 27, *) { return true }
        return false
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .appleDefault
    }

    /// nil means leave the filter's initial version unchanged. Unsupported opt-in
    /// throws, never silently renders different pixels under the selected choice.
    func version(supported: [CIRAWDecoderVersion], supportsRAW9: Bool) throws -> CIRAWDecoderVersion? {
        guard self == .raw9 else { return nil }
        guard supportsRAW9 else { throw RawDecoderError.requiresNewerSystem }
        // Xcode 27's header omits availability on these exported constants.
        // Referencing .version9 would strongly link a symbol absent on older Macs.
        // Match the SDK's verified identifiers, then use the file's actual version.
        guard let version = supported.first(where: { $0.rawValue == "9" || $0.rawValue == "9.dng" }) else {
            throw RawDecoderError.unsupportedFile
        }
        return version
    }

    var failureMessage: String {
        self == .raw9
            ? L10n.text("RAW 9 needs macOS 27, a supported file, and Apple’s model resources. Retry, or choose Apple Default in the RAW menu.")
            : L10n.text("This Mac couldn’t render the RAW. Retry or use the camera preview.")
    }
}

enum RawDecoderError: Error {
    case requiresNewerSystem
    case unsupportedFile
}

/// The same decoder supplies fitted previews and 100% source tiles.
/// Keep sensor-oriented histogram adjustments in RawHistogramProcessor.
enum RawImageRendering {
    private static let context = CIContext()
    private static let softwareContext = CIContext(options: [.useSoftwareRenderer: true])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let logger = Logger(subsystem: "com.alexandermarkin.louppe", category: "RAW decoder")

    /// Called only on bounded background decoding lanes. Resource failure leaves
    /// RAW unavailable; it must not switch to the default decoder or previewImage.
    static func filter(url: URL, decoder: AppleRawDecoder = .appleDefault) -> CIRAWFilter? {
        guard let filter = CIRAWFilter(imageURL: url),
              filter.supportedDecoderVersions.contains(where: { $0 != .none }) else { return nil }
        do {
            if let version = try decoder.version(
                supported: filter.supportedDecoderVersions,
                supportsRAW9: AppleRawDecoder.supportsRAW9
            ) {
                filter.decoderVersion = version
                if #available(macOS 27, *) {
                    let completion = ResourceCompletion()
                    let progress = filter.downloadResources(timeout: 15) { error in
                        completion.finish(error: error)
                    }
                    guard completion.wait() else {
                        progress.cancel()
                        logger.error("RAW 9 model resources unavailable or timed out")
                        return nil
                    }
                }
            }
        } catch {
            logger.notice("Requested RAW decoder unavailable for this system or file")
            return nil
        }
        return filter
    }

    private final class ResourceCompletion: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var succeeded = false
        func finish(error: Error?) {
            lock.lock()
            succeeded = error == nil
            lock.unlock()
            semaphore.signal()
        }
        func wait() -> Bool {
            guard semaphore.wait(timeout: .now() + 16) == .success else { return false }
            lock.lock()
            defer { lock.unlock() }
            return succeeded
        }
    }

    static func image(url: URL, maximumPixelSize: CGFloat? = nil, decoder: AppleRawDecoder = .appleDefault) -> CIImage? {
        guard let filter = filter(url: url, decoder: decoder) else { return nil }
        filter.isDraftModeEnabled = false
        if let maximumPixelSize {
            let maximum = max(filter.nativeSize.width, filter.nativeSize.height)
            guard maximum.isFinite, maximum > 0 else { return nil }
            filter.scaleFactor = Float(min(1, maximumPixelSize / maximum))
        } else {
            filter.scaleFactor = 1
        }
        guard var image = filter.outputImage else { return nil }
        let extent = image.extent.integral
        guard extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return nil }
        image = image.transformed(by: CGAffineTransform(
            translationX: -extent.minX, y: -extent.minY
        ))
        if let maximumPixelSize {
            let maximum = max(image.extent.width, image.extent.height)
            if maximum > maximumPixelSize {
                let scale = maximumPixelSize / maximum
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        return image
    }

    static func preview(url: URL, maximumPixelSize: CGFloat, decoder: AppleRawDecoder = .appleDefault) -> CGImage? {
        guard let image = image(url: url, maximumPixelSize: maximumPixelSize, decoder: decoder) else { return nil }
        let bounds = image.extent.integral
        guard bounds.width <= maximumPixelSize + 1,
              bounds.height <= maximumPixelSize + 1 else { return nil }
        if let rendered = context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: colorSpace) {
            return rendered
        }
        // RAW 9 depends on Core ML resources; a CPU retry is not a resource remedy.
        guard decoder == .appleDefault else { return nil }
        return softwareContext.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: colorSpace)
    }
}
