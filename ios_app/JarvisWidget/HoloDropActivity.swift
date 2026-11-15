import ActivityKit
import SwiftUI
import AppIntents
import WidgetKit

/// Holo Drop's "Drop waiting" card on the Lock Screen and in the Dynamic Island. Views live in
/// `Copilot/Shared/HoloDropActivityAttributes.swift`.
struct HoloDropActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HoloDropActivityAttributes.self) { context in
            HoloDropLockScreenView(dropID: context.attributes.dropID, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.72))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(HoloDropActivityText.url(context.attributes.dropID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: HoloDropActivityText.symbol(context.state.kind))
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(HoloDropActivityText.headline(context.state))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(HoloDropActivityText.detail(context.state))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "hand.point.up.braille.fill").foregroundStyle(.white)
            } compactTrailing: {
                Image(systemName: HoloDropActivityText.symbol(context.state.kind)).foregroundStyle(.white)
            } minimal: {
                Image(systemName: "hand.point.up.braille.fill").foregroundStyle(.white)
            }
            .widgetURL(HoloDropActivityText.url(context.attributes.dropID))
            .keylineTint(.white)
        }
    }
}

/// Control Center: one tap into Holo Drop — the Orbit with your newest photo, ready to throw.
@available(iOS 18.0, *)
struct HoloDropControl: ControlWidget {
    static let kind = "com.jarviscopilot.jarviscopilotMobileAndIOS.JarvisWidget1.HoloDropControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenURLIntent(URL(string: "jarviscopilot://holo-drop/send")!)) {
                Label("Holo Drop", systemImage: "hand.point.up.braille.fill")
            }
        }
        .displayName("Holo Drop")
        .description("Throw your newest photo to another device.")
    }
}
