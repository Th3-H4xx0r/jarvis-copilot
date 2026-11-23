import Foundation
import Observation

// MARK: - The computer's /pair listener

enum ComputerPairSendError: Error, Equatable {
    /// No answer: another network, a firewall, or iOS's local-network prompt still up.
    case unreachable(String)
    /// It answered and said no — `message` is its `error` (bad key, used or expired, claim failed).
    case rejected(status: Int, message: String)
}

protocol ComputerPairSending: Sendable {
    /// POSTs the sealed body; returns the name the computer paired as ("" when it didn't say).
    func send(_ body: Data, to url: URL) async throws -> String
}

/// `POST http://host:port/pair` on the home network (ATS allows it: `NSAllowsLocalNetworking`).
struct ComputerPairHTTP: ComputerPairSending {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    func send(_ body: Data, to url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw ComputerPairSendError.unreachable(error.localizedDescription)
        }
        return try Self.reply(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// `{"ok":true,"device_name":…}` → the name; anything else → `.rejected` with its `error`.
    static func reply(data: Data, status: Int) throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), object["ok"] as? Bool == true else {
            let error = jcTrim(object["error"] as? String ?? "")
            throw ComputerPairSendError.rejected(status: status, message: error.isEmpty ? "HTTP \(status)" : error)
        }
        return jcTrim(object["device_name"] as? String ?? "")
    }
}

// MARK: - The flow

/// Pairs a computer from its QR: Face ID → a pairing code from the server (labelled with the
/// computer's name) → the code, the server and its Cloudflare token sealed with the QR's key →
/// `POST /pair` on the computer. When the computer can't be reached or turns it down, the
/// code is shown to type on it instead. Everything external is injected so tests drive it.
@Observable
@MainActor
final class ComputerPairFlow {
    enum Phase: Equatable {
        /// The sheet asks "Pair <name> (<OS>)?".
        case confirm
        /// One step in flight; the text says which.
        case working(String)
        /// Done — the name the computer paired as.
        case paired(String)
        /// The hand-off didn't land; type `code` on the computer. `error` is the computer's own
        /// refusal, nil when it couldn't be reached at all.
        case fallback(code: String, error: String?)
        /// No code to hand over (the server failed).
        case failed(String)
    }

    let payload: ComputerPairPayload
    private(set) var phase: Phase = .confirm
    /// Why the last tap stopped at the confirm step (Face ID said no).
    private(set) var notice: String?

    private struct Issued {
        let server: String
        let code: String
        let cfID: String
        let cfSecret: String
    }

    private let api: DevicesAPI
    private let sender: ComputerPairSending
    private let confirmOwner: @MainActor (String) async -> Bool
    private let now: () -> Date
    /// The code pair/start gave, kept so "Try again" re-sends it without a second code.
    private var issued: Issued?

    init(payload: ComputerPairPayload,
         api: DevicesAPI = DevicesAPI(),
         sender: ComputerPairSending = ComputerPairHTTP(),
         confirmOwner: @escaping @MainActor (String) async -> Bool = { await OwnerCheck.confirm(reason: $0) },
         now: @escaping () -> Date = { Date() }) {
        self.payload = payload
        self.api = api
        self.sender = sender
        self.confirmOwner = confirmOwner
        self.now = now
    }

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    /// The fallback sentence up to the code, which the sheet then shows large.
    var fallbackLead: String? {
        guard case .fallback(_, let error) = phase else { return nil }
        if let error { return "\(payload.name) turned it down (\(error)) \u{2014} type this code on it:" }
        return "Your phone can't reach the computer \u{2014} type this code on it:"
    }

    var fallbackMessage: String? {
        guard case .fallback(let code, _) = phase, let lead = fallbackLead else { return nil }
        return "\(lead) \(code)"
    }

    /// Only an unreachable computer is worth another send — the first one often loses to iOS's
    /// local-network prompt. One that refused has closed its listener or holds another key.
    var canRetrySend: Bool {
        if case .fallback(_, nil) = phase { return issued != nil }
        return false
    }

    func pair() async {
        guard !isWorking else { return }
        notice = nil
        phase = .working("Checking it's you\u{2026}")
        // Pairing hands a computer access to his Jarvis: Face ID before a code exists.
        guard await confirmOwner("Pair \(payload.name) with your Jarvis") else {
            notice = "Face ID didn't confirm it's you."
            phase = .confirm
            return
        }
        guard let server = serverURL else {
            phase = .failed("This phone isn't paired with a Jarvis server.")
            return
        }
        phase = .working("Getting a pairing code\u{2026}")
        let reply: JSONObject
        do {
            reply = try await api.startPair(ttl: 600, label: payload.name)
        } catch {
            phase = .failed("Couldn't get a pairing code: \(apiErrorMessage(error))")
            return
        }
        let code = jcTrim(reply["code"] as? String ?? "")
        guard !code.isEmpty else {
            phase = .failed("The server didn't return a pairing code.")
            return
        }
        let cf = reply["cf_access"] as? [String: Any]
        issued = Issued(server: server, code: code,
                        cfID: cf?["client_id"] as? String ?? "",
                        cfSecret: cf?["client_secret"] as? String ?? "")
        await send()
    }

    /// Re-seals the same code under a fresh nonce and timestamp and sends it again.
    func retrySend() async {
        guard canRetrySend else { return }
        await send()
    }

    private func send() async {
        guard let issued else { return }
        phase = .working("Sending it to \(payload.name)\u{2026}")
        let plaintext = ComputerPairSeal.plaintext(server: issued.server, code: issued.code,
                                                   cfID: issued.cfID, cfSecret: issued.cfSecret,
                                                   ts: Int(now().timeIntervalSince1970))
        do {
            // The key is checked to be 32 bytes at parse time, so sealing can't fail in practice.
            let body = try ComputerPairSeal.body(sealing: plaintext, key: payload.key)
            let name = try await sender.send(body, to: payload.pairURL)
            phase = .paired(name.isEmpty ? payload.name : name)
        } catch ComputerPairSendError.rejected(_, let message) {
            phase = .fallback(code: issued.code, error: message)
        } catch {
            phase = .fallback(code: issued.code, error: nil)
        }
    }

    /// The app's own server, as the phone's API client knows it (`https://host[:port]`).
    private var serverURL: String? {
        guard var text = api.api.credentials.baseURL?.absoluteString, !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}
