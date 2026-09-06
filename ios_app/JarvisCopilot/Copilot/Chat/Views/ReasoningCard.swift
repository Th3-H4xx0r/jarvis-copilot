import SwiftUI

/// The collapsible "thought process" trace at the top of an assistant card,
/// ported from `chat/widgets/reasoning_card.dart`. Collapsed by default — the
/// reasoning is context, not the answer — and labelled "Thinking…" while it is
/// still the only thing arriving.
struct ChatReasoningCard: View {
    let text: String
    /// The model is still reasoning and no visible text has arrived yet.
    var active = false

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").font(.system(size: 11))
                    Text(active ? "Thinking…" : "Thought process")
                        .font(.system(size: 12, weight: .bold))
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(0.7)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .foregroundStyle(JcTheme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 12.5))
                        .foregroundStyle(JcTheme.text.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(JcTheme.accent.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(JcTheme.accent.opacity(0.18), lineWidth: 1))
    }
}
