import Foundation

/// The Mac's stand-in for the phone's `LiveCaptureBeacon` (which drives a Live
/// Activity — ActivityKit does not exist on macOS). It keeps the same facts, so
/// `LiveStore` reports capture exactly as it does on the phone and the menubar
/// can show that the Mac is listening.
@MainActor
@Observable
final class LiveCaptureBeacon {

    static let shared = LiveCaptureBeacon()

    private(set) var capturing = false
    private(set) var startedAt: Date?
    private(set) var interrupted = false

    private init() {}

    func began(at: Date = Date(), kept: String, detail: String) {
        capturing = true
        interrupted = false
        startedAt = at
    }

    func update(interrupted paused: Bool, elapsed: TimeInterval,
                kept: String, detail: String) {
        guard capturing else { return }
        interrupted = paused
    }

    func ended() {
        capturing = false
        interrupted = false
        startedAt = nil
    }

    func reapOrphans() {}

    func observeAppLifecycle() {}
}
