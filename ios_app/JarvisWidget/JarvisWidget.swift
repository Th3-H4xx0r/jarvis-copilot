import WidgetKit
import SwiftUI
import AppIntents
import UIKit
import CryptoKit

/// iOS Lock Screen + Home Screen widget that quick-launches JarvisCopilot
/// straight into the Voice screen. Tapping opens `jarviscopilot://voice`, which
/// `AppServices.open(url:)` routes to the same path as the Siri voice
/// intent (opens the Voice tab and starts a realtime turn).
///
/// Add to your Lock Screen: long-press the Lock Screen → Customize → the area
/// under the clock → add the "JARVIS Voice" circular widget.
struct JarvisWidgetEntry: TimelineEntry { let date: Date }

struct JarvisWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> JarvisWidgetEntry { JarvisWidgetEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (JarvisWidgetEntry) -> Void) {
        completion(JarvisWidgetEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<JarvisWidgetEntry>) -> Void) {
        completion(Timeline(entries: [JarvisWidgetEntry(date: Date())], policy: .never))
    }
}

struct JarvisWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: JarvisWidgetProvider.Entry

    var body: some View {
        switch family {
        case .accessoryCircular:
            // Lock Screen: a 1×1 circular mic. accessoryWidgetBackground gives
            // the standard translucent ring; widgetAccentable tints it.
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "atom")
                    .font(.system(size: 22, weight: .semibold))
            }
            .widgetAccentable()
            .jcContainerBackground(Color.clear)
            .widgetURL(URL(string: "jarviscopilot://voice"))
        default:
            // Home Screen systemSmall: gradient tile with the mic, on-brand.
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.27, green: 0.88, blue: 0.88),
                             Color(red: 0.54, green: 0.49, blue: 1.0),
                             Color(red: 1.0, green: 0.44, blue: 0.85)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 8) {
                    Image(systemName: "atom")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Talk to JARVIS")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                }
            }
            .jcContainerBackground(Color.black)
            .widgetURL(URL(string: "jarviscopilot://voice"))
        }
    }
}

extension View {
    /// `containerBackground(for: .widget)` is iOS 17+. On 16 it's a no-op (the
    /// widget still renders), so gate it on availability to keep the iOS-16
    /// deployment target building.
    @ViewBuilder
    func jcContainerBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(style, for: .widget)
        } else {
            self
        }
    }
}

struct JarvisWidget: Widget {
    let kind = "JarvisWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JarvisWidgetProvider()) { entry in
            JarvisWidgetView(entry: entry)
        }
        .configurationDisplayName("JARVIS Voice")
        .description("Quick-launch JARVIS into voice.")
        .supportedFamilies([.accessoryCircular, .systemSmall])
    }
}

// ── Control Center button (iOS 18+) ──────────────────────────────────────────
//
// A Control Center control that quick-launches JARVIS into the Voice screen and
// starts listening. Tapping it runs `OpenJarvisVoiceIntent` (in the shared
// VoiceLaunchIntent.swift — a member of both this extension and the app):
// because it sets `openAppWhenRun`, iOS runs it IN THE APP, where it sets the
// pending-voice flag + posts the start notification — the same proven path Siri
// uses. (A custom URL scheme via OpenURLIntent proved unreliable from a Control.)
//
// Add it from: Settings → Control Center (or edit Control Center → "+") → add
// "Talk to JARVIS".

@available(iOS 18.0, *)
struct JarvisVoiceControl: ControlWidget {
    static let kind = "com.jarviscopilot.jarviscopilotMobileAndIOS.JarvisWidget.VoiceControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenJarvisVoiceIntent()) {
                Label("Talk to JARVIS", systemImage: "atom")
            }
        }
        .displayName("Talk to JARVIS")
        .description("Quick-launch JARVIS into voice and start listening.")
    }
}

// ── Dynamic Island + Lock Screen Live Activity (iOS 16.2+) ───────────────────
//
// JARVIS's live voice status: a state-styled glowing orb, the current state, a
// one-line activity (your phrase / reply snippet / "Searching the web…"), and a
// Connected/Offline footer. Tapping anywhere opens the Voice screen. Persists
// (resting at Idle) after a session until dismissed. App-driven via
// LiveActivityManager (AppDelegate). Uses JarvisActivityAttributes (shared).

