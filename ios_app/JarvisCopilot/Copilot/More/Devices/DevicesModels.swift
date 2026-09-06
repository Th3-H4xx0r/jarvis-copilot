import Foundation

/// One skill a device advertises (the per-device ACL row).
struct DeviceSkill: Identifiable, Equatable, Sendable {
    var name: String
    var title: String
    var description: String
    var allowed: Bool

    var id: String { name }
    var displayName: String { title.isEmpty ? name : title }

    init(json: JSONObject) {
        name = MoreJSON.text(json["name"] ?? json["skill"] ?? json["id"])
        title = MoreJSON.text(json["title"] ?? json["label"])
        description = MoreJSON.text(json["description"])
        // The ACL list marks explicit denials; absent means allowed.
        allowed = !MoreJSON.isFalse(json["allowed"])
    }
}

/// One paired device from `GET /api/devices`.
struct Device: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var platform: String
    var online: Bool
    var lastSeen: String
    var createdAt: String
    var skills: [DeviceSkill]

    init(json: JSONObject) {
        id = MoreJSON.text(json["id"] ?? json["device_id"])
        label = MoreJSON.text(json["label"] ?? json["name"])
        platform = MoreJSON.text(json["platform"] ?? json["kind"])
        online = MoreJSON.isTrue(json["online"])
        lastSeen = MoreJSON.text(json["last_seen"] ?? json["last_seen_at"])
        createdAt = MoreJSON.text(json["created_at"])
        skills = MoreJSON.mapList(json["skills"]).map(DeviceSkill.init(json:))
    }

    var displayName: String { label.isEmpty ? (id.isEmpty ? "(unknown device)" : id) : label }
    var statusLabel: String { online ? "ONLINE" : "OFFLINE" }
    var statusTone: MoreTone { online ? .success : .muted }

    func lastSeenLabel(now: Date = Date()) -> String {
        RelativeTime.format(lastSeen, now: now)
    }
}
