import SwiftUI

/// The "that refresh failed" strip, for screens that already have content.
///
/// Every More screen renders its `errorMessage` only when its collection is
/// EMPTY — so the first load failing is visible, but a pull-to-refresh that
/// fails while rows are on screen is completely silent: the spinner retracts,
/// nothing changes, and the user reads stale data as current. This is the other
/// half of that story: a non-blocking banner over content that is still good.
///
/// Deliberately dismissible and deliberately not a `CenteredMessage`: the data
/// underneath is real, just older than the user asked for.
struct LoadErrorBannerModifier: ViewModifier {
    let message: String?
    /// Whether the screen is showing something. `false` means the page's own
    /// full-screen error state is (or should be) up, and two error affordances
    /// at once is worse than one.
    let hasContent: Bool

    /// The message the user dismissed, so the same failure doesn't come back on
    /// the next re-render. A NEW message shows again.
    @State private var dismissed: String?

    private var shown: String? {
        guard hasContent, let message, !message.isEmpty, message != dismissed else { return nil }
        return message
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let shown {
                    banner(shown)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: shown)
    }

    private func banner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.amber)
            Text(text)
                .font(JcText.small)
                .foregroundStyle(JcTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                dismissed = text
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(JcTheme.surfaceAlt,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(JcTheme.amber.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }
}

extension View {
    /// Show `message` as a non-blocking banner while the screen still has
    /// content to show. A screen with nothing on it keeps its own full-screen
    /// error state instead.
    func loadErrorBanner(_ message: String?, hasContent: Bool) -> some View {
        modifier(LoadErrorBannerModifier(message: message, hasContent: hasContent))
    }
}
