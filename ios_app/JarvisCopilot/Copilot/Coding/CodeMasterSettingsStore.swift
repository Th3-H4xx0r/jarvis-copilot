import Foundation
import Observation

/// Global "Code Master settings" — which coding events notify you on which
/// channels, whether the account-usage rings show, and whether tool-permission
/// prompts relay to the phone for remote approval.
///
/// Port of the logic in `pages/code_master_settings_page.dart` (the view comes
/// later). Backed by `GET/POST /api/coding/settings`:
/// `{events: {finished|needs_input|error: {telegram,mobile,toast,photon}},
/// usage_display, remote_approvals}`.
///
/// Loading MERGES over the defaults so a server that omits a key doesn't silently
/// flip a switch off, and saving reflects the server's canonical reply back into
/// the UI.
@Observable @MainActor
final class CodeMasterSettingsStore {

    /// (key, label) pairs in WebUI order.
    static let events: [(key: String, label: String)] = [
        ("finished", "Finished"),
        ("needs_input", "Needs input"),
        ("error", "Error"),
    ]

    /// (key, label, SF Symbol) — the symbols mirror the Flutter icons.
    static let channels: [(key: String, label: String, symbol: String)] = [
        ("telegram", "Telegram", "paperplane.fill"),
        ("mobile", "Mobile push", "iphone"),
        ("toast", "WebUI toast", "bell.badge"),
        ("photon", "iMessage", "message"),
    ]

    /// Backend per-channel defaults for an event (overlaid by whatever GET returns).
    static let channelDefaults: [String: Bool] = [
        "telegram": false,
        "mobile": true,
        "toast": true,
        "photon": false,
    ]

    private let api: CodingSessionsAPI

    init(api: CodingSessionsAPI = CodingSessionsAPI()) {
        self.api = api
        events = Self.defaultMatrix()
    }

    /// `events[eventKey][channelKey]` — the editable matrix.
    var events: [String: [String: Bool]]
    /// Default on.
    var usageDisplay = true
    /// Default off.
    var remoteApprovals = false

    var loading = true
    var saving = false
    var error: String?
    /// Set on a successful save so the view can show its confirmation.
    var savedAt: Date?

    static func defaultMatrix() -> [String: [String: Bool]] {
        var out: [String: [String: Bool]] = [:]
        for e in events {
            var row: [String: Bool] = [:]
            for c in channels { row[c.key] = channelDefaults[c.key] ?? false }
            out[e.key] = row
        }
        return out
    }

    func value(event: String, channel: String) -> Bool {
        events[event]?[channel] ?? Self.channelDefaults[channel] ?? false
    }

    func set(event: String, channel: String, _ value: Bool) {
        events[event, default: [:]][channel] = value
    }

    func toggle(event: String, channel: String) {
        set(event: event, channel: channel, !value(event: event, channel: channel))
    }

    func load() async {
        loading = true
        error = nil
        do {
            let settings = try await api.codeMasterSettings()
            apply(settings, fillDefaults: true)
        } catch {
            self.error = apiErrorMessage(error)
        }
        loading = false
    }

    /// The full payload — the endpoint replaces the whole document, so every
    /// event×channel is written even when it's at its default.
    func payload() -> [String: Any] {
        var matrix: [String: Any] = [:]
        for e in Self.events {
            var row: [String: Any] = [:]
            for c in Self.channels { row[c.key] = events[e.key]?[c.key] ?? false }
            matrix[e.key] = row
        }
        return ["events": matrix, "usage_display": usageDisplay, "remote_approvals": remoteApprovals]
    }

    @discardableResult
    func save() async -> Bool {
        saving = true
        error = nil
        defer { saving = false }
        do {
            let saved = try await api.saveCodeMasterSettings(payload())
            // Reflect the server's canonical settings back into the UI, but only
            // for the keys it actually returned.
            apply(saved, fillDefaults: false)
            savedAt = Date()
            return true
        } catch {
            self.error = apiErrorMessage(error)
            return false
        }
    }

    /// `fillDefaults` is the difference between a load (start from defaults and
    /// overlay) and a save reply (only adopt what came back).
    private func apply(_ settings: [String: Any], fillDefaults: Bool) {
        let ev = CodingJSON.dict(settings["events"]) ?? [:]
        for e in Self.events {
            let row = CodingJSON.dict(ev[e.key]) ?? [:]
            for c in Self.channels {
                // Only a REAL bool counts — the matrix must not be flipped by a
                // stray string or number.
                if Self.isBool(row[c.key]) {
                    set(event: e.key, channel: c.key, CodingJSON.bool(row[c.key]))
                } else if fillDefaults {
                    set(event: e.key, channel: c.key, Self.channelDefaults[c.key] ?? false)
                }
            }
        }
        if fillDefaults || settings.keys.contains("usage_display") {
            // `s['usage_display'] != false`: on unless the server explicitly says false.
            usageDisplay = !Self.isFalse(settings["usage_display"])
        }
        if fillDefaults || settings.keys.contains("remote_approvals") {
            remoteApprovals = Self.isTrue(settings["remote_approvals"])
        }
    }

    /// Dart's `x == true` / `x == false`: only a REAL bool matches, so a stray
    /// string or number can never flip a switch.
    private static func isBool(_ v: Any?) -> Bool {
        guard let v, !(v is NSNull) else { return false }
        return CodingJSON.isBoolean(v)
    }
    private static func isTrue(_ v: Any?) -> Bool { isBool(v) && CodingJSON.bool(v) }
    private static func isFalse(_ v: Any?) -> Bool { isBool(v) && !CodingJSON.bool(v) }
}
