import SwiftUI

/// Compact Gallery zoom control. Fit is an explicit state; the slider shows
/// source-pixel magnification from 30% to 400% on a logarithmic scale.
struct PhotoZoomControl: View {
    @ObservedObject var store: SessionStore
    @State private var lastReading: ZoomReading?
    @AppStorage(RawDisplayMode.preferenceKey) private var rawDisplayMode = RawDisplayMode.fast
    @AppStorage(AppleRawDecoder.preferenceKey) private var rawDecoder = AppleRawDecoder.appleDefault

    private let minimum = 0.30
    private let maximum = Double(ActualSizeGeometry.maximumZoom)

    var body: some View {
        HStack(spacing: 5) {
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
                .accessibilityValue("\(store.currentPhotoRepresentation?.label ?? "Loading"), \(rawDecoder.title)")
            }
            Button(L10n.text("Fit")) { store.zoomToFit() }
                .buttonStyle(.bordered)
                .fontWeight(store.zoomMode == .fit ? .semibold : .regular)
                .accessibilityLabel(L10n.text("Fit photo in window"))
                .accessibilityAddTraits(store.zoomMode == .fit ? .isSelected : [])

            Slider(value: sliderValue, in: 0...1)
                .frame(width: 105)
                .disabled(displayedScale == nil)
                .accessibilityLabel(L10n.text("Photo zoom"))
                .accessibilityValue(currentValueLabel)
                .help(L10n.text("Zoom from 30% to 400%. At 100%, one source pixel fills one display pixel."))

            Text(currentValueLabel)
                .font(.caption.monospacedDigit())
                .frame(width: 45, alignment: .trailing)
        }
        .controlSize(.small)
        .tint(Color.louppeAccent)
        .onChange(of: currentReading, initial: true) { _, reading in
            if let reading { lastReading = reading }
        }
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
