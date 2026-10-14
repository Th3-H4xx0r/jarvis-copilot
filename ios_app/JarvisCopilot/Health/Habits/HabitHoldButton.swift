import SwiftUI

/// Hold for 3 seconds to log a relapse — long enough that a pocket or a
/// passing thumb never does it. A ring fills while it is held, with a tick
/// each second; letting go early drains it and nothing is logged. Around it,
/// the streak target's progress.
struct HabitHoldButton: View {
    /// Toward the streak target, 0–1; nil when there is none.
    var goalProgress: Double?
    let onComplete: () -> Void

    @State private var fill: CGFloat = 0
    @State private var pressing = false
    @State private var completed = false
    @State private var tick = 0
    @State private var done = 0
    @State private var ticking: Task<Void, Never>?

    static let holdSeconds: Double = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 4)
            if let goalProgress {
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, goalProgress)))
                    .stroke(JcTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(pressing ? Color.orange : JcTheme.accent)
                .frame(width: 50, height: 50)
                .jcLiquidGlass(in: Circle(), tint: pressing ? Color.orange.opacity(0.25) : .clear)
                .overlay {
                    Circle()
                        .trim(from: 0, to: fill)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2)
                }
                .scaleEffect(pressing ? 0.94 : 1)
                .animation(.snappy(duration: 0.2), value: pressing)
        }
        .frame(width: 64, height: 64)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: Self.holdSeconds, maximumDistance: 30) {
            completed = true
            done += 1
            onComplete()
            withAnimation(.easeOut(duration: 0.3).delay(0.3)) { fill = 0 }
        } onPressingChanged: { isPressing in
            pressing = isPressing
            if isPressing {
                completed = false
                withAnimation(.linear(duration: Self.holdSeconds)) { fill = 1 }
                ticking?.cancel()
                ticking = Task { @MainActor in
                    for _ in 0..<Int(Self.holdSeconds) - 1 {
                        try? await Task.sleep(for: .seconds(1))
                        if Task.isCancelled { return }
                        tick += 1
                    }
                }
            } else {
                ticking?.cancel()
                if !completed { withAnimation(.easeOut(duration: 0.25)) { fill = 0 } }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: tick)
        .sensoryFeedback(.impact(weight: .heavy), trigger: done)
        .accessibilityElement()
        .accessibilityLabel("Log a relapse")
        .accessibilityHint("Hold for 3 seconds")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Log a relapse") { onComplete() }
    }
}
