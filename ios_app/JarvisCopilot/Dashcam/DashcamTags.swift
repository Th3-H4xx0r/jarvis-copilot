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
/// without asking the server first. The server is the truth: it follows every listing, lock answer and tag change —
/// in and out — except that a clip tagged on this phone stays in for `raceGuard` whatever an answer says (that
/// answer may have been read before the tap).
enum DashcamTagged {
    static let key = "jc.dashcam.taggedClips"
    /// When this phone tagged each clip (Unix seconds), for `raceGuard`.
    static let markedAtKey = "jc.dashcam.taggedAt"
    static let raceGuard: TimeInterval = 300
    /// Read-modify-write, from the main actor and the uploader alike.
    private static let lock = NSLock()

    static func contains(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        lock.withLock { (defaults.stringArray(forKey: key) ?? []).contains(id) }
    }

    static func ids(defaults: UserDefaults = .standard) -> Set<String> {
        lock.withLock { Set(defaults.stringArray(forKey: key) ?? []) }
    }

    /// Tagged on this phone: kept from the tap on, before the server has answered.
    static func mark(_ id: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        lock.withLock {
            var ids = Set(defaults.stringArray(forKey: key) ?? [])
            ids.insert(id)
            defaults.set(Array(ids).sorted(), forKey: key)
            var at = recentMarks(defaults, now: now)
            at[id] = now.timeIntervalSince1970
            defaults.set(at, forKey: markedAtKey)
        }
    }

    /// Clips the server named locked (refusing a delete, say): kept like tagged ones. Not a tap of his.
    static func learn(ids locked: [String], defaults: UserDefaults = .standard) {
        guard !locked.isEmpty else { return }
        lock.withLock {
            let ids = Set(defaults.stringArray(forKey: key) ?? []).union(locked)
            defaults.set(Array(ids).sorted(), forKey: key)
        }
    }

    /// A listing as the server has it: tagged clips in, untagged ones out — but not one tagged on this phone in the
    /// last `raceGuard` (the listing may be older than the tap).
    static func learn(_ clips: [DashcamServerClip], defaults: UserDefaults = .standard, now: Date = Date()) {
        guard !clips.isEmpty else { return }
        lock.withLock {
            let recent = recentMarks(defaults, now: now)
            var ids = Set(defaults.stringArray(forKey: key) ?? [])
            for clip in clips {
                if !clip.tags.isEmpty || clip.locked { ids.insert(clip.id) }
                else if recent[clip.id] == nil { ids.remove(clip.id) }
            }
            defaults.set(Array(ids).sorted(), forKey: key)
        }
    }

    /// The server's whole list of locked clips: everything else comes out, except a recent tap.
    static func replace(with locked: Set<String>, defaults: UserDefaults = .standard, now: Date = Date()) {
        lock.withLock {
            let recent = Set(recentMarks(defaults, now: now).keys)
            defaults.set(Array(locked.union(recent.intersection(Set(defaults.stringArray(forKey: key) ?? [])))).sorted(),
                         forKey: key)
        }
    }

    /// Taps within `raceGuard` (older ones are pruned on every write).
    private static func recentMarks(_ defaults: UserDefaults, now: Date) -> [String: Double] {
        (defaults.dictionary(forKey: markedAtKey) ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            .filter { now.timeIntervalSince1970 - $0.value < raceGuard }
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

/// Locked clips: any tag locks a clip, and a locked clip is never deleted — not from the phone, the cloud or the
/// camera's card — and goes up first whatever the upload rules (his Oct 21 accident clip was tagged and still lost
/// its phone copy). One decision for every place that deletes or uploads: the server's word, the clip's own tags,
/// or this phone's record of tagged clips (kept from the tap on, before the server answers). Any one locks it.
enum DashcamLock {
    static func isLocked(id: String, server: Bool = false, tags: [String] = [], tagged: Set<String>) -> Bool {
        server || !tags.isEmpty || tagged.contains(id)
    }

    static func isLocked(_ clip: DashcamServerClip, tagged: Set<String>) -> Bool {
        isLocked(id: clip.id, server: clip.locked, tags: clip.tags, tagged: tagged)
    }

    static func isLocked(_ clip: DashcamServerClip, defaults: UserDefaults = .standard) -> Bool {
        isLocked(clip, tagged: DashcamTagged.ids(defaults: defaults))
    }

    /// The clip page's line under its tags.
    static let pageLine = "Locked — tagged clips are never deleted. Remove its tags to delete it."
    /// Why a delete was refused (after "Couldn't delete everywhere — ").
    static let refusal = "it's locked: tagged clips are never deleted. Remove its tags to delete it."

    /// Several clips chosen for a delete: the ones that may go, and the locked ones that stay.
    static func split(_ clips: [DashcamServerClip], tagged: Set<String>) -> (deletable: [DashcamServerClip], locked: [DashcamServerClip]) {
        (clips.filter { !isLocked($0, tagged: tagged) }, clips.filter { isLocked($0, tagged: tagged) })
    }

    /// What a delete of several clips says about the locked ones it left (nil when there were none).
    static func skippedLine(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "Skipped \(count) locked clip\(count == 1 ? "" : "s") — tagged clips are never deleted."
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

    /// One of his own tags, off every clip too. A clip it was the only tag on unlocks: the server's list of locked
    /// clips is read again so the phone stops treating it as locked.
    func delete(_ id: String) async throws {
        try await api.deleteTag(id)
        tags.removeAll { $0.id == id }
        DashcamSync.shared.refreshLocksSoon()
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
        sync.noteServerClips(clips)
        for c in clips where !c.tags.isEmpty && c.onCamera && c.phoneState != "local" && !c.uploaded { sync.pull(c.path) }
        // Locked now: one whose phone copy went after its upload comes back from the cloud at once.
        if clips.contains(where: { !$0.tags.isEmpty && $0.uploaded && $0.phoneState != "local" }) { sync.restoreLockedSoon(force: true) }
        return clips
    }
}
