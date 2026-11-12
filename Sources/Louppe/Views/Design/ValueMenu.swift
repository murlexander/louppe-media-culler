import SwiftUI

/// A current value outside a grouped Form. Keep choices in the native inline
/// picker, with primary value ink and the system-tinted menu indicator.
struct ValueMenu<Selection: Hashable, Options: View>: View {
    let title: String
    let value: String
    @Binding var selection: Selection
    @ViewBuilder var options: () -> Options

    init(
        _ title: String, value: String, selection: Binding<Selection>,
        @ViewBuilder options: @escaping () -> Options
    ) {
        self.title = title
        self.value = value
        _selection = selection
        self.options = options
    }

    var body: some View {
        Menu {
            Picker(title, selection: $selection, content: options)
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            Text(verbatim: value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(minHeight: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        // Native Menu can use its intrinsic label height; keep the composed
        // control's layout and hit region at the same minimum too.
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}
