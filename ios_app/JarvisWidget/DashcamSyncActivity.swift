import ActivityKit
import SwiftUI
import WidgetKit

/// The dashcam syncing, outside the app: what is coming off the camera and what is going to the cloud.
/// The views live in `Copilot/Shared/DashcamSyncActivityViews.swift` (black and white, 2026-11-04).
struct DashcamSyncActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DashcamSyncAttributes.self) { context in
            DashcamLockScreenView(cameraName: context.attributes.cameraName, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.72))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    DashcamIslandLeading(cameraName: context.attributes.cameraName, state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DashcamIslandTrailing(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DashcamIslandBottom(state: context.state)
                }
            } compactLeading: {
                DashcamCompactLeading(state: context.state)
            } compactTrailing: {
                DashcamCompactTrailing(state: context.state)
            } minimal: {
                DashcamCompactLeading(state: context.state)
            }
            .keylineTint(.white)
        }
    }
}
