import SwiftUI

/// Swipe a row left to show Delete; swipe far to delete at once — the list
/// gesture, for rows that are not in a `List`.
struct SwipeToDeleteRow: ViewModifier {
    let onDelete: () -> Void
    @State private var offset: CGFloat = 0
    @State private var open = false
    private let reveal: CGFloat = 76

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            if offset < 0 {
                Button {
                    withAnimation(.snappy) { offset = 0; open = false }
                    onDelete()
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: max(0, -offset), alignment: .center)
                        .frame(maxHeight: .infinity)
                        .background(JcTheme.danger)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete")
            }
            content
                .offset(x: offset)
        }
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                    offset = min(0, (open ? -reveal : 0) + value.translation.width)
                }
                .onEnded { _ in
                    withAnimation(.snappy) {
                        if offset < -reveal * 2.2 {
                            offset = 0
                            open = false
                            onDelete()
                        } else if offset < -reveal / 2 {
                            offset = -reveal
                            open = true
                        } else {
                            offset = 0
                            open = false
                        }
                    }
                })
        .accessibilityAction(named: "Delete", onDelete)
    }
}

extension View {
    func swipeToDelete(_ onDelete: @escaping () -> Void) -> some View { modifier(SwipeToDeleteRow(onDelete: onDelete)) }
}
