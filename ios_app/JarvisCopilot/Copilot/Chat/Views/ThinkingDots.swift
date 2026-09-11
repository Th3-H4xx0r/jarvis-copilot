import SwiftUI

/// Three dots rising in sequence — the "still working" indicator in the chat,
/// the ESP32 chat and coding tool cards.
struct ThinkingDots: View {
    var size: CGFloat = 7
    var color: Color = .secondary
    @State private var phase = false

    var body: some View {
        HStack(spacing: size * 0.7) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
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
