import Foundation

/// Heuristic: does a tool/skill name look like an outward-facing or destructive
/// action that should be confirmed before the on-device model fires it
/// autonomously? Small local models can mis-route, so we treat anything that
/// sends, deletes, calls, posts, or pays as needing confirmation.
///
/// Matching is on underscore-delimited NAME SEGMENTS (not raw substrings) so
/// innocent names like `text_to_speech` / `type_text` aren't flagged just for
/// containing "text".
///
/// Port of `mobile_client/lib/services/local_action_safety.dart`.
private let riskySegments: Set<String> = [
    "send", "email", "mail", "sms", "call", "dial", "delete", "remove", "erase",
    "wipe", "purchase", "buy", "pay", "transfer", "post", "tweet", "publish",
    "share",
]

func isOutwardOrDestructive(_ name: String) -> Bool {
    name.lowercased()
        .split(whereSeparator: { $0 == "_" || $0.isWhitespace })
        .contains { riskySegments.contains(String($0)) }
}

/// Skills the LOCAL EXECUTOR may fire on this device with no server round-trip
/// and no confirmation. Deliberately a hard-coded ALLOW-list, not a deny-list:
/// a new skill is server-only until someone reviews it and adds it here.
///
/// Every entry must be:
///   • confined to THIS phone (nothing that reaches another device or person),
///   • non-destructive and trivially reversible,
///   • unambiguous enough to drive from a small spoken grammar.
///
/// Deliberately absent: send_sms / make_call / share_text (outward), the
/// contacts + calendar readers (personal data, and the server has better
/// context), run_shortcut / take-anything-arbitrary (arbitrary effects),
/// record_audio, get_location.
let kLocalActionAllowList: Set<String> = [
    "open_app",
    "open_url",
    "flashlight_on",
    "flashlight_off",
    "set_volume",
    "adjust_volume",
    "phone_control",   // iOS volume/brightness only — the executor never emits other verbs
    "vibrate",
    "set_alarm",
    "notify",
    "clipboard_read",
    "clipboard_write",
    "take_photo",
    "play_audio",
]

/// True when `name` may be executed by the on-device local executor.
func isLocallyAllowed(_ name: String) -> Bool {
    kLocalActionAllowList.contains(name) && !isOutwardOrDestructive(name)
}

// MARK: - Openable URL schemes

/// Schemes `open_url` may hand to `UIApplication.open`, on top of the app
/// schemes in `AppSchemeTable`. Anything else is a private control surface, not
/// "a link", and the server (or a mis-routed local model) has no business
/// reaching it: `open_url` and `open_app` are both on `kLocalActionAllowList`,
/// so they fire with no confirmation at all.
let kOpenableWebSchemes: Set<String> = ["http", "https", "mailto", "tel"]

/// Never openable, whatever else says otherwise.
///
/// - `shortcuts` would let `open_url` run an arbitrary Shortcut through
///   `shortcuts://x-callback-url/run-shortcut?name=…`, straight past a
///   `run_shortcut` the user switched off in the Skills tab.
/// - `jarviscopilot` is our own callback scheme: opening it lets a caller
///   forge a Shortcut result (`jarviscopilot://shortcut-result/<rid>`) or any
///   future deep link, including pairing.
let kRefusedOpenSchemes: Set<String> = ["shortcuts", "jarviscopilot"]

/// Everything before the first colon, lowercased. Taken off the raw text rather
/// than `URL.scheme` because `App-Prefs:` (and other schemeless-authority forms)
/// don't survive `URL(string:)` on every OS version.
private func openScheme(_ text: String) -> String {
    guard let colon = text.firstIndex(of: ":") else { return "" }
    return String(text[text.startIndex..<colon]).lowercased()
}

/// Every scheme `AppSchemeTable` can name, minus the refused ones.
private let kKnownAppSchemes: Set<String> =
    Set(AppSchemeTable.knownApps.values.map(openScheme))
        .subtracting(kRefusedOpenSchemes)
        .subtracting([""])

/// True when `open_url` may open this URL: a web/mail/tel link, or one of the
/// app schemes the app-scheme table already knows about.
func isOpenableURL(_ url: URL) -> Bool {
    isOpenableScheme((url.scheme ?? "").lowercased())
}

private func isOpenableScheme(_ scheme: String) -> Bool {
    guard !scheme.isEmpty, !kRefusedOpenSchemes.contains(scheme) else { return false }
    return kOpenableWebSchemes.contains(scheme) || kKnownAppSchemes.contains(scheme)
}

/// True when `open_app` may try this candidate scheme URL.
///
/// Wider than `isOpenableURL` in exactly one way: `AppSchemeTable.resolve` falls
/// back to the app's condensed name (`"wells fargo"` → `"wellsfargo://"`), and
/// that shape — a bare scheme with nothing after the authority — can't carry a
/// payload, so it stays allowed. An *explicit* `scheme_url` with a path or query
/// has to clear the same allowlist `open_url` does.
func isOpenableAppScheme(_ candidate: String) -> Bool {
    let scheme = openScheme(candidate)
    guard !scheme.isEmpty, !kRefusedOpenSchemes.contains(scheme) else { return false }
    if isOpenableScheme(scheme) { return true }
    return candidate.dropFirst(scheme.count) == "://"
}
