import Foundation

/// Every CarPlay screen as a pure function of plain inputs. Nothing here reads a
/// store or touches CarPlay; `CarPlayCoordinator` snapshots the stores and
/// renders the result. Dashcam screens are in `CarPlayDashcamScreens.swift`.
@MainActor
enum CarPlayScreens {

    static let notPaired = [CarPlaySection(title: nil, rows: [
        CarPlayRow(id: "pair", title: "Pair Jarvis on your iPhone",
                   detail: "Open JarvisCopilot on the phone to sign in", symbol: "iphone"),
    ])]

    // MARK: Jarvis tab

    static func jarvisTab(_ voice: CarPlayVoiceSummary) -> [CarPlaySection] {
        [CarPlaySection(title: nil, rows: [
            CarPlayRow(id: "talk", title: "Talk to Jarvis", detail: voice.stateText, orb: true, action: .startVoice),
         ]),
         CarPlaySection(title: "Voice", rows: [
            CarPlayRow(id: "chat", title: "Chat", detail: voice.chatLabel, symbol: "bubble.left.and.bubble.right",
                       action: .push(.voiceChats)),
            CarPlayRow(id: "harness", title: "Harness", detail: voice.harnessLabel, symbol: "flowchart",
                       action: .push(.harnesses)),
            CarPlayRow(id: "model", title: "Model", detail: voice.modelLabel, symbol: "sparkles",
                       action: .push(.modelProviders)),
         ])]
    }

    /// The voice harnesses (Single model last, as on the phone's sheet).
    static func harnesses(_ list: [(id: String, title: String)], current: String) -> [CarPlaySection] {
        var rows = list.filter { $0.id != "single" }.map {
            CarPlayRow(id: "harness:\($0.id)", title: $0.title, checked: $0.id == current, action: .selectHarness($0.id))
        }
        rows.append(CarPlayRow(id: "harness:single", title: "Single model", detail: "The model you pick",
                               checked: current == "single", action: .selectHarness("single")))
        return [CarPlaySection(title: "Voice runs", rows: rows)]
    }

    /// Auto (the server's fast lane) first, then one row per provider.
    static func modelProviders(_ providers: [String], selectedProvider: String?) -> [CarPlaySection] {
        var rows = [CarPlayRow(id: "model:auto", title: "Auto", detail: "The server decides",
                               checked: selectedProvider == nil, action: .selectModel(id: nil, provider: nil))]
        rows += providers.map {
            CarPlayRow(id: "provider:\($0)", title: $0, checked: $0 == selectedProvider, action: .push(.models(provider: $0)))
        }
        return [CarPlaySection(title: nil, rows: rows)]
    }

    static func models(_ models: [ChatModel], selectedID: String?) -> [CarPlaySection] {
        [CarPlaySection(title: nil, rows: models.map {
            CarPlayRow(id: "model:\($0.id)", title: $0.label, checked: $0.id == selectedID,
                       action: .selectModel(id: $0.id, provider: $0.providerID))
        })]
    }

    /// Which chat voice talks into: a new one, the server's Voice session, or a recent chat.
    static func voiceChats(_ sessions: [ChatSessionSummary], target: VoiceSessionSelection.Target) -> [CarPlaySection] {
        var rows = [
            CarPlayRow(id: "voicechat:new", title: "New chat", symbol: "plus.bubble", action: .newVoiceChat),
            CarPlayRow(id: "voicechat:voice", title: "Voice", detail: "Jarvis's own voice chat",
                       checked: target == .defaultVoice, action: .selectVoiceChat(id: nil, title: "Voice")),
        ]
        rows += sessions.prefix(20).map {
            CarPlayRow(id: "voicechat:\($0.id)", title: $0.displayTitle, checked: target.sessionID == $0.id,
                       action: .selectVoiceChat(id: $0.id, title: $0.displayTitle))
        }
        return [CarPlaySection(title: nil, rows: rows)]
    }

    // MARK: Chats

    static func chats(_ sessions: [ChatSessionSummary], error: String? = nil,
                      now: Date = Date(), calendar: Calendar = .current) -> [CarPlaySection] {
        let groups = ChatSessionGroup.group(sessions, now: now, calendar: calendar)
        guard !groups.isEmpty else {
            let row = error.map { CarPlayRow(id: "chatsError", title: "Couldn't load chats", detail: $0, symbol: "exclamationmark.triangle", tint: .amber) }
                ?? CarPlayRow(id: "nochats", title: "No chats yet")
            return [CarPlaySection(title: nil, rows: [row])]
        }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .short
        return groups.map { group in
            CarPlaySection(title: group.title, rows: group.sessions.map { s in
                CarPlayRow(id: "chat:\(s.id)", title: s.displayTitle,
                           detail: s.updatedAt.map { relative.localizedString(for: Date(timeIntervalSince1970: TimeInterval($0)), relativeTo: now) },
                           action: .push(.chat(id: s.id, title: s.displayTitle)))
            })
        }
    }

    /// The messages a list row shows (the newest ones), oldest first.
    static let chatRowLimit = 30
    static let previewLength = 120

    static func chat(id: String, title: String, messages: [ChatMessage], error: String? = nil) -> [CarPlaySection] {
        let texts = messages.compactMap { m -> (who: String, text: String)? in
            let text = m.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, m.role != .system else { return nil }
            return (m.isUser ? "You" : "Jarvis", text)
        }.suffix(chatRowLimit)
        var rows = [CarPlayRow(id: "continue", title: "Continue by voice", symbol: "waveform",
                               action: .continueByVoice(id: id, title: title))]
        rows += texts.enumerated().map { i, m in
            CarPlayRow(id: "msg:\(i)", title: m.who, detail: preview(m.text),
                       action: .push(.message(title: m.who, text: m.text)))
        }
        if let error {
            rows.append(CarPlayRow(id: "msgError", title: "Couldn't load the messages", detail: error,
                                   symbol: "exclamationmark.triangle", tint: .amber))
        } else if texts.isEmpty {
            rows.append(CarPlayRow(id: "empty", title: "No messages yet"))
        }
        return [CarPlaySection(title: nil, rows: rows)]
    }

    static func message(title: String, text: String) -> CarPlayInfo {
        CarPlayInfo(title: title, items: [CarPlayInfoItem(title: title, detail: text)])
    }

    static func preview(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > previewLength else { return flat }
        return flat.prefix(previewLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: Devices

    static func devices(_ input: CarPlayDevicesInput) -> [CarPlaySection] {
        var sections: [CarPlaySection] = []
        if let cam = input.dashcam {
            let row = cam.setUp
                ? CarPlayRow(id: "dashcam", title: cam.name, detail: cam.status, symbol: "video", action: .push(.dashcam))
                : CarPlayRow(id: "dashcam", title: cam.name, detail: "Set up on your iPhone", symbol: "video", enabled: false)
            sections.append(CarPlaySection(title: "Dashcam", rows: [row]))
        }
        if !input.wearables.isEmpty {
            sections.append(CarPlaySection(title: "Wearables", rows: input.wearables.map { w in
                CarPlayRow(id: "wearable:\(w.id)", title: w.name,
                           detail: [w.statusText, w.batteryPercent.map { "\($0)%" }].compactMap { $0 }.joined(separator: " · "),
                           symbol: symbol(forKind: w.kind), tint: w.connected ? .success : .muted,
                           action: .push(.device(id: w.id)))
            }))
        }
        if let error = input.serverError, input.server.isEmpty {
            sections.append(CarPlaySection(title: "Server devices", rows: [
                CarPlayRow(id: "serverError", title: "Couldn't load server devices", detail: error,
                           symbol: "exclamationmark.triangle", tint: .amber),
            ]))
        }
        if !input.server.isEmpty {
            sections.append(CarPlaySection(title: "Server devices", rows: input.server.map { d in
                CarPlayRow(id: "server:\(d.id)", title: d.displayName, detail: d.online ? "Online" : "Offline",
                           symbol: d.platform.contains("mobile") ? "iphone" : "desktopcomputer",
                           tint: d.online ? .success : .muted, action: .push(.serverDevice(id: d.id)))
            }))
        }
        return sections.isEmpty ? [CarPlaySection(title: nil, rows: [CarPlayRow(id: "nodevices", title: "No devices yet")])] : sections
    }

    static func device(_ w: CarPlayWearable) -> CarPlayInfo {
        var items = [CarPlayInfoItem(title: "Status", detail: w.statusText),
                     CarPlayInfoItem(title: "Model", detail: w.model)]
        if let b = w.batteryPercent { items.append(CarPlayInfoItem(title: "Battery", detail: "\(b)%")) }
        if let rssi = w.rssi { items.append(CarPlayInfoItem(title: "Signal", detail: "\(rssi) dBm")) }
        if let seen = w.lastSeen, !w.connected {
            items.append(CarPlayInfoItem(title: "Last seen", detail: seen.formatted(.relative(presentation: .named))))
        }
        let actions = w.connected ? [] : [CarPlayRow(id: "connect", title: "Connect", action: .connectWearable(w.id))]
        return CarPlayInfo(title: w.name, items: items, actions: actions)
    }

    static func serverDevice(_ d: Device) -> CarPlayInfo {
        var items = [CarPlayInfoItem(title: "Status", detail: d.online ? "Online" : "Offline")]
        if !d.platform.isEmpty { items.append(CarPlayInfoItem(title: "Platform", detail: d.platform)) }
        if !d.lastSeen.isEmpty { items.append(CarPlayInfoItem(title: "Last seen", detail: d.lastSeen)) }
        items.append(CarPlayInfoItem(title: "Skills", detail: "\(d.skills.filter(\.allowed).count) allowed"))
        return CarPlayInfo(title: d.displayName, items: items)
    }

    static func symbol(forKind kind: String) -> String {
        switch kind {
        case WearableKeepAlive.ring, WearableKeepAlive.x5ring: return "circle.circle"
        case WearableKeepAlive.bottle: return "waterbottle"
        case WearableKeepAlive.scale: return "scalemass"
        case WearableKeepAlive.esp32: return "cpu"
        case WearableKeepAlive.glasses: return "eyeglasses"
        case "jarvis_pod": return "circle.hexagongrid"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}
