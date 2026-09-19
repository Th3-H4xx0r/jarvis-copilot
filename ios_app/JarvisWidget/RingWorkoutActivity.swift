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
                    if let detail = context.state.detail {
                        Text("Next: \(detail)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        if let hr = context.state.heartRate {
                            Label("\(hr)", systemImage: "heart.fill")
                                .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.4))
                        }
                        if let distance = context.state.distanceText {
                            Text(distance).foregroundStyle(.white.opacity(0.75))
                        }
                        if !context.state.running {
                            Text("Paused").foregroundStyle(.orange)
                        }
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                }
                Spacer()
                if let rest = RestWindow(context) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Rest").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                        Text(timerInterval: rest.range, countsDown: true)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(Color(red: 1, green: 0.76, blue: 0.3))
                    }
                } else {
                    WorkoutTimerText(state: context.state, font: .system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) {
                if let rest = RestWindow(context) {
                    ProgressView(timerInterval: rest.range, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                        .tint(Color(red: 1, green: 0.76, blue: 0.3))
                        .padding(.horizontal, 18)
                        .padding(.bottom, 6)
                }
            }
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
                    if let rest = RestWindow(context) {
                        Text(timerInterval: rest.range, countsDown: true)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(Color(red: 1, green: 0.76, blue: 0.3))
                            .padding(.trailing, 4)
                    } else {
                        WorkoutTimerText(state: context.state, font: .system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let detail = context.state.detail {
                        Text(RestWindow(context) == nil ? detail : "Next: \(detail)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                    }
                    HStack {
                        if let hr = context.state.heartRate {
                            Label("\(hr) bpm", systemImage: "heart.fill")
                                .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.4))
                        }
                        Spacer()
                        if let distance = context.state.distanceText {
                            Text(distance).foregroundStyle(.white)
                        }
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Image(systemName: context.attributes.symbol).foregroundStyle(tint)
            } compactTrailing: {
                if let rest = RestWindow(context) {
                    Text(timerInterval: rest.range, countsDown: true)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(Color(red: 1, green: 0.76, blue: 0.3))
                        .frame(maxWidth: 56)
                } else {
                    WorkoutTimerText(state: context.state, font: .system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                        .frame(maxWidth: 56)
                }
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

/// A strength rest the widget counts down by itself.
struct RestWindow: Equatable {
    let range: ClosedRange<Date>

    init?(_ context: ActivityViewContext<RingWorkoutAttributes>) {
        let state = context.state
        guard !context.isStale, let ends = state.restEnds, ends > Date() else { return nil }
        range = min(state.restStarted ?? ends, ends)...ends
    }
}
