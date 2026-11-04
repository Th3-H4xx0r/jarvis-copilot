import ActivityKit
import SwiftUI
import WidgetKit

/// A workout outside the app, for every sport: the sport, a live timer the
/// system counts itself, heart rate, distance and zone — or, for strength, the
/// next set and a rest counting down. The views live in
/// `Copilot/Shared/RingWorkoutActivityViews.swift`.
struct RingWorkoutActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RingWorkoutAttributes.self) { context in
            WorkoutLockScreenView(sport: context.attributes.sport, symbol: context.attributes.symbol,
                                  state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.72))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WorkoutIslandLeading(sport: context.attributes.sport, symbol: context.attributes.symbol,
                                         state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WorkoutIslandTrailing(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    WorkoutIslandBottom(state: context.state, isStale: context.isStale)
                }
            } compactLeading: {
                WorkoutCompactLeading(symbol: context.attributes.symbol)
            } compactTrailing: {
                WorkoutCompactTrailing(state: context.state, isStale: context.isStale)
            } minimal: {
                WorkoutCompactLeading(symbol: context.attributes.symbol)
            }
            .keylineTint(JcAccent.color)
        }
    }
}
