import AppIntents
import SwiftUI
import WidgetKit

/// "Talk to Jarvis" for the car: a CarPlay Widgets-page button that talks to Jarvis
/// without leaving the screen. One tap starts a one-shot turn in the background
/// (`CarTalkIntent`), a second stops it; the face shows the state and his words,
/// then the reply. The phone's own JARVIS Voice widget (which opens the app) is
/// separate and unchanged.
struct JarvisCarTalkEntry: TimelineEntry {
    let date: Date
    let snapshot: CarTalkSnapshot
}

struct JarvisCarTalkProvider: TimelineProvider {
    func placeholder(in context: Context) -> JarvisCarTalkEntry {
        JarvisCarTalkEntry(date: Date(), snapshot: .idle)
    }

    func getSnapshot(in context: Context, completion: @escaping (JarvisCarTalkEntry) -> Void) {
        completion(entry(now: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JarvisCarTalkEntry>) -> Void) {
        let now = Date()
        let current = entry(now: now)
        // Anything still showing goes stale on its own, even if the app was killed
        // before it could say so: come back then and draw it idle.
        let showing = current.snapshot.state != "idle" || !current.snapshot.line.isEmpty
        let policy: TimelineReloadPolicy = showing
            ? .after(current.snapshot.updatedAt.addingTimeInterval(CarTalkSnapshot.staleAfter + 1))
            : .never
        completion(Timeline(entries: [current], policy: policy))
    }

    private func entry(now: Date) -> JarvisCarTalkEntry {
        JarvisCarTalkEntry(date: now, snapshot: CarTalkSnapshot.load().shown(now: now))
    }
}

struct JarvisCarTalkView: View {
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    let entry: JarvisCarTalkEntry

    private var state: String { entry.snapshot.state }

    var body: some View {
        Button(intent: CarTalkIntent()) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    orb
                    Spacer(minLength: 0)
                    Image(systemName: state == "idle" || state == "error" ? "mic.fill" : "stop.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(textColor)
                }
                Text(CarCardText.title(state: state))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(state == "idle" ? textColor : jcStateColor(state))
                    .lineLimit(1)
                if !entry.snapshot.line.isEmpty {
                    Text(entry.snapshot.line)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(textColor.opacity(0.85))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        // Removable, like the JARVIS Voice widget: CarPlay drops it and the face sits
        // on the car's own surface.
        .containerBackground(for: .widget) {
            LinearGradient(colors: [JcAccent.color, JcAccent.deep],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var textColor: Color { showsBackground ? .white : .primary }

    @ViewBuilder private var orb: some View {
        if let image = WidgetImages.model("orb") ?? jarvisOrbUIImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .shadow(color: JcAccent.color.opacity(0.55), radius: 8)
        } else {
            Image(systemName: "atom")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(textColor)
        }
    }
}

struct JarvisCarTalkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JarvisCarTalk", provider: JarvisCarTalkProvider()) { entry in
            JarvisCarTalkView(entry: entry)
        }
        .configurationDisplayName("Talk to Jarvis (car)")
        .description("In CarPlay: tap to talk to Jarvis without leaving the screen, tap again to stop.")
        .supportedFamilies([.systemSmall])
        // Meant for CarPlay's Widgets page; the phone has the JARVIS Voice widget.
        .disfavoredLocations([.homeScreen, .lockScreen, .standBy, .iPhoneWidgetsOnMac],
                             for: [.systemSmall])
    }
}
