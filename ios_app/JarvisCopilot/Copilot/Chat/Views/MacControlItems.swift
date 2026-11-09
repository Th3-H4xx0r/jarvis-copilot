import Observation
import SwiftUI

// The Mac Command Center's items, once: "I meant buttons from the control center menu". The
// Command Center sheet and the live view's pinned strip are both made of `MacControlItem`s, and
// every tap on either goes through `MacControlActions` — the same channel message, the same
// optimistic change, the same Face ID path for Unlock.

// MARK: - The items

enum MacControlItem: String, CaseIterable, Identifiable, Codable {
    case wifi, bluetooth, dark, stage, airdrop, focus, mirroring
    case controlCenter = "control_center"
    case nowPlaying = "now_playing", display, sound
    case unlock, lock, sleep
    case keepAwake = "keep_awake"
    case missionControl = "mission_control"
    case showDesktop = "show_desktop"
    case spotlight
    case switchApp = "switch_app"
    case copy, paste, undo
    case closeWindow = "close_window"
    case screenshot
    case forceQuit = "force_quit"

    var id: String { rawValue }

    enum Kind: Equatable {
        /// The Mac reports it and the phone flips it (Wi-Fi, Bluetooth, Dark Mode).
        case toggle
        /// macOS lets no app switch it: a tap opens the Mac's own Control Center.
        case onMac
        case media, slider, power, keepAwake, shortcut
    }

    /// The Command Center sheet's sections, in its order.
    static let switches: [MacControlItem] = [.wifi, .bluetooth, .dark, .stage, .airdrop, .focus, .mirroring, .controlCenter]
    static let mediaAndSliders: [MacControlItem] = [.nowPlaying, .display, .sound]
    static let power: [MacControlItem] = [.unlock, .lock, .sleep, .keepAwake]
    static let shortcuts: [MacControlItem] = [.missionControl, .showDesktop, .spotlight, .switchApp, .copy, .paste,
                                              .undo, .closeWindow, .screenshot, .forceQuit]
    /// Pinned on a phone that never chose: what he reaches for most while watching the Mac.
    static let defaultPins: [MacControlItem] = [.nowPlaying, .sound]

    var kind: Kind {
        switch self {
        case .wifi, .bluetooth, .dark: return .toggle
        case .stage, .airdrop, .focus, .mirroring, .controlCenter: return .onMac
        case .nowPlaying: return .media
        case .display, .sound: return .slider
        case .unlock, .lock, .sleep: return .power
        case .keepAwake: return .keepAwake
        default: return .shortcut
        }
    }

    var opensMacControlCenter: Bool { kind == .onMac }

    var title: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .bluetooth: return "Bluetooth"
        case .dark: return "Dark Mode"
        case .stage: return "Stage Manager"
        case .airdrop: return "AirDrop"
        case .focus: return "Focus"
        case .mirroring: return "Mirroring"
        case .controlCenter: return "Control Center"
        case .nowPlaying: return "Now Playing"
        case .display: return "Display"
        case .sound: return "Sound"
        case .unlock: return "Unlock"
        case .lock: return "Lock"
        case .sleep: return "Sleep"
        case .keepAwake: return "Keep awake"
        case .missionControl: return "Mission Control"
        case .showDesktop: return "Show Desktop"
        default: return shortcut?.title ?? rawValue
        }
    }

    var symbol: String {
        switch self {
        case .wifi: return "wifi"
        case .bluetooth: return "dot.radiowaves.left.and.right"
        case .dark: return "circle.lefthalf.filled"
        case .stage: return "squares.leading.rectangle"
        case .airdrop: return "airplayaudio"
        case .focus: return "moon.fill"
        case .mirroring: return "rectangle.on.rectangle"
        case .controlCenter: return "switch.2"
        case .nowPlaying: return "music.note"
        case .display: return "sun.max.fill"
        case .sound: return "speaker.wave.2.fill"
        case .unlock: return "lock.open.fill"
        case .lock: return "lock.fill"
        case .sleep: return "moon.zzz.fill"
        case .keepAwake: return "cup.and.saucer"
        case .missionControl: return "rectangle.3.group"
        case .showDesktop: return "menubar.dock.rectangle"
        default: return shortcut?.symbol ?? "questionmark"
        }
    }

    /// The keyboard shortcut a shortcut item sends (the sheet's `MacShortcut.all`).
    var shortcut: MacShortcut? {
        let title: String
        switch self {
        case .spotlight: title = "Spotlight"
        case .switchApp: title = "Switch App"
        case .copy: title = "Copy"
        case .paste: title = "Paste"
        case .undo: title = "Undo"
        case .closeWindow: title = "Close Window"
        case .screenshot: title = "Screenshot"
        case .forceQuit: title = "Force Quit"
        default: return nil
        }
        return MacShortcut.all.first { $0.title == title }
    }

    // MARK: what it shows

    struct Face: Equatable {
        var title: String
        var subtitle: String?
        var symbol: String
        var on: Bool
    }

    /// The live state a tile shows, from the Mac's last `cc_state` (and the server's Keep awake).
    func face(_ c: MacControlState, keepAwake: Bool? = nil) -> Face {
        var f = Face(title: title, subtitle: nil, symbol: symbol, on: false)
        switch self {
        case .wifi:
            f.subtitle = MacControlState.onOff(c.wifi, on: c.wifiName ?? "On")
            f.on = c.wifi == true
        case .bluetooth:
            f.subtitle = MacControlState.onOff(c.bluetooth)
            f.on = c.bluetooth == true
        case .dark:
            f.subtitle = MacControlState.onOff(c.dark)
            f.on = c.dark == true
        case .stage:
            f.subtitle = MacControlState.onOff(c.stage)
            f.on = c.stage == true
        case .airdrop, .focus, .mirroring, .controlCenter:
            f.subtitle = "On the Mac"
        case .nowPlaying:
            f.title = c.nowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? title
            f.subtitle = c.nowArtist.flatMap { $0.isEmpty ? nil : $0 } ?? "Controls whatever is playing"
            f.on = c.nowPlaying == true
        case .display:
            f.subtitle = c.brightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "Not on this display"
        case .sound:
            if c.muted == true {
                f.subtitle = "Muted"
                f.symbol = "speaker.slash.fill"
            } else {
                f.subtitle = c.volume.map { "\(Int($0.rounded()))%" } ?? "—"
            }
        case .unlock:
            f.on = c.locked == true
            f.subtitle = c.locked == true ? "Locked" : nil
        case .keepAwake:
            f.subtitle = MacControlState.onOff(keepAwake)
            f.on = keepAwake == true
        default:
            break
        }
        return f
    }

    /// Whether it can do anything now: Display needs a display with brightness, Keep awake the
    /// Mac on the server.
    func isAvailable(_ c: MacControlState, hasMac: Bool) -> Bool {
        switch self {
        case .display: return c.brightness != nil
        case .keepAwake: return hasMac
        default: return true
        }
    }

    // MARK: what a tap does

    /// A plain tap's action, as the Command Center sheet does it. Nil for Now Playing and the
    /// sliders, which have their own controls (transport buttons, a slider).
    func tap(_ c: MacControlState, keepAwake: Bool? = nil) -> MacControlTap? {
        switch self {
        case .wifi: return .toggle("wifi", on: !(c.wifi ?? false))
        case .bluetooth: return .toggle("bluetooth", on: !(c.bluetooth ?? false))
        case .dark: return .toggle("dark", on: !(c.dark ?? false))
        case .stage, .airdrop, .focus, .mirroring, .controlCenter: return .command("control_center")
        case .nowPlaying, .display, .sound: return nil
        case .unlock: return .unlock
        case .lock: return .lock
        case .sleep: return .sleep
        case .keepAwake: return .keepAwake(!(keepAwake ?? false))
        case .missionControl: return .command("mission_control")
        case .showDesktop: return .command("show_desktop")
        default:
            guard let s = shortcut else { return nil }
            return s.opensAppSwitcher ? .appSwitcher : .key(s.key, mods: s.mods)
        }
    }
}

/// One thing a Command Center control does.
enum MacControlTap: Equatable {
    /// A Mac switch over the channel (`wifi`, `bluetooth`, `dark`) to `on`.
    case toggle(String, on: Bool)
    /// A plain channel action (`control_center`, `mission_control`, `show_desktop`).
    case command(String)
    case media(String)
    case mute(Bool)
    case key(String, mods: [String])
    case lock, unlock, sleep
    case keepAwake(Bool)
    /// "Switch App": the phone's list of the Mac's open apps.
    case appSwitcher
}

// MARK: - The one action path

/// Runs Command Center taps for one live view, for the sheet and the pinned strip alike.
/// Channel actions go through `MacScreenSession.command` (Mac side MacControls.swift); Unlock,
/// Sleep and Keep awake through the server like the Agents → Mac card (Unlock asks his Face ID
/// in `MacPasswordSheet`).
@MainActor
@Observable
final class MacControlActions {
    @ObservationIgnored private weak var session: MacScreenSession?
    /// The sliders' own values: they follow the Mac until he drags, then his.
    var volume: Double = 50
    var brightness: Double = 0.5
    private(set) var busy: String?
    var powerError: String?
    /// Unlock's approval, for `macControlPrompts` to present.
    var passwordRequest: MacPasswordRequest?
    /// "Switch App" was tapped: the host shows the open-apps sheet.
    var wantsSwitcher = false
    /// Bumped on every tap, for the light haptic.
    private(set) var taps = 0
    @ObservationIgnored private var slideTask: Task<Void, Never>?

    init(session: MacScreenSession) {
        self.session = session
    }

    private var store: AgentsStore { AgentsStore.shared }
    var mac: AgentMacPower? { store.macs.first(where: \.isAwake) ?? store.macs.first }
    var keepAwake: Bool? { mac?.keepAwake }
    private var controls: MacControlState { session?.controls ?? MacControlState() }

    func face(_ item: MacControlItem) -> MacControlItem.Face { item.face(controls, keepAwake: keepAwake) }
    func isAvailable(_ item: MacControlItem) -> Bool { item.isAvailable(controls, hasMac: mac != nil) }

    /// A tap on an item's tile, in the sheet or the strip.
    func perform(_ item: MacControlItem) {
        guard isAvailable(item), let tap = item.tap(controls, keepAwake: keepAwake) else { return }
        run(tap)
    }

    func media(_ key: String) { run(.media(key)) }

    func toggleMute() { run(.mute(!(controls.muted ?? false))) }

    func run(_ tap: MacControlTap) {
        taps += 1
        guard let session else { return }
        switch tap {
        case .toggle(let action, let on):
            session.command(action, ["on": on]) { c in
                switch action {
                case "wifi": c.wifi = on
                case "bluetooth": c.bluetooth = on
                case "dark": c.dark = on
                default: break
                }
            }
        case .command(let action):
            session.command(action)
        case .media(let key):
            session.command("media", ["key": key]) { if key == "play" { $0.nowPlaying = !($0.nowPlaying ?? false) } }
        case .mute(let on):
            session.command("mute", ["on": on]) { $0.muted = on }
        case .key(let key, let mods):
            session.send(["t": "key", "key": key, "mods": mods])
        case .lock:
            session.command("lock") { $0.locked = true }
        case .unlock:
            unlock()
        case .sleep:
            power(.letSleep, id: "sleep")
        case .keepAwake(let on):
            power(.keepAwake(on), id: "keep")
        case .appSwitcher:
            wantsSwitcher = true
        }
    }

    // MARK: sliders

    enum Slider { case volume, brightness }

    /// A slider moved: one message per pause in a drag, never one per pixel.
    func slide(_ slider: Slider, to value: Double) {
        slideTask?.cancel()
        slideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let session = self?.session else { return }
            switch slider {
            case .volume: session.command("volume", ["value": Int(value)])
            case .brightness: session.command("brightness", ["value": value])
            }
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { self?.slideTask = nil }
        }
    }

    /// The Mac's new state: the sliders follow it unless he is dragging one.
    func absorb(_ c: MacControlState) {
        guard slideTask == nil else { return }
        if let v = c.volume { volume = v }
        if let b = c.brightness { brightness = b }
    }

    // MARK: power (through the server)

    func refreshMac() async { await store.refresh() }

    private func power(_ action: AgentsStore.MacPowerAction, id: String) {
        guard let mac else { powerError = "Jarvis can't find your Mac on the server."; return }
        powerError = nil
        busy = id
        Task {
            powerError = await store.macPower(mac, action)
            busy = nil
        }
    }

    /// Unlock Mac: the server asks the Mac, the Mac asks for his yes (Face ID on this phone, the
    /// sheet), then types the password.
    private func unlock() {
        guard let mac else { powerError = "Jarvis can't find your Mac on the server."; return }
        powerError = nil
        busy = "unlock"
        Task {
            defer { busy = nil }
            if let error = await store.macPower(mac, .unlock) { powerError = error; return }
            for _ in 0..<20 {
                let mine = store.passwordRequests.filter { $0.deviceId == mac.deviceId }
                if let request = mine.first(where: { $0.kind == "unlock" }) ?? mine.first {
                    passwordRequest = request
                    return
                }
                try? await Task.sleep(for: .seconds(1))
                await store.refresh()
            }
            powerError = "The Mac didn't ask to unlock. Is Jarvis running on it?"
        }
    }

    func answer(_ request: MacPasswordRequest, allow: Bool) async -> String? {
        let error = await store.answerMacPassword(request, allow: allow)
        if error == nil { passwordRequest = nil }
        return error
    }

    func macName(_ request: MacPasswordRequest) -> String {
        AgentsMacPowerCopy.macName(request.deviceId, in: store.macs)
    }
}

extension View {
    /// Unlock's Face ID approval (`MacPasswordSheet`) and the Switch App list for one live view.
    /// `active` false while a sheet above this view presents them itself.
    func macControlPrompts(_ actions: MacControlActions, session: MacScreenSession, active: Bool = true,
                           afterSwitch: @escaping () -> Void = {}) -> some View {
        modifier(MacControlPrompts(actions: actions, session: session, active: active, afterSwitch: afterSwitch))
    }
}

private struct MacControlPrompts: ViewModifier {
    @Bindable var actions: MacControlActions
    let session: MacScreenSession
    let active: Bool
    let afterSwitch: () -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { active && actions.wantsSwitcher },
                                        set: { if !$0 { actions.wantsSwitcher = false } })) {
                MacAppSwitcherSheet(session: session) {
                    actions.wantsSwitcher = false
                    afterSwitch()
                }
            }
            .sheet(item: Binding(get: { active ? actions.passwordRequest : nil },
                                 set: { actions.passwordRequest = $0 })) { request in
                MacPasswordSheet(request: request, macName: actions.macName(request),
                                 answer: { allow in await actions.answer(request, allow: allow) },
                                 expired: { actions.passwordRequest = nil })
            }
            .sensoryFeedback(.impact(weight: .light), trigger: actions.taps) { _, _ in active }
    }
}

// MARK: - Pins

/// Which Command Center items the live view pins, in his order. `order` is every item as he last
/// arranged them in the editor (a row he dragged keeps its place while unpinned); `pinned` are
/// the ones switched on. Ids this build doesn't know are dropped quietly.
struct MacControlPins: Codable, Equatable {
    var order: [String] = []
    var pinned: [String]

    static let key = "jc.macScreen.controls"
    /// e966a60fa5's phone-button selection, which this replaces.
    static let retiredKey = "jc.macScreen.buttons"

    init(order: [String] = [], pinned: [String] = MacControlItem.defaultPins.map(\.rawValue)) {
        self.order = order
        self.pinned = pinned
    }

    static func load(defaults: UserDefaults = ControlButtonShelf.defaults) -> MacControlPins {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(MacControlPins.self, from: data) else { return .init() }
        return stored.known
    }

    func save(defaults: UserDefaults = ControlButtonShelf.defaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    /// Without ids this build has no item for (and without repeats).
    var known: MacControlPins {
        func clean(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return ids.filter { MacControlItem(rawValue: $0) != nil && seen.insert($0).inserted }
        }
        return MacControlPins(order: clean(order), pinned: clean(pinned))
    }

    func isPinned(_ item: MacControlItem) -> Bool { pinned.contains(item.rawValue) }

    /// The editor's rows: every item in his order; ones he never placed follow in the sheet's order.
    var rows: [MacControlItem] {
        let placed = order.compactMap(MacControlItem.init(rawValue:))
        return placed + MacControlItem.allCases.filter { !placed.contains($0) }
    }

    /// What the live view shows: the pinned items in his order.
    var visible: [MacControlItem] { rows.filter(isPinned) }

    mutating func set(_ item: MacControlItem, on: Bool) {
        pinned.removeAll { $0 == item.rawValue }
        if on { pinned.append(item.rawValue) }
    }

    /// A drag in the editor: `rows` are the ids as the editor listed them.
    mutating func move(in rows: [String], from source: IndexSet, to destination: Int) {
        var ids = rows
        ids.move(fromOffsets: source, toOffset: destination)
        order = ids
    }
}

/// The pins, shared by the strip and the editor, saved on every change.
@MainActor
@Observable
final class MacControlPinsModel {
    static let shared = MacControlPinsModel()

    private(set) var pins: MacControlPins
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = ControlButtonShelf.defaults) {
        self.defaults = defaults
        defaults.removeObject(forKey: MacControlPins.retiredKey)
        pins = .load(defaults: defaults)
    }

    func update(_ change: (inout MacControlPins) -> Void) {
        var next = pins
        change(&next)
        guard next != pins else { return }
        pins = next
        next.save(defaults: defaults)
    }
}
