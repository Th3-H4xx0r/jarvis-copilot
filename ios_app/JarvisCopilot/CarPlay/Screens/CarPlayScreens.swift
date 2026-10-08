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

    /// The voice card covers the bottom of the tab and shows the orb and the state
    /// itself: while it's open the header steps aside so the text sits above the card.
    static func showsVoiceHeader(cardOpen: Bool) -> Bool { !cardOpen }

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

    // MARK: Car tab (the Wearables tab is the car)

    /// The car's controls, what is linked to it, then any other car wearable on its own.
    static func carTab(_ car: CarPlayCarInput, others: [CarPlayCarDevice]) -> [CarPlaySection] {
        let controls = car.controls.isEmpty
            ? [CarPlayRow(id: "nocontrols", title: "No controls yet", detail: "Linked devices add theirs here",
                          symbol: "slider.horizontal.3")]
            : car.controls.map(controlRow)
        let linked = car.linked.isEmpty
            ? [CarPlayRow(id: "nolinked", title: "Nothing linked yet", detail: "Link devices to the car on your iPhone",
                          symbol: "link")]
            : car.linked.map { item in
                CarPlayRow(id: "linked:\(item.kind)", title: item.title, detail: item.status, symbol: item.symbol,
                           tint: item.connected ? .success : .muted, action: item.screen.map { .push($0) } ?? .none)
            }
        var sections = [CarPlaySection(title: "Controls", rows: controls),
                        CarPlaySection(title: "Linked devices", rows: linked)]
        if !others.isEmpty {
            sections.append(CarPlaySection(title: "Other wearables", rows: wearablesTab(others).flatMap(\.rows)))
        }
        return sections
    }

    /// Toggles and buttons act in place; levels and choices open their list.
    static func controlRow(_ control: CarPlayControl) -> CarPlayRow {
        var row = CarPlayRow(id: "control:\(control.id)", title: control.title, symbol: control.symbol)
        row.enabled = control.enabled
        switch control.kind {
        case .toggle(let on):
            row.detail = on ? "On" : "Off"
            row.tint = on ? .accent : .muted
            row.action = .control(id: control.id, .toggle(!on))
        case .button:
            row.action = .control(id: control.id, .press)
        case .level(let value, _, _, let unit):
            row.detail = levelText(value, unit: unit)
            row.action = .push(.wearableControl(id: control.id))
        case .choice(let selected, let options):
            row.detail = options.first { $0.id == selected }?.title ?? selected
            row.action = .push(.wearableControl(id: control.id))
        }
        return row
    }

    /// A level's steps or a choice's options, the current one ticked.
    static func controlPicker(_ control: CarPlayControl) -> [CarPlaySection] {
        switch control.kind {
        case .choice(let selected, let options):
            return [CarPlaySection(title: nil, rows: options.map { option in
                CarPlayRow(id: "option:\(option.id)", title: option.title, checked: option.id == selected,
                           action: .control(id: control.id, .choice(option.id)))
            })]
        case .level(let value, let range, let step, let unit):
            // The current level is always a row, so ticking it keeps it.
            let current = WearableControl.snap(value, range: range, step: step)
            var steps = levelSteps(range: range, step: step)
            if !steps.contains(current) { steps = (steps + [current]).sorted() }
            return [CarPlaySection(title: nil, rows: steps.map { level in
                CarPlayRow(id: "level:\(level)", title: levelText(level, unit: unit), checked: level == current,
                           action: .control(id: control.id, .level(level)))
            })]
        case .toggle, .button:
            return []
        }
    }

    /// At most `maxCount` evenly spread levels, both ends included, each on the control's step.
    static func levelSteps(range: ClosedRange<Double>, step: Double, maxCount: Int = 11) -> [Double] {
        let span = range.upperBound - range.lowerBound
        guard span > 0, span.isFinite else { return [range.lowerBound] }
        // + epsilon: 0.6 / 0.1 is 5.999…, which would drop a level. Compared as a Double first:
        // a tiny step would overflow `Int(_:)`.
        let ratio = step > 0 ? span / step + 1e-9 : .infinity
        let natural = ratio.isFinite && ratio < Double(maxCount) ? Int(ratio.rounded(.down)) + 1 : maxCount
        let count = min(max(natural, 2), maxCount)
        var out: [Double] = []
        for i in 0..<count {
            let level = WearableControl.snap(range.lowerBound + span * Double(i) / Double(count - 1), range: range, step: step)
            if out.last != level { out.append(level) }
        }
        return out
    }

    private static func levelText(_ value: Double, unit: String?) -> String {
        WearableControl.format(value) + (unit.map { " \($0)" } ?? "")
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
