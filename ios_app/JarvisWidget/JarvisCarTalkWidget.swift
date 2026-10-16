import AppIntents
import SwiftUI
import WidgetKit

/// "Talk to Jarvis" for the car: a CarPlay Widgets-page button that talks to Jarvis
/// without leaving the screen. One tap starts a one-shot turn in the background
/// (`CarTalkIntent`), a second stops it. The face never claims a live state —
/// WidgetKit won't redraw a backgrounded app's widget in step with a turn — only
/// whether the last tap failed; the turn shows on the Live Activity card and in
/// the earcons. The phone's own JARVIS Voice widget is separate and unchanged.
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
        // A failure clears itself after a while, app or no app.
        let showing = current.snapshot.state == "error"
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

    private var failed: Bool { entry.snapshot.state == "error" && !entry.snapshot.line.isEmpty }

    /// Just the orb, big and centred — the whole widget is the button. A line under
    /// it only when the last tap couldn't start.
    var body: some View {
        Button(intent: CarTalkIntent()) {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                orb(size: failed ? 76 : 104)
                if failed {
                    Text(entry.snapshot.line)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(jcStateColor("error"))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    @ViewBuilder private func orb(size: CGFloat) -> some View {
        if let image = WidgetImages.model("orb") ?? jarvisOrbUIImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .shadow(color: JcAccent.color.opacity(0.55), radius: size / 6)
        } else {
            Image(systemName: "atom")
                .font(.system(size: size * 0.55, weight: .bold))
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
