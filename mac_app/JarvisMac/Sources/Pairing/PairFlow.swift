import Foundation
import Observation

/// The app's link to jc-client as the pair screen needs it: JcLink, or a fake in the tests.
@MainActor
protocol PairLink: AnyObject {
    func request(_ body: [String: Any], reply: (@MainActor ([String: Any]) -> Void)?)
}

extension JcLink: PairLink {}

/// The "Pair with your iPhone" screen's logic, over jc-client's app link (contract:
/// docs/superpowers/plans/2026-11-23-qr-pairing.md): `pair_status` (paired? which server?),
/// `pair_qr_start` (the QR payload and when it expires; a new key and listener each call),
/// `pair_state` broadcasts (waiting / pairing / paired / expired / error) and `pair_manual` (the
/// "Type a code instead" fallback). The code renews itself when it expires while the screen is
/// open (the window calls `tick()` once a second); `close()` stops that. Mirrors the Windows
/// app's PairFlow (windows_app/Jarvis.Core/Pairing/PairFlow.cs).
@MainActor
@Observable
final class PairFlow {
    enum Stage: Equatable { case loading, waiting, pairing, paired, failed }

    static let oldClientError =
        "Jarvis on this Mac is too old to show a pairing code. Update it (jc-client update), then try again."

    /// An "expired" broadcast this soon after a new code is about the code it replaced.
    private static let freshFor: TimeInterval = 5

    private(set) var stage: Stage = .loading
    private(set) var payload: String?
    private(set) var expiresAt: Date?
    private(set) var host = ""
    private(set) var port = 0
    private(set) var error: String?
    /// What `pair_status` said: nil until it answers.
    private(set) var isPaired: Bool?
    /// The server this Mac is (or was last) paired with: the manual form's prefill. Empty when
    /// jc-client knows none; never a made-up LAN address.
    private(set) var server = ""
    private(set) var deviceName = ""
    private(set) var manualBusy = false
    private(set) var manualError: String?
    /// Moved by `tick()`, so the countdown redraws.
    private(set) var now: Date

    @ObservationIgnored private let link: PairLink
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var codeAt = Date.distantPast

    init(link: PairLink = JcLink.shared, clock: @escaping () -> Date = Date.init) {
        self.link = link
        self.clock = clock
        now = clock()
    }

    var secondsLeft: Int {
        guard let expiresAt else { return 0 }
        return max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
    }

    /// "9:42", or "" when the code has no expiry.
    var countdown: String { expiresAt == nil ? "" : Self.format(secondsLeft) }

    static func format(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    /// True only when jc-client answers `pair_status` and says it isn't paired. An older
    /// jc-client or a link that's down never pops the screen on a guess.
    nonisolated static func needsPairing(_ reply: [String: Any]) -> Bool {
        J.b(reply["ok"]) && (reply["paired"] as? Bool) == false
    }

    /// Settings' one line about it.
    nonisolated static func summary(paired: Bool?, server: String) -> String {
        guard let paired else { return "Jarvis isn't running on this Mac" }
        guard paired else { return "Not paired" }
        let s = server.trimmingCharacters(in: .whitespaces)
        if let host = URL(string: s)?.host, !host.isEmpty { return "Paired with \(host)" }
        return s.isEmpty ? "Paired" : "Paired with \(s)"
    }

    func check(_ done: (([String: Any]) -> Void)? = nil) {
        link.request(["type": "pair_status"]) { [weak self] reply in
            guard let self, !self.closed else { return }
            if J.b(reply["ok"]) {
                if let paired = reply["paired"] as? Bool { self.isPaired = paired }
                self.server = J.s(reply["server"]).trimmingCharacters(in: .whitespaces)
                self.deviceName = J.s(reply["device_name"]).trimmingCharacters(in: .whitespaces)
            }
            done?(reply)
        }
    }

    /// The screen opened: who we are (the manual form's server), then the first code.
    func open() {
        stage = .loading
        check { [weak self] _ in self?.newCode() }
    }

    /// A fresh code (the screen opening, the old one expiring, or "Show a new code").
    func newCode() {
        guard !closed, !loading, stage != .paired else { return }
        loading = true
        if stage == .failed || payload == nil {
            stage = .loading
            error = nil
        }
        link.request(["type": "pair_qr_start"]) { [weak self] reply in
            guard let self else { return }
            self.loading = false
            guard !self.closed, self.stage != .paired else { return }
            let payload = J.s(reply["payload"])
            guard J.b(reply["ok"]), !payload.isEmpty else {
                let e = J.s(reply["error"])
                self.stage = .failed
                self.error = e.hasPrefix("unknown request") ? Self.oldClientError : (e.isEmpty ? "jc-client didn't make a code." : e)
                self.payload = nil
                self.expiresAt = nil
                return
            }
            let now = self.clock()
            self.now = now
            self.payload = payload
            self.host = J.s(reply["host"])
            self.port = J.i(reply["port"])
            // Already past (or missing): no countdown and no timer renewal, so a bad reply can't loop.
            let expires = J.d(reply["expires_at"]) ?? 0
            let at = Date(timeIntervalSince1970: expires)
            self.expiresAt = expires > 0 && at > now ? at : nil
            self.codeAt = now
            self.stage = .waiting
            self.error = nil
        }
    }

    /// jc-client's `pair_state` broadcast.
    func handle(_ msg: [String: Any]) {
        guard !closed, J.s(msg["type"]) == "pair_state", stage != .paired else { return }
        switch J.s(msg["state"]) {
        case "waiting":
            if payload != nil, stage == .pairing || stage == .waiting { stage = .waiting }
        case "pairing":
            stage = .pairing
        case "paired":
            if let name = msg["device_name"] as? String, !name.isEmpty { deviceName = name }
            markPaired()
        case "expired":
            if stage == .waiting, clock().timeIntervalSince(codeAt) >= Self.freshFor { newCode() }
        case "error":
            stage = .failed
            let e = J.s(msg["error"])
            error = e.isEmpty ? "Pairing didn't work." : e
        default:
            break
        }
    }

    /// Once a second from the window: the countdown moves, and an expired code renews (only
    /// while it's waiting for the phone: never mid-claim, never over an error he hasn't seen).
    func tick() {
        guard !closed else { return }
        now = clock()
        if stage == .waiting, expiresAt != nil, secondsLeft <= 0 { newCode() }
    }

    /// "Type a code instead": the server's address and the code the iPhone shows (plus the
    /// Cloudflare Access service token when the server sits behind one). False when what he
    /// typed is incomplete (nothing is sent).
    @discardableResult
    func manual(server: String, code: String, cfId: String = "", cfSecret: String = "") -> Bool {
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = server.lowercased()
        manualError = server.isEmpty ? "Type your Jarvis server's address."
            : !(lower.hasPrefix("https://") || lower.hasPrefix("http://")) ? "The address starts with https:// (or http://)."
            : code.isEmpty ? "Type the code your iPhone shows."
            : nil
        guard manualError == nil, !manualBusy, !closed else { return false }
        var body: [String: Any] = ["type": "pair_manual", "server": server, "code": code]
        let id = cfId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = cfSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { body["cf_id"] = id }
        if !secret.isEmpty { body["cf_secret"] = secret }
        manualBusy = true
        link.request(body) { [weak self] reply in
            guard let self else { return }
            self.manualBusy = false
            guard !self.closed else { return }
            guard J.b(reply["ok"]) else {
                let e = J.s(reply["error"])
                self.manualError = e.hasPrefix("unknown request") ? Self.oldClientError : (e.isEmpty ? "Pairing didn't work." : e)
                return
            }
            self.server = server
            self.markPaired()
        }
        return true
    }

    private func markPaired() {
        stage = .paired
        isPaired = true
        error = nil
        manualError = nil
    }

    /// The window closed: no more renewals, late replies ignored.
    func close() { closed = true }
}
