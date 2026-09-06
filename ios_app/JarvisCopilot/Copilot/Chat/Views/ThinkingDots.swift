import SwiftUI

/// Three dots rising in sequence — the "still working" indicator under an
/// assistant turn that has produced nothing visible yet.
///
/// Lifted verbatim from `Esp32ChatView.swift`'s `ThinkingDots` so both chats look
/// identical. It is named `Chat…` only because that file still declares its own
/// module-scope `ThinkingDots`; when Esp32ChatView adopts these views its copy
/// goes away and this becomes the single implementation.
struct ChatThinkingDots: View {
    var size: CGFloat = 7
    @State private var phase = false

    var body: some View {
        HStack(spacing: size * 0.7) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: size, height: size)
                    .offset(y: phase ? -size * 0.6 : size * 0.3)
                    .opacity(phase ? 1 : 0.45)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.16), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}
