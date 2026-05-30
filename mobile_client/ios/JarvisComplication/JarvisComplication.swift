import WidgetKit
import SwiftUI

/// A small watch-face complication that quick-launches the JARVIS watch app
/// straight into dictation. Tapping it opens `jarviswatch://listen`, which the
/// watch app handles (ContentView.onOpenURL) by presenting the dictation sheet.
struct JarvisEntry: TimelineEntry { let date: Date }

struct JarvisProvider: TimelineProvider {
    func placeholder(in context: Context) -> JarvisEntry { JarvisEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (JarvisEntry) -> Void) {
        completion(JarvisEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<JarvisEntry>) -> Void) {
        completion(Timeline(entries: [JarvisEntry(date: Date())], policy: .never))
    }
}

struct JarvisComplicationView: View {
    var entry: JarvisProvider.Entry
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "mic.fill")
                .font(.system(size: 24, weight: .semibold))
                .widgetAccentable()
        }
        .widgetURL(URL(string: "jarviswatch://listen"))
    }
}

@main
struct JarvisComplication: Widget {
    let kind = "JarvisComplication"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JarvisProvider()) { entry in
            JarvisComplicationView(entry: entry)
        }
        .configurationDisplayName("JARVIS")
        .description("Talk to JARVIS")
        .supportedFamilies([.accessoryCircular])
    }
}
