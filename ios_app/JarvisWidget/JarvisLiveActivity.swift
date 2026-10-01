import WidgetKit
import SwiftUI
import ActivityKit
import UIKit

struct JarvisLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JarvisActivityAttributes.self) { context in
            JarvisLockScreen(st: context.state)
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: jcWidgetURL(context.state)))
        } dynamicIsland: { context in
            let st = context.state
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
                            JCDesignRenderer(tint: tint).render(node?.node("leading"), ctx)
                        }
                    }
                    DynamicIslandExpandedRegion(.trailing) {
                        if isRegions {
                            JCDesignRenderer(tint: tint).render(node?.node("trailing"), ctx)
                        }
                    }
                    DynamicIslandExpandedRegion(.center) {
                        if isRegions {
                            JCDesignRenderer(tint: tint).render(node?.node("center"), ctx)
                        }
                    }
                    DynamicIslandExpandedRegion(.bottom) {
                        // Small safety inset so wide content (bars/lists) doesn't
                        // run into the island's rounded corners; designs should
                        // still pad their own root (see the skill's layout rules).
                        Group {
                            if isRegions {
                                JCDesignRenderer(tint: tint).render(node?.node("bottom"), ctx)
                            } else if let node = node {
                                JCDesignRenderer(tint: tint).render(node, ctx)
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
                // Header left-aligned: orb + JARVIS/Connected sit together on the
                // leading side (a little padding off the orb), state pill trailing.
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
                        HStack(spacing: 9) {
                            JarvisOrb(state: st.state, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("JARVIS").font(.system(size: 15, weight: .heavy))
                                    .foregroundStyle(.white)
                                HStack(spacing: 4) {
                                    Circle().fill(st.connected ? Color.green : Color.gray)
                                        .frame(width: 5, height: 5)
                                    Text(st.connected ? "Connected" : "Offline")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                            }
                        }
                        .padding(.leading, 4)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if st.mode == "coding" {
                        JCUsageBlock(st: st).padding(.trailing, 4)
                    } else {
                        jcStatePill(st.state).padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if st.mode == "coding" {
                        VStack(alignment: .leading, spacing: 9) {
                            JCSegBar(sessions: jcDecodeSessions(st.sessions))
                            JCLegend(sessions: jcDecodeSessions(st.sessions), total: st.entryTotal)
                        }
                    } else {
                        // Both the expanded island AND the lock-screen banner are
                        // height-capped by the system, so the waveform is dropped
                        // from both. State is conveyed by the pill + animating orb,
                        // so the freed room goes to the content.
                        VStack(spacing: 6) {
                            JarvisConvo(st: st)
                            JarvisDevices(st: st)
                        }
                    }
                }
            } compactLeading: {
                if st.mode == "coding" {
                    JCCompactSpinner(color: jcCodingColor(jcSpotlight(st.sessions)?.state ?? "idle"))
                } else {
                    JarvisOrb(state: st.state, size: 24)
                }
            } compactTrailing: {
                if st.mode == "coding" {
                    JCCompactFleetBar(sessions: jcDecodeSessions(st.sessions))
                } else {
                    Text(jcStateLabel(st.state))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(jcStateColor(st.state))
                }
            } minimal: {
                if st.mode == "coding" {
                    JCCompactSpinner(color: jcCodingColor(jcSpotlight(st.sessions)?.state ?? "idle"))
                } else {
                    JarvisOrb(state: st.state, size: 22)
                }
            }
            .widgetURL(URL(string: jcWidgetURL(st)))
        }
    }
}

/// Deep-link target for a tap on the activity. Coding → coding tab; custom →
/// the island tab; voice (and fallback) → the Voice screen.
func jcWidgetURL(_ st: JarvisActivityAttributes.ContentState) -> String {
    switch st.mode {
    case "coding": return "jarviscopilot://coding"
    case "custom": return "jarviscopilot://island"
    default: return "jarviscopilot://voice"
    }
}

/// The Lock Screen / banner presentation — the full layout: header (orb +
/// JARVIS / Connected + state pill), waveform, conversation panel, devices.
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
            // No waveform here: the lock-screen banner is height-capped too, and a
            // two-row conversation was pushing the devices strip off the bottom.
            // The pill already shows state, so the room goes to the content.
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    JarvisOrb(state: st.state, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("JARVIS").font(.system(size: 16, weight: .heavy)).foregroundStyle(.white)
                        HStack(spacing: 5) {
                            Circle().fill(st.connected ? Color.green : Color.gray)
                                .frame(width: 6, height: 6)
                            Text(st.connected ? "Connected" : "Offline")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Spacer()
                    jcStatePill(st.state)
                }
                JarvisConvo(st: st)
                JarvisDevices(st: st)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
    }
}

@main
struct JarvisWidgetBundle: WidgetBundle {
    var body: some Widget {
        JarvisWidget()
        // Dynamic Island / Lock Screen Live Activity.
        JarvisLiveActivity()
        JarvisStopwatchActivity()
        RingWorkoutActivity()
        // Live Jarvis recording the room.
        LiveCaptureActivity()
        // Ring health: any of the server's scores on the home or lock screen.
        if #available(iOS 17.0, *) {
            HealthWidget()
        }
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
            JarvisButtonControl()
            JarvisSwitchControl()
        }
    }
}

