import Foundation
import Observation

/// Drives pairing a Jarvis Pod: connect to its hotspot → choose Wi-Fi → send credentials →
/// pair → done. Everything external (the pod, iOS's hotspot API, the Jarvis server, time)
/// is injected so the whole flow runs in tests.
@Observable
@MainActor
final class PodSetupFlow {
    enum Step: Int, CaseIterable, Identifiable {
        case connect, wifi, send, pair, done
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .connect: return "Connect to Jarvis Pod"
            case .wifi: return "Choose Wi-Fi"
            case .send: return "Send credentials"
            case .pair: return "Pair"
            case .done: return "Done"
            }
        }
    }

    enum Status: Equatable {
        case pending, active, done
        case failed(String)
    }

    let code: PodSetupCode
    private(set) var statuses: [Step: Status] = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, .pending) })
    private(set) var detail: [Step: String] = [:]
    private(set) var info: PodInfo?
    private(set) var networks: [PodNetwork] = []
    private(set) var scanning = false
    var selectedSSID: String?
    var password = ""
    private(set) var focusPassword = false
    private(set) var finished = false

    private let client: PodSetupTalking
    private let joiner: HotspotJoining
    private let server: PodServerTalking
    private let sleep: @Sendable (Double) async -> Void
    private let now: @Sendable () -> Date
    private var pairing: PodPairing?
    private var phoneSSID: String?
    private var startedAt = Date.distantPast
    private var cancelled = false
    private var freshCodeTries = 0

    init(code: PodSetupCode,
         client: PodSetupTalking = PodSetupHTTP(),
         joiner: HotspotJoining = SystemHotspotJoiner(),
         server: PodServerTalking = JarvisPodServer(),
         sleep: @escaping @Sendable (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.code = code
        self.client = client
        self.joiner = joiner
        self.server = server
        self.sleep = sleep
        self.now = now
    }

    var selectedIsSecure: Bool { networks.first { $0.ssid == selectedSSID }?.secure ?? true }
    var canSubmitWifi: Bool {
        statuses[.wifi] == .active && selectedSSID != nil && (!selectedIsSecure || password.count >= 8)
    }
    var failedStep: Step? {
        Step.allCases.first { if case .failed = statuses[$0] { return true } else { return false } }
    }

    // MARK: Steps

    func start() async {
        cancelled = false
        for step in Step.allCases { statuses[step] = .pending }
        statuses[.connect] = .active
        detail[.connect] = "Getting a pairing code…"
        phoneSSID = await joiner.currentSSID()
        guard await fetchPairing() else { return }
        startedAt = now()
        detail[.connect] = "Joining \(code.ssid)…"
        do {
            try await joiner.join(ssid: code.ssid, passphrase: code.passphrase)
        } catch HotspotJoinError.declined {
            return fail(.connect, "Tap Join when iOS asks to connect to \(code.ssid).")
        } catch {
            return fail(.connect, "Couldn't join \(code.ssid). Is the pod showing its QR code?")
        }
        guard let info = await retrying(seconds: 10, { try await self.client.info() }) else {
            return fail(.connect, "Joined \(code.ssid) but the pod didn't answer.")
        }
        guard !cancelled else { return }
        self.info = info
        detail[.connect] = "\(info.battery)% battery" + (info.firmware.isEmpty ? "" : " · \(info.firmware)")
        statuses[.connect] = .done
        await loadNetworks()
    }

    func loadNetworks() async {
        statuses[.wifi] = .active
        scanning = true
        networks = (try? await client.scan()) ?? networks
        scanning = false
        if selectedSSID == nil || !networks.contains(where: { $0.ssid == selectedSSID }) {
            selectedSSID = networks.first(where: { $0.ssid == phoneSSID })?.ssid ?? networks.first?.ssid
        }
        if networks.isEmpty { detail[.wifi] = "The pod can't see any networks. Move it closer and refresh." }
    }

    func submitWifi() async {
        guard let ssid = selectedSSID, let pairing else { return }
        focusPassword = false
        statuses[.wifi] = .done
        detail[.wifi] = ssid
        statuses[.send] = .active
        detail[.send] = nil
        let body = await Self.setupBody(ssid: ssid, password: selectedIsSecure ? password : "",
                                        server: server.serverURL(), pairing: pairing)
        do {
            try await client.setup(body)
        } catch PodSetupError.rejected(let message) {
            return fail(.send, message)
        } catch {
            return fail(.send, "Lost the pod's hotspot. Retry.")
        }
        statuses[.send] = .done
        await pair(ssid: ssid)
    }

    private func pair(ssid: String) async {
        statuses[.pair] = .active
        detail[.pair] = "Joining \(ssid)…"
        var misses = 0
        var rejoined = false
        let deadline = now().addingTimeInterval(90)
        while now() < deadline {
            guard !cancelled else { return }
            do {
                let s = try await client.status()
                misses = 0
                if !s.message.isEmpty { detail[.pair] = s.message }
                switch s.state {
                case "paired": return await finish()
                case "failed": return await handle(failure: s, ssid: ssid)
                default: break
                }
            } catch {
                // Normal for a moment: the hotspot follows the pod onto the home network's channel.
                misses += 1
                if misses == 10 && !rejoined {
                    rejoined = true
                    try? await joiner.join(ssid: code.ssid, passphrase: code.passphrase)
                }
                if misses >= 20 { return await serverFallback() }
            }
            await sleep(1)
        }
        fail(.pair, "The pod didn't finish pairing. Check its screen.")
    }

    private func handle(failure s: PodSetupStatus, ssid: String) async {
        switch s.error {
        case "wifi_auth", "wifi_not_found", "no_ip":
            statuses[.pair] = .pending
            statuses[.send] = .pending
            statuses[.wifi] = .active
            detail[.wifi] = s.message.isEmpty ? "That didn't work. Check the network and password." : s.message
            if s.error == "wifi_auth" {
                password = ""
                focusPassword = true
            } else {
                await loadNetworks()
            }
        case "code_rejected" where freshCodeTries < 1:
            freshCodeTries += 1
            detail[.pair] = "Getting a fresh pairing code…"
            await joiner.leave(ssid: code.ssid)
            guard await fetchPairing(step: .pair) else { return }
            try? await joiner.join(ssid: code.ssid, passphrase: code.passphrase)
            await submitWifi()
        default:
            fail(.pair, s.message.isEmpty ? "The pod reached Wi-Fi but not Jarvis." : s.message)
        }
    }

    private func serverFallback() async {
        detail[.pair] = "Waiting for the pod to reach Jarvis…"
        await joiner.leave(ssid: code.ssid)
        for _ in 0..<30 {
            guard !cancelled else { return }
            if await server.podOnline(name: code.podName, since: startedAt) { return await finish(confirmed: true) }
            await sleep(2)
        }
        fail(.pair, "The pod didn't come online. Check its screen.")
    }

    private func finish(confirmed: Bool = false) async {
        statuses[.pair] = .done
        detail[.pair] = "Paired"
        statuses[.done] = .active
        await joiner.leave(ssid: code.ssid)
        if !confirmed { await confirmOnline() } else { complete() }
    }

    private func confirmOnline() async {
        statuses[.done] = .active
        detail[.done] = "Waiting for the pod to come online…"
        // The pod reboots after pairing; give it time to rejoin Wi-Fi and open its bridge.
        for _ in 0..<30 {
            guard !cancelled else { return }
            if await server.podOnline(name: code.podName, since: startedAt) { return complete() }
            await sleep(2)
        }
        fail(.done, "Paired, but Jarvis hasn't seen the pod online yet.")
    }

    private func complete() {
        statuses[.done] = .done
        detail[.done] = "\(code.podName) is paired"
        finished = true
    }

    func retry() async {
        switch failedStep {
        case .connect?: await start()
        case .send?, .pair?:
            if pairing == nil { guard await fetchPairing(step: .send) else { return } }
            try? await joiner.join(ssid: code.ssid, passphrase: code.passphrase)
            await submitWifi()
        case .done?: await confirmOnline()
        default: break
        }
    }

    func cancel() async {
        cancelled = true
        await joiner.leave(ssid: code.ssid)
    }

    // MARK: Helpers

    private func fetchPairing(step: Step = .connect) async -> Bool {
        do {
            pairing = try await server.pairStart(label: code.podName)
            return true
        } catch {
            fail(step, "Couldn't get a pairing code from Jarvis: \(error.localizedDescription)")
            return false
        }
    }

    private func fail(_ step: Step, _ message: String) {
        statuses[step] = .failed(message)
    }

    private func retrying<T>(seconds: Int, _ body: @escaping () async throws -> T) async -> T? {
        for _ in 0..<seconds {
            if cancelled { return nil }
            if let value = try? await body() { return value }
            await sleep(1)
        }
        return nil
    }

    static func setupBody(ssid: String, password: String, server: String, pairing: PodPairing,
                          timeZone: TimeZone = .current, now: Date = Date()) -> Data {
        let body: [String: Any] = [
            "wifi": ["ssid": ssid, "password": password],
            "server": server,
            "code": pairing.code,
            "cf_access": ["client_id": pairing.cfID, "client_secret": pairing.cfSecret],
            "theme": JarvisPodLook.theme,
            "timezone": timeZone.identifier,
            "tz_posix": JarvisPodLook.posixTZ(timeZone, now: now),
            "clock_24h": JarvisPodLook.clock24h,
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}
