import Foundation

/// Map a server device record (from `/api/devices`) to a normalized icon kind
/// for the Live Activity devices strip. Port of `voice/device_icon.dart`.
///
/// The record's authoritative field is `kind` ∈ {browser, desktop, mobile-ios,
/// mobile-android}; we refine it with the free-text `name` + `user_agent` to
/// pick the most recognizable PHYSICAL-device icon — e.g. a browser whose UA
/// says Macintosh shows a laptop, not a generic globe. (The webui's "Chrome ·
/// macOS" label is display-only and never reaches the client, so we must derive
/// from `kind`/`name`/`user_agent`.)
///
/// Returns one of: watch, tablet, phone, laptop, desktop, web.
func deviceIconKind(_ d: [String: Any]) -> String {
    let kind = (d.string("kind") ?? "").lowercased()
    let s = "\(d.string("name") ?? "") \(d.string("user_agent") ?? "")".lowercased()
    func has(_ tokens: [String]) -> Bool { tokens.contains { s.contains($0) } }

    if has(["watch"]) { return "watch" }
    if has(["ipad", "tablet"]) { return "tablet" }
    if kind == "mobile-ios" || kind == "mobile-android" || has(["iphone", "android"]) {
        return "phone"
    }
    if has(["macbook", "laptop"]) { return "laptop" }
    if has(["imac", "mac mini", "mac pro", "mac studio"]) { return "desktop" }
    if has(["macintosh", "mac os", "macos"]) { return "laptop" }
    if has(["windows", "linux", "desktop"]) { return "desktop" }
    if kind == "browser" { return "web" }
    return "desktop"
}
