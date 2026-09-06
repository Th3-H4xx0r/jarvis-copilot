import SwiftUI

/// Stands in for a screen another area still owns. Every tab root and every More
/// destination routes through one of these until its real page lands, so the shell
/// compiles and runs end-to-end from day one.
///
/// Replacing one: write the real view in that area's own file and swap the single
/// reference (`Copilot/Chat/ChatPage.swift`, `MorePage.destination(for:)`, …).
struct PlaceholderPage: View {
    let title: String
    var symbol: String = "square.dashed"
    /// What lands here, so a reader knows this is scaffolding and not a dead end.
    var note: String? = nil

    init(title: String, symbol: String = "square.dashed", note: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.note = note
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(JcTheme.muted)
            Text(title)
                .font(JcText.title)
                .foregroundStyle(JcTheme.text)
            Text(note ?? "Not ported yet.")
                .font(JcText.small)
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .jcScreen(title)
    }
}
