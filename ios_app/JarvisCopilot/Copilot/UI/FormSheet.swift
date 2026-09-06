import SwiftUI

/// An OPAQUE modal sheet for create/edit forms, ported from `widgets/form_sheet.dart`.
///
/// Opaque (`JcTheme.surface`) is deliberate — a translucent sheet bleeds the aurora
/// backdrop through, the recurring JARVIS-skin gotcha.
///
/// `onSave` returns true on success (the sheet dismisses) or false to stay open
/// (validation failed and the caller surfaced why).
///
/// ```swift
/// .sheet(isPresented: $editing) {
///     FormSheet(title: "New todo", onSave: { await store.save() }) {
///         FormTextField(label: "Title", text: $title)
///     }
/// }
/// ```
struct FormSheet<Fields: View>: View {
    let title: String
    var saveLabel: String = "Save"
    let onSave: () async -> Bool
    @ViewBuilder var fields: Fields

    init(title: String,
         saveLabel: String = "Save",
         onSave: @escaping () async -> Bool,
         @ViewBuilder fields: () -> Fields) {
        self.title = title
        self.saveLabel = saveLabel
        self.onSave = onSave
        self.fields = fields()
    }

    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(JcTheme.text)
                    .padding(.bottom, 16)
                fields
                HStack(spacing: 12) {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                        .tint(JcTheme.muted)
                        .frame(maxWidth: .infinity)
                        .disabled(saving)
                    Button {
                        saving = true
                        Task {
                            let ok = await onSave()
                            saving = false
                            if ok { dismiss() }
                        }
                    } label: {
                        if saving {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Text(saveLabel)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(JcTheme.accent)
                    .frame(maxWidth: .infinity)
                    .disabled(saving)
                }
                .padding(.top, 20)
            }
            .padding(20)
        }
        .background(JcTheme.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// An uppercase muted field label — the form-field caption.
struct FormFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11.5, weight: .bold))
            .kerning(0.6)
            .foregroundStyle(JcTheme.muted)
    }
}

/// Labelled, optionally multiline text field for use inside a `FormSheet`.
struct FormTextField: View {
    let label: String
    @Binding var text: String
    var hint: String = ""
    var lineLimit: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            FormFieldLabel(label)
            Group {
                if lineLimit > 1 {
                    TextField(hint, text: $text, axis: .vertical).lineLimit(lineLimit...)
                } else {
                    TextField(hint, text: $text)
                }
            }
            .jcFieldStyle()
        }
        .padding(.bottom, 16)
    }
}

/// Labelled select for use inside a `FormSheet` — opens the themed picker sheet.
struct FormDropdown<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [PickerOption<Value>]
    var sheetTitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            FormFieldLabel(label)
            PickerField(selection: $selection, options: options,
                        hint: label, sheetTitle: sheetTitle ?? label)
        }
        .padding(.bottom, 16)
    }
}

/// Labelled on/off switch for use inside a `FormSheet`.
struct FormToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label).font(JcText.body).foregroundStyle(JcTheme.text)
        }
        .tint(JcTheme.accent)
        .padding(.bottom, 6)
    }
}

/// Multi-select chip row for use inside a `FormSheet`.
struct FormChipMulti: View {
    let label: String
    let all: [String]
    @Binding var selected: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(JcTheme.muted)
            JcWrap(spacing: 8) {
                ForEach(all, id: \.self) { item in
                    let on = selected.contains(item)
                    Button {
                        if on { selected.remove(item) } else { selected.insert(item) }
                    } label: {
                        HStack(spacing: 5) {
                            if on {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(JcTheme.accent)
                            }
                            Text(item).font(JcText.small)
                        }
                        .foregroundStyle(on ? JcTheme.text : JcTheme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(on ? JcTheme.accent.opacity(0.3) : JcTheme.surfaceAlt, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.bottom, 14)
    }
}

/// Flutter's `Wrap` — lay children out in rows, wrapping at the container width.
/// SwiftUI has no equivalent container, so this is a small `Layout`.
struct JcWrap: Layout {
    var spacing: CGFloat = 8
    var runSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rows: CGFloat = 1, x: CGFloat = 0, rowHeight: CGFloat = 0, total: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > width {
                total += rowHeight + runSpacing
                rows += 1; x = 0; rowHeight = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        _ = rows
        return CGSize(width: proposal.width ?? x, height: total + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + spacing + size.width > bounds.maxX {
                y += rowHeight + runSpacing
                x = bounds.minX; rowHeight = 0
            }
            if x > bounds.minX { x += spacing }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension View {
    /// The frosted input decoration from `theme.dart`'s `inputDecorationTheme`:
    /// glass fill, 14pt radius, hairline border.
    func jcFieldStyle(radius: CGFloat = JcTheme.fieldRadius) -> some View {
        self
            .font(JcText.body)
            .foregroundStyle(JcTheme.text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }
}
