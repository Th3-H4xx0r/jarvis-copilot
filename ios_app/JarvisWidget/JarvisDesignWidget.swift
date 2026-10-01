import SwiftUI
import WidgetKit

// "Jarvis widget": any design from Jarvis → Settings → Widget creator, at any Home Screen or
// Lock Screen size, drawn by the shared renderer over the app's data snapshot.

struct JarvisDesignEntry: TimelineEntry {
    let date: Date
    let design: JCDesign?
    let chosen: Bool
    let data: [String: JCJSON]
}

struct JarvisDesignProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> JarvisDesignEntry {
        JarvisDesignEntry(date: Date(), design: nil, chosen: false, data: [:])
    }

    func snapshot(for configuration: ChooseWidgetDesignIntent, in context: Context) async -> JarvisDesignEntry {
        entry(configuration)
    }

    /// The app reloads this when its data changes; the 15 minutes are a floor for a phone that
    /// never opens it.
    func timeline(for configuration: ChooseWidgetDesignIntent, in context: Context) async -> Timeline<JarvisDesignEntry> {
        Timeline(entries: [entry(configuration)], policy: .after(Date().addingTimeInterval(900)))
    }

    private func entry(_ configuration: ChooseWidgetDesignIntent) -> JarvisDesignEntry {
        // Before one is chosen, the first design there is — better than an empty square.
        let id = configuration.design?.id ?? WidgetDesignCache.infos().first?.id
        return JarvisDesignEntry(date: Date(), design: id.flatMap { WidgetDesignCache.load($0) },
                                 chosen: configuration.design != nil, data: WidgetDataFile.read())
    }
}

struct JarvisDesignWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: JarvisDesignEntry

    private var size: WidgetSize { WidgetSize(family: family) }

    var body: some View {
        content
            .containerBackground(for: .widget) { background }
    }

    @ViewBuilder
    private var content: some View {
        if let design = entry.design, let node = design.node(for: size) {
            JCDesignRenderer(tint: jcParseColor(design.tint) ?? JcAccent.color)
                .render(node, JCBindingContext(data: entry.data))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let design = entry.design {
            // No layout for this size: the design's icon and name, so it is never blank.
            fallback(icon: design.icon.isEmpty ? "square.grid.2x2" : design.icon, title: design.name)
        } else {
            fallback(icon: "square.grid.2x2.fill",
                     title: entry.chosen ? "That design was deleted — touch and hold → Edit Widget to pick another"
                                         : "Pick a design in Jarvis → Settings → Widget creator")
        }
    }

    @ViewBuilder
    private func fallback(icon: String, title: String) -> some View {
        switch size {
        case .circular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: icon).font(.title3)
            }
        case .inline:
            Label(title, systemImage: icon)
        default:
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2).foregroundStyle(JcAccent.color)
                Text(title).font(.caption).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var background: some View {
        if size.isLockScreen {
            Color.clear
        } else {
            LinearGradient(colors: [Color(white: 0.11), Color(white: 0.04)], startPoint: .top, endPoint: .bottom)
        }
    }
}

struct JarvisDesignWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "JarvisDesignWidget", intent: ChooseWidgetDesignIntent.self,
                               provider: JarvisDesignProvider()) { entry in
            JarvisDesignWidgetView(entry: entry)
        }
        .configurationDisplayName("Jarvis widget")
        .description("Any design from Jarvis → Settings → Widget creator.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
