import WidgetKit
import SwiftUI
import ActivityKit

/// The JARVIS stopwatch in the Dynamic Island / Lock Screen: counts up live
/// while running (the system re-renders `Text(timerInterval:)` itself), shows
/// the frozen time while stopped, and the last laps when expanded.
struct JarvisStopwatchActivity: Widget {
    private var tint: Color { Color(red: 0.31, green: 0.45, blue: 1.0) }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JarvisStopwatchAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "stopwatch.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.label)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(context.state.running ? "JARVIS · running" : "JARVIS · stopped")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                JarvisStopwatchTime(state: context.state, tint: tint,
                                    font: .system(size: 34, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .activityBackgroundTint(Color.black.opacity(0.65))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "stopwatch.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    JarvisStopwatchTime(state: context.state, tint: tint,
                                        font: .system(size: 30, weight: .semibold, design: .rounded))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    let laps = context.state.laps
                    HStack {
                        Text(context.state.running ? "Running" : "Stopped")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        if let last = laps.last {
                            Text("Lap \(max(context.state.lapCount, laps.count)) · \(JarvisStopwatchTime.format(last))")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.white)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Image(systemName: "stopwatch.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            } compactTrailing: {
                JarvisStopwatchTime(state: context.state, tint: tint,
                                    font: .system(size: 14, weight: .semibold, design: .rounded))
                    .frame(maxWidth: 70)
            } minimal: {
                Image(systemName: "stopwatch.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .keylineTint(tint)
        }
    }
}

private struct JarvisStopwatchTime: View {
    let state: JarvisStopwatchAttributes.ContentState
    let tint: Color
    let font: Font

    var body: some View {
        Group {
            if state.running {
                // Counting UP from the reference instant (now minus elapsed-so-far).
                Text(timerInterval: state.reference...Date.distantFuture, countsDown: false)
            } else {
                Text(Self.format(state.frozenElapsed))
            }
        }
        .font(font)
        .monospacedDigit()
        .foregroundStyle(tint)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .multilineTextAlignment(.trailing)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600
        let m = (Int(total) % 3600) / 60
        let s = Int(total) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
