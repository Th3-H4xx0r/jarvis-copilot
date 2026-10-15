import ActivityKit
import SwiftUI
import WidgetKit

/// One coding agent's Live Activity (Lock Screen + Dynamic Island): its logo, its
/// lead session and how many others there are. There is one of these per agent
/// TYPE with live sessions; the Jarvis voice / custom activity is separate
/// (`JarvisLiveActivity`). The views live in `Copilot/Shared/AgentActivityViews.swift`.
struct AgentLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            AgentLockScreenView(agent: context.attributes.agent, st: context.state)
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(jcAgentWidgetURL(context.state))
        } dynamicIsland: { context in
            let agent = context.attributes.agent
            let st = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    AgentIslandLeading(agent: agent, st: st)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AgentIslandTrailing(st: st)
                }
                DynamicIslandExpandedRegion(.center) {
                    if st.waitsOnYou { AgentIslandWaitingCenter(agent: agent, st: st) }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    AgentIslandBottom(st: st)
                }
            } compactLeading: {
                AgentCompactLeading(agent: agent, st: st)
            } compactTrailing: {
                AgentCompactTrailing(st: st)
            } minimal: {
                AgentMinimal(agent: agent, st: st)
            }
            .keylineTint(jcAgentStateColor(st.state))
            .widgetURL(jcAgentWidgetURL(st))
        }
    }
}
