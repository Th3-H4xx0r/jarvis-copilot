import Foundation

/// How the bridge paces reconnects and when its outage began.
///
/// A socket counts as recovered only once it has stayed up `stableAfter` past its hello. On
/// Oct 21 the phone's socket was accepted and closed within ~100 ms, 276 times in 12 minutes:
/// each hello reset the backoff to 2 s and cleared the outage, so the loop never slowed and
/// the keepalive never let go, and every round re-sent the ~95 KB skill catalogue. A drop that
/// soon after its hello (a flap) now keeps the backoff growing and the outage its first start.
struct BridgeReconnect: Equatable {
    static let stableAfter: TimeInterval = 30
    static let maxAttempt = 6   // 2^6 = 64 s between tries at most

    private(set) var attempt = 0
    /// When the current run of failed or flapping connections began; nil while connected.
    private(set) var outageStartedAt: Date?
    private var helloAt: Date?
    private var outageBeforeHello: Date?

    /// The server said hello: online for now, though not yet proven.
    mutating func hello(at now: Date) {
        helloAt = now
        outageBeforeHello = outageStartedAt
        outageStartedAt = nil
    }

    /// The socket dropped. Returns how long to wait before the next try.
    mutating func drop(at now: Date) -> TimeInterval {
        if let helloAt {
            if now.timeIntervalSince(helloAt) >= Self.stableAfter {
                attempt = 0                          // a real recovery: start afresh
            } else {
                outageStartedAt = outageBeforeHello  // a flap: the outage never ended
            }
        }
        helloAt = nil
        outageBeforeHello = nil
        attempt = min(attempt + 1, Self.maxAttempt)
        if outageStartedAt == nil { outageStartedAt = now }
        return pow(2, Double(attempt))
    }

    /// The socket has been down (or flapping) for at least `grace`.
    func inOutage(at now: Date, grace: TimeInterval) -> Bool {
        guard let outageStartedAt else { return false }
        return now.timeIntervalSince(outageStartedAt) >= grace
    }

    /// What a drop looked like, for the energy ledger: `close.<code>` when the socket was closed
    /// with a code (1009 = a message over the receive limit), else the error's domain and code
    /// (`NSURL.-1005`, `NSPOSIX.57`).
    static func cause(of error: Error, closeCode: Int) -> String {
        if closeCode != 0 { return "close.\(closeCode)" }
        let ns = error as NSError
        let domain = ns.domain.replacingOccurrences(of: "ErrorDomain", with: "")
            .replacingOccurrences(of: "Domain", with: "")
        return "\(domain).\(ns.code)"
    }
}
