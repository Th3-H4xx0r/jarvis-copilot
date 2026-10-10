import Foundation
import UserNotifications

/// The door alarm as a Jarvis device on this phone. The alarm itself runs on the server (the
/// `door_*` tools); the phone only lends what the server can't do from far away:
/// - `door_alarm_ring` — a real system alarm (AlarmKit) that rings through Silent and Focus when
///   the alarm goes off, or `{stop: true}` to end it once disarmed;
/// - `door_show_approvals` — bring up a disarm/silence request Jarvis made, for Face ID.
@MainActor
final class DoorAlarmDevice: WearableDevice {
    static let shared = DoorAlarmDevice()
    static let kind = "door_alarm"
    static let model = "Smart Life door alarm (PHYSEN)"
    private static let idKey = "jc.door.deviceID"
    private static let ringKey = "jc.door.ringingAlarm"

    let deviceID: String
    private let alarms: AlarmScheduling
    private let defaults: UserDefaults

    init(alarms: AlarmScheduling = DefaultAlarmScheduler(), defaults: UserDefaults = .standard) {
        self.alarms = alarms
        self.defaults = defaults
        if let id = defaults.string(forKey: Self.idKey) {
            deviceID = id
        } else {
            deviceID = "door-" + UUID().uuidString.prefix(8).lowercased()
            defaults.set(deviceID, forKey: Self.idKey)
        }
    }

    var name: String { WearableNames.shared.name(Self.kind, fallback: "Door Alarm") }
    /// Lives on the server: always reachable while this app is paired.
    var isConnected: Bool { true }

    func start() {
        DeviceRegistry.shared.syncMembership(of: self, identity: Self.kind, model: Self.model)
    }

    var capabilities: [DeviceCapability] {
        [
            DeviceCapability(name: "door_alarm_ring", description: """
                The server calls this when the door alarm goes off: rings a full-screen system alarm on \
                Pranav's iPhone (through Silent and Focus). {stop: true} ends it. Don't call it yourself — \
                use the door_* tools.
                """, inputSchema: DeviceCapability.schema([
                    "name": ["type": "string", "description": "Which door opened."],
                    "stop": ["type": "boolean", "description": "End the ringing alarm."],
                ])),
            DeviceCapability(name: "door_show_alarm", description: """
                The server calls this when a door trips the alarm: brings up the alarm card (countdown, \
                Face ID disarm) over the app. Don't call it yourself.
                """, inputSchema: DeviceCapability.schema()),
            DeviceCapability(name: "door_show_approvals", description: """
                Bring up the door alarm's waiting Face ID approvals (disarm / silence) on his iPhone. \
                The server calls this itself after door_disarm; you don't need to.
                """, inputSchema: DeviceCapability.schema()),
        ]
    }

    func snapshot() -> [String: Any] {
        guard let state = DoorAlarmStore.shared.state else { return ["loaded": false] }
        return ["alarm": state.alarm.state, "hub": state.hubName,
                "doors": state.contacts.map { ["name": $0.name, "open": $0.open as Any] }]
    }

    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "door_show_alarm":
            Task { await DoorAlarmAlert.shared.refresh() }
            return ["ok": true]
        case "door_show_approvals":
            Task { await DoorApprovals.shared.refresh() }
            return ["ok": true]
        case "door_alarm_ring":
            if args["stop"] as? Bool == true { return await stopRinging() }
            return await ring(door: args["name"] as? String ?? "A door")
        default:
            throw DeviceError.unknownCommand(name)
        }
    }

    /// Asks for AlarmKit permission while the app is on screen (the page calls it), so the first
    /// real alarm — often while the phone is locked — can ring through Silent.
    func prepareAlarmSound() async {
        guard alarms.isAvailable else { return }
        _ = try? await alarms.requestAuthorization()
    }

    // MARK: Ringing

    private func ring(door: String) async -> [String: Any] {
        _ = await stopRinging()
        let label = "Door alarm — \(door) opened"
        if alarms.isAvailable, (try? await alarms.requestAuthorization()) == true {
            do {
                // A one-second timer: AlarmKit's alerting UI, which plays through Silent mode.
                let alarm = try await alarms.schedule(AlarmSpec(kind: .timer(seconds: 1), label: label, snoozeMinutes: 1))
                defaults.set(alarm.id, forKey: Self.ringKey)
                return ["ok": true, "via": "alarmkit"]
            } catch {
                JcLog.core.error("door alarm: AlarmKit failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let content = UNMutableNotificationContent()
        content.title = "Door alarm"
        content.body = "\(door) opened — the alarm is going off."
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "door-alarm-ring", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        return ["ok": true, "via": "notification"]
    }

    private func stopRinging() async -> [String: Any] {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["door-alarm-ring"])
        guard let id = defaults.string(forKey: Self.ringKey) else { return ["ok": true, "stopped": false] }
        defaults.removeObject(forKey: Self.ringKey)
        try? await alarms.stop(id: id)
        try? await alarms.cancel(id: id)
        return ["ok": true, "stopped": true]
    }
}
