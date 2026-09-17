import AppIntents
import SwiftUI
import WidgetKit

/// Any of the ring's health numbers on the home or lock screen.
///
/// The widget reads a snapshot the app wrote to the shared app group. It never
/// talks to the ring or the network: the numbers were computed on the server
/// and are only being displayed here, so a snapshot that has gone cold renders
/// greyed with its age rather than as a confident current figure.
struct HealthWidgetEntry: TimelineEntry {
    let date: Date
    let metric: HealthWidgetMetric
    let snapshot: HealthSnapshot?

    var value: Int? { snapshot?.value(for: metric) }

    var band: String {
        guard let snapshot, metric == .health else { return "" }
        return snapshot.band
    }

    /// Cold once the ring has not been scored for a while, or when the server
    /// itself scored older data.
    var isStale: Bool {
        guard let snapshot else { return false }
        if snapshot.stale { return true }
        return Date().timeIntervalSince(snapshot.generatedAt) > 6 * 60 * 60
    }

    var age: String {
        guard let snapshot else { return "" }
        let seconds = Date().timeIntervalSince(snapshot.generatedAt)
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}

@available(iOS 17.0, *)
struct HealthMetricIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Health metric"
    static var description = IntentDescription("Which health number this widget shows.")

    @Parameter(title: "Metric", default: .health)
    var metric: HealthMetricChoice

    init() {}
}

@available(iOS 17.0, *)
enum HealthMetricChoice: String, AppEnum {
    case health, sleep, recovery, body, activity

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Health metric"
    static var caseDisplayRepresentations: [HealthMetricChoice: DisplayRepresentation] = [
        .health: "Health score",
        .sleep: "Sleep",
        .recovery: "Recovery",
        .body: "Body",
        .activity: "Activity",
    ]

    var metric: HealthWidgetMetric { HealthWidgetMetric(rawValue: rawValue) ?? .health }
}

@available(iOS 17.0, *)
struct HealthWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> HealthWidgetEntry {
        HealthWidgetEntry(date: Date(), metric: .health, snapshot: nil)
    }

    func snapshot(for configuration: HealthMetricIntent, in context: Context) async -> HealthWidgetEntry {
        entry(configuration)
    }

    func timeline(for configuration: HealthMetricIntent, in context: Context) async -> Timeline<HealthWidgetEntry> {
        // The app reloads this timeline when a run stores new scores, so the
        // hourly refresh is only a floor for a phone that never opened the app.
        Timeline(entries: [entry(configuration)], policy: .after(Date().addingTimeInterval(3600)))
    }

    private func entry(_ configuration: HealthMetricIntent) -> HealthWidgetEntry {
        HealthWidgetEntry(date: Date(), metric: configuration.metric.metric, snapshot: HealthSnapshot.read())
    }
}

@available(iOS 17.0, *)
struct HealthWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: HealthWidgetEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: -2) {
                    Text(number).font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text(entry.metric.label.prefix(3).uppercased()).font(.system(size: 8, weight: .medium))
                }
            }
            .widgetAccentable()
        case .accessoryInline:
            Text("\(entry.metric.label) \(number)\(entry.band.isEmpty ? "" : " · \(entry.band)")")
        case .systemMedium:
            medium
        default:
            small
        }
    }

    private var number: String { entry.value.map(String.init) ?? "—" }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.metric.label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(number)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(entry.isStale ? .secondary : .primary)
            if !entry.band.isEmpty {
                Text(entry.band).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if entry.snapshot == nil {
                Text("No score yet").font(.caption2).foregroundStyle(.tertiary)
            } else if entry.isStale {
                Text(entry.age).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.snapshot?.health.map(String.init) ?? "—")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(entry.isStale ? .secondary : .primary)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Health").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(entry.snapshot?.band ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if entry.isStale, entry.snapshot != nil {
                    Text(entry.age).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 14) {
                part("Sleep", entry.snapshot?.sleep)
                part("Recovery", entry.snapshot?.recovery)
                part("Body", entry.snapshot?.body)
                part("Activity", entry.snapshot?.activity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func part(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            Text(value.map(String.init) ?? "—")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}

@available(iOS 17.0, *)
struct HealthWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: HealthSnapshot.widgetKind,
                               intent: HealthMetricIntent.self,
                               provider: HealthWidgetProvider()) { entry in
            HealthWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "jarviscopilot://devices"))
        }
        .configurationDisplayName("Ring health")
        .description("A health number from your ring: the score, sleep, recovery, body or activity.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline])
    }
}
