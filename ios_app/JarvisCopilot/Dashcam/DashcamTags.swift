import Foundation

/// A label he puts on clips by hand (Accident, Near miss…), to find them again. The server keeps the list
/// and each clip's tags; presets can't be deleted.
struct DashcamTag: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let preset: Bool

    init(id: String, name: String, preset: Bool) {
        self.id = id
        self.name = name
        self.preset = preset
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty, let name = json["name"] as? String else { return nil }
        self.init(id: id, name: name, preset: json["preset"] as? Bool ?? false)
    }

    /// The server's presets, shown until its list arrives (and offline).
    static let presets = [DashcamTag(id: "accident", name: "Accident", preset: true),
                          DashcamTag(id: "near_miss", name: "Near miss", preset: true),
                          DashcamTag(id: "bad_driver", name: "Bad driver", preset: true),
                          DashcamTag(id: "scenic", name: "Scenic", preset: true)]
}

/// What a tap does to a clip's tags.
enum DashcamTagging {
    /// On if it was off (appended; the server puts it in the list's order), off if it was on.
    static func toggled(_ tags: [String], _ tag: String) -> [String] {
        tags.contains(tag) ? tags.filter { $0 != tag } : tags + [tag]
    }

    /// Several clips selected: the tag goes on every one that lacks it — or, when every one has it
    /// already, comes off them all. Only clips that change are listed.
    static func bulk(_ tag: String, on clips: [DashcamServerClip]) -> (add: Bool, changes: [(clipID: String, tags: [String])]) {
        let add = !clips.allSatisfy { $0.tags.contains(tag) }
        let changes = clips.filter { $0.tags.contains(tag) != add }.map { ($0.id, toggled($0.tags, tag)) }
        return (add, changes)
    }
}

/// Which clips carry tags, kept on the phone so an upload can leave a tagged clip's copy in place
/// without asking the server first. Follows every listing the clean-up reads and every tag change.
enum DashcamTagged {
    static let key = "jc.dashcam.taggedClips"
    /// Read-modify-write, from the main actor and the uploader alike.
    private static let lock = NSLock()

    static func contains(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        lock.withLock { (defaults.stringArray(forKey: key) ?? []).contains(id) }
    }

    static func ids(defaults: UserDefaults = .standard) -> Set<String> {
        lock.withLock { Set(defaults.stringArray(forKey: key) ?? []) }
    }

    /// Tagged on this phone: kept from the tap on, before the server has answered.
    static func mark(_ id: String, defaults: UserDefaults = .standard) {
        lock.withLock {
            var ids = Set(defaults.stringArray(forKey: key) ?? [])
            ids.insert(id)
            defaults.set(Array(ids).sorted(), forKey: key)
        }
    }

    /// Tagged clips from a listing. Only ever adds: a listing may be older than a tap that untagged or
    /// tagged a clip since, and only a tag change's reply (`update`) takes a clip out.
    static func learn(_ clips: [DashcamServerClip], defaults: UserDefaults = .standard) {
        let tagged = clips.filter { !$0.tags.isEmpty }.map(\.id)
        guard !tagged.isEmpty else { return }
        lock.withLock {
            let ids = Set(defaults.stringArray(forKey: key) ?? []).union(tagged)
            defaults.set(Array(ids).sorted(), forKey: key)
        }
    }

    /// These clips as a tag change left them on the server: tagged ones in, untagged ones out.
    static func update(_ clips: [DashcamServerClip], defaults: UserDefaults = .standard) {
        lock.withLock {
            var ids = Set(defaults.stringArray(forKey: key) ?? [])
            for clip in clips {
                if clip.tags.isEmpty { ids.remove(clip.id) } else { ids.insert(clip.id) }
            }
            defaults.set(Array(ids).sorted(), forKey: key)
        }
    }
}

/// The tag list for every screen, and setting a clip's tags.
@MainActor
final class DashcamTagStore: ObservableObject {
    static let shared = DashcamTagStore()

    @Published private(set) var tags: [DashcamTag] = DashcamTag.presets
    var api = DashcamAPI()

    func load() async {
        if let fresh = try? await api.tags(), !fresh.isEmpty { tags = fresh }
    }

    /// A tag of his own (a name he has already is that tag).
    func add(_ name: String) async throws -> DashcamTag {
        let tag = try await api.addTag(name)
        if !tags.contains(where: { $0.id == tag.id }) { tags.append(tag) }
        return tag
    }

    /// One of his own tags, off every clip too.
    func delete(_ id: String) async throws {
        try await api.deleteTag(id)
        tags.removeAll { $0.id == id }
    }

    func name(_ id: String) -> String {
        tags.first { $0.id == id }?.name ?? id.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Puts tags on the clip and takes others off; the server makes the same change on the other lenses'
    /// clips of that moment, and all come back as they are now. A clip being tagged is kept on the phone
    /// from the tap on, and one still only on the camera is pulled at the next chance — the camera records
    /// over old footage (the sync also pulls every tagged clip, after a relaunch too).
    func change(_ clip: DashcamServerClip, add: [String] = [], remove: [String] = []) async throws -> [DashcamServerClip] {
        let sync = DashcamSync.shared
        if !add.isEmpty { DashcamTagged.mark(clip.id, defaults: sync.defaults) }
        let clips = try await api.changeTags(clipID: clip.id, add: add, remove: remove)
        DashcamTagged.update(clips, defaults: sync.defaults)
        for c in clips where !c.tags.isEmpty && c.onCamera && c.phoneState != "local" && !c.uploaded { sync.pull(c.path) }
        return clips
    }
}
