import Foundation

/// Schedules the offline plan embedded in a Dynamic Island design as local
/// notifications, so a flight status or a meeting reminder fires at its time with
/// no network at all.
///
/// Port of `scheduleIslandNotifications` / `cancelIslandNotifications` in
/// `skills/common.dart`. The Flutter version used a fixed block of 64 integer
/// notification slots; iOS identifiers are strings, so the block is
/// `jc.island.plan.<0…63>` and cancelling the whole block is what a re-sync does
/// first — only one custom design is ever active, so per-design buckets (which
/// could collide) are not needed.
@MainActor
final class IslandPlanNotifier {
    static let slotPrefix = "jc.island.plan."
    static let slotCount = 64

    private let notifier: any Notifying
    private let now: @MainActor () -> Date

    /// Design id + item signature of what is currently scheduled. The coordinator
    /// pushes every ~5 s; without this the scheduler would be torn down and
    /// rebuilt on every tick.
    private var signature = ""
    private var designID = ""

    init(notifier: (any Notifying)? = nil, now: (@MainActor () -> Date)? = nil) {
        self.notifier = notifier ?? DefaultNotifier()
        self.now = now ?? { Date() }
    }

    static var slotIdentifiers: [String] { (0..<slotCount).map { "\(slotPrefix)\($0)" } }

    /// Bring the scheduled plan in line with the active design. Idempotent: an
    /// unchanged design + plan does nothing at all.
    func sync(_ design: IslandDesign?) {
        let id = design?.id ?? ""
        let items = design?.offlineScheduledItems ?? []
        let next = "\(id)|\(IslandOffline.scheduledItemsSignature(items))"
        guard next != signature else { return }
        signature = next
        designID = id
        guard !id.isEmpty, !items.isEmpty else {
            cancelAll()
            return
        }
        schedule(items)
    }

    private func cancelAll() {
        let notifier = self.notifier
        Task { await notifier.cancel(identifiers: Self.slotIdentifiers) }
    }

    private func schedule(_ items: [JSONObject]) {
        let requests = Self.requests(items, now: now())
        let notifier = self.notifier
        Task {
            // Cancel the whole block first — a shrunk plan must not leave the
            // tail of the previous one firing.
            await notifier.cancel(identifiers: Self.slotIdentifiers)
            for request in requests { _ = try? await notifier.post(request) }
        }
    }

    /// Pure: turn `[{at, title, body?, action?}]` into the notifications to post.
    /// Past, untitled and malformed entries are skipped, and the list is capped at
    /// the slot block.
    static func requests(_ items: [JSONObject], now: Date) -> [LocalNotificationRequest] {
        var out: [LocalNotificationRequest] = []
        for item in items {
            guard out.count < slotCount else { break }
            guard let seconds = epochSeconds(item["at"]) else { continue }
            let at = Date(timeIntervalSince1970: seconds)
            guard at > now else { continue }              // past → skip
            let title = MoreJSON.text(item["title"])
            guard !title.isEmpty else { continue }
            // A job's optional action rides in the payload; tapping it enqueues
            // and runs the action, exactly like a deferred foreground skill.
            var payload: String?
            if let action = item["action"] as? JSONObject {
                let skill = MoreJSON.text(action["skill"])
                if !skill.isEmpty {
                    payload = notificationActionPayload(
                        skill: skill, args: MoreJSON.map(action["args"]))
                }
            }
            out.append(LocalNotificationRequest(
                title: title,
                body: MoreJSON.text(item["body"]),
                at: at,
                identifier: "\(slotPrefix)\(out.count)",
                payload: payload,
                sound: true,
                timeSensitive: true))
        }
        return out
    }

    private static func epochSeconds(_ value: Any?) -> TimeInterval? {
        if let d = MoreJSON.double(value), d.isFinite, d > 0 { return d }
        return nil
    }
}
