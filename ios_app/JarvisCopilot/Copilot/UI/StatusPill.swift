import SwiftUI

/// A compact status chip: a coloured label on a soft tinted background, used
/// across the More-tab screens so status reads the same everywhere. `live` adds a
/// gently pulsing leading dot (a running task). Ported from `status_pill.dart`.
struct StatusPill: View {
    let label: String
    let color: Color
    var live: Bool = false
    var dense: Bool = false

    init(_ label: String, color: Color, live: Bool = false, dense: Bool = false) {
        self.label = label
        self.color = color
        self.live = live
        self.dense = dense
    }

    var body: some View {
        // The Voice page's status pill: a quiet translucent capsule where only
        // the dot carries the colour, instead of a tinted badge.
        HStack(spacing: 6) {
            if live { PulsingDot(color: color, size: dense ? 6 : 7) }
            else { Circle().fill(color).frame(width: dense ? 5 : 6, height: dense ? 5 : 6) }
            Text(label)
                .font(.system(size: dense ? 10.5 : 11.5, weight: .medium))
                .foregroundStyle(JcTheme.text.opacity(0.85))
        }
        .padding(.horizontal, dense ? 8 : 11)
        .padding(.vertical, dense ? 3 : 5)
        .background(.white.opacity(0.045), in: Capsule())
    }
}

/// A small dot that breathes (opacity + halo) — signals a live/active state.
///
/// The animation is driven by a single repeating `withAnimation`, so a list of
/// these costs one animation each rather than a ticker per frame.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8

    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(expanded ? 0.25 : 0.7), radius: expanded ? 3.5 : 1)
            .opacity(expanded ? 0.65 : 1)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: expanded)
            .onAppear { expanded = true }
    }
}

/// A bold section heading used inside detail sheets and dashboards.
struct SectionHeader<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing

    init(_ text: String, @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 11.5, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(JcTheme.muted)
            Spacer()
            trailing
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ text: String) { self.init(text) { EmptyView() } }
}
