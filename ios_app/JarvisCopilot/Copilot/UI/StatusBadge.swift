import SwiftUI

/// The bridge's three states, as `status_badge.dart` models them. Kept separate
/// from `BridgeClient.Status` (which carries a failure message) because this is
/// purely what the badge needs to draw.
enum BridgeStatusKind: Equatable {
    case offline, connecting, online

    var color: Color {
        switch self {
        case .offline:    return JcTheme.muted
        case .connecting: return JcTheme.accent
        case .online:     return JcTheme.success
        }
    }

    var defaultLabel: String {
        switch self {
        case .offline:    return "offline"
        case .connecting: return "connecting…"
        case .online:     return "online"
        }
    }
}

/// A dot plus a word — the connection indicator in every screen's chrome.
struct StatusBadge: View {
    let status: BridgeStatusKind
    var label: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
                // Only the online state glows, so a live link is obvious at a glance.
                .shadow(color: status == .online ? status.color.opacity(0.6) : .clear, radius: 3)
            Text(label ?? status.defaultLabel)
                .font(.system(size: 11.5))
                .foregroundStyle(status.color)
        }
    }
}
