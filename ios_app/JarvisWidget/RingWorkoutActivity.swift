import ActivityKit
import SwiftUI
import WidgetKit

/// A ring workout outside the app: the sport, a live timer the system counts
/// itself, heart rate and distance.
struct RingWorkoutActivity: Widget {
    private var tint: Color { JcAccent.color }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RingWorkoutAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.attributes.symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.sport)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    HStack(spacing: 10) {
                        if let hr = context.state.heartRate {
                            Label("\(hr)", systemImage: "heart.fill")
                                .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.4))
                        }
                        if let km = context.state.distanceKm {
                            Text(String(format: "%.2f km", km)).foregroundStyle(.white.opacity(0.75))
                        }
                        if !context.state.running {
                            Text("Paused").foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                }
                Spacer()
                WorkoutTimerText(state: context.state, font: .system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .activityBackgroundTint(Color.black.opacity(0.65))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.sport, systemImage: context.attributes.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WorkoutTimerText(state: context.state, font: .system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        if let hr = context.state.heartRate {
                            Label("\(hr) bpm", systemImage: "heart.fill")
                                .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.4))
                        }
                        Spacer()
                        if let km = context.state.distanceKm {
                            Text(String(format: "%.2f km", km)).foregroundStyle(.white)
                        }
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Image(systemName: context.attributes.symbol).foregroundStyle(tint)
            } compactTrailing: {
                WorkoutTimerText(state: context.state, font: .system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: context.attributes.symbol).foregroundStyle(tint)
            }
            .keylineTint(tint)
        }
    }
}

/// Counts up by itself while running; the frozen time while paused.
struct WorkoutTimerText: View {
    let state: RingWorkoutAttributes.ContentState
    let font: Font

    var body: some View {
        Group {
            if state.running {
                Text(timerInterval: state.reference...Date.distantFuture, countsDown: false)
            } else {
                Text(Duration.seconds(state.frozenElapsed).formatted(.time(pattern: state.frozenElapsed >= 3600 ? .hourMinuteSecond : .minuteSecond)))
            }
        }
        .font(font)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
}
