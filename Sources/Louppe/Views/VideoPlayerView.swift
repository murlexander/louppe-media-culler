import SwiftUI
import AVKit

#if DEBUG
/// Hosted AppKit checks track the actual mounted transport lifetime; this also
/// works when a test process has no enabled accessibility client or key loop.
@MainActor
enum GalleryVideoControlsTestProbe {
    private static var mountedControllers: Set<ObjectIdentifier> = []
    static func isMounted(for playback: VideoPlaybackController) -> Bool {
        mountedControllers.contains(ObjectIdentifier(playback))
    }
    static func mount(_ playback: VideoPlaybackController) {
        mountedControllers.insert(ObjectIdentifier(playback))
    }
    static func unmount(_ playback: VideoPlaybackController) {
        mountedControllers.remove(ObjectIdentifier(playback))
    }
}
#endif

/// Gallery video surface with persistent native controls. AVPlayerView applies
/// an unavoidable whole-video hover scrim, so Gallery uses AVPlayerLayer.
/// Keeping the transport visible also preserves keyboard and VoiceOver access.
struct GalleryVideoPlayerView: View {
    let item: PhotoItem
    @ObservedObject var playback: VideoPlaybackController
    @StateObject private var presentation = GalleryVideoPresentationController()
    @State private var isScrubbing = false
    @State private var scrubPosition = 0.0
    @State private var volume = 1.0
    @State private var isMuted = false

    var body: some View {
        Group {
            if !item.videoIsPlayable {
                unsupportedView
            } else if let error = playback.errorMessage,
                      playback.represents(item) {
                ContentUnavailableView(
                    L10n.text("Can't play this video"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ZStack {
                    Color.appBackground
                    GalleryVideoSurface(
                        player: playback.player,
                        presentationSize: videoPresentationSize,
                        presentation: presentation
                    )
                    // Native transport stays visible during playback, so all
                    // controls remain reachable without moving the pointer.
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Spacer()
                            controlButton(
                                systemName: presentation.isPictureInPictureActive
                                    ? "pip.exit" : "pip.enter",
                                help: presentation.isPictureInPictureActive
                                    ? L10n.text("Close Picture in Picture")
                                    : L10n.text("Picture in Picture")
                            ) {
                                presentation.togglePictureInPicture()
                            }
                            .disabled(!presentation.pictureInPictureSupported)
                            controlButton(
                                systemName: "arrow.up.left.and.arrow.down.right",
                                help: L10n.text("Toggle full screen")
                            ) {
                                presentation.toggleFullScreen()
                            }
                        }
                        .padding(12)
                        Spacer()
                        GalleryMediaTransportView(
                            item: item,
                            playback: playback,
                            isScrubbing: $isScrubbing,
                            scrubPosition: $scrubPosition,
                            volume: $volume,
                            isMuted: $isMuted,
                            compact: false
                        )
                            .padding(.horizontal, 18)
                            .padding(.bottom, 14)
                    }
                    .accessibilityIdentifier("louppe.gallery.video.controls")
#if DEBUG
                    .onAppear { GalleryVideoControlsTestProbe.mount(playback) }
                    .onDisappear { GalleryVideoControlsTestProbe.unmount(playback) }
#endif
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    presentation.toggleFullScreen()
                }
            }
        }
        .onAppear {
            playback.prepare(item)
            volume = Double(playback.player.volume)
            isMuted = playback.player.isMuted
        }
        .onChange(of: item.contentRevision) { playback.prepare(item) }
    }

    private func controlButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var videoPresentationSize: CGSize {
        guard let size = item.videoDimensions,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return CGSize(width: 16, height: 9)
        }
        return size
    }

    private var unsupportedView: some View {
        ContentUnavailableView(
            L10n.text("Video isn't supported"),
            systemImage: "film",
            description: Text(L10n.text("macOS can’t play this video format. You can still rate and export it — \(item.displayName)"))
        )
    }
}

/// One AVPlayer-backed transport for Gallery video and audio. Audio uses two
/// rows so the controls remain usable when the Gallery pane is narrow.
private struct GalleryMediaTransportView: View {
    let item: PhotoItem
    @ObservedObject var playback: VideoPlaybackController
    @Binding var isScrubbing: Bool
    @Binding var scrubPosition: Double
    @Binding var volume: Double
    @Binding var isMuted: Bool
    let compact: Bool

    var body: some View {
        Group {
            if compact {
                stackedTransport
            } else {
                ViewThatFits(in: .horizontal) {
                    wideTransport
                        .frame(minWidth: 460)
                    stackedTransport
                        .background(
                            Color.appBackground,
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                }
            }
        }
    }

    private var wideTransport: some View {
        HStack(spacing: 12) {
            playbackControls
            timelineControls
            volumeControls
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.appBackground, in: Capsule())
    }

    private var stackedTransport: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                playbackControls
                Spacer(minLength: 8)
                volumeControls
            }
            timelineControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var duration: Double {
        guard let value = item.duration,
              value.isFinite, value > 0 else { return 0 }
        return value
    }

    private var displayedTime: Double {
        isScrubbing ? scrubPosition * duration : playback.currentTimeSeconds
    }

    private var timelineValue: Binding<Double> {
        Binding(
            get: {
                isScrubbing
                    ? scrubPosition
                    : playback.normalizedPlaybackPosition(for: item.duration)
            },
            set: { value in
                scrubPosition = min(max(value, 0), 1)
                if !isScrubbing {
                    playback.seek(item, to: scrubPosition * duration)
                }
            }
        )
    }

    private var playbackControls: some View {
        HStack(spacing: 12) {
            controlButton(systemName: "gobackward.15", help: L10n.text("Skip back 15 seconds")) {
                playback.seek(item, by: -15)
            }
            controlButton(
                systemName: playback.isPlaying ? "pause.fill" : "play.fill",
                help: playback.isPlaying ? L10n.text("Pause") : L10n.text("Play")
            ) {
                playback.toggle(item)
            }
            controlButton(systemName: "goforward.15", help: L10n.text("Skip forward 15 seconds")) {
                playback.seek(item, by: 15)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private var timelineControls: some View {
        HStack(spacing: 12) {
            Text(MediaDurationFormat.display(displayedTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .trailing)
            Slider(
                value: timelineValue,
                in: 0...1,
                onEditingChanged: { editing in
                    if editing {
                        scrubPosition = playback.normalizedPlaybackPosition(
                            for: item.duration
                        )
                    } else {
                        playback.seek(item, to: scrubPosition * duration)
                    }
                    isScrubbing = editing
                }
            )
            .disabled(duration <= 0)
            .accessibilityLabel(L10n.text("Timeline"))
            Text(MediaDurationFormat.display(item.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var volumeControls: some View {
        HStack(spacing: 12) {
            controlButton(
                systemName: isMuted || volume == 0
                    ? "speaker.slash.fill" : "speaker.wave.2.fill",
                help: isMuted ? L10n.text("Unmute") : L10n.text("Mute")
            ) {
                playback.player.isMuted.toggle()
                isMuted = playback.player.isMuted
            }
            Slider(value: $volume, in: 0...1)
                .frame(width: compact ? 74 : 82)
                .accessibilityLabel(L10n.text("Volume"))
                .onChange(of: volume) {
                    playback.player.volume = Float(volume)
                    if volume > 0, playback.player.isMuted {
                        playback.player.isMuted = false
                        isMuted = false
                    }
                }
        }
    }

    private func controlButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Waveform and controls share AVPlayer with Gallery video and Grid playback.
struct GalleryAudioPlayerView: View {
    let item: PhotoItem
    @ObservedObject var playback: VideoPlaybackController
    @State private var waveform: AudioLevelAnalysis?
    @State private var waveformRevision: PhotoContentRevision?
    @State private var waveformLoadFailed = false
    @State private var isScrubbing = false
    @State private var scrubPosition = 0.0
    @State private var volume = 1.0
    @State private var isMuted = false

    var body: some View {
        Group {
            if !item.audioIsPlayable {
                unsupportedView
            } else if let error = playback.errorMessage,
                      playback.represents(item) {
                ContentUnavailableView(
                    L10n.text("Can't play this audio"),
                    systemImage: "waveform.badge.exclamationmark",
                    description: Text(error)
                )
            } else {
                VStack(spacing: 18) {
                    Group {
                        if waveformRevision == item.contentRevision,
                           let waveform {
                            AudioWaveformView(
                                analysis: waveform,
                                progress: playback.normalizedPlaybackPosition(
                                    for: item.duration
                                )
                            )
                        } else if waveformRevision == item.contentRevision,
                                  waveformLoadFailed {
                            VStack(spacing: 8) {
                                Image(systemName: "waveform.badge.exclamationmark")
                                    .font(.title)
                                    .foregroundStyle(.secondary)
                                Text(L10n.text("Waveform unavailable"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(L10n.text("Preparing waveform…"))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: 760, minHeight: 150, maxHeight: 240)
                    .padding(.horizontal, 36)
                    VStack(spacing: 5) {
                        Text(item.displayName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                        Text(MediaDurationFormat.display(item.duration))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GalleryMediaTransportView(
                        item: item,
                        playback: playback,
                        isScrubbing: $isScrubbing,
                        scrubPosition: $scrubPosition,
                        volume: $volume,
                        isMuted: $isMuted,
                        compact: true
                    )
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            playback.prepare(item)
            volume = Double(playback.player.volume)
            isMuted = playback.player.isMuted
        }
        .onChange(of: item.contentRevision) { playback.prepare(item) }
        .task(id: item.contentRevision) {
            let requestedRevision = item.contentRevision
            waveform = nil
            waveformLoadFailed = false
            waveformRevision = requestedRevision
            let loaded = await AudioLevelPipeline.shared.analysis(for: item)
            guard !Task.isCancelled,
                  waveformRevision == requestedRevision else { return }
            waveform = loaded
            waveformLoadFailed = loaded == nil
        }
    }

    private var unsupportedView: some View {
        ContentUnavailableView(
            L10n.text("Audio isn't supported"),
            systemImage: "waveform.badge.exclamationmark",
            description: Text(L10n.text("macOS can’t play this audio format. You can still rate and export it — \(item.displayName)"))
        )
    }
}

enum NativeVideoControls {
    case audio
    case none
}

/// AppKit bridge used for both Gallery and Grid so playback stays entirely on
/// macOS's AVKit/AVFoundation stack.
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    let controls: NativeVideoControls

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        Self.configure(view, player: player, controls: controls)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        Self.configure(view, player: player, controls: controls)
    }

    /// Keep configuration idempotent: resetting AVKit's controls style during
    /// every SwiftUI update causes its secondary buttons to animate and shift.
    static func configure(
        _ view: AVPlayerView,
        player: AVPlayer,
        controls: NativeVideoControls
    ) {
        if view.player !== player { view.player = player }
        view.videoGravity = .resizeAspect
        switch controls {
        case .audio:
            if view.controlsStyle != .inline { view.controlsStyle = .inline }
            view.showsFullScreenToggleButton = false
            view.showsFrameSteppingButtons = false
            view.allowsPictureInPicturePlayback = false
        case .none:
            if view.controlsStyle != .none { view.controlsStyle = .none }
            view.showsFullScreenToggleButton = false
            view.showsFrameSteppingButtons = false
            view.allowsPictureInPicturePlayback = false
        }
    }
}

/// Direct AVFoundation surface for Gallery video. SwiftUI's photo-pane gray
/// stays visible through its clear root layer, and the player layer is only as
/// large as the fitted movie rectangle, so AVFoundation never contributes
/// black letterboxing.
struct GalleryVideoSurface: NSViewRepresentable {
    let player: AVPlayer
    let presentationSize: CGSize
    let presentation: GalleryVideoPresentationController

    func makeNSView(context: Context) -> GalleryVideoSurfaceView {
        let view = GalleryVideoSurfaceView()
        view.configure(player: player, presentationSize: presentationSize)
        presentation.attach(to: view.playerLayer)
        return view
    }

    func updateNSView(_ view: GalleryVideoSurfaceView, context: Context) {
        view.configure(player: player, presentationSize: presentationSize)
        presentation.attach(to: view.playerLayer)
    }
}

final class GalleryVideoSurfaceView: NSView {
    let playerLayer = AVPlayerLayer()
    private(set) var presentationSize = CGSize(width: 16, height: 9)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        prepareLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        prepareLayers()
    }

    func configure(player: AVPlayer, presentationSize: CGSize) {
        if playerLayer.player !== player { playerLayer.player = player }
        self.presentationSize = presentationSize
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = Self.aspectFitRect(presentationSize, in: bounds)
        CATransaction.commit()
    }

    private func prepareLayers() {
        wantsLayer = true
        // SwiftUI's Color.appBackground remains visible around the fitted
        // player layer; resolving NSColor directly here can lose dark-mode
        // appearance when converted to CGColor.
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(playerLayer)
    }

    static func aspectFitRect(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}

@MainActor
final class GalleryVideoPresentationController: NSObject, ObservableObject,
    @preconcurrency AVPictureInPictureControllerDelegate {
    @Published private(set) var isPictureInPictureActive = false
    private var pictureInPictureController: AVPictureInPictureController?
    private weak var attachedLayer: AVPlayerLayer?

    var pictureInPictureSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    func attach(to playerLayer: AVPlayerLayer) {
        guard attachedLayer !== playerLayer else { return }
        attachedLayer = playerLayer
        pictureInPictureController = pictureInPictureSupported
            ? AVPictureInPictureController(playerLayer: playerLayer)
            : nil
        pictureInPictureController?.delegate = self
    }

    func togglePictureInPicture() {
        guard let controller = pictureInPictureController else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isPictureInPictureActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        isPictureInPictureActive = false
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        isPictureInPictureActive = false
    }
}
