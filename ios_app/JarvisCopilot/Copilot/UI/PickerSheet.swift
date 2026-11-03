import SwiftUI

/// One selectable option in a `PickerField` / `PickerSheet`. Ported from
/// `widgets/picker.dart`.
struct PickerOption<Value: Hashable>: Identifiable, Hashable {
    let value: Value
    let label: String
    var subtitle: String? = nil
    var symbol: String? = nil

    init(_ value: Value, _ label: String, subtitle: String? = nil, symbol: String? = nil) {
        self.value = value
        self.label = label
        self.subtitle = subtitle
        self.symbol = symbol
    }

    var id: Value { value }
}

/// A field's edge: a solid fill with the app's one hairline. (The name is
/// historical — it was a cyan-to-teal gradient.)
struct GradientBorder<Content: View>: View {
    var radius: CGFloat = JcTheme.fieldRadius
    @ViewBuilder var content: Content

    init(radius: CGFloat = JcTheme.fieldRadius, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        content
            .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(JcTheme.border, lineWidth: 1))
    }
}

/// A select field: a hairline-edged glass pill showing the current value, opening
/// a themed sheet on tap. Replaces the stock picker, whose menu can't be themed
/// to match the app.
struct PickerField<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [PickerOption<Value>]
    var hint: String = "Select"
    var sheetTitle: String? = nil

    @State private var showSheet = false

    private var current: PickerOption<Value>? { options.first { $0.value == selection } }

    var body: some View {
        Button { showSheet = true } label: {
            GradientBorder(radius: JcTheme.fieldRadius) {
                HStack(spacing: 10) {
                    if let symbol = current?.symbol {
                        JcIcon(symbol).font(.system(size: 16)).foregroundStyle(JcTheme.muted)
                    }
                    Text(current?.label ?? hint)
                        .font(JcText.body.weight(.medium))
                        .foregroundStyle(current == nil ? JcTheme.muted : JcTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    JcIcon("chevron.down", size: 13, weight: .semibold)
                        .foregroundStyle(JcTheme.muted)
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.vertical, 13)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            PickerSheet(title: sheetTitle ?? hint, options: options, selection: $selection)
        }
    }
}

/// The themed modal picker: an opaque dark sheet, a title, the options as rows;
/// the chosen one is lifted and carries the accent check.
///
/// Opaque on purpose — a translucent sheet bleeds the aurora backdrop through.
struct PickerSheet<Value: Hashable>: View {
    let title: String
    let options: [PickerOption<Value>]
    @Binding var selection: Value

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(JcText.title)
                .foregroundStyle(JcTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 24)
                .padding(.bottom, 14)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(options) { option in
                        Button {
                            selection = option.value
                            dismiss()
                        } label: {
                            PickerRow(option: option, selected: option.value == selection)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
        .background(JcTheme.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct PickerRow<Value: Hashable>: View {
    let option: PickerOption<Value>
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let symbol = option.symbol {
                JcIcon(symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? JcTheme.text : JcTheme.muted)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                if let subtitle = option.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
            }
            Spacer(minLength: 0)
            if selected {
                JcIcon("checkmark", size: 15, weight: .semibold).foregroundStyle(JcTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background {
            let shape = RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous)
            shape.fill(selected ? Color.white.opacity(0.10) : JcTheme.glassFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous)
                .strokeBorder(JcTheme.border, lineWidth: 1)
        }
    }
}
