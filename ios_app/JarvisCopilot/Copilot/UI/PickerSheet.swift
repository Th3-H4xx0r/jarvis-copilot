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

/// A thin gradient hairline border — the app's "futuristic glass edge". Wraps
/// `content` in a 1.2pt iridescent outline over a solid fill.
struct GradientBorder<Content: View>: View {
    var radius: CGFloat = JcTheme.fieldRadius
    var fill: Color? = nil
    var gradient: LinearGradient? = nil
    var thickness: CGFloat = 1.2
    var glow: Bool = false
    @ViewBuilder var content: Content

    init(radius: CGFloat = JcTheme.fieldRadius,
         fill: Color? = nil,
         gradient: LinearGradient? = nil,
         thickness: CGFloat = 1.2,
         glow: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.fill = fill
        self.gradient = gradient
        self.thickness = thickness
        self.glow = glow
        self.content = content()
    }

    private static var defaultGradient: LinearGradient {
        LinearGradient(colors: [Color(jcHex: 0x46E0E0, alpha: 0x55 / 255.0),
                                Color(jcHex: 0x8A7CFF, alpha: 0x55 / 255.0),
                                Color(jcHex: 0xFF6FD8, alpha: 0x55 / 255.0)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        content
            .background((fill ?? JcTheme.surfaceAlt),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .padding(thickness)
            .background {
                RoundedRectangle(cornerRadius: radius + thickness, style: .continuous)
                    .fill(gradient ?? Self.defaultGradient)
                    .shadow(color: glow ? JcTheme.accent.opacity(0.20) : .clear, radius: 8)
            }
    }
}

/// A select field: a gradient-edged glass pill showing the current value, opening
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
                        Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(JcTheme.cyan)
                    }
                    Text(current?.label ?? hint)
                        .font(JcText.body.weight(.semibold))
                        .foregroundStyle(current == nil ? JcTheme.muted : JcTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
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

/// The themed modal picker: an opaque dark sheet with a gradient top accent; the
/// selected row gets an iridescent tint and a cyan check.
///
/// Opaque on purpose — a translucent sheet bleeds the aurora backdrop through.
struct PickerSheet<Value: Hashable>: View {
    let title: String
    let options: [PickerOption<Value>]
    @Binding var selection: Value

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(JcTheme.brandGradient).frame(height: 3)
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(JcTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 12)
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
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? JcTheme.cyan : JcTheme.muted)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(option.label)
                    .font(.system(size: 15.5, weight: selected ? .bold : .medium))
                    .foregroundStyle(JcTheme.text)
                if let subtitle = option.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(JcTheme.muted)
                }
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18)).foregroundStyle(JcTheme.cyan)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background {
            let shape = RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous)
            if selected {
                shape.fill(LinearGradient(
                    colors: [JcTheme.accent.opacity(0.22), JcTheme.cyan.opacity(0.06)],
                    startPoint: .leading, endPoint: .trailing))
            } else {
                shape.fill(JcTheme.glassFill)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous)
                .strokeBorder(selected ? JcTheme.accent.opacity(0.45) : JcTheme.glassBorder,
                              lineWidth: selected ? 1 : 0.8)
        }
    }
}
