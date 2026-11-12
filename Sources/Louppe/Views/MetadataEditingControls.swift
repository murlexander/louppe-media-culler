import SwiftUI

extension PhotoColorLabel {
    var swatchColor: Color {
        switch self {
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        }
    }
}

/// Independent decision, star, and color controls shared by single-photo and
/// batch editing in the Info panel.
struct MetadataEditingControls: View {
    @ObservedObject var store: SessionStore
    var showsDecision = true

    var body: some View {
        let stars = store.effectiveStarRatingState
        let color = store.effectiveColorLabelState
        VStack(alignment: .leading, spacing: 9) {
            if showsDecision {
                HStack {
                    Text(L10n.text("Decision"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    MetadataDecisionButton(store: store, size: 22)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Stars"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    Button {
                        store.setStarRating(nil)
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(!store.canRate)
                    .accessibilityLabel(L10n.text("Clear stars"))
                    .accessibilityValue(MediaTileAccessibility.starDescription(for: stars))
                    .help(L10n.text("Clear stars"))

                    ForEach(StarRating.allCases, id: \.self) { rating in
                        let title = L10n.plural("Set %lld Stars", rating.count)
                        Button {
                            store.setStarRating(rating)
                        } label: {
                            Image(systemName: starSymbol(for: rating, state: stars))
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(starColor(for: rating, state: stars))
                        .disabled(!store.canRate)
                        .accessibilityLabel(title)
                        .accessibilityValue(MediaTileAccessibility.starDescription(for: stars))
                        .accessibilityAddTraits(stars == .stars(rating) ? .isSelected : [])
                        .help(title)
                    }
                }
            }

            HStack {
                Text(L10n.text("Color label"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ColorLabelMark(state: color)
                ValueMenu(L10n.text("Color label"), value: colorLabelText(for: color), selection: Binding(
                    get: { color },
                    set: { state in
                        switch state {
                        case .none: store.setColorLabel(nil)
                        case .label(let label): store.setColorLabel(label)
                        case .mixed: break
                        }
                    }
                )) {
                    if color == .mixed {
                        Text(L10n.text("Mixed")).tag(PhotoItemColorLabelState.mixed).disabled(true)
                        Divider()
                    }
                    Text(L10n.text("None")).tag(PhotoItemColorLabelState.none)
                    Divider()
                    ForEach(PhotoColorLabel.allCases, id: \.self) { label in
                        Text(label.localizedDisplayName).tag(PhotoItemColorLabelState.label(label))
                    }
                }
                .fixedSize()
                .disabled(!store.canRate)
            }
        }
    }

    private func starSymbol(for rating: StarRating, state: PhotoItemStarRatingState) -> String {
        switch state {
        case .stars(let selected) where selected.count >= rating.count:
            return "star.fill"
        default:
            return "star"
        }
    }

    private func starColor(for rating: StarRating, state: PhotoItemStarRatingState) -> Color {
        switch state {
        case .stars(let selected) where selected.count >= rating.count:
            return .louppeAccent
        case .mixed:
            return .secondary
        default:
            // Available empty stars stay readable, not disabled-looking.
            return .secondary
        }
    }

    private func colorLabelText(for state: PhotoItemColorLabelState) -> String {
        switch state {
        case .none: return L10n.text("None")
        case .label(let label): return label.localizedDisplayName
        case .mixed: return L10n.text("Mixed")
        }
    }
}

/// The one decision control used in both the filename row and batch editor.
struct MetadataDecisionButton: View {
    @ObservedObject var store: SessionStore
    let size: CGFloat

    var body: some View {
        let decision = store.effectiveDecisionState
        Button {
            store.toggleRating(at: store.currentIndex)
        } label: {
            RatingBadge(
                rating: decision.effectiveRating,
                isMixed: decision == .mixed,
                size: size
            )
            .frame(width: max(36, size + 6), height: max(36, size + 6))
        }
        .buttonStyle(.plain)
        .disabled(!store.canRate)
        .accessibilityLabel(L10n.text("Change decision"))
        .accessibilityValue(
            MediaTileAccessibility.decisionDescription(
                for: decision
            )
        )
        .help(L10n.text("Change Yes/No decision"))
    }
}

/// Color labels are rounded squares so a green or red label never reads as
/// the round ✓ / ✗ decision badge.
struct ColorLabelMark: View {
    static let shape = RoundedRectangle(cornerRadius: 3.5, style: .continuous)
    let state: PhotoItemColorLabelState

    var body: some View {
        Group {
            switch state {
            case .none:
                Self.shape
                    .strokeBorder(Color.secondary, lineWidth: 1.5)
            case .label(let label):
                // A filled Shape keeps its explicit label color inside Menu
                // labels; SF Symbols inherit the app's purple menu tint.
                Self.shape
                    .fill(label.swatchColor)
            case .mixed:
                Image(systemName: "square.lefthalf.filled")
                    .foregroundStyle(Color.louppeAccent)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// Small noninteractive summary for Browser and Grid thumbnails.
struct MetadataBadgeStrip: View {
    let starRatingState: PhotoItemStarRatingState
    let colorLabelState: PhotoItemColorLabelState
    var showsColorNames = false

    var body: some View {
        if starRatingState != .unrated || colorLabelState != .none {
            HStack(spacing: TileBadgeLayout.spacing) {
                if starRatingState != .unrated {
                    starBadge
                }
                if colorLabelState != .none {
                    if showsColorNames {
                        Text(colorTitle)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .frame(height: TileBadgeLayout.height)
                            .mediaBadgeBackdrop(Capsule(), role: .text)
                    } else {
                        ColorLabelMark(state: colorLabelState)
                            .frame(width: TileBadgeLayout.height, height: TileBadgeLayout.height)
                            .mediaBadgeBackdrop(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            .frame(height: TileBadgeLayout.height)
            .foregroundStyle(.white)
            .shadow(radius: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var colorTitle: String {
        switch colorLabelState {
        case .none: L10n.text("None")
        case .mixed: L10n.text("Mixed")
        case .label(let label): label.localizedDisplayName
        }
    }

    private var starBadge: some View {
        Group {
            switch starRatingState {
            case .unrated:
                EmptyView()
            case .stars(let rating):
                HStack(spacing: 1) {
                    Image(systemName: "star.fill")
                    Text("\(rating.count)")
                }
            case .mixed:
                Text("★–")
            }
        }
        .font(.system(size: TileBadgeLayout.iconSize, weight: .semibold))
        .padding(.horizontal, 5)
        .frame(height: TileBadgeLayout.height)
        .mediaBadgeBackdrop(Capsule())
    }
}
