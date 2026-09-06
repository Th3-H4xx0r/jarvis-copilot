import SwiftUI

/// The transient bottom banner the More stores raise through their `toast`
/// property — Flutter's `ScaffoldMessenger.showSnackBar`, which SwiftUI has no
/// equivalent for.
///
/// A shared component, so it lives with the rest of them: every screen whose
/// store has a `var toast: String?` uses `.moreToast($store.toast)`.
struct MoreToastModifier: ViewModifier {
    @Binding var message: String?
    var seconds: Double = 2.5

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(JcText.small)
                    .foregroundStyle(JcTheme.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(JcTheme.surfaceAlt,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    // `id:` restarts the timer when a second toast replaces the
                    // first, so the new one gets its full dwell.
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        if !Task.isCancelled { self.message = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }
}

extension View {
    /// Show `message` as a transient banner, clearing it when it times out.
    func moreToast(_ message: Binding<String?>, seconds: Double = 2.5) -> some View {
        modifier(MoreToastModifier(message: message, seconds: seconds))
    }
}
