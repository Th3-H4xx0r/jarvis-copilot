import SwiftUI

/// The quiet line under a finished reply: "1.2k in · 340 out · 12.4 s", and
/// nothing else. Rounded, tabular and tertiary so it reads as metadata rather
/// than as part of the answer — the treatment `Esp32ChatView` uses.
///
/// The text itself comes from ``ChatTurnStats/line``; this view only styles it.
struct ChatStatsLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
    }
}
