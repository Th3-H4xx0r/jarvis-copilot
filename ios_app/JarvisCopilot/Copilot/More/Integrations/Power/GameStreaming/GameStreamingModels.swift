import Foundation

// Game Streaming — the Codable-ish models behind the card and page, decoded from
// `GET /api/game-streaming/status` (webui/api/game_streaming_routes.py). The app
// decodes JSON through `init(json:)`, as the rest of the integrations do.

/// The live stream, as the status reply reports it. A Sunshine stream is
/// client-initiated, so "active" comes from the PC's log watcher, not a poll.
struct GameLive: Equatable {
    var active: Bool
    var client: String?
    var app: String?

    init(active: Bool = false, client: String? = nil, app: String? = nil) {
        self.active = active
        self.client = client
        self.app = app
    }

    init(json o: [String: Any]) {
        active = o["active"] as? Bool ?? false
        client = (o["client"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        app = (o["app"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// A Moonlight device paired with the host (Sunshine `clients/list`).
struct GamePaired: Identifiable, Equatable {
    let name: String
    let uuid: String
    var id: String { uuid.isEmpty ? name : uuid }

    init(name: String, uuid: String) {
        self.name = name
        self.uuid = uuid
    }

    init?(json o: [String: Any]) {
        let name = o["name"] as? String ?? ""
        let uuid = o["uuid"] as? String ?? ""
        guard !(name.isEmpty && uuid.isEmpty) else { return nil }
        self.name = name.isEmpty ? uuid : name
        self.uuid = uuid
    }
}

/// A game Sunshine exposes (`GET /api/apps`). Games are read live from the host,
/// never re-entered on the device.
struct GameApp: Identifiable, Equatable {
    let name: String
    var id: String { name }

    init(name: String) { self.name = name }

    init?(json o: [String: Any]) {
        guard let name = o["name"] as? String, !name.isEmpty else { return nil }
        self.name = name
    }
}

/// A Moonlight target Jarvis can point at the host, from the integration's
/// settings. `kind` is `mac`, `androidtv` or `ios`.
struct GameTarget: Identifiable, Equatable {
    let name: String
    let kind: String
    let host: String
    /// An Android TV's own adb address (for `adb connect`); empty for other kinds.
    let tvAddr: String
    var id: String { name }

    init(name: String, kind: String, host: String = "", tvAddr: String = "") {
        self.name = name
        self.kind = kind
        self.host = host
        self.tvAddr = tvAddr
    }

    init?(json o: [String: Any]) {
        guard let name = o["name"] as? String, !name.isEmpty else { return nil }
        self.name = name
        kind = o["kind"] as? String ?? ""
        host = o["host"] as? String ?? ""
        tvAddr = o["tv_addr"] as? String ?? ""
    }

    /// The device kind in words, for the row's subtitle.
    var kindLabel: String {
        switch kind {
        case "mac": return "Mac"
        case "androidtv", "android": return "Android TV"
        case "ios": return "iPhone / iPad"
        default: return kind.isEmpty ? "Device" : kind.capitalized
        }
    }
}

/// `GET /api/game-streaming/status`.
struct GameStreamingStatus: Equatable {
    var ok: Bool
    var reachable: Bool
    var live: GameLive
    var paired: [GamePaired]
    var apps: [GameApp]
    var targets: [GameTarget]

    static let empty = GameStreamingStatus(ok: false, reachable: false, live: GameLive(),
                                           paired: [], apps: [], targets: [])

    init(ok: Bool, reachable: Bool, live: GameLive,
         paired: [GamePaired], apps: [GameApp], targets: [GameTarget]) {
        self.ok = ok
        self.reachable = reachable
        self.live = live
        self.paired = paired
        self.apps = apps
        self.targets = targets
    }

    init(json o: [String: Any]) {
        ok = o["ok"] as? Bool ?? false
        reachable = o["reachable"] as? Bool ?? false
        live = GameLive(json: o["live"] as? [String: Any] ?? [:])
        paired = (o["paired"] as? [[String: Any]] ?? []).compactMap(GamePaired.init(json:))
        apps = (o["apps"] as? [[String: Any]] ?? []).compactMap(GameApp.init(json:))
        targets = (o["targets"] as? [[String: Any]] ?? []).compactMap(GameTarget.init(json:))
    }
}

/// A stream this phone launched, kept on the device. The server has no
/// "last used" endpoint, so the card leads with "Stream <last game> -> <last
/// device>" from here.
struct GameRecent: Identifiable, Equatable, Codable {
    let game: String
    let target: String
    let at: Date
    var id: String { game + " -> " + target }
}

/// What `POST /start` came back as. Start is durable: an asleep PC returns
/// pending and the connect completes when it next reports awake.
enum GameStartOutcome: Equatable {
    case started(note: String?)
    case pending
}

/// What `POST /pair` came back as. 409 means the PC is asleep/offline.
enum GamePairOutcome: Equatable {
    case paired(detail: String?)
    case offline(String)
    case failed(String)
}

/// The result of a card/page action, for a toast.
enum GameActionResult: Equatable {
    case ok(String?)
    case failed(String)
}

/// The Game Streaming card's words, kept pure so the tests can check them without
/// a view. Black and white: no colour decisions live here.
enum GameStreamingCardModel {
    /// The live line under the Power header while a stream runs ("Streaming <app>").
    /// Nil when nothing is streaming, so the card shows only its main button.
    static func liveLabel(_ status: GameStreamingStatus?) -> String? {
        guard let live = status?.live, live.active else { return nil }
        return "Streaming \(live.app ?? "a game")"
    }

    /// The one main button's game and device: the last stream this phone launched
    /// (while its target still exists), else the first game and target the host
    /// offers. Nil when there is no target yet.
    static func primary(_ status: GameStreamingStatus?, recent: GameRecent?) -> GamePrimary? {
        let targets = status?.targets ?? []
        if let recent, targets.contains(where: { $0.name == recent.target }) {
            return GamePrimary(game: recent.game, target: recent.target)
        }
        guard let target = targets.first?.name else { return nil }
        let game = status?.apps.first?.name ?? recent?.game ?? "a game"
        return GamePrimary(game: game, target: target)
    }

    /// The main button's title.
    static func primaryTitle(_ primary: GamePrimary?) -> String {
        guard let primary else { return "Open Game Streaming" }
        return "Stream \(primary.game) -> \(primary.target)"
    }
}

/// The game + device the card's one main button streams.
struct GamePrimary: Equatable {
    let game: String
    let target: String
}


// MARK: - Setup

/// GET /api/game-streaming/detect — whether Sunshine is running on the gaming PC and
/// whether the login works. Lets the setup page say "Found Sunshine" or show a hint
/// instead of a bare reachable flag. The PC is reached at localhost by jc-client.
struct GameDetect: Equatable {
    var online: Bool
    var running: Bool
    var needsLogin: Bool

    init(online: Bool = false, running: Bool = false, needsLogin: Bool = false) {
        self.online = online
        self.running = running
        self.needsLogin = needsLogin
    }

    init(json o: [String: Any]) {
        online = o["online"] as? Bool ?? false
        running = o["running"] as? Bool ?? false
        needsLogin = o["needsLogin"] as? Bool ?? (o["needs_login"] as? Bool ?? false)
    }

    /// True only when Sunshine was found and the login already works.
    var found: Bool { online && running && !needsLogin }

    /// The one status line shown at the top of setup. Pure, for the tests.
    var headline: String {
        if !online { return "Your PC is offline — turn it on to finish setup" }
        if found { return "Found Sunshine on your gaming PC" }
        if running { return "Sunshine is running — add your Sunshine login below" }
        return "Sunshine isn't running on your PC yet"
    }
}

/// Guesses a device's type from its paired name, best-effort and always editable.
/// SHIELD/Fire/Google TV/Android TV -> Android TV; iPhone/iPad -> iPhone;
/// MacBook/iMac/Mac -> Mac. Anything else falls back to Mac.
enum GameTypeGuess {
    static func kind(for name: String) -> String {
        let n = name.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { n.contains($0) } }
        if has(["shield", "fire tv", "firestick", "fire stick", "google tv",
                "android tv", "androidtv", "nvidia", "chromecast", "mi box", "onn", " tv"]) {
            return "androidtv"
        }
        if has(["iphone", "ipad", "ipod"]) { return "ios" }
        if has(["macbook", "imac", "mac mini", "mac studio", "mac pro", "mac"]) { return "mac" }
        return "mac"
    }
}

/// One editable row on the setup page: a device name, its (guessed, editable) type,
/// and an Android TV's adb address. No host field — the Moonlight host auto-fills server-side.
struct GameDeviceDraft: Identifiable, Equatable {
    var name: String
    var kind: String
    var tvAddr: String
    var id: String { name }

    init(name: String, kind: String, tvAddr: String = "") {
        self.name = name
        self.kind = kind
        self.tvAddr = tvAddr
    }

    /// The device kind in words, for the type control.
    static let kinds: [(value: String, label: String)] =
        [("mac", "Mac"), ("androidtv", "Android TV"), ("ios", "iPhone")]
}

/// What POST /api/game-streaming/targets writes for one device.
struct GameTargetEdit: Equatable {
    let name: String
    let kind: String
    let tvAddr: String
}

/// Builds the setup device list: Sunshine's paired clients first, then any saved
/// targets Sunshine no longer lists, each with its saved type (or a guess) and an
/// Android TV's address carried over. Pure, for the tests.
enum GameSetupModel {
    static func drafts(paired: [GamePaired], targets: [GameTarget]) -> [GameDeviceDraft] {
        let byName = Dictionary(targets.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [GameDeviceDraft] = []
        for p in paired {
            let existing = byName[p.name]
            out.append(GameDeviceDraft(
                name: p.name,
                kind: existing?.kind ?? GameTypeGuess.kind(for: p.name),
                tvAddr: existing?.tvAddr ?? ""))
            seen.insert(p.name)
        }
        for t in targets where !seen.contains(t.name) {
            out.append(GameDeviceDraft(name: t.name, kind: t.kind, tvAddr: t.tvAddr))
        }
        return out
    }
}

