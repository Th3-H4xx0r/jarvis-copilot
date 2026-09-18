import SwiftUI

extension View {
    /// Calls `reveal` once this view is at least a third on screen, so what is
    /// inside it (a ring filling, a chart drawing) plays when it is seen, not
    /// when the screen loads. Outside a scroll view it is on screen at once.
    func onScrolledIntoView(_ reveal: @escaping () -> Void) -> some View {
        onGeometryChange(for: Bool.self) { proxy in
            // The visible region is the scroll view's own size at its origin;
            // `frame(in: .scrollView)` is measured against that. (Its bounds
            // come back in this view's space, which is why they are not used.)
            guard let size = proxy.bounds(of: .scrollView)?.size else { return true }
            let frame = proxy.frame(in: .scrollView)
            let seen = frame.intersection(CGRect(origin: .zero, size: size)).height
            return seen >= min(frame.height, size.height) * 0.33
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

extension String {
    /// The same text with every digit at zero — where an odometer starts, so
    /// `numericText` rolls each digit up to its value ("0,000" → "7,520").
    var odometerZero: String { String(map { $0.isNumber ? "0" : $0 }) }
}

extension Animation {
    /// Long enough to read as digits rolling up, not a flicker.
    static let odometer = Animation.spring(duration: 1.0, bounce: 0.08)
}
