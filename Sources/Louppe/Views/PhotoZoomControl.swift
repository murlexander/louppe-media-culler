import AppKit
import SwiftUI

/// Floating Gallery zoom control. Fit is an explicit state; the slider shows
/// source-pixel magnification from 30% to 400% on a logarithmic scale.
struct PhotoZoomControl: View {
    @ObservedObject var store: SessionStore
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var lastReading: ZoomReading?
    @AppStorage(RawDisplayMode.preferenceKey) private var rawDisplayMode = RawDisplayMode.fast
    @AppStorage(AppleRawDecoder.preferenceKey) private var rawDecoder = AppleRawDecoder.appleDefault

    private let minimum = 0.30
    private let maximum = Double(ActualSizeGeometry.maximumZoom)

    var body: some View {
        controls
            .padding(.horizontal, 12)
            .frame(height: 36) // Match the native macOS toolbar glass groups.
            .modifier(ZoomControlSurface(reduceTransparency: reduceTransparency, contrast: contrast))
            .contentShape(Capsule())
            .background(ZoomFitDoubleClickSurface { store.zoomToFit() })
            .help(L10n.text("Double-click to fit"))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("photoZoomControl")
            .onChange(of: currentReading, initial: true) { _, reading in
                if let reading { lastReading = reading }
            }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if store.currentItem?.isRaw == true {
                Menu {
                    Picker(L10n.text("RAW display"), selection: $rawDisplayMode) {
                        ForEach(RawDisplayMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Picker(L10n.text("Apple RAW decoder"), selection: $rawDecoder) {
                        ForEach(AppleRawDecoder.allCases, id: \.self) { decoder in
                            Text(decoder.title).tag(decoder)
                                .disabled(decoder == .raw9 && !AppleRawDecoder.supportsRAW9)
                        }
                    }
                } label: {
                    Text(store.currentPhotoRepresentation?.label ?? "…")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.text("RAW display and decoder. RAW 9 requires a supported macOS 27 file and uses more time and memory."))
                .accessibilityLabel(L10n.text("RAW display"))
                .accessibilityValue("\(store.currentPhotoRepresentation?.label ?? L10n.text("Loading")), \(rawDecoder.title)")
            }
            Button { store.zoomToFit() } label: {
                Text(L10n.text("Fit"))
                    .frame(minWidth: 30, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .fontWeight(store.zoomMode == .fit ? .semibold : .regular)
            .accessibilityLabel(L10n.text("Fit photo in window"))
            .accessibilityAddTraits(store.zoomMode == .fit ? .isSelected : [])

            Slider(value: sliderValue, in: 0...1)
                .frame(minWidth: 64, idealWidth: 120, maxWidth: 120)
                .disabled(displayedScale == nil)
                .accessibilityLabel(L10n.text("Photo zoom"))
                .accessibilityValue(currentValueLabel)
                .help(L10n.text("Zoom from 30% to 400%. At 100%, one source pixel fills one display pixel."))

            Text(currentValueLabel)
                .environment(\.layoutDirection, .leftToRight)
                .font(.caption.monospacedDigit())
                .frame(minWidth: 38, alignment: .trailing)
                .fixedSize()
                .accessibilityHidden(true) // The slider already announces this value.
        }
        .controlSize(.small)
        .tint(Color.louppeAccent)
    }

    private struct ZoomReading: Equatable {
        let revision: PhotoContentRevision
        let scale: CGFloat
    }

    private var currentReading: ZoomReading? {
        guard let revision = store.currentItem?.contentRevision,
              let scale = store.displayedPhotoZoomScale else { return nil }
        return ZoomReading(revision: revision, scale: scale)
    }

    private var displayedScale: CGFloat? {
        if let reading = currentReading { return reading.scale }
        // Fit/Phone report their scale after layout. Hold the current photo's
        // last value during that handoff: resetting the native slider
        // and disabling/re-enabling it interrupts its knob/track animation.
        guard lastReading?.revision == store.currentItem?.contentRevision
        else { return nil }
        return lastReading?.scale
    }

    private var currentValueLabel: String {
        guard let scale = displayedScale else { return "…" }
        return "\(Int((scale * 100).rounded()))%"
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: {
                let scale = min(max(Double(displayedScale ?? minimum), minimum), maximum)
                return log(scale / minimum) / log(maximum / minimum)
            },
            set: { fraction in
                let clamped = min(max(fraction, 0), 1)
                let scale = minimum * pow(maximum / minimum, clamped)
                store.setPhotoZoomScale(CGFloat(scale))
            }
        )
    }
}

/// One surface for the whole control; native controls retain their own input
/// and focus behavior. Older macOS versions use a standard material fallback.
private struct ZoomControlSurface: ViewModifier {
    let reduceTransparency: Bool
    let contrast: ColorSchemeContrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color.appBackground, in: Capsule())
                .overlay { border }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .overlay { border }
        }
    }

    private var border: some View {
        Capsule()
            .strokeBorder(
                Color.primary.opacity(contrast == .increased ? 1 : 0.25),
                lineWidth: contrast == .increased ? 2 : 1
            )
            .allowsHitTesting(false)
    }
}

/// Observe double-clicks before NSSlider starts its synchronous tracking loop.
/// Ordinary clicks and drags pass through immediately to the native controls.
private struct ZoomFitDoubleClickSurface: NSViewRepresentable {
    let fit: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.fit = fit
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.fit = fit
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: Void) {
        nsView.removeMonitor()
    }

    final class MonitorView: NSView {
        var fit: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.clickCount == 2,
                      let window = self.window, event.window === window,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      !self.isHiddenOrHasHiddenAncestor else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                let capsule = NSBezierPath(roundedRect: self.bounds,
                                          xRadius: self.bounds.height / 2,
                                          yRadius: self.bounds.height / 2)
                guard self.visibleRect.contains(point), capsule.contains(point) else { return event }
                self.fit()
                return nil
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
