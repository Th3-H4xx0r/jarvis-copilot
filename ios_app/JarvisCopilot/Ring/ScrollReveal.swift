import SwiftUI

extension View {
    /// Cards rise and fade in as they scroll into view, and ease back a little
    /// as they leave at the top — the motion stays with the scroll, not a timer.
    func scrollReveal() -> some View {
        scrollTransition(.animated(.spring(duration: 0.55, bounce: 0.12)).threshold(.visible(0.12))) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : (phase.value < 0 ? 0.55 : 0))
                .scaleEffect(phase.isIdentity ? 1 : 0.96)
                .offset(y: phase.value > 0 ? 28 : 0)
        }
    }

    /// Calls `reveal` once this view is at least a third on screen, so what is
    /// inside it (a ring filling, a chart drawing) plays when it is seen, not
    /// when the screen loads. Outside a scroll view it is on screen at once.
    func onScrolledIntoView(_ reveal: @escaping () -> Void) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            guard let viewport = proxy.bounds(of: .scrollView) else { return true }
            let frame = proxy.frame(in: .scrollView)
            let seen = frame.intersection(viewport).height
            return seen >= min(frame.height, viewport.height) * 0.33
        } action: { visible in
            if visible { reveal() }
        }
    }
}

/// Progress toward a goal as a ring, with what is left inside it: it fills
/// from empty and the count rolls down once the card is seen.
struct RingGoalRing: View {
    let value: Int
    let goal: Int
    var revealed = true
    var tint: Color = JcTheme.accent

    private var progress: Double { goal > 0 ? min(1, Double(value) / Double(goal)) : 0 }
    private var remaining: Int { max(0, goal - value) }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 6)
            Circle()
                .trim(from: 0, to: revealed ? progress : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 1.1, bounce: 0.1), value: revealed)
                .animation(.snappy, value: progress)
            VStack(spacing: 0) {
                if remaining == 0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(tint)
                    Text("Goal")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text((revealed ? remaining : goal).formatted())
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText(value: Double(revealed ? remaining : goal)))
                        .animation(.spring(duration: 1.1, bounce: 0.1), value: revealed)
                    Text("to go")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(width: 66, height: 66)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(remaining == 0 ? "Step goal met" : "\(remaining.formatted()) steps to your goal of \(goal.formatted())")
    }
}
