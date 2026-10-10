import Foundation
import UIKit

/// The door alarm's state for the card and the page. The server owns the alarm; this polls it every
/// 3 s while a door-alarm screen is on screen (entry delays count down in seconds) and otherwise
/// loads on demand. Disarm and silence go through Face ID first.
@MainActor
final class DoorAlarmStore: ObservableObject {
    static let shared = DoorAlarmStore()

    struct Refusal: Identifiable, Equatable {
        let id = UUID()
        let mode: String
        let message: String
        let open: [DoorContact]
    }

    @Published private(set) var state: DoorState?
    @Published private(set) var events: [DoorEvent] = []
    @Published private(set) var problem: String?
    @Published private(set) var busy: String?
    /// A short line after an action ("Armed away", "The hub didn't confirm …").
    @Published var notice: String?
    @Published var refusal: Refusal?

    let api: DoorAlarmAPI
    let approver: ToyotaApprover
    private var watchers = 0
    private var poller: Task<Void, Never>?
    /// Bumped by every action: a refresh that started before it must not overwrite its newer state.
    private var generation = 0

    init(api: DoorAlarmAPI = DoorAlarmAPI(), approver: ToyotaApprover? = nil) {
        self.api = api
        self.approver = approver ?? ToyotaApprover.shared
    }

    var isSetUp: Bool { state?.setup.hub == true }

    func load() async {
        guard api.api.isPaired else { problem = "Pair with a Jarvis server first."; return }
        let started = generation
        do {
            let fresh = try await api.state()
            guard started == generation else { return }
            state = fresh
            problem = nil
        } catch {
            if !wasCancelled(error) { problem = apiErrorMessage(error) }
        }
    }

    func loadHistory(contact: String? = nil) async {
        do {
            events = try await api.history(limit: 150, contact: contact)
        } catch {
            if !wasCancelled(error) { problem = apiErrorMessage(error) }
        }
    }

    /// A screen that shows live state calls this on appear and `unwatch` on disappear.
    func watch() {
        watchers += 1
        guard poller == nil else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                // Only while the app is on screen: the keep-alive holds it running in the background.
                if UIApplication.shared.applicationState == .active { await self?.load() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        if watchers == 0 {
            poller?.cancel()
            poller = nil
        }
    }

    // MARK: Actions

    func arm(_ mode: String, bypass: [String] = []) async {
        busy = "arm"
        defer { busy = nil }
        generation += 1
        do {
            state = try await api.arm(mode, bypass: bypass)
            notice = mode == "away" ? "Arming — leave within \(state?.alarm.exitDelay ?? 60) s" : "Armed home"
        } catch {
            // A 409 is either "a door is open" or "not set up": offer "arm anyway" only for doors
            // the server reports open right now, never from what this page last showed.
            await load()
            if case .http(409, let message)? = error as? APIError, let open = state?.openContacts, !open.isEmpty {
                refusal = Refusal(mode: mode, message: message, open: open)
            } else if !wasCancelled(error) {
                notice = apiErrorMessage(error)
            }
        }
    }

    func disarm() async { await faceID("disarm", title: "Disarm the door alarm") }

    func silence() async { await faceID("silence", title: "Silence the siren") }

    private func faceID(_ action: String, title: String) async {
        busy = action
        defer { busy = nil }
        generation += 1
        do {
            let proof = try await approver.proof(for: action, title: title, domain: DoorAlarmAPI.domain)
            state = try await api.send(action, proof: proof)
            notice = action == "disarm" ? "Disarmed" : "Siren silenced"
        } catch CarSignError.cancelled {
            return
        } catch {
            if case .http(403, _)? = error as? APIError { approver.forgetRegistration() }
            if !wasCancelled(error) { notice = apiErrorMessage(error) }
        }
    }

    /// Changes one of the hub's own settings. The server only answers once the hub confirms.
    func set(_ point: DoorDataPoint, to value: Any) async {
        busy = point.code
        defer { busy = nil }
        do {
            _ = try await api.set(point.code, value: value)
            await load()
        } catch {
            if !wasCancelled(error) { notice = apiErrorMessage(error) }
            await load()
        }
    }

    func updateContact(_ id: String, _ changes: [String: Any]) async {
        await update(["contacts": [id: changes]])
    }

    func updateAlarm(_ changes: [String: Any]) async {
        await update(["alarm": changes])
    }

    func updateSiren(_ changes: [String: Any]) async {
        await update(["siren": changes])
    }

    private func update(_ body: [String: Any]) async {
        do {
            try await api.updateSettings(body)
            await load()
        } catch {
            if !wasCancelled(error) { notice = apiErrorMessage(error) }
        }
    }

    func rename(_ name: String) async {
        do {
            try await api.rename(name)
            await load()
        } catch {
            if !wasCancelled(error) { notice = apiErrorMessage(error) }
        }
    }
}
