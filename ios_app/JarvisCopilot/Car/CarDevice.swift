import Combine
import Foundation

/// The car as a Jarvis device and as a host for linked wearables (the dashcam now, lights later).
/// Its skills: `car_get_status` and `car_directions` always; `car_set_control` only while the car
/// has controls — the car re-sends its registration whenever that set changes.
@MainActor
final class CarDevice: WearableDevice, WearableHost {
    static let shared = CarDevice()
    static let kind = "car"
    static let model = CarProfile.camry.description
    /// Kinds that can be linked to the car.
    static let accepted: Set<String> = [DashcamDevice.identityKey, CarLightsDevice.kind]
    private static let idKey = "jc.car.deviceID"

    let profile = CarProfile.camry
    let links: WearableLinks
    let presence: CarPresence
    let deviceID: String
    private let acceptedKinds: Set<String>
    /// What the last registration said about the controls (`car_set_control`'s description).
    private var advertisedControls: [String]?
    private var cancellables: Set<AnyCancellable> = []

    init(links: WearableLinks = .shared, presence: CarPresence = .shared, defaults: UserDefaults = .standard,
         accepted: Set<String> = CarDevice.accepted) {
        self.links = links
        self.presence = presence
        acceptedKinds = accepted
        if let id = defaults.string(forKey: Self.idKey) {
            deviceID = id
        } else {
            deviceID = "car-" + UUID().uuidString.prefix(8).lowercased()
            defaults.set(deviceID, forKey: Self.idKey)
        }
    }

    var name: String { WearableNames.shared.name(Self.kind, fallback: profile.model) }
    var isConnected: Bool { presence.inCar }
    /// The car is CarPlay's Wearables tab itself, not a row in it.
    var carEnabled: Bool { false }

    // MARK: Host

    var hostKind: String { Self.kind }
    var hostName: String { name }
    func accepts(_ kind: String) -> Bool { acceptedKinds.contains(kind) }
    var ownControls: [WearableControl] { [] }
    var controls: [WearableControl] { links.controls(for: Self.kind) }

    /// Join the links as a host and Jarvis as a device, and keep the skills in step with the controls.
    func start() {
        links.register(host: self)
        presence.start()
        refreshMembership()
        guard cancellables.isEmpty else { return }
        links.$revision
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.readvertiseIfControlsChanged() }
            .store(in: &cancellables)
    }

    func refreshMembership() {
        DeviceRegistry.shared.syncMembership(of: self, identity: Self.kind, model: Self.model)
    }

    private func readvertiseIfControlsChanged() {
        let ids = controls.map { "\($0.id)|\($0.kindName)|\($0.title)" }
        defer { advertisedControls = ids }
        guard let before = advertisedControls, before != ids else { return }
        BridgeClient.shared.sendRegistration()
    }

    // MARK: Skills

    var capabilities: [DeviceCapability] {
        var out = [DeviceCapability(name: "car_show_approvals", description: """
            Bring up Pranav's waiting car approvals on his iPhone so he can approve them with Face ID. \
            The server calls this itself after toyota_command; you don't need to.
            """, inputSchema: DeviceCapability.schema())]
        out.append(DeviceCapability(name: "car_get_status", description: """
            The car (\(profile.description), \(profile.colorName)): whether the phone is with it now \
            and when it last was, the devices linked to it (like the dashcam) with their status, and \
            its controls with their current values.
            """, inputSchema: DeviceCapability.schema()))
        // Always offered, not only in the car: a tool list that changed with every drive
        // would throw away the server's prompt cache. It says why when CarPlay isn't there.
        out.append(DeviceCapability(name: "car_directions", description: """
            While driving with CarPlay: start turn-by-turn driving directions on the car's screen \
            (his maps app) to a place by name or address — the closest match near him. Use it for \
            "take me to / navigate to / directions to". Then tell him in one short sentence which place \
            (name and street) and how far; the map opens when you finish speaking.
            """, inputSchema: DeviceCapability.schema([
                "destination": ["type": "string", "description": "A place name or address, e.g. \"Costco\"."],
            ], required: ["destination"])))
        let controls = self.controls
        if !controls.isEmpty {
            let list = controls.map { "\($0.id) (\($0.kindName): \($0.title))" }.joined(separator: ", ")
            out.append(DeviceCapability(name: "car_set_control", description: """
                Use one of the car's controls: \(list). Toggles take on/off, levels a number, \
                choices an option id, buttons nothing.
                """, inputSchema: DeviceCapability.schema([
                    "control": ["type": "string", "enum": controls.map(\.id), "description": "The control's id."],
                    // One plain type: some providers reject a list of types.
                    "value": ["type": "string",
                              "description": "toggle: on/off · level: a number · choice: an option id · button: omit"],
                ], required: ["control"])))
        }
        return out
    }

    func snapshot() -> [String: Any] {
        var out: [String: Any] = [
            "name": name,
            "car": profile.json,
            "in_car": presence.inCar,
            "linked": links.children(of: Self.kind).map { child -> [String: Any] in
                ["kind": child.kind, "title": child.title, "status": child.linkStatus.text,
                 "connected": child.linkStatus.connected]
            },
            "controls": controls.map(\.stateJSON),
        ]
        if let seen = presence.lastSeen { out["last_seen"] = ISO8601DateFormatter().string(from: seen) }
        return out
    }

    /// A `car_set_control` button follows the control its `control` argument names, at the value
    /// the car's page shows: a toggle's side (on/off is also its `value`), a level, a choice.
    func commandState(_ skill: String, arguments: [String: String]) -> CommandLiveState? {
        guard skill == "car_set_control", let id = arguments["control"],
              let control = controls.first(where: { $0.id == id }) else { return nil }
        return Self.state(of: control)
    }

    static func state(of control: WearableControl) -> CommandLiveState? {
        switch control.kind {
        case .toggle(let isOn): return CommandLiveState(on: isOn, mode: isOn ? "on" : "off")
        case .level(let value, _, _, _): return CommandLiveState(mode: WearableControl.format(value))
        case .choice(let selected, _): return selected.isEmpty ? nil : CommandLiveState(mode: selected)
        case .button: return nil
        }
    }

    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "car_show_approvals":
            Task { await CarApprovals.shared.refresh() }
            return ["ok": true]
        case "car_get_status":
            return snapshot()
        case "car_directions":
            let destination = (args["destination"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !destination.isEmpty else { throw DeviceError.badArgument("destination is required") }
            return try await CarDirections.start(to: destination, presence: presence)
        case "car_set_control":
            guard let id = args["control"] as? String else { throw DeviceError.badArgument("control is required") }
            guard let control = controls.first(where: { $0.id == id }) else {
                throw DeviceError.badArgument("the car has no control '\(id)'")
            }
            let value = try control.value(fromJSON: args["value"])
            try await links.perform(id, value: value, on: Self.kind)
            let now = controls.first { $0.id == id } ?? control
            return ["ok": true, "control": now.stateJSON]
        default:
            throw DeviceError.unknownCommand(name)
        }
    }
}
