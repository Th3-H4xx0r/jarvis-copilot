import SwiftUI
import WidgetKit

/// "Talk to Jarvis" for the car: a CarPlay Widgets-page orb. A tap opens Jarvis on
/// the car's screen already listening, for one answer (`CarTalkLink`). iOS refuses a
/// backgrounded app the microphone, so the orb never tries to start it in place.
/// The phone's own JARVIS Voice widget is separate and unchanged.
struct JarvisCarTalkEntry: TimelineEntry {
    let date: Date
}

struct JarvisCarTalkProvider: TimelineProvider {
    func placeholder(in context: Context) -> JarvisCarTalkEntry { JarvisCarTalkEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (JarvisCarTalkEntry) -> Void) {
        completion(JarvisCarTalkEntry(date: Date()))
    }

    /// The face never changes: there is nothing to redraw.
    func getTimeline(in context: Context, completion: @escaping (Timeline<JarvisCarTalkEntry>) -> Void) {
        completion(Timeline(entries: [JarvisCarTalkEntry(date: Date())], policy: .never))
    }
}

struct JarvisCarTalkView: View {
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    let entry: JarvisCarTalkEntry

    /// Just the orb, big and centred — the whole widget is the link.
    var body: some View {
        orb(size: 104)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .widgetURL(CarTalkLink.url)
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
        .description("In CarPlay: tap to open Jarvis on the car's screen, already listening.")
        .supportedFamilies([.systemSmall])
        // Meant for CarPlay's Widgets page; the phone has the JARVIS Voice widget.
        .disfavoredLocations([.homeScreen, .lockScreen, .standBy, .iPhoneWidgetsOnMac],
                             for: [.systemSmall])
    }
}
