import Foundation

/// Human text for the machine strings the devices endpoint hands us.
///
/// The server speaks in identifiers — `open_url`, `clipboard_read`,
/// `mobile-ios` — and the first cut of this screen printed them straight onto
/// thirty coloured chips. Everything here turns one of those into the sentence a
/// person would say, so the view layer never has to.
///
/// All of it is pure and lives apart from the views so the mapping can be tested
/// without rendering anything.
enum DevicesSkillText {

    /// Words whose casing must survive sentence-casing. Anything not listed is
    /// treated as an ordinary lowercase word.
    private static let spellings: [String: String] = [
        "url": "URL", "urls": "URLs", "uri": "URI",
        "sms": "SMS", "mms": "MMS", "tts": "TTS",
        "id": "ID", "ios": "iOS", "os": "OS", "ui": "UI",
        "api": "API", "ai": "AI", "gps": "GPS", "ip": "IP", "qr": "QR",
        "healthkit": "HealthKit", "wifi": "Wi-Fi", "http": "HTTP",
        "https": "HTTPS", "json": "JSON", "pdf": "PDF", "ocr": "OCR",
    ]

    /// The catalogue's own title when it has one, otherwise a title derived from
    /// the identifier.
    static func title(for skill: DeviceSkill) -> String {
        let explicit = skill.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return explicit.isEmpty ? title(forIdentifier: skill.name) : explicit
    }

    /// `open_url` → "Open URL", `read_healthkit` → "Read HealthKit".
    ///
    /// Sentence case, not Title Case: thirty Title Cased phrases in a column read
    /// like a menu of proper nouns, which is exactly the shouty look this screen
    /// is trying to lose. `SkillArgs.titleCase` is left for the places that do
    /// want every word capitalised.
    static func title(forIdentifier identifier: String) -> String {
        let words = identifier
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !words.isEmpty else { return identifier }

        let rendered = words.enumerated().map { index, word -> String in
            if let fixed = spellings[word.lowercased()] { return fixed }
            // A word that already carries capitals came from a human (the
            // catalogue's own spelling) — leave it alone.
            guard word == word.lowercased() else { return word }
            return index == 0 ? SkillArgs.titleCase(word) : word
        }
        return rendered.joined(separator: " ")
    }

    // MARK: Categories

    /// Category rules, first match wins; each key is matched as a substring of one
    /// of the identifier's underscore-separated words, so `read_healthkit` lands
    /// under Health via "health".
    ///
    /// Device skills carry no category from the server (`all_device_skills` just
    /// forwards what the device registered: name, description, schema), and a flat
    /// alphabetical run of thirty rows is unreadable. This is the smallest thing
    /// that produces meaningful headings; an unmatched skill falls to "Other"
    /// rather than being hidden.
    private static let rules: [(keys: [String], title: String)] = [
        (["clipboard", "paste"], "Clipboard"),
        (["photo", "camera", "scan"], "Camera & photos"),
        (["audio", "sound", "speech", "speak", "voice", "tts", "volume", "music",
          "record", "play"], "Audio"),
        (["sms", "message", "call", "dial", "contact", "mail", "email"], "Calls & messages"),
        (["calendar", "event", "alarm", "reminder", "clock", "timer"], "Calendar & reminders"),
        (["location", "map", "geo", "gps", "directions"], "Location"),
        (["health", "workout", "steps", "sleep"], "Health"),
        (["shortcut", "automation", "workflow"], "Shortcuts"),
        (["notify", "notification", "alert", "banner", "badge"], "Notifications"),
        (["url", "link", "browser", "web", "app", "open", "share"], "Apps & sharing"),
        (["battery", "device", "phone", "system", "flashlight", "torch", "vibrate",
          "brightness", "screen", "setting", "info", "capabilit", "power",
          "network", "wifi"], "Device"),
        (["file", "note", "todo", "memory", "data", "read", "write", "search"],
         "Files & data"),
    ]

    /// Where an unmatched skill goes. Always sorted last.
    static let otherCategory = "Other"

    /// The order categories appear in — rule order, then "Other".
    static var categoryOrder: [String] { rules.map(\.title) + [otherCategory] }

    static func category(for skill: DeviceSkill) -> String {
        category(forIdentifier: skill.name)
    }

    static func category(forIdentifier identifier: String) -> String {
        let words = identifier.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard !words.isEmpty else { return otherCategory }
        for rule in rules where words.contains(where: { word in
            rule.keys.contains(where: word.contains)
        }) {
            return rule.title
        }
        return otherCategory
    }

    /// The granted skills as titled groups, categories in `categoryOrder` and rows
    /// alphabetical by the name the user actually sees.
    static func groups(_ skills: [DeviceSkill]) -> [DeviceSkillGroup] {
        guard !skills.isEmpty else { return [] }
        var buckets: [String: [DeviceSkill]] = [:]
        for skill in skills {
            buckets[category(for: skill), default: []].append(skill)
        }
        return categoryOrder.compactMap { name in
            guard let rows = buckets[name] else { return nil }
            // Case-insensitively: a raw `<` puts every acronym ("Open URL") above
            // the ordinary words it belongs among.
            return DeviceSkillGroup(
                title: name,
                skills: rows.sorted { title(for: $0).lowercased() < title(for: $1).lowercased() })
        }
    }

    /// "31 skills granted" — the disclosure's collapsed line.
    static func grantedSummary(_ count: Int) -> String {
        switch count {
        case 0:  return "No skills granted"
        case 1:  return "1 skill granted"
        default: return "\(count) skills granted"
        }
    }
}

/// One titled run of a device's granted skills.
struct DeviceSkillGroup: Identifiable, Equatable, Sendable {
    var title: String
    var skills: [DeviceSkill]

    var id: String { title }
}

/// What kind of thing a device record describes, in words rather than in the
/// record's `platform` slug.
enum DevicesKind {

    /// "iPhone" / "iPad" / "Mac" / "Browser" — the leading term of a device's meta
    /// line. Built on `deviceIconKind` so the word and the glyph can never
    /// disagree, then refined by the platform slug (an Android phone must not be
    /// called an iPhone just because it draws with the same symbol).
    static func label(for device: Device) -> String {
        let platform = device.platform.lowercased()
        switch deviceIconKind(["kind": device.platform, "name": device.label]) {
        case "watch":   return "Apple Watch"
        case "tablet":  return platform.contains("android") ? "Tablet" : "iPad"
        case "phone":
            if platform.contains("android") || device.label.lowercased().contains("android") {
                return "Android phone"
            }
            return "iPhone"
        case "laptop":  return "Mac"
        case "web":     return "Browser"
        default:        return "Computer"
        }
    }

    /// "iPhone · Online · 11m ago" — kind, reachability, freshness, in one muted
    /// line. The platform slug is deliberately NOT here; it reads as noise beside
    /// the word it was translated into, and lives in the expanded detail instead.
    static func metaLine(for device: Device, now: Date = Date()) -> String {
        [label(for: device),
         device.online ? "Online" : "Offline",
         device.lastSeenLabel(now: now)]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The record's own fields, for the expanded row: the slug the server knows
    /// this device by and when it was paired.
    static func detailLine(for device: Device) -> String {
        var parts: [String] = []
        if !device.platform.isEmpty { parts.append(device.platform) }
        if let paired = RelativeTime.parse(device.createdAt) {
            parts.append("paired \(RelativeTime.isoDate(paired))")
        }
        return parts.joined(separator: " · ")
    }
}

/// Which record in `/api/devices` is the phone the app is running on.
///
/// The server never tells the client its own device id — the bridge's `hello`
/// carries one but `BridgeClient` doesn't keep it — so this recognises the record
/// by the name the app pairs under, falling back to "the only iOS record there
/// is". Two unnamed iOS phones and it gives up rather than tag the wrong one.
enum DevicesLocal {
    /// Mirrors `BridgeClient.deviceLabel()`, which is private and must not grow a
    /// dependency on this screen.
    static let pairedLabel = "JarvisCopilot (iPhone)"
    /// The platform the server stamps on us once `announcePlatform()` lands.
    static let platform = "mobile-ios"

    static func thisDeviceID(in devices: [Device],
                            label: String = Self.pairedLabel,
                            platform: String = Self.platform) -> String? {
        let wanted = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !wanted.isEmpty,
           let exact = devices.first(where: {
               $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
           }) {
            return exact.id
        }
        let sameKind = devices.filter { $0.platform.lowercased() == platform.lowercased() }
        return sameKind.count == 1 ? sameKind[0].id : nil
    }
}
