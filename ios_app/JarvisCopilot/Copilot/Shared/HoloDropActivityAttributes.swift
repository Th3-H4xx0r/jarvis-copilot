import ActivityKit
import SwiftUI

/// "Drop waiting": a Holo Drop reached this phone while it was locked or asleep. The server
/// push-starts it (`holo-start` token) because Jarvis notifications don't show on the Lock
/// Screen; opening the app takes the drop and ends it. Black and white like the other cards.
struct HoloDropActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// What's waiting ("IMG_4021.HEIC", a page title, a link).
        var title: String = ""
        /// Who sent it ("MacBook").
        var from: String = ""
        /// link | text | image | video | file
        var kind: String = "file"
        /// How many drops are waiting.
        var count: Int = 1
    }

    /// The first waiting drop's id (the tap opens it).
    var dropID: String

    static let maxTextChars = 48
}

/// The activity's words and symbols, in Copilot/Shared so the widget draws them and tests can check them.
enum HoloDropActivityText {
    static func symbol(_ kind: String) -> String {
        switch kind {
        case "link": return "link"
        case "text": return "text.alignleft"
        case "image": return "photo"
        case "video": return "film"
        default: return "doc"
        }
    }

    static func headline(_ s: HoloDropActivityAttributes.ContentState) -> String {
        s.count > 1 ? "\(s.count) drops waiting" : "Drop waiting"
    }

    static func detail(_ s: HoloDropActivityAttributes.ContentState) -> String {
        let what = String(s.title.prefix(HoloDropActivityAttributes.maxTextChars))
        return s.from.isEmpty ? what : "\(what) · from \(s.from)"
    }

    static func url(_ dropID: String, do action: String? = nil) -> URL? {
        URL(string: "jarviscopilot://holo-drop?drop=\(dropID)" + (action.map { "&do=\($0)" } ?? ""))
    }
}

struct HoloDropLockScreenView: View {
    let dropID: String
    let state: HoloDropActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 0) {
        HStack(spacing: 12) {
            Image(systemName: HoloDropActivityText.symbol(state.kind))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.black)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(HoloDropActivityText.headline(state))
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text(HoloDropActivityText.detail(state))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding([.horizontal, .top], 16)
        HoloDropActivityButtons(dropID: dropID, kind: state.kind)
            .padding([.horizontal, .bottom], 16).padding(.top, 10)
        }
    }
}

/// Open · Save · Copy on the card. Save and Copy run in the background (Live Activity intents);
/// Open brings Jarvis forward. Grey pills, white for the main one (his black & white rule).
struct HoloDropActivityButtons: View {
    let dropID: String
    let kind: String

    var body: some View {
        HStack(spacing: 8) {
            if let url = HoloDropActivityText.url(dropID, do: "open") {
                Link(destination: url) { pill("Open", main: true) }
            }
            Button(intent: HoloDropLiveIntent(dropID: dropID, action: "save")) { pill("Save", main: false) }
                .buttonStyle(.plain)
            if kind != "video" && kind != "file" {
                Button(intent: HoloDropLiveIntent(dropID: dropID, action: "copy")) { pill("Copy", main: false) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func pill(_ title: String, main: Bool) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold))
            .foregroundStyle(main ? .black : .white)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(Capsule().fill(main ? Color.white : Color.white.opacity(0.16)))
    }
}
