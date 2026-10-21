import Foundation

/// The iMessage memory card: everything `GET /api/imessage-memory` says, and what
/// every mutation hands back. One snapshot — the screen redraws from it whole.
///
/// Decoding is lenient on purpose: a field the server leaves out reads as its
/// empty value rather than failing the whole card, so an older or newer server
/// still shows a screen.
struct IMessageMemoryCard: Decodable, Equatable {
    var enabled: Bool
    /// Whether the jarvis_memory provider is the active one — memories go nowhere otherwise.
    var memoryActive: Bool
    /// The model or harness extraction runs on. nil = Same as Default.
    var agent: AgentChoice?
    /// The server's own words for what that resolves to right now.
    var runsOn: String
    /// When the Mac last reported (epoch seconds); nil = it never has.
    var macSeenAt: Double?
    var chats: [IMessageChat]
    var skip: [IMessagePerson]
    var jobs: [IMessageBackfillJob]
    var activeJob: IMessageBackfillJob?
    var totals: Totals

    struct Totals: Decodable, Equatable {
        var memories: Int
        var bursts: Int
        var pending: Int

        init(memories: Int = 0, bursts: Int = 0, pending: Int = 0) {
            self.memories = memories
            self.bursts = bursts
            self.pending = pending
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            memories = try c.value(.memories, 0)
            bursts = try c.value(.bursts, 0)
            pending = try c.value(.pending, 0)
        }

        private enum CodingKeys: String, CodingKey { case memories, bursts, pending }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, agent, chats, skip, jobs, totals
        case memoryActive = "memory_active"
        case runsOn = "runs_on"
        case macSeenAt = "mac_seen_at"
        case activeJob = "active_job"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.value(.enabled, false)
        memoryActive = try c.value(.memoryActive, false)
        agent = try c.decodeIfPresent(IMessageMemoryAgent.self, forKey: .agent)?.choice
        runsOn = try c.value(.runsOn, "")
        macSeenAt = try c.decodeIfPresent(Double.self, forKey: .macSeenAt)
        chats = try c.value(.chats, [])
        skip = try c.value(.skip, [])
        jobs = try c.value(.jobs, [])
        activeJob = try c.decodeIfPresent(IMessageBackfillJob.self, forKey: .activeJob)
        totals = try c.value(.totals, Totals())
    }

    static func decode(_ data: Data) throws -> IMessageMemoryCard {
        try JSONDecoder().decode(IMessageMemoryCard.self, from: data)
    }

    // MARK: What the screens read

    var macSeen: Date? { macSeenAt.map { Date(timeIntervalSince1970: $0) } }

    /// Chats whose messages are being remembered.
    var tickedCount: Int { chats.filter(\.effective).count }

    /// The line under the pinned card on the Integrations list.
    var subtitle: String {
        if macSeenAt == nil { return "Mac not seen yet" }
        guard enabled else { return "Off" }
        let chatWord = tickedCount == 1 ? "chat" : "chats"
        let memoryWord = totals.memories == 1 ? "memory" : "memories"
        return "On · \(tickedCount) \(chatWord) · \(totals.memories) \(memoryWord)"
    }

    /// Why memories may not be landing, or nil when nothing is wrong.
    var warning: String? {
        if !memoryActive { return "Jarvis memory isn't the active memory provider, so nothing is stored." }
        if macSeenAt == nil { return "Your Mac hasn't reported yet. Open Jarvis on the Mac and give it Full Disk Access." }
        return nil
    }

    /// Everyone in an uploaded chat who isn't already skipped, once each, by name.
    var skippablePeople: [IMessagePerson] {
        let skipped = Set(skip.map(\.handle))
        var seen = Set<String>()
        var people: [IMessagePerson] = []
        for chat in chats {
            for person in chat.participants where !skipped.contains(person.handle) {
                if seen.insert(person.handle).inserted { people.append(person) }
            }
        }
        return people.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Finished jobs, newest first — the active one has its own card.
    var recentJobs: [IMessageBackfillJob] {
        jobs.filter { $0.id != activeJob?.id }.sorted { $0.createdAt > $1.createdAt }
    }
}

/// One iMessage conversation the Mac uploaded.
struct IMessageChat: Decodable, Equatable, Identifiable, Hashable {
    var guid: String
    var name: String
    var isGroup: Bool
    var participants: [IMessagePerson]
    var lastMessageAt: Double?
    /// His explicit choice: true / false, or nil = follow the default.
    var pick: Bool?
    /// Whether it is being remembered, after the default is applied.
    var effective: Bool
    /// Memories already stored from it.
    var remembered: Int

    var id: String { guid }

    var lastMessage: Date? { lastMessageAt.map { Date(timeIntervalSince1970: $0) } }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let names = participants.map(\.displayName)
        return names.isEmpty ? guid : names.joined(separator: ", ")
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if displayName.localizedCaseInsensitiveContains(q) { return true }
        return participants.contains { $0.label.localizedCaseInsensitiveContains(q) || $0.handle.localizedCaseInsensitiveContains(q) }
    }

    private enum CodingKeys: String, CodingKey {
        case guid, name, participants, pick, effective, remembered
        case isGroup = "is_group"
        case lastMessageAt = "last_message_at"
    }

    init(guid: String, name: String = "", isGroup: Bool = false, participants: [IMessagePerson] = [],
         lastMessageAt: Double? = nil, pick: Bool? = nil, effective: Bool = false, remembered: Int = 0) {
        self.guid = guid
        self.name = name
        self.isGroup = isGroup
        self.participants = participants
        self.lastMessageAt = lastMessageAt
        self.pick = pick
        self.effective = effective
        self.remembered = remembered
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guid = try c.decode(String.self, forKey: .guid)
        name = try c.value(.name, "")
        isGroup = try c.value(.isGroup, false)
        participants = try c.value(.participants, [])
        lastMessageAt = try c.decodeIfPresent(Double.self, forKey: .lastMessageAt)
        pick = try c.decodeIfPresent(Bool.self, forKey: .pick)
        effective = try c.value(.effective, false)
        remembered = try c.value(.remembered, 0)
    }
}

/// A person by their iMessage handle (phone or email) and the name the Mac knows them by.
struct IMessagePerson: Codable, Equatable, Identifiable, Hashable {
    var handle: String
    var label: String

    var id: String { handle }

    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? handle : trimmed
    }

    init(handle: String, label: String = "") {
        self.handle = handle
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle)
        label = try c.value(.label, "")
    }

    /// The shape `POST /api/imessage-memory/settings` takes for `skip`.
    var json: [String: Any] { ["handle": handle, "label": label] }

    private enum CodingKeys: String, CodingKey { case handle, label }
}

/// One backfill run over a date range.
struct IMessageBackfillJob: Decodable, Equatable, Identifiable, Hashable {
    enum Status: String, Decodable, Equatable, Hashable {
        case pending, running, done, stopped, error

        var title: String {
            switch self {
            case .pending: return "Waiting for the Mac"
            case .running: return "Running"
            case .done: return "Done"
            case .stopped: return "Stopped"
            case .error: return "Failed"
            }
        }

        var isLive: Bool { self == .pending || self == .running }
    }

    var id: String
    var start: Double
    var end: Double
    /// The chats it covers; nil = every ticked chat.
    var chats: [String]?
    var status: Status
    var received: Int
    var stored: Int
    var skipped: Int
    var createdAt: Double
    var updatedAt: Double
    var error: String?

    var startDate: Date { Date(timeIntervalSince1970: start) }
    var endDate: Date { Date(timeIntervalSince1970: end) }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, chats, status, received, stored, skipped, error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        start = try c.value(.start, 0)
        end = try c.value(.end, 0)
        chats = try c.decodeIfPresent([String].self, forKey: .chats)
        // An unknown status word from a newer server reads as "error", not a dead card.
        let raw = try c.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        status = Status(rawValue: raw) ?? .error
        received = try c.value(.received, 0)
        stored = try c.value(.stored, 0)
        skipped = try c.value(.skipped, 0)
        createdAt = try c.value(.createdAt, 0)
        updatedAt = try c.value(.updatedAt, 0)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// The `agent` field: `{"harness_id"}` ↔ `.harness`, `{"model","provider"}` ↔ `.model`,
/// `null` ↔ nil (Same as Default).
struct IMessageMemoryAgent: Decodable, Equatable {
    var choice: AgentChoice?

    init(_ choice: AgentChoice?) { self.choice = choice }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let harness = try c.decodeIfPresent(String.self, forKey: .harnessID) ?? ""
        let model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        if !harness.isEmpty {
            choice = .harness(harness)
        } else if !model.isEmpty {
            let provider = try c.decodeIfPresent(String.self, forKey: .provider)
            choice = .model(id: model, provider: provider?.isEmpty == true ? nil : provider)
        } else {
            choice = nil
        }
    }

    /// What goes on the wire: a dictionary, or `NSNull` for Same as Default.
    var json: Any {
        switch choice {
        case nil: return NSNull()
        case .harness(let id)?: return ["harness_id": id]
        case .model(let id, let provider)?: return ["model": id, "provider": provider.map { $0 as Any } ?? NSNull()]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case model, provider
        case harnessID = "harness_id"
    }
}

/// The From / To presets on the Backfill card.
enum IMessageBackfillPreset: String, CaseIterable, Identifiable {
    case week = "Last week"
    case month = "Last month"
    case threeMonths = "Last 3 months"

    var id: String { rawValue }

    func range(endingAt now: Date, calendar: Calendar = .current) -> (from: Date, to: Date) {
        let from: Date?
        switch self {
        case .week: from = calendar.date(byAdding: .day, value: -7, to: now)
        case .month: from = calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths: from = calendar.date(byAdding: .month, value: -3, to: now)
        }
        return (from ?? now, now)
    }
}

extension KeyedDecodingContainer {
    /// The value under `key`, or `fallback` when it is missing or null.
    fileprivate func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}
