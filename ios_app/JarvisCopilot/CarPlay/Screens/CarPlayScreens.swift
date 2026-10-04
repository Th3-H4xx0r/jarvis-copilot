import Foundation

/// Every CarPlay screen as a pure function of plain inputs. Nothing here reads a
/// store or touches CarPlay; `CarPlayCoordinator` snapshots the stores and
/// renders the result. Dashcam screens are in `CarPlayDashcamScreens.swift`.
///
/// Two tabs: Voice (talk to Jarvis) and Wearables (only device types that set
/// `WearableDevice.carEnabled` — the dashcam today).
@MainActor
enum CarPlayScreens {

    static let notPaired = [CarPlaySection(title: nil, rows: [
        CarPlayRow(id: "pair", title: "Pair Jarvis on your iPhone",
                   detail: "Open JarvisCopilot on the phone to sign in", symbol: "iphone"),
    ])]

    // MARK: Voice tab

    /// Under the header (orb, state, Talk): the conversation in CarPlay's big row text —
    /// Jarvis's reply as it's spoken (its newest words) with what you said under it in
    /// grey. CarPlay left-aligns list text; this is as close to the phone as it allows.
    static func voiceTab(_ text: CarPlayVoiceText?, speaking: Bool) -> [CarPlaySection] {
        guard let text else { return [] }
        let reply = speaking ? text.spoken : (text.spoken + text.unspoken).trimmingCharacters(in: .whitespacesAndNewlines)
        let row = reply.isEmpty
            ? text.heard.map { CarPlayRow(id: "conversation", title: $0) }
            : CarPlayRow(id: "conversation", title: newestWords(reply), detail: text.heard)
        return row.map { [CarPlaySection(title: nil, rows: [$0])] } ?? []
    }

    /// How much of a reply the row shows: about a car-screen line and a half.
    static let replyLength = 90

    /// The last `replyLength` characters, starting at a word ("…" when cut).
    static func newestWords(_ text: String) -> String {
        guard text.count > replyLength else { return text }
        let tail = text.suffix(replyLength)
        let start = tail.firstIndex(where: \.isWhitespace).map { tail.index(after: $0) } ?? tail.startIndex
        return "…" + tail[start...]
    }

    /// Talk when idle; during a conversation the voice card has Mute and End, so none here.
    static func voiceButtons(active: Bool, muted: Bool, pushToTalk: Bool) -> [CarPlayVoiceButton] {
        active ? [] : [.talk]
    }

    /// The line under "Jarvis": what it's doing, or what's in the way.
    static func voiceStateText(state: VoiceState, error: String?, micAllowed: Bool) -> String {
        switch state {
        case .connecting: return "Connecting…"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking"
        case .idle, .error:
            if let error { return error }
            return micAllowed ? "Tap Talk to start" : "Allow the microphone on your iPhone"
        }
    }

    /// The conversation as the phone shows it: what you said, then Jarvis's reply with
    /// the words already spoken lit and the rest dimmed. Nil before anything was said.
    static func voiceText(heard: String, reply: String, spokenWords: Int) -> CarPlayVoiceText? {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty || !reply.isEmpty else { return nil }
        var cut = reply.startIndex
        var words = 0
        var index = reply.startIndex
        while index < reply.endIndex, words < spokenWords {
            while index < reply.endIndex, reply[index].isWhitespace { index = reply.index(after: index) }
            guard index < reply.endIndex else { break }
            while index < reply.endIndex, !reply[index].isWhitespace { index = reply.index(after: index) }
            words += 1
            cut = index
        }
        return CarPlayVoiceText(heard: heard.isEmpty ? nil : heard,
                                spoken: String(reply[..<cut]), unspoken: String(reply[cut...]))
    }

    // MARK: Wearables tab

    static func wearablesTab(_ devices: [CarPlayCarDevice]) -> [CarPlaySection] {
        guard !devices.isEmpty else {
            return [CarPlaySection(title: nil, rows: [
                CarPlayRow(id: "nodevices", title: "No car wearables yet",
                           detail: "Set up the dashcam on your iPhone and share it with Jarvis", symbol: "car"),
            ])]
        }
        return [CarPlaySection(title: nil, rows: devices.map { d in
            CarPlayRow(id: "car:\(d.id)", title: d.name, detail: d.status,
                       symbol: d.isDashcam ? "video" : "dot.radiowaves.left.and.right",
                       tint: d.connected ? .success : .muted,
                       action: .push(d.isDashcam ? .dashcam : .device(id: d.id)))
        })]
    }

    /// A car-enabled wearable with no screen of its own: whether it's reachable,
    /// then the plain values it reports (nested state is left to the phone).
    static func carDevice(name: String, connected: Bool, snapshot: [String: Any]) -> CarPlayInfo {
        var items = [CarPlayInfoItem(title: "Status", detail: connected ? "Connected" : "Not connected")]
        for (key, value) in snapshot.sorted(by: { $0.key < $1.key }) {
            let text: String
            switch value {
            case let b as Bool: text = b ? "Yes" : "No"
            case let n as NSNumber: text = n.stringValue
            case let s as String: text = s
            default: continue
            }
            items.append(CarPlayInfoItem(title: key.replacingOccurrences(of: "_", with: " ").capitalized, detail: text))
        }
        return CarPlayInfo(title: name, items: items)
    }
}
