import SwiftUI

struct XMPConflictResolverView: View {
    let conflicts: [XMPSameStemConflictDescriptor]
    let onCancel: () -> Void
    let onApply: ([XMPConflictResolutionRequest]) -> Void

    @State private var choices: [String: XMPConflictResolutionChoice]

    init(
        conflicts: [XMPSameStemConflictDescriptor],
        onCancel: @escaping () -> Void,
        onApply: @escaping ([XMPConflictResolutionRequest]) -> Void
    ) {
        self.conflicts = conflicts
        self.onCancel = onCancel
        self.onApply = onApply
        // A real plan emits one row per sidecar family, but this must not be
        // the place a malformed internal list becomes a crash — SessionStore's
        // mutation boundary already rejects duplicate and overlapping rows.
        _choices = State(initialValue: Dictionary(
            conflicts.map { ($0.id, .skip) },
            uniquingKeysWith: { first, _ in first }
        ))
    }

    var body: some View {
        SheetForm(title: L10n.text("Resolve RAW + JPEG Metadata")) {
            Text(L10n.text("These same-name files have different review metadata. Capture One and other sidecar workflows share one XMP metadata set."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

            Group {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(conflicts) { conflict in
                        conflictRow(conflict)
                        if conflict.id != conflicts.last?.id { Divider() }
                    }
                }
                .padding(.vertical, 2)
            }

            HStack {
                Text(L10n.text("Apply the same choice to all conflicts"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu(L10n.text("Apply to All…")) {
                    Button(L10n.text("Skip XMP for all")) { applyToAll(.skip) }
                    Button(L10n.text("Use RAW metadata for all")) { applyToAll(.useRAW) }
                    Button(L10n.text("Use JPEG metadata for all")) { applyToAll(.useJPEG) }
                }
            }

            Text(L10n.text("RAW or JPEG sets both files’ decision, stars, and color in one undoable action. XMP is written only after you review and confirm a new plan."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

        } actions: {
            HStack {
                Spacer()
                Button(L10n.text("Cancel")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text("Apply Resolutions")) {
                    onApply(conflicts.map {
                        XMPConflictResolutionRequest(
                            conflict: $0,
                            choice: choices[$0.id] ?? .skip
                        )
                    })
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!hasActionableChoice)
            }
        }
        .frame(width: 640, height: 620)
    }

    private func conflictRow(
        _ conflict: XMPSameStemConflictDescriptor
    ) -> some View {
        let raw = conflict.rawMember
        let jpeg = conflict.jpegMember
        return VStack(alignment: .leading, spacing: 9) {
            Text(conflictTitle(conflict))
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(conflictTitle(conflict))

            metadataHeader
            if let raw {
                metadataRow(raw, differing: conflict.differingDimensions)
            }
            if let jpeg {
                metadataRow(jpeg, differing: conflict.differingDimensions)
            }

            Picker(
                L10n.text("Resolution for \(conflictTitle(conflict))"),
                selection: choiceBinding(for: conflict.id)
            ) {
                Text(L10n.text("Keep separate and skip this XMP"))
                    .tag(XMPConflictResolutionChoice.skip)
                Text(L10n.text("Use RAW metadata for both"))
                    .tag(XMPConflictResolutionChoice.useRAW)
                    .accessibilityLabel(
                        L10n.text("Use RAW metadata for both. Change \(jpeg?.filename ?? "the JPEG") to match \(raw?.filename ?? "the RAW").")
                    )
                Text(L10n.text("Use JPEG metadata for both"))
                    .tag(XMPConflictResolutionChoice.useJPEG)
                    .accessibilityLabel(
                        L10n.text("Use JPEG metadata for both. Change \(raw?.filename ?? "the RAW") to match \(jpeg?.filename ?? "the JPEG").")
                    )
            }
            .pickerStyle(.radioGroup)
        }
        .accessibilityElement(children: .contain)
    }

    private var metadataHeader: some View {
        HStack(spacing: 10) {
            Text(L10n.text("Type"))
                .frame(width: 38, alignment: .leading)
            Text(L10n.text("File"))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.text("Decision"))
                .frame(width: 92, alignment: .leading)
            Text(L10n.text("Stars"))
                .frame(width: 86, alignment: .leading)
            Text(L10n.text("Color"))
                .frame(minWidth: 86, alignment: .leading)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private func metadataRow(
        _ member: XMPSameStemConflictDescriptor.Member,
        differing: Set<XMPMetadataDimension>
    ) -> some View {
        HStack(spacing: 10) {
            Text(member.role == .raw ? "RAW" : "JPEG")
                .font(.caption.weight(.semibold))
                .frame(width: 38, alignment: .leading)
            Text(member.filename)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(member.filename)
            decisionValue(
                member.metadata.rating,
                differs: differing.contains(.decision)
            )
            starValue(
                member.metadata.starRating,
                differs: differing.contains(.stars)
            )
            colorValue(
                member.metadata.colorLabel,
                differs: differing.contains(.color)
            )
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.text("\(member.role == .raw ? "RAW" : "JPEG"), \(member.filename), decision \(decisionLabel(member.metadata.rating)), \(starsLabel(member.metadata.starRating)), color \(colorLabel(member.metadata.colorLabel))")
        )
    }

    private func decisionValue(_ rating: Rating, differs: Bool) -> some View {
        HStack(spacing: 5) {
            RatingBadge(rating: rating, size: 13)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(decisionLabel(rating))
        }
        .fontWeight(differs ? .semibold : .regular)
        .foregroundStyle(differs ? Color.primary : Color.secondary)
        .frame(width: 92, alignment: .leading)
    }

    private func starValue(
        _ rating: StarRating?,
        differs: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: rating == nil ? "star" : "star.fill")
                .foregroundStyle(
                    rating == nil ? Color.secondary : Color.louppeAccent
                )
                .accessibilityHidden(true)
            Text(starsLabel(rating))
        }
        .fontWeight(differs ? .semibold : .regular)
        .foregroundStyle(differs ? Color.primary : Color.secondary)
        .frame(width: 86, alignment: .leading)
    }

    private func colorValue(
        _ label: PhotoColorLabel?,
        differs: Bool
    ) -> some View {
        HStack(spacing: 5) {
            ColorLabelMark(state: label.map(PhotoItemColorLabelState.label) ?? .none)
            Text(colorLabel(label))
        }
        .fontWeight(differs ? .semibold : .regular)
        .foregroundStyle(differs ? Color.primary : Color.secondary)
        .frame(minWidth: 86, alignment: .leading)
    }

    private func choiceBinding(
        for id: String
    ) -> Binding<XMPConflictResolutionChoice> {
        Binding(
            get: { choices[id] ?? .skip },
            set: { choices[id] = $0 }
        )
    }

    private var hasActionableChoice: Bool {
        choices.values.contains { $0 != .skip }
    }

    private func applyToAll(_ choice: XMPConflictResolutionChoice) {
        for conflict in conflicts { choices[conflict.id] = choice }
    }

    private func conflictTitle(
        _ conflict: XMPSameStemConflictDescriptor
    ) -> String {
        let name = conflict.rawMember?.filename
            ?? conflict.jpegMember?.filename
            ?? "RAW + JPEG"
        return (name as NSString).deletingPathExtension
    }

    private func decisionLabel(_ rating: Rating) -> String {
        switch rating {
        case .yes: return L10n.text("Yes")
        case .no: return L10n.text("No")
        case .undecided: return L10n.text("Undecided")
        }
    }

    private func starsLabel(_ rating: StarRating?) -> String {
        guard let rating else { return L10n.text("Unrated") }
        return rating == .one ? L10n.text("1 star") : "\(rating.count) stars"
    }

    private func colorLabel(_ label: PhotoColorLabel?) -> String {
        label?.displayName ?? L10n.text("None")
    }
}
