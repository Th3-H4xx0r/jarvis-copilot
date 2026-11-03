import SwiftUI

/// The quiet line under a finished reply: "1.2k in · 340 out · 12.4 s", and
/// nothing else. Rounded, tabular and tertiary so it reads as metadata rather
/// than as part of the answer — the treatment `Esp32ChatView` uses.
///
/// The text itself comes from ``ChatTurnStats/line``; this view only styles it.
struct ChatStatsLine: View {
    let text: String
    /// What a tap shows (route, tokens, cache…); none → plain text.
    var details: [(String, String)] = []

    @State private var showing = false

    var body: some View {
        if details.isEmpty {
            label
        } else {
            Button { showing = true } label: {
                HStack(spacing: 4) {
                    label
                    Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows how this reply was made")
            .popover(isPresented: $showing) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(details.indices, id: \.self) { i in
                        GridRow {
                            Text(details[i].0).foregroundStyle(JcTheme.muted)
                            Text(details[i].1).foregroundStyle(JcTheme.text)
                        }
                    }
                }
                .font(.footnote.monospacedDigit())
                .padding(14)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
    }
}
