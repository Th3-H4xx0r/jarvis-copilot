import Foundation
import NetworkExtension

// MARK: - The pod's setup API (http://192.168.4.1 inside its WPA2 hotspot)

struct PodInfo: Equatable, Sendable {
    var battery: Int
    var firmware: String
    var touch: Bool
}

struct PodNetwork: Identifiable, Equatable, Sendable {
    var ssid: String
    var rssi: Int
    var secure: Bool
    var id: String { ssid }
}

struct PodSetupStatus: Equatable, Sendable {
    var state: String   // idle | joining_wifi | claiming | paired | failed
    var error: String   // wifi_auth | wifi_not_found | no_ip | code_rejected | server_unreachable
    var message: String
}

enum PodSetupError: Error, Equatable {
    case unreachable
    case rejected(String)
}

protocol PodSetupTalking: Sendable {
    func info() async throws -> PodInfo
    func scan() async throws -> [PodNetwork]
    func setup(_ body: Data) async throws
    func status() async throws -> PodSetupStatus
}

struct PodSetupHTTP: PodSetupTalking {
    var base = URL(string: "http://192.168.4.1")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private func call(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 5) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: req)
        } catch {
            throw PodSetupError.unreachable
        }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw PodSetupError.rejected(obj["error"] as? String ?? "The pod said no (\(code))")
        }
        return obj
    }

    func info() async throws -> PodInfo {
        let o = try await call("GET", "jarvis/info")
        return PodInfo(battery: o["battery"] as? Int ?? 0, firmware: o["fw"] as? String ?? "", touch: o["touch"] as? Bool ?? false)
    }

    func scan() async throws -> [PodNetwork] {
        let o = try await call("GET", "jarvis/wifi/scan", timeout: 15)
        return (o["networks"] as? [[String: Any]] ?? []).compactMap { n in
            guard let ssid = n["ssid"] as? String, !ssid.isEmpty else { return nil }
            return PodNetwork(ssid: ssid, rssi: n["rssi"] as? Int ?? -100, secure: n["secure"] as? Bool ?? true)
        }
    }

    func setup(_ body: Data) async throws {
        _ = try await call("POST", "jarvis/setup", body: body)
    }

    func status() async throws -> PodSetupStatus {
        let o = try await call("GET", "jarvis/setup/status")
        return PodSetupStatus(state: o["state"] as? String ?? "", error: o["error"] as? String ?? "",
                               message: o["message"] as? String ?? "")
    }
}

// MARK: - Joining the pod's hotspot

enum HotspotJoinError: Error, Equatable {
    case declined
    case failed(String)
}

protocol HotspotJoining: Sendable {
    func join(ssid: String, passphrase: String) async throws
    func leave(ssid: String) async
    func currentSSID() async -> String?
}

struct SystemHotspotJoiner: HotspotJoining {
    func join(ssid: String, passphrase: String) async throws {
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        config.joinOnce = true
        do {
            try await NEHotspotConfigurationManager.shared.apply(config)
        } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain {
            switch NEHotspotConfigurationError(rawValue: error.code) {
            case .alreadyAssociated: return
            case .userDenied: throw HotspotJoinError.declined
            default: throw HotspotJoinError.failed(error.localizedDescription)
            }
        }
    }

    func leave(ssid: String) async {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }

    func currentSSID() async -> String? {
        await NEHotspotNetwork.fetchCurrent()?.ssid
    }
}
