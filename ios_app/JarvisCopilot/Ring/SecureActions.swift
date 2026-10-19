import Foundation
import UIKit

/// What a button can do to the door alarm.
enum DoorButtonCommand: String, Codable, CaseIterable, Sendable {
    case armHome = "arm_home", armAway = "arm_away", armNow = "arm_now", cancelArming = "cancel_arming"
    case disarm, silence, status

    var title: String {
        switch self {
        case .armHome: return "Arm Home"
        case .armAway: return "Arm Away"
        case .armNow: return "Arm now (skip the exit delay)"
        case .cancelArming: return "Cancel arming"
        case .disarm: return "Disarm"
        case .silence: return "Silence the alarm"
        case .status: return "Alarm status"
        }
    }

    /// What Face ID asks, and the notification says, when it has to ask.
    var approvalTitle: String { self == .disarm ? "Disarm the door alarm" : "Silence the door alarm" }

    /// Disarm and silence take Face ID — or the button key, when the button skips it.
    var needsFaceID: Bool { self == .disarm || self == .silence }
}

/// The car's commands as button actions: every `ToyotaCommand`, plus "status".
enum CarButtonCommand {
    static let status = "status"

    static var all: [String] { ToyotaCommand.allCases.map(\.rawValue) + [status] }

    static func title(_ command: String) -> String {
        if command == status { return "Car status" }
        return ToyotaCommand(rawValue: command)?.approvalTitle ?? command
    }

    static func needsFaceID(_ command: String) -> Bool { ToyotaCommand(rawValue: command)?.needsFaceID ?? false }
}

/// A door or car command waiting for Face ID: a press from Control Center, a widget or the ring
/// can't show Face ID in the background, so a notification asks and the tap runs it in the app.
struct PendingSecureAction: Codable, Equatable, Sendable {
    enum Target: String, Codable, Sendable { case door, car }
    let target: Target
    let command: String
    let at: Date
}

/// Runs door-alarm and car actions. Disarm, silence and car commands need a proof: the button
/// key's when the action skips Face ID AND a person pressed it, otherwise Face ID — right away when
/// the app is open, else through a "Tap to …" notification.
@MainActor
struct SecureActionRunner {
    var armDoor: (String) async throws -> DoorState = { try await DoorAlarmAPI().arm($0) }
    var doorAction: (String) async throws -> DoorState = { try await DoorAlarmAPI().action($0) }
    var sendDoor: (String, ToyotaApprover.Proof, Bool) async throws -> DoorState = {
        try await DoorAlarmAPI().send($0, proof: $1, byButton: $2)
    }
    var doorState: () async throws -> DoorState = { try await DoorAlarmAPI().state() }
    var runCar: (ToyotaCommand, ToyotaApprover.Proof?, Bool) async throws -> String = {
        try await ToyotaAPI().run($0, proof: $1, byButton: $2)
    }
    var carState: () async throws -> String = { try await SecureActionRunner.carSummary() }
    var faceIDProof: (String, String, String) async throws -> ToyotaApprover.Proof = { command, title, domain in
        // A button key the server lost is registered again under this same Face ID.
        if !ButtonKeyRegistration.isRegistered, SecureActionPending.wantsButtonKey {
            return try await ToyotaApprover.shared.proofRegisteringButtonKey(for: command, title: title, domain: domain)
        }
        return try await ToyotaApprover.shared.proof(for: command, title: title, domain: domain)
    }
    var buttonProof: (String, String) throws -> ToyotaApprover.Proof = { command, domain in
        try ToyotaApprover.shared.buttonProof(for: command, domain: domain)
    }
    var buttonKeyRegistered: () -> Bool = { ButtonKeyRegistration.isRegistered }
    var forgetButtonKey: () -> Void = { ButtonKeyRegistration.isRegistered = false }
    /// The phone's own window is up (not just CarPlay, not a background launch for a press).
    var isForeground: () -> Bool = {
        UIApplication.shared.applicationState == .active && AppLifecycle.shared.isForeground
    }
    /// Posts the "Tap to …" notification and keeps the action; false when it can't be posted.
    var askOnTap: (PendingSecureAction, String) async -> Bool = { action, title in
        await SecureActionPending.ask(action, title: title)
    }
    var now: () -> Date = Date.init

    func door(_ command: DoorButtonCommand, skipFaceID: Bool, physical: Bool) async -> String {
        do {
            switch command {
            case .armHome, .armAway:
                return line(try await armDoor(command == .armHome ? "home" : "away"))
            case .armNow, .cancelArming:
                return line(try await doorAction(command.rawValue))
            case .status:
                return line(try await doorState())
            case .disarm, .silence:
                let domain = DoorAlarmAPI.domain
                if skipFaceID && physical && buttonKeyRegistered() {
                    do {
                        let proof = try buttonProof(command.rawValue, domain)
                        return line(try await sendDoor(command.rawValue, proof, true))
                    } catch where Self.buttonKeyRefused(error) {
                        forgetButtonKey()
                    }
                }
                guard isForeground() else {
                    return await askForFaceID(.init(target: .door, command: command.rawValue, at: now()),
                                              command.approvalTitle)
                }
                let proof = try await faceIDProof(command.rawValue, command.approvalTitle, domain)
                return line(try await sendDoor(command.rawValue, proof, false))
            }
        } catch CarSignError.cancelled {
            return "Not approved"
        } catch {
            return "\(command.title) failed: \(apiErrorMessage(error))"
        }
    }

    func car(_ command: String, skipFaceID: Bool, physical: Bool) async -> String {
        let title = CarButtonCommand.title(command)
        do {
            if command == CarButtonCommand.status { return try await carState() }
            guard let toyota = ToyotaCommand(rawValue: command) else { return "unknown car command \(command)" }
            guard toyota.needsFaceID else { return try await runCar(toyota, nil, false) }
            let domain = "jarvis-car"
            if skipFaceID && physical && buttonKeyRegistered() {
                do {
                    return try await runCar(toyota, try buttonProof(command, domain), true)
                } catch where Self.buttonKeyRefused(error) {
                    forgetButtonKey()
                }
            }
            guard isForeground() else {
                return await askForFaceID(.init(target: .car, command: command, at: now()), title)
            }
            return try await runCar(toyota, try await faceIDProof(command, title, domain), false)
        } catch CarSignError.cancelled {
            return "Not approved"
        } catch {
            return "\(title) failed: \(apiErrorMessage(error))"
        }
    }

    private func askForFaceID(_ action: PendingSecureAction, _ title: String) async -> String {
        await askOnTap(action, title) ? "Tap the notification to approve with Face ID"
                                      : "\(title) needs Face ID — turn on notifications or open Jarvis"
    }

    private func line(_ state: DoorState) -> String {
        let alarm = state.alarm
        switch alarm.state {
        case "arming": return "Arming \(alarm.mode ?? "")".trimmingCharacters(in: .whitespaces)
        case "armed_away": return "Armed Away"
        case "armed_home": return "Armed Home"
        case "entry": return "Entry delay — \(alarm.contactName ?? "a door") opened"
        case "triggered": return "Alarm going off"
        default: return "Disarmed"
        }
    }

    /// The button key couldn't sign, or the server refused it (reset, a new Face ID key, a key made
    /// since): Face ID instead, which registers it again. Anything else is a real failure.
    static func buttonKeyRefused(_ error: Error) -> Bool {
        if case .http(403, _) = error as? APIError { return true }
        return error is CarSignError
    }

    static func carSummary() async throws -> String {
        let state = try await ToyotaAPI().state()
        if let error = state.error { return error }
        guard let car = state.car else { return "No car" }
        var parts = [car.running ? "Running" : "Off"]
        if let locked = car.doors?.locked { parts.append(locked ? "locked" : "unlocked") }
        if let fuel = car.fuelPct { parts.append("\(Int(fuel))% fuel") }
        if let range = car.rangeMi { parts.append("\(Int(range)) mi") }
        return parts.joined(separator: " · ")
    }
}

/// Door/car actions waiting for the "Tap to …" notification, run with Face ID when the app comes up.
@MainActor
enum SecureActionPending {
    static let key = "jc.secureActions.pending"
    /// How long a tap still counts: a disarm asked for a while ago is not what he means now.
    static let freshFor: TimeInterval = 3 * 60
    static var defaults: UserDefaults = .standard

    /// True while any saved button skips Face ID, so a Face ID prompt also restores the button key.
    static var wantsButtonKey: Bool { ControlButtonStore.shared.buttons.contains { $0.skipsFaceID } }

    static func ask(_ action: PendingSecureAction, title: String) async -> Bool {
        do {
            try await DefaultNotifier().post(LocalNotificationRequest(title: title, body: "Tap to approve with Face ID",
                                                                      timeSensitive: true))
        } catch {
            JcLog.dropped(JcLog.services, "secure action notification", error)
            return false
        }
        save(load() + [action])
        return true
    }

    /// Runs what is still fresh, once, with Face ID. Called when the app comes to the foreground.
    static func drain(runner: SecureActionRunner? = nil, now: Date = Date()) async {
        var runner = runner ?? SecureActionRunner()
        guard !load().isEmpty, runner.isForeground() else { return }
        // Never asks again from here: an action that can't get Face ID now is dropped, not renewed.
        runner.askOnTap = { _, _ in false }
        let fresh = load().filter { now.timeIntervalSince($0.at) < freshFor }
        save([])
        for action in fresh {
            let result: String
            switch action.target {
            case .door:
                guard let command = DoorButtonCommand(rawValue: action.command) else { continue }
                result = await runner.door(command, skipFaceID: false, physical: false)
            case .car:
                result = await runner.car(action.command, skipFaceID: false, physical: false)
            }
            JcLog.services.notice("secure action \(action.command, privacy: .public): \(result, privacy: .public)")
        }
    }

    static func load() -> [PendingSecureAction] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PendingSecureAction].self, from: data)) ?? []
    }

    static func save(_ actions: [PendingSecureAction]) {
        defaults.set(try? JSONEncoder().encode(actions), forKey: key)
    }
}
