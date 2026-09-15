import SwiftUI
import WidgetKit

/// A watch face complication that opens JARVIS ready to talk: tap it and the watch app
/// launches on the voice screen, where the orb takes your dictation.
///
/// Add it from the watch face: long-press the face → Edit → a complication slot → JARVIS.
struct WatchWidgetEntry: TimelineEntry { let date: Date }

struct WatchWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchWidgetEntry { WatchWidgetEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (WatchWidgetEntry) -> Void) {
        completion(WatchWidgetEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchWidgetEntry>) -> Void) {
        completion(Timeline(entries: [WatchWidgetEntry(date: Date())], policy: .never))
    }
}

struct WatchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: WatchWidgetProvider.Entry

    var body: some View {
        switch family {
        case .accessoryCorner, .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill").font(.system(size: 18, weight: .semibold))
            }
            .widgetAccentable()
            .containerBackground(Color.clear, for: .widget)
        case .accessoryInline:
            Label("Talk to JARVIS", systemImage: "mic.fill")
        default:  // accessoryRectangular
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.system(size: 20, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("JARVIS").font(.headline)
                    Text("Tap to talk").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .widgetAccentable()
            .containerBackground(Color.clear, for: .widget)
        }
    }
}

struct JarvisWatchWidget: Widget {
    let kind = "JarvisWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchWidgetProvider()) { entry in
            WatchWidgetView(entry: entry)
        }
        .configurationDisplayName("JARVIS")
        .description("Open JARVIS ready to talk.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

@main
struct JarvisWatchWidgetBundle: WidgetBundle {
    var body: some Widget { JarvisWatchWidget() }
}
