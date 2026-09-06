import Foundation

/// Cadence decisions for the Live Activity / fleet coordinator. Pure so they're
/// unit-testable (port of `live_activity/la_poll_policy.dart`).
///
/// The fleet/usage poll is the app's single biggest always-on default drain (two
/// HTTP calls every 5s started at launch even with zero sessions). We keep the
/// fast 5s cadence ONLY when there's a live reason to refresh; otherwise we drop
/// to a 60s discovery cadence and let the server's APNs push-to-update keep a
/// backgrounded activity fresh.
enum LivePollPolicy {
    static let fastInterval: TimeInterval = 5
    static let slowInterval: TimeInterval = 60
    static let usageMinInterval: TimeInterval = 60

    static func pollInterval(voiceActive: Bool, codingVisible: Bool, sessionTotal: Int) -> TimeInterval {
        (voiceActive || codingVisible || sessionTotal > 0) ? fastInterval : slowInterval
    }

    /// `GET /api/coding/usage` returns slow-moving quota — it does not need the
    /// 5s cadence.
    static func shouldFetchUsage(now: Date, lastUsageFetch: Date) -> Bool {
        now.timeIntervalSince(lastUsageFetch) >= usageMinInterval
    }
}
