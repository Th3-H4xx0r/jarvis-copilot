import SwiftUI

/// A form the agent drew in the conversation.
///
/// Some questions are a bad fit for prose — "what should I call it, how often and
/// at what time" is three answers to hold in your head and type back in order.
/// The agent calls `form_ask` instead, and this draws the boxes.
///
/// The layout is fixed here, not by the model: a header, the fields in the order
/// it asked for them, and one button. The model supplies labels, types and
/// options and nothing else, which is what keeps every form looking like the app.
/// Submitting sends the answers as the user's next message, so the turn after it
/// reads them like anything else they said.
struct ChatFormCard: View {
    let formID: String
    /// Sends the answers on as the user's reply.
    let onSubmit: (String) -> Void
    var api: JarvisAPI = .shared

    @State private var form: ChatForm?
    @State private var values: [String: String] = [:]
    @State private var toggles: [String: Bool] = [:]
    @State private var errorMessage: String?
    @State private var working = false
    @FocusState private var focusedKey: String?

    var body: some View {
        GlassCard(padding: 0, borderColor: JcTheme.accent.opacity(0.3)) {
            VStack(alignment: .leading, spacing: 0) {
                if let form {
                    header(form)
                    if form.isAnswered { answered(form) } else { fields(form) }
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.danger)
                        .padding(14)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 22)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { if form == nil { await load() } }
    }

    // MARK: Pieces

    private func header(_ form: ChatForm) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 9) {
                JcIcon(form.isAnswered ? "checkmark.circle.fill" : "square.and.pencil", size: 14)
                    .foregroundStyle(form.isAnswered ? JcTheme.success : JcTheme.accent)
                    .fixedSize()
                Text(form.title)
                    .font(JcText.label)
                    .foregroundStyle(JcTheme.text)
                Spacer(minLength: 0)
            }
            if !form.intro.isEmpty, !form.isAnswered {
                Text(form.intro)
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func fields(_ form: ChatForm) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(form.fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text(field.label)
                            .font(JcText.small)
                            .foregroundStyle(JcTheme.text)
                        if field.required {
                            Text("*").font(JcText.small).foregroundStyle(JcTheme.accent)
                        }
                    }
                    control(field)
                    if !field.help.isEmpty {
                        Text(field.help)
                            .font(JcText.small)
                            .foregroundStyle(JcTheme.muted)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GradientButton(form.submitLabel, symbol: "checkmark", busy: working, full: true) {
                submit(form)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func control(_ field: ChatForm.Field) -> some View {
        switch field.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { toggles[field.key] ?? false },
                                 set: { toggles[field.key] = $0 })) {
                Text(toggles[field.key] == true ? "Yes" : "No")
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.muted)
            }
            .tint(JcTheme.accent)

        case .choice:
            // Every option on screen: a short list is quicker to tap than to open.
            JcWrap(spacing: 8, runSpacing: 8) {
                ForEach(field.options, id: \.self) { option in
                    let picked = values[field.key] == option
                    Button { values[field.key] = picked ? "" : option } label: {
                        Text(option)
                            .font(JcText.small)
                            .foregroundStyle(picked ? JcTheme.bg : JcTheme.text)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(picked ? JcTheme.accent : JcTheme.glassFill, in: Capsule())
                            .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

        case .multiline:
            box(field, axis: .vertical, lines: 2...5)

        case .number:
            box(field, axis: .horizontal, lines: 1...1, keyboard: .decimalPad)

        case .text:
            box(field, axis: .horizontal, lines: 1...1)
        }
    }

    private func box(_ field: ChatForm.Field, axis: Axis, lines: ClosedRange<Int>,
                     keyboard: UIKeyboardType = .default) -> some View {
        TextField(field.placeholder,
                  text: Binding(get: { values[field.key] ?? "" },
                                set: { values[field.key] = $0 }),
                  axis: axis)
            .lineLimit(lines)
            .keyboardType(keyboard)
            .focused($focusedKey, equals: field.key)
            .jcFieldStyle()          // the app's frosted input, not a box of my own
            .overlay(RoundedRectangle(cornerRadius: JcTheme.fieldRadius, style: .continuous)
                .strokeBorder(JcTheme.accent, lineWidth: focusedKey == field.key ? 1 : 0))
    }

    /// Once answered the card keeps what was entered, rather than going blank —
    /// scrolling back should show what you said, not an empty form.
    private func answered(_ form: ChatForm) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(form.fields) { field in
                VStack(alignment: .leading, spacing: 1) {
                    Text(field.label)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                    Text(form.shownValue(for: field))
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    // MARK: Actions

    private func load() async {
        do {
            let loaded = ChatForm(json: try await api.get("/api/forms/\(formID)").object())
            form = loaded
            for field in loaded.fields where !field.defaultValue.isEmpty {
                values[field.key] = field.defaultValue
            }
            errorMessage = nil
            focusFirstBox(in: loaded)
        } catch {
            errorMessage = apiErrorMessage(error)
        }
    }

    /// A form arrives to be filled in, so it opens with the keyboard up on the
    /// first thing you actually type into — a choice or a toggle is tapped, not
    /// typed, and focusing one would raise a keyboard with nowhere to go.
    private func focusFirstBox(in form: ChatForm) {
        guard !form.isAnswered else { return }
        guard let first = form.fields.first(where: {
            $0.kind == .text || $0.kind == .multiline || $0.kind == .number
        }) else { return }
        // A frame later: the field has to be in the hierarchy to take focus.
        Task { @MainActor in focusedKey = first.key }
    }

    private func submit(_ form: ChatForm) {
        working = true
        errorMessage = nil
        var payload: [String: Any] = values
        for field in form.fields where field.kind == .toggle {
            payload[field.key] = toggles[field.key] ?? false
        }
        Task {
            do {
                let body = try await api.post("/api/forms/\(formID)/submit",
                                              json: ["values": payload]).object()
                self.form = ChatForm(json: MoreJSON.map(body["form"]))
                focusedKey = nil
                onSubmit(MoreJSON.text(body["reply"]))
            } catch {
                errorMessage = apiErrorMessage(error)
            }
            working = false
        }
    }
}

/// What the agent asked for, as the card draws it.
struct ChatForm: Equatable, Sendable {
    struct Field: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable { case text, multiline, number, choice, toggle }

        var key: String
        var label: String
        var kind: Kind
        var placeholder: String
        var help: String
        var options: [String]
        var required: Bool
        var defaultValue: String
        var id: String { key }
    }

    var id: String
    var title: String
    var intro: String
    var submitLabel: String
    var status: String
    var fields: [Field]
    var values: JSONObject

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"])
        title = MoreJSON.text(json["title"])
        intro = MoreJSON.text(json["intro"])
        let label = MoreJSON.text(json["submit_label"])
        submitLabel = label.isEmpty ? "Done" : label
        status = MoreJSON.text(json["status"])
        values = MoreJSON.map(json["values"])
        fields = MoreJSON.mapList(json["fields"]).map { raw in
            Field(key: MoreJSON.text(raw["key"]),
                  label: MoreJSON.text(raw["label"]),
                  kind: Field.Kind(rawValue: MoreJSON.text(raw["type"])) ?? .text,
                  placeholder: MoreJSON.text(raw["placeholder"]),
                  help: MoreJSON.text(raw["help"]),
                  options: MoreJSON.stringList(raw["options"]),
                  required: MoreJSON.isTrue(raw["required"]),
                  defaultValue: MoreJSON.text(raw["default"]))
        }
    }

    static func == (l: ChatForm, r: ChatForm) -> Bool {
        l.id == r.id && l.status == r.status && l.fields == r.fields
    }

    var isAnswered: Bool { status == "answered" }

    func shownValue(for field: Field) -> String {
        let raw = values[field.key]
        if let flag = raw as? Bool { return flag ? "Yes" : "No" }
        let text = MoreJSON.text(raw)
        return text.isEmpty ? "—" : text
    }

    /// The form's id, out of the tool call that asked for it.
    static func formID(in tool: ToolInvocation) -> String? {
        guard tool.name == "form_ask" else { return nil }
        for text in [tool.result, tool.preview].compactMap({ $0 }) {
            guard let range = text.range(of: "\"form_id\"") else { continue }
            let tail = text[range.upperBound...]
            guard let open = tail.firstIndex(of: "\""),
                  case let start = tail.index(after: open),
                  let close = tail[start...].firstIndex(of: "\"") else { continue }
            let value = String(tail[start..<close])
            if !value.isEmpty { return value }
        }
        return nil
    }
}
