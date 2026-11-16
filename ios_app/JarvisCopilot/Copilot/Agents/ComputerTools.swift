import SwiftUI
import Observation

// The Mac and the PC as button targets (2026-11-15: "expose their tools like regular wearables,
// so I can create buttons for them and map them to actions"). Each computer's jc-client tools run
// through the server's /api/devices/skills/invoke like any server device; its power actions
// (Wake, Sleep, Lock, Unlock, Screen) are saved as synthetic `computer_*` skills and run through
// the same /api/coding/agents/mac/* calls the Agents card uses — so Wake goes through the
// server's wake path while the machine sleeps, and Unlock keeps its Face ID approval.

// MARK: - Power actions

enum ComputerPowerAction: String, CaseIterable, Identifiable {
    case wake, sleep, lock, unlock, screen

    var id: String { rawValue }

    /// The skill name a button saves ("computer_wake").
    var skill: String { "computer_\(rawValue)" }

    init?(skill: String) {
        guard skill.hasPrefix("computer_"), let a = ComputerPowerAction(rawValue: String(skill.dropFirst(9))) else {
            return nil
        }
        self = a
    }

    func title(isPC: Bool) -> String {
        switch self {
        case .wake: return isPC ? "Wake PC" : "Wake Mac"
        case .sleep: return "Sleep"
        case .lock: return "Lock"
        case .unlock: return "Unlock"
        case .screen: return "Screen"
        }
    }

    func detail(isPC: Bool) -> String {
        let it = isPC ? "the PC" : "the Mac"
        switch self {
        case .wake: return isPC ? "Wakes the PC over Wi-Fi from your other computer" : "Wakes the Mac, even from sleep"
        case .sleep: return "Puts \(it) to sleep now"
        case .lock: return "Locks \(it)'s screen"
        case .unlock: return "Unlocks \(it)'s screen after Face ID"
        case .screen: return "Opens \(it)'s screen live to watch and control"
        }
    }

    var symbol: String {
        switch self {
        case .wake: return "power"
        case .sleep: return "moon.fill"
        case .lock: return "lock.fill"
        case .unlock: return "lock.open.fill"
        case .screen: return "rectangle.on.rectangle"
        }
    }

    /// The Agents card's server call; nil for Screen (it opens the live view here).
    var macPower: AgentsStore.MacPowerAction? {
        switch self {
        case .wake: return .wake
        case .sleep: return .letSleep
        case .lock: return .lock
        case .unlock: return .unlock
        case .screen: return nil
        }
    }

    /// Why it can't run right now, or nil. Everything but Wake needs the computer awake; Wake
    /// needs a PC whose Wi-Fi adapter can be woken.
    func unavailable(_ c: ServerComputer, name: String) -> String? {
        switch self {
        case .wake:
            if c.isPC, c.wakeCapable == false { return c.wakeReason ?? "This PC's Wi-Fi adapter can't be woken remotely" }
            return nil
        default:
            return c.awake ? nil : "\(name) is asleep — wake it first"
        }
    }
}

/// A Mac or PC as the server's Agents card knows it.
struct ServerComputer: Equatable {
    let os: String
    let awake: Bool
    var wakeCapable: Bool? = nil
    var wakeReason: String? = nil

    var isPC: Bool { os == "windows" }

    init(os: String, awake: Bool, wakeCapable: Bool? = nil, wakeReason: String? = nil) {
        self.os = os
        self.awake = awake
        self.wakeCapable = wakeCapable
        self.wakeReason = wakeReason
    }

    init(_ mac: AgentMacPower) {
        self.init(os: mac.os, awake: mac.isAwake, wakeCapable: mac.wakeCapable, wakeReason: mac.wakeReason)
    }
}

/// The Macs and PCs, by device id, with their display names: from the Agents list (already loaded
/// when the Agents tab has been open, else fetched).
@MainActor
enum ComputerDirectory {
    static var fetch: () async -> [AgentMacPower] = {
        let loaded = AgentsStore.shared.macs
        if !loaded.isEmpty { return loaded }
        return (try? await AgentsAPI().list().mac) ?? []
    }

    static func load() async -> [String: (name: String, computer: ServerComputer)] {
        var out: [String: (name: String, computer: ServerComputer)] = [:]
        for mac in await fetch() {
            out[mac.deviceId] = (AgentsMacPowerCopy.cardName(mac.name, os: mac.os), ServerComputer(mac))
        }
        return out
    }
}

/// Runs a saved power action (a button, a ring gesture) and says what happened.
@MainActor
enum ComputerPowerRunner {
    static var api: AgentsAPI = AgentsAPI()

    static func run(_ action: ComputerPowerAction, deviceID: String) async -> String {
        guard let call = action.macPower else {
            MacScreenPresenter.shared.open(deviceID)
            return "screen: opening the live view"
        }
        do {
            try await api.macPower(call.path, deviceId: deviceID, on: call.on)
            Task { await AgentsStore.shared.refresh() }
            return "\(action.skill): sent"
        } catch {
            return "\(action.rawValue) unavailable: \(apiErrorMessage(error))"
        }
    }
}

/// Opens a computer's live screen from anywhere (a button press): the root view presents it.
@Observable
@MainActor
final class MacScreenPresenter {
    static let shared = MacScreenPresenter()
    var session: MacScreenSession?

    func open(_ deviceID: String) { session = MacScreenSession(deviceId: deviceID) }
}

extension View {
    /// The full-screen live view a `computer_screen` button asks for.
    func macScreenPresenter() -> some View { modifier(MacScreenPresenterHost()) }
}

private struct MacScreenPresenterHost: ViewModifier {
    @State private var presenter = MacScreenPresenter.shared

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(get: { presenter.session != nil },
                                                     set: { if !$0 { presenter.session = nil } })) {
            if let session = presenter.session { MacScreenControlView(session: session, closesShare: true) }
        }
    }
}

// MARK: - The tools page (Agents → the Mac/PC card → Tools)

/// A computer's tools listed the way a wearable's are: the power actions it answers to (tap to run)
/// and every tool Jarvis can call on it, each greyed with why while the computer can't run it.
struct ComputerToolsPage: View {
    let deviceId: String
    let name: String
    var store: AgentsStore = .shared

    @State private var tools: [DeviceCapability] = []
    @State private var loaded = false
    @State private var running: ComputerPowerAction?
    @State private var message: String?

    private var mac: AgentMacPower? { store.macs.first { $0.deviceId == deviceId } }
    private var computer: ServerComputer { mac.map(ServerComputer.init) ?? ServerComputer(os: "macos", awake: false) }

    var body: some View {
        JcPage(name) {
            ComputerToolsList(name: name, computer: computer, tools: tools, loaded: loaded, running: running,
                              message: message) { run($0) }
        }
        .task { await load() }
    }

    private func load() async {
        ServerDevices.forgetCache()
        tools = await ServerDevices.load().first { $0.id == deviceId }?.capabilities ?? []
        loaded = true
    }

    private func run(_ action: ComputerPowerAction) {
        guard let mac else { return }
        if action == .screen {
            MacScreenPresenter.shared.open(deviceId)
            return
        }
        guard let call = action.macPower else { return }
        running = action
        message = nil
        Task {
            message = await store.macPower(mac, call)
            running = nil
        }
    }
}

/// The page's body, separate so it renders and tests without the network.
struct ComputerToolsList: View {
    let name: String
    let computer: ServerComputer
    let tools: [DeviceCapability]
    var loaded = true
    var running: ComputerPowerAction? = nil
    var message: String? = nil
    let run: (ComputerPowerAction) -> Void

    var body: some View {
        JcSectionLabel("Power", first: true)
        JcCard(padding: 0) {
            let actions = ComputerToolsCopy.powerActions(computer)
            ForEach(Array(actions.enumerated()), id: \.element) { i, action in
                let reason = action.unavailable(computer, name: name)
                JcRow(symbol: action.symbol, title: action.title(isPC: computer.isPC),
                      subtitle: reason ?? action.detail(isPC: computer.isPC), subtitleLines: 2,
                      last: i == actions.count - 1, action: reason == nil ? ({ run(action) } as () -> Void) : nil) {
                    if running == action { JcLoader(size: 16) } else if reason == nil { JcRowChevron() }
                }
                .disabled(reason != nil)
            }
        }
        if let message {
            Label { Text(message) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                .font(.footnote)
                .foregroundStyle(JcTheme.danger)
                .padding(.top, 8)
        }
        JcSectionLabel("Tools") { Text(tools.isEmpty ? "" : "\(tools.count)") }
        if tools.isEmpty {
            JcCard {
                Text(loaded ? "\(name) hasn't told Jarvis about any tools yet." : "Loading…")
                    .font(.subheadline)
                    .foregroundStyle(JcTheme.muted)
            }
        } else {
            JcCard(padding: 0) {
                let sorted = ComputerToolsCopy.sorted(tools)
                ForEach(Array(sorted.enumerated()), id: \.element.name) { i, tool in
                    JcRow(symbol: ComputerToolsCopy.symbol(tool.name), title: DevicesSkillText.title(forIdentifier: tool.name),
                          subtitle: computer.awake ? ActionPickerIndex.firstSentence(tool.description)
                                                   : "\(name) is asleep — wake it first",
                          subtitleLines: 2, last: i == sorted.count - 1) { EmptyView() }
                        .opacity(computer.awake ? 1 : 0.5)
                }
            }
        }
        Text("Any of these can be a Control Center or widget button, or a ring gesture: More → Widget creator.")
            .font(.footnote)
            .foregroundStyle(JcTheme.muted)
            .padding(.top, 10)
    }
}

enum ComputerToolsCopy {
    /// The power actions in card order. A Mac has no Wake while it's awake (nothing to do), the
    /// others stay listed (greyed while asleep) so a button can be mapped to them any time.
    static func powerActions(_ c: ServerComputer) -> [ComputerPowerAction] {
        c.awake ? [.sleep, .lock, .unlock, .screen] : [.wake, .sleep, .lock, .unlock, .screen]
    }

    static func sorted(_ tools: [DeviceCapability]) -> [DeviceCapability] {
        tools.filter { !ActionPickerIndex.hiddenSkills.contains($0.name) }
            .sorted { DevicesSkillText.title(forIdentifier: $0.name)
                .localizedCaseInsensitiveCompare(DevicesSkillText.title(forIdentifier: $1.name)) == .orderedAscending }
    }

    /// A tool's row icon by its family.
    static func symbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.hasPrefix("chrome_") || n.hasPrefix("browser_") { return "globe" }
        if n.hasPrefix("ui_") || n.hasPrefix("screen") { return "cursorarrow.rays" }
        if n.hasPrefix("vscode_") || n.hasPrefix("code_") { return "chevron.left.forwardslash.chevron.right" }
        if n.hasPrefix("file") || n.contains("_file") { return "doc" }
        if n.contains("clipboard") { return "doc.on.clipboard" }
        if n.contains("notif") { return "bell" }
        if n.contains("music") || n.contains("media") || n.contains("volume") { return "speaker.wave.2" }
        if n.contains("app") { return "square.grid.2x2" }
        if n.hasPrefix("wol_") || n.contains("wake") { return "power" }
        if n.contains("shell") || n.contains("terminal") || n.contains("run") { return "terminal" }
        return "wrench.and.screwdriver"
    }
}
