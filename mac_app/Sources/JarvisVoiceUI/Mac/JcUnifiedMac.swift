import SwiftUI

// The two pieces of the iPhone's unified design (ios_app/.../UI/JcUnified.swift)
// that the shared voice code uses. That file pulls in the iPhone's whole page
// chrome, so the Mac voice library carries just these; keep them in step.

enum JcUnified {
    static let cardRadius: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 24
    static let labelGap: CGFloat = 8
    static let pageInset: CGFloat = 16
    static let iconSquare: CGFloat = 28
}

/// A small tinted action (same initializer as the iPhone's).
struct JcSmallAction: View {
    let title: String
    var symbol: String?
    var tint: Color = JcTheme.accent
    var busy = false
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, tint: Color = JcTheme.accent, busy: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.busy = busy
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if busy {
                    JcLoader(size: 12)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                }
                Text(title).lineLimit(1).fixedSize()
            }
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(busy)
    }
}
