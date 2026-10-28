import WidgetKit
import SwiftUI
import ActivityKit
import UIKit

struct JarvisLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JarvisActivityAttributes.self) { context in
            JarvisFamilyLockScreen(st: context.state)
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: jcWidgetURL(context.state)))
        } dynamicIsland: { context in
            jarvisDynamicIsland(context.state)
        }
        // The `.small` card: the CarPlay Dashboard (and the Watch Smart Stack).
        .supplementalActivityFamilies([.small])
    }
}

/// The Dynamic Island.
func jarvisDynamicIsland(_ st: JarvisActivityAttributes.ContentState) -> DynamicIsland {
    // Custom data-driven design (Dynamic Island Designs). A `regions`
    // top-level node maps to the native DI regions; otherwise the whole
    // expanded tree lands in the bottom region. Compact/minimal pull from
    // their presentation nodes, with the orb/fallback as a safety net.
    if st.mode == "custom" {
        let design = JCDesignCache.load(st.designId)
        let ctx = JCBindingContext(dataJSON: st.data)
        let tint = design.flatMap { jcParseColor($0.tint) } ?? jcCodingColor("working")
        let node = design?.presentations.expanded
        let isRegions = (node?.type == "regions")
        // Declare the four regions inline (mirrors the coding pattern) so
        // the @DynamicIslandExpandedContentBuilder body is straight-line;
        // all branching lives inside each region's ViewBuilder closure.
        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                if isRegions {
                    JCDesignRenderer(tint: tint, liveOrb: true).render(node?.node("leading"), ctx)
                }
            }
            DynamicIslandExpandedRegion(.trailing) {
                if isRegions {
                    JCDesignRenderer(tint: tint, liveOrb: true).render(node?.node("trailing"), ctx)
                }
            }
            DynamicIslandExpandedRegion(.center) {
                if isRegions {
                    JCDesignRenderer(tint: tint, liveOrb: true).render(node?.node("center"), ctx)
                }
            }
            DynamicIslandExpandedRegion(.bottom) {
                // Small safety inset so wide content (bars/lists) doesn't
                // run into the island's rounded corners; designs should
                // still pad their own root (see the skill's layout rules).
                Group {
                    if isRegions {
                        JCDesignRenderer(tint: tint, liveOrb: true).render(node?.node("bottom"), ctx)
                    } else if let node = node {
                        JCDesignRenderer(tint: tint, liveOrb: true).render(node, ctx)
                    } else {
                        JCDesignFallback(st: st)
                    }
                }
                .padding(.horizontal, 6)
            }
        } compactLeading: {
            JCDesignView(st: st, presentation: .compactLeading)
        } compactTrailing: {
            JCDesignView(st: st, presentation: .compactTrailing)
        } minimal: {
            JCDesignView(st: st, presentation: .minimal)
        }
        .widgetURL(URL(string: jcWidgetURL(st)))
    }
    return DynamicIsland {
        // Voice, centred like Siri: the pulsing orb leading, the glass stop trailing,
        // and under them, centred, "Listening 0:04", his words and Jarvis's answer.
        // Coding keeps its fleet view.
        DynamicIslandExpandedRegion(.leading) {
            if st.mode == "coding" {
                HStack(spacing: 9) {
                    JarvisOrb(state: "idle", size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude Code").font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        (Text("\(st.sessionTotal) sessions").foregroundColor(.white.opacity(0.55))
                         + Text(st.waitingCount > 0 ? " · \(st.waitingCount) waiting" : "")
                            .foregroundColor(jcCodingColor("waiting")))
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .padding(.leading, 4)
            } else {
                JarvisOrbBadge(st: st, size: 58)
                    .padding(.leading, 2)
            }
        }
        DynamicIslandExpandedRegion(.trailing) {
            if st.mode == "coding" {
                JCUsageBlock(st: st).padding(.trailing, 4)
            } else {
                // The stop that ends the talk; at rest, a mic.
                JarvisVoiceControls(st: st, size: 42)
                    .frame(height: 58)
                    .padding(.trailing, 4)
            }
        }
        DynamicIslandExpandedRegion(.center) {
            // Under the camera, between the orb and the stop: "Listening 0:04".
            if st.mode != "coding" {
                JarvisVoiceStateLine(st: st)
                    .padding(.top, 2)
            }
        }
        DynamicIslandExpandedRegion(.bottom) {
            if st.mode == "coding" {
                VStack(alignment: .leading, spacing: 9) {
                    if !st.leadAgent.isEmpty {
                        JCLeadRow(st: st)
                    } else {
                        JCSegBar(sessions: jcDecodeSessions(st.sessions))
                    }
                    JCLegend(sessions: jcDecodeSessions(st.sessions), total: st.entryTotal)
                }
            } else {
                // Centred: his words and Jarvis's answer.
                if jcVoiceHasWords(st) {
                    JarvisExchange(st: st, mainSize: 17, mainLines: 2)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
        }
    } compactLeading: {
        if st.mode == "coding" {
            JCCompactSpinner(color: jcCodingColor(jcSpotlight(st.sessions)?.state ?? "idle"))
        } else {
            JarvisOrbBadge(st: st, size: 34)
        }
    } compactTrailing: {
        if st.mode == "coding" {
            JCCompactFleetBar(sessions: jcDecodeSessions(st.sessions))
        } else {
            JarvisCompactTrailing(st: st)
                .frame(height: 34)
        }
    } minimal: {
        if st.mode == "coding" {
            JCCompactSpinner(color: jcCodingColor(jcSpotlight(st.sessions)?.state ?? "idle"))
        } else {
            JarvisOrbBadge(st: st, size: 30)
        }
    }
    .widgetURL(URL(string: jcWidgetURL(st)))
}

/// Deep-link target for a tap on the activity. Coding → coding tab; custom →
/// the island tab; voice (and fallback) → the Voice screen.
func jcWidgetURL(_ st: JarvisActivityAttributes.ContentState) -> String {
    switch st.mode {
    case "coding":
        guard !st.leadKey.isEmpty,
              let key = st.leadKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return "jarviscopilot://agents" }
        return "jarviscopilot://agents?key=\(key)"
    case "custom": return "jarviscopilot://island"
    default: return "jarviscopilot://voice"
    }
}

/// The Lock Screen / banner presentation: custom design, the coding fleet, or the voice card
/// (orb, state, waveform, the latest words).
struct JarvisLockScreen: View {
    let st: JarvisActivityAttributes.ContentState
    var body: some View {
        if st.mode == "custom" {
            // Data-driven custom design (Dynamic Island Designs). Renders the
            // cached layout tree; falls back to app name + data.title if missing.
            JCDesignView(st: st, presentation: .lockScreen)
        } else if st.mode == "coding" {
            // Coding fleet view (Scheme 4): header + segmented bar + legend.
            JarvisCodingBody(st: st)
                .padding(.horizontal, 16).padding(.vertical, 13)
        } else {
            JarvisVoiceLockScreen(st: st)
        }
    }
}

@main
struct JarvisWidgetBundle: WidgetBundle {
    var body: some Widget {
        JarvisWidget()
        // Dynamic Island / Lock Screen Live Activity, and its CarPlay card.
        JarvisLiveActivity()
        // The car's Talk to Jarvis button (CarPlay's Widgets page).
        JarvisCarTalkWidget()
        // One per coding agent with live sessions, wearing that agent's logo.
        AgentLiveActivity()
        JarvisStopwatchActivity()
        RingWorkoutActivity()
        // A Jarvis button's countdown: arming, remote start, a sterilise cycle.
        ButtonActivity()
        // Live Jarvis recording the room.
        LiveCaptureActivity()
        // The dashcam syncing (on its Wi-Fi, clips moving).
        DashcamSyncActivity()
        // Ring health: any of the server's scores on the home or lock screen.
        if #available(iOS 17.0, *) {
            HealthWidget()
        }
        // Any design from the widget creator.
        JarvisDesignWidget()
        // Coding agents: the one that needs you, or the list.
        AgentsWidget()
        // AlarmKit alarm / timer countdown (iOS 26+). The type only exists
        // when the SDK has AlarmKit, so the availability check is not enough.
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            JarvisAlarmActivity()
        }
        #endif
        // Control Center button — only on iOS 18+, where Controls exist.
        if #available(iOS 18.0, *) {
            JarvisVoiceControl()
            JarvisTalkHereControl()
            JarvisButtonControl()
            JarvisSwitchControl()
            AgentsControl()
        }
    }
}

