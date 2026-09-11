import SwiftUI

/// The centred "nothing here" / "that failed" message, with an optional Retry.
struct CenteredMessage: View {
    let text: String
    var color: Color = JcTheme.muted
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Text(text)
                .font(JcText.body)
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
            if let onRetry {
                Button("Retry", action: onRetry)
                    .font(JcText.label)
                    .foregroundStyle(JcTheme.accent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
