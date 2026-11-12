import SwiftUI

/// A caption label above its value, as in Info's ordinary fields, selection
/// summaries and opening details. VoiceOver reads the pair as one element.
/// The caller styles the value; Info's centered shooting rows set their own
/// label/value accessibility because their visible labels are abbreviated or hidden.
struct LabeledReadout<Value: View>: View {
    let label: String
    var labelStyle: HierarchicalShapeStyle = .secondary
    var spacing: CGFloat = 1
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            Text(label)
                .font(.caption)
                .foregroundStyle(labelStyle)
            value
        }
        .accessibilityElement(children: .combine)
    }
}
