import AppKit

/// Tells jc-client the Mac is about to sleep or just woke. On sleep it flushes
/// the live transcript copies to the server and says what was running, so the
/// phone can offer "Continue on server"; on wake it holds prompts in sessions
/// that may have moved until the server says which did.
@MainActor
final class PowerRelay {
    static let shared = PowerRelay()
    private var tokens: [NSObjectProtocol] = []

    nonisolated static func message(_ event: String) -> [String: Any] {
        ["type": "power", "event": event]
    }

    func start(link: JcLink = .shared) {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil,
                                         queue: .main) { _ in
            // Wait (briefly) for jc-client to flush and tell the server before
            // the Mac actually sleeps; never longer than a few seconds.
            _ = link.requestAndWait(PowerRelay.message("will_sleep"), timeout: 4)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                         queue: .main) { _ in
            link.request(PowerRelay.message("did_wake"))
        })
    }
}
