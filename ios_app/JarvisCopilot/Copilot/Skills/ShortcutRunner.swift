import Foundation

/// Result plumbing for `shortcuts://x-callback-url`.
///
/// `run_shortcut` opens the Shortcut with an
/// `x-success=jarviscopilot://shortcut-result/<rid>` callback. When the
/// Shortcut finishes, iOS re-opens this app at that URL with the textual output
/// appended as `result`; whoever handles incoming URLs forwards it here and the
/// waiting `run` call completes.
///
/// TODO(app-wave): the app has to forward incoming URLs into
/// `ShortcutResultBus.shared.deliver(_:)` — one line in the scene's
/// `.onOpenURL { ShortcutResultBus.shared.deliver($0) }`. Until then a
/// `run_shortcut` with `awaitResult` still launches the Shortcut and returns the
/// same "launched but no result in time" note the Flutter client produced on a
/// timeout, so nothing breaks; it just can't report the output.
@MainActor
final class ShortcutResultBus {
    static let shared = ShortcutResultBus()

    /// The scheme registered in Info.plist (`CFBundleURLTypes`).
    static let callbackScheme = "jarviscopilot"

    private var waiters: [String: CheckedContinuation<ShortcutOutcome?, Never>] = [:]

    /// A result that arrived before anyone waited on it — a Shortcut that
    /// finishes in a few hundred ms can call back before `open` even returns.
    ///
    /// Bounded in both directions: nothing prunes this otherwise, and it is fed
    /// by *incoming URLs*, so anything that can open the app can grow it without
    /// limit. An unclaimed result is worthless once its run has timed out.
    private struct Early {
        let outcome: ShortcutOutcome
        let at: Date
    }
    private var early: [String: Early] = [:]
    /// Longer than the longest `run_shortcut` timeout the schema allows (300 s).
    static let earlyTTL: TimeInterval = 310
    static let earlyCap = 32

    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    func arm(_ rid: String) {
        early.removeValue(forKey: rid)
    }

    /// Wait for this run's callback. Nil when nothing arrived in time.
    func wait(_ rid: String, timeoutSeconds: Int) async -> ShortcutOutcome? {
        pruneEarly()
        if let alreadyThere = early.removeValue(forKey: rid) { return alreadyThere.outcome }
        var timeout: Task<Void, Never>?
        defer { timeout?.cancel() }
        return await withCheckedContinuation { continuation in
            // The waiter is installed FIRST. Arming the timeout before the
            // continuation existed meant a timeout that fired in between found
            // no waiter to resume, and the continuation that landed afterwards
            // was never resumed at all — the call hung forever.
            waiters[rid] = continuation
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutSeconds)) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.resume(rid, nil)
            }
        }
    }

    /// Whether a `wait` is currently parked on this run id. Lets a test observe
    /// the waiter instead of sleeping for one.
    func isWaiting(_ rid: String) -> Bool { waiters[rid] != nil }

    func cancel(_ rid: String) {
        resume(rid, nil)
        early.removeValue(forKey: rid)
    }

    /// Feed an incoming URL in. Returns true when it was one of ours, so the
    /// app's URL handler can fall through to other schemes.
    @discardableResult
    func deliver(_ url: URL) -> Bool {
        guard let parsed = Self.parse(url) else { return false }
        if waiters[parsed.rid] != nil {
            resume(parsed.rid, parsed.outcome)
        } else {
            early[parsed.rid] = Early(outcome: parsed.outcome, at: clock())
            pruneEarly()
        }
        return true
    }

    /// Drop expired entries, then the oldest ones until the cap holds.
    private func pruneEarly() {
        let cutoff = clock().addingTimeInterval(-Self.earlyTTL)
        early = early.filter { $0.value.at > cutoff }
        guard early.count > Self.earlyCap else { return }
        for (rid, _) in early.sorted(by: { $0.value.at < $1.value.at })
            .prefix(early.count - Self.earlyCap) {
            early.removeValue(forKey: rid)
        }
    }

    /// How many unclaimed early results are held. Test-facing.
    var earlyCount: Int { early.count }

    private func resume(_ rid: String, _ outcome: ShortcutOutcome?) {
        guard let continuation = waiters.removeValue(forKey: rid) else { return }
        continuation.resume(returning: outcome)
    }

    /// Pure URL → (rid, outcome). `rid` rides in the PATH rather than a query so
    /// Shortcuts can cleanly append its own `?result=…` / `?errorMessage=…`
    /// without producing a double query string.
    static func parse(_ url: URL) -> (rid: String, outcome: ShortcutOutcome)? {
        guard url.scheme?.lowercased() == callbackScheme else { return nil }
        let host = url.host?.lowercased() ?? ""
        guard host == "shortcut-result" || host == "shortcut-error" else { return nil }
        let rid = url.pathComponents.filter { $0 != "/" }.first ?? ""
        guard !rid.isEmpty else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if host == "shortcut-result" {
            return (rid, ShortcutOutcome(ran: true, launched: true, result: value("result") ?? ""))
        }
        let message = value("errorMessage") ?? value("error") ?? "shortcut failed"
        return (rid, ShortcutOutcome(ran: false, launched: true, error: message))
    }
}

/// Runs a named Shortcut via `shortcuts://x-callback-url`.
///
/// `awaitResult: true`  → include x-success/x-error, wait up to `timeoutSeconds`
///                        and return the Shortcut's textual output.
/// `awaitResult: false` → "launch" mode: omit the callbacks so iOS leaves the
///                        user in whatever app the Shortcut opens.
///
/// Port of the `_runShortcut` helper in `mobile_client/lib/skills/ios.dart`.
final class DefaultShortcutRunner: ShortcutRunning {
    private let urls: any URLOpening

    init(urls: any URLOpening = DefaultURLOpener()) { self.urls = urls }

    func run(name: String, input: String, timeoutSeconds: Int,
             awaitResult: Bool) async -> ShortcutOutcome {
        let rid = "sc\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        var params: [(String, String)] = [("name", name)]
        if !input.isEmpty {
            params.append(("input", "text"))
            params.append(("text", input))
        }
        if awaitResult {
            let scheme = ShortcutResultBus.callbackScheme
            params.append(("x-success", "\(scheme)://shortcut-result/\(rid)"))
            params.append(("x-error", "\(scheme)://shortcut-error/\(rid)"))
            params.append(("x-cancel", "\(scheme)://shortcut-error/\(rid)"))
        }
        // Built with %20 for spaces (NOT `+`): a Shortcut name like
        // "JC Brightness" must not arrive as "JC+Brightness".
        let query = PhoneCommand.encodeQueryWithPercent20(params)
        guard let url = URL(string: "shortcuts://x-callback-url/run-shortcut?\(query)") else {
            return ShortcutOutcome(ran: false, error: "could not build the Shortcuts URL")
        }

        if awaitResult { await ShortcutResultBus.shared.arm(rid) }
        let launched = await urls.open(url)
        if !awaitResult { return ShortcutOutcome(ran: launched, launched: launched) }
        guard launched else {
            await ShortcutResultBus.shared.cancel(rid)
            return ShortcutOutcome(ran: false,
                                   error: "Could not open Shortcuts (is it installed?)")
        }
        if let outcome = await ShortcutResultBus.shared.wait(rid, timeoutSeconds: timeoutSeconds) {
            return outcome
        }
        return ShortcutOutcome(
            ran: true, launched: true,
            note: "Launched but no result within \(timeoutSeconds)s — the Shortcut may "
                + "still be running, awaiting input, or produces no output.")
    }

    /// iOS exposes no API for enumerating a user's Shortcuts (the Flutter
    /// bridge returned an empty list for the same reason), so this is nil and
    /// the skill says so honestly rather than implying an empty library.
    func installedNames() async -> [String]? { nil }

    func openEditor(importURL: String, suggestedName: String) async -> Bool {
        let url: URL?
        if importURL.isEmpty {
            url = URL(string: "shortcuts://create-shortcut")
        } else {
            var params: [(String, String)] = [("url", importURL)]
            if !suggestedName.isEmpty { params.append(("name", suggestedName)) }
            url = URL(string: "shortcuts://x-callback-url/import-shortcut?"
                      + PhoneCommand.encodeQueryWithPercent20(params))
        }
        guard let url else { return false }
        return await urls.open(url)
    }
}
