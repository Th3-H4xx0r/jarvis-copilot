import Foundation
import Observation

/// Paired Jarvis Pods, their live status, and the settings the pod page edits.
@Observable
@MainActor
final class JarvisPodStore {
    static let shared = JarvisPodStore()

    private(set) var pods: [JarvisPodDevice] = []
    private(set) var statuses: [String: JarvisPodStatus] = [:]
    private(set) var settings: [String: JarvisPodSettings] = [:]
    private(set) var homes: [String: [JarvisPodHome]] = [:]
    /// The latest screenshot of each pod's screen (JPEG), for the live home preview.
    private(set) var screens: [String: Data] = [:]
    /// Pods whose screenshot is being fetched: the tile shows a spinner, not a stale screen.
    private(set) var loadingScreens: Set<String> = []
    /// Voice turns the server kept for each pod, newest first.
    private(set) var recordings: [String: [JarvisPodRecording]] = [:]
    private(set) var error: String?

    private let api: JarvisPodAPI
    private var lastRefresh = Date.distantPast

    init(api: JarvisPodAPI = JarvisPodAPI()) {
        self.api = api
    }

    /// The same "connected" the other wearable cards and the wearables skills use: a live link.
    var rosterEntries: [WearableEntry] {
        pods.map {
            WearableEntry(kind: "jarvis_pod", deviceID: $0.id, model: "Jarvis Pod", name: $0.name,
                          connected: $0.bridgeConnected, rssi: nil, lastRSSI: statuses[$0.id]?.rssi,
                          lastSeen: $0.lastSeen, listed: true)
        }
    }

    func refresh(force: Bool = false) async {
        guard BridgeClient.shared.isPaired else { return }
        guard force || Date().timeIntervalSince(lastRefresh) > 15 else { return }
        lastRefresh = Date()
        do {
            pods = try await api.pods()
            error = nil
        } catch {
            self.error = error.localizedDescription
            return
        }
        for pod in pods where pod.bridgeConnected {
            if let status = try? await api.status(pod.id) { statuses[pod.id] = status }
        }
    }

    /// While a screen showing pods is on screen.
    func pollWhileVisible() async {
        while !Task.isCancelled {
            await refresh(force: true)
            try? await Task.sleep(for: .seconds(15))
        }
    }

    /// Settings + homes for the pod page; also brings the pod's theme and clock in line with the phone.
    func loadDetail(_ id: String) async {
        do {
            var s = try await api.settings(id)
            homes[id] = try await api.homes(id)
            var sync: [String: Any] = [:]
            if s.accent != JarvisPodLook.hex(JcAccent.hex) { sync["theme"] = JarvisPodLook.theme }
            let tz = TimeZone.current
            if s.timezone != tz.identifier || s.tzPosix != JarvisPodLook.posixTZ(tz) {
                sync["timezone"] = tz.identifier
                sync["tz_posix"] = JarvisPodLook.posixTZ(tz)
            }
            if !sync.isEmpty { s = try await api.setSettings(id, sync) }
            settings[id] = s
            error = nil
            await loadScreen(id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadScreen(_ id: String) async {
        loadingScreens.insert(id)
        if let data = try? await api.snapshot(id) { screens[id] = data }
        loadingScreens.remove(id)
    }

    func update(_ id: String, _ changes: [String: Any]) async {
        do {
            settings[id] = try await api.setSettings(id, changes)
            if let status = try? await api.status(id) { statuses[id] = status }
            error = nil
            if changes["home"] != nil {
                screens[id] = nil               // never show the previous home's screen
                loadingScreens.insert(id)
                try? await Task.sleep(for: .milliseconds(600))  // let the pod draw the new home first
                await loadScreen(id)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteHome(_ id: String, home: String) async {
        do {
            try await api.deleteHome(id, home: home)
            await loadDetail(id)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func rename(_ id: String, to name: String) async {
        do {
            try await api.rename(id, to: name)
            await refresh(force: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadRecordings(_ id: String) async {
        if let list = try? await api.recordings(id) { recordings[id] = list }
    }

    func recordingAudio(_ id: String, _ recording: JarvisPodRecording) async throws -> Data {
        try await api.recordingAudio(id, recording.id)
    }

    func deleteRecording(_ id: String, _ recording: JarvisPodRecording) async {
        do {
            try await api.deleteRecording(id, recording.id)
            recordings[id]?.removeAll { $0.id == recording.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reboot(_ id: String) async {
        do {
            try await api.reboot(id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
