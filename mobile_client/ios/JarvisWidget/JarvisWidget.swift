import WidgetKit
import SwiftUI

/// iOS Lock Screen + Home Screen widget that quick-launches JarvisCopilot
/// straight into the Voice screen. Tapping opens `jarviscopilot://voice`, which
/// AppDelegate.handleIncomingURL routes to the same path as the Siri voice
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
                Image(systemName: "mic.fill")
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
                    Image(systemName: "mic.fill")
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

@main
struct JarvisWidgetBundle: WidgetBundle {
    var body: some Widget {
        JarvisWidget()
    }
}
