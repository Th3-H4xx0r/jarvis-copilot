import Foundation
import Observation

/// The PC's lighting, LED map, looks, setup and specs as the server holds them (/api/pc-lighting,
/// /api/pc-specs). Push-driven: while a PC page is open it wants the `pc_lighting` topic; it fetches
/// on open, after a reconnect and on pull-to-refresh. Nothing on a timer.
@MainActor
@Observable
final class PcStore {
    static let shared = PcStore()
    static let topic = "pc_lighting"

    private(set) var deviceId: String?
    private(set) var online = false
    private(set) var address = ""
    private(set) var state: PcLightingState?
    private(set) var map: PcLedMap?
    private(set) var looks: [PcLightLook] = []
    private(set) var setup: [String: PcSetupStep] = [:]
    private(set) var coverage: [String: String] = [:]   // part → host part or "missing" (absent = own LEDs)
    private(set) var engine: String?
    private(set) var engineError: String?
    private(set) var pausedForGame = false
    private(set) var controllers: [PcController] = []
    private(set) var specs: PcSpecs?
    private(set) var specsLoaded = false
    private(set) var loaded = false
    private(set) var loadError: String?

    @ObservationIgnored let api: JarvisAPI
    @ObservationIgnored private let topics: BridgeTopics
    @ObservationIgnored private var watchers = 0
    /// How often a running setup step is checked (tests shorten it).
    @ObservationIgnored var pollInterval: Duration = .seconds(2)
    @ObservationIgnored private var listening = false

    init(api: JarvisAPI = .shared, topics: BridgeTopics = .shared) {
        self.api = api
        self.topics = topics
    }

    var isMapped: Bool { map?.isMapped ?? false }

    func sharesWith(_ part: PcPart) -> PcPart? {
        coverage[part.rawValue].flatMap { $0 == "missing" ? nil : PcPart(rawValue: $0) }
    }

    func isMissing(_ part: PcPart) -> Bool { coverage[part.rawValue] == "missing" }

    // MARK: data in

    func apply(_ body: [String: Any]) {
        deviceId = body["device_id"] as? String
        online = body["online"] as? Bool ?? false
        address = body["address"] as? String ?? address
        state = PcCodec.decode(PcLightingState.self, body["state"]) ?? state
        map = PcCodec.decode(PcLedMap.self, body["map"]) ?? map
        looks = PcCodec.decode([PcLightLook].self, body["looks"]) ?? looks
        setup = PcCodec.decode([String: PcSetupStep].self, body["setup"]) ?? setup
        if let cov = body["coverage"] as? [String: Any] {
            coverage = cov.compactMapValues { $0 as? String }
        }
        if let live = body["live"] as? [String: Any] {
            engine = live["engine"] as? String
            engineError = live["error"] as? String
            pausedForGame = live["paused_for_game"] as? Bool ?? false
            controllers = PcCodec.decode([PcController].self, live["controllers"]) ?? []
        }
        loaded = true
    }

    func refresh() async {
        do {
            apply(try await api.get("/api/pc-lighting", timeout: 15).object())
            loadError = nil
        } catch where !wasCancelled(error) {
            loadError = apiErrorMessage(error)
        } catch {}
    }

    // MARK: changes (each returns nil, or what went wrong in words)

    func set(part: PcPart?, effect: PcEffect? = nil, color: String? = nil, speed: Int? = nil,
             brightness: Int? = nil, on: Bool? = nil) async -> String? {
        var body: [String: Any] = ["part": part?.rawValue ?? "all"]
        if let effect { body["effect"] = effect.rawValue }
        if let color { body["color"] = color }
        if let speed { body["speed"] = speed }
        if let brightness { body["brightness"] = brightness }
        if let on { body["on"] = on }
        return await post("/api/pc-lighting/state", body)
    }

    func applyLook(_ name: String) async -> String? { await post("/api/pc-lighting/looks/apply", ["name": name]) }

    func saveLook(_ name: String) async -> String? {
        do {
            _ = try await api.post("/api/pc-lighting/looks", json: ["name": name])
            await refresh()
            return nil
        } catch { return apiErrorMessage(error) }
    }

    func deleteLook(_ name: String) async -> String? {
        let path = "/api/pc-lighting/looks/" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
        do {
            _ = try await api.delete(path)
            looks.removeAll { $0.name == name }
            return nil
        } catch { return apiErrorMessage(error) }
    }

    func probe(_ args: [String: Any]) async -> String? {
        do {
            _ = try await api.post("/api/pc-lighting/probe", json: args, timeout: 20)
            return nil
        } catch { return apiErrorMessage(error) }
    }

    /// Saves the calibrated map; nil or the server's reason.
    func putMap(_ newMap: PcLedMap) async -> String? {
        do {
            let body = try await api.put("/api/pc-lighting/map", json: PcCodec.object(newMap)).object()
            map = PcCodec.decode(PcLedMap.self, body["map"]) ?? newMap
            if let cov = body["coverage"] as? [String: Any] { coverage = cov.compactMapValues { $0 as? String } }
            await refresh()
            return nil
        } catch { return apiErrorMessage(error) }
    }

    /// Starts a step on the PC (the server answers at once) and waits until it's no longer running.
    func runSetup(_ step: String) async -> PcSetupStep? {
        do {
            let body = try await api.post("/api/pc-lighting/setup", json: ["step": step], timeout: 30).object()
            if let started = PcCodec.decode(PcSetupStep.self, body["step"]) { setup[started.id] = started }
            let deadline = ContinuousClock.now + .seconds(17 * 60)
            while ContinuousClock.now < deadline {
                await refresh()
                if let s = setup[step], s.state != "running" { return s }
                try await Task.sleep(for: pollInterval)
            }
            return setup[step]
        } catch {
            let failed = PcSetupStep(id: step, state: "failed", detail: apiErrorMessage(error))
            setup[step] = failed
            return failed
        }
    }

    func loadSpecs() async {
        do {
            let body = try await api.get("/api/pc-specs", query: deviceId.map { ["device_id": $0] } ?? [:]).object()
            specs = PcCodec.decode(PcSpecs.self, body["specs"])
        } catch {}
        specsLoaded = true
    }

    func refreshSpecs() async -> String? {
        do {
            let body = try await api.post("/api/pc-specs/refresh", json: ["device_id": deviceId ?? ""], timeout: 100).object()
            specs = PcCodec.decode(PcSpecs.self, body["specs"]) ?? specs
            return nil
        } catch { return apiErrorMessage(error) }
    }

    private func post(_ path: String, _ body: [String: Any]) async -> String? {
        do {
            let reply = try await api.post(path, json: body, timeout: 20).object()
            if let s = PcCodec.decode(PcLightingState.self, reply["state"]) { state = s }
            return nil
        } catch {
            return apiErrorMessage(error)
        }
    }

    // MARK: visibility

    /// A PC page (or card) on screen wants pushes; balanced on/off calls.
    func watch(_ on: Bool) {
        listen()
        watchers = max(0, watchers + (on ? 1 : -1))
        if on && watchers == 1 {
            topics.want(Self.topic, owner: "pc-page", every: 0.5)
            Task { await refresh() }
        } else if !on && watchers == 0 {
            topics.drop(Self.topic, owner: "pc-page")
        }
    }

    private func listen() {
        guard !listening else { return }
        listening = true
        topics.on(Self.topic) { [weak self] data in self?.apply(data) }
        topics.onResync { [weak self] in
            guard let self, self.watchers > 0 else { return }
            Task { await self.refresh() }
        }
    }
}
