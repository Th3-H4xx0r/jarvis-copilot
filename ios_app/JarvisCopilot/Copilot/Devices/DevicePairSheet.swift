import SwiftUI

/// "Pair another device": asks the server for a code and shows it with its
/// expiry, the way the webui's pairing dialog does.
struct DevicePairSheet: View {
    let store: DevicesStore

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var reply: JSONObject?
    @State private var busy = false
    @State private var failed = false

    /// The reply as a plain map — optional-chaining a subscript would give a
    /// doubly-wrapped `Any??`, which `MoreJSON.text` would stringify as
    /// "Optional(…)".
    private var pairBody: JSONObject { reply ?? [:] }
    private var code: String { MoreJSON.text(pairBody["code"] ?? pairBody["pair_code"]) }

    var body: some View {
        DetailSheet(title: "Pair another device") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Open Jarvis on the other device and enter this code. It is valid "
                   + "for ten minutes.")
                    .font(JcText.body)
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if code.isEmpty {
                    FormTextField(label: "Label (optional)", text: $label,
                                  hint: "e.g. Work laptop")
                    if failed {
                        Text("Couldn't start pairing. Try again.")
                            .font(JcText.small).foregroundStyle(JcTheme.danger)
                    }
                } else {
                    Text(code)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .kerning(6)
                        .foregroundStyle(JcTheme.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(JcTheme.glassFill,
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .textSelection(.enabled)
                    if let expiry = MoreJSON.nonEmpty(pairBody["expires_at"]) {
                        Text("Expires \(Insights.formatTimestamp(expiry))")
                            .font(JcText.small).foregroundStyle(JcTheme.muted)
                    }
                }
            }
        } actions: {
            if code.isEmpty {
                GradientButton("Get a code", symbol: "qrcode", busy: busy) {
                    Task { await start() }
                }
            } else {
                GlassButton(title: "Done", ghost: true) { dismiss() }
            }
        }
    }

    private func start() async {
        busy = true
        failed = false
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        reply = await store.startPair(label: trimmed.isEmpty ? nil : trimmed)
        failed = reply == nil
        busy = false
    }
}
