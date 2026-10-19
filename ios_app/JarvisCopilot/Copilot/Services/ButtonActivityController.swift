import ActivityKit
import Foundation

/// Starts, updates and ends the buttons' Lock Screen cards (`ButtonActivityAttributes`): one per
/// source ("door", "car", "button.<id>"), so Arm Away and Arm Home share the door's card. Adopts
/// cards left from an earlier launch or started by the server (push-to-start), and sends every
/// card's push token to the server (`POST /api/live/activity-token`) so it can update and end it
/// while the app sleeps.
@MainActor
final class ButtonActivityController {
    static let shared = ButtonActivityController()

    /// The source the server's push-to-start token is filed under.
    static let doorStartSource = "door-start"
    /// A card is stale this long after its countdown ends with no word since.
    static let staleGrace: TimeInterval = 5
    /// How long a finished card shows its result.
    static let resultFor: TimeInterval = 4

    private let system: any ButtonActivitySystem
    private let upload: @MainActor @Sendable (String, String) async -> Bool

    /// source → its card.
    private var bySource: [String: any ButtonActivityHandle] = [:]
    /// Card ids already watched (one may arrive twice: requested here and seen in the updates).
    private var watched: Set<String> = []
    /// source → the state you swiped its card away in; it stays away for that state.
    private var dismissed: [String: String] = [:]
    /// source → newest token, and the one the server took. A token counts as sent only once the
    /// POST succeeded; anything else goes again on the next flush.
    private var latestTokens: [String: String] = [:]
    private var sentTokens: [String: String] = [:]
    private var inFlight: Set<String> = []
    private var uploads: [Task<Void, Never>] = []
    private var startToken = ""
    private var doorStartEnabled = false
    private var observing = false
    private var tail: Task<Void, Never>?

    init(system: (any ButtonActivitySystem)? = nil,
         upload: (@MainActor @Sendable (String, String) async -> Bool)? = nil) {
        self.system = system ?? ActivityKitButtonActivities()
        self.upload = upload ?? Self.post
    }

    /// Show `state` on `source`'s card: updates the one already up, else starts one (when Live
    /// Activities are on and you haven't swiped this state's card away).
    func show(source: String, buttonID: String, name: String, symbol: String, state: ButtonLiveState) async {
        observe()
        let content = ButtonActivityAttributes.ContentState(state: state, finished: false, result: nil)
        let stale = Self.staleDate(for: state)
        if let current = bySource[source] {
            await serial { await current.update(content, staleDate: stale) }
            return
        }
        guard system.enabled, dismissed[source] != Self.episode(state) else { return }
        dismissed[source] = nil
        let attributes = ButtonActivityAttributes(source: source, buttonID: buttonID, name: name, symbol: symbol)
        guard let started = system.request(attributes, content, staleDate: stale) else { return }
        adopt(started)
    }

    /// Done: the card shows `result` with a checkmark for a few seconds, then goes.
    func finish(source: String, result: String) async {
        dismissed[source] = nil
        guard let current = bySource.removeValue(forKey: source) else { return }
        let final = ButtonActivityAttributes.ContentState(state: current.content.state, finished: true, result: result)
        await serial {
            await current.update(final, staleDate: nil)
            await current.end(final, dismissAfter: Self.resultFor)
        }
    }

    /// Gone now, without a result.
    func end(source: String) async {
        dismissed[source] = nil
        guard let current = bySource.removeValue(forKey: source) else { return }
        await serial { await current.end(nil, dismissAfter: nil) }
    }

    /// The door's card may be started by the server (arming from the Door page, the web, a door
    /// opening). On: its push-to-start token goes to the server as "door-start"; off: "" (forget it).
    func setDoorPushToStart(enabled: Bool) {
        observe()
        doorStartEnabled = enabled
        if enabled {
            if startToken.isEmpty {
                latestTokens[Self.doorStartSource] = nil
            } else {
                latestTokens[Self.doorStartSource] = startToken
            }
        } else {
            latestTokens[Self.doorStartSource] = ""
        }
        flushTokens()
    }

    /// Begin watching cards (ones on screen from before, ones the server starts) and the
    /// push-to-start token. Idempotent; `show` and `setDoorPushToStart` call it.
    func observe() {
        guard !observing else { return }
        observing = true
        for handle in system.running where handle.isLive { adopt(handle) }
        system.watchNew { [weak self] handle in self?.adopt(handle) }
        system.watchStartToken { [weak self] token in self?.startTokenChanged(token) }
    }

    /// What each source's card shows now (tests).
    var running: [String: ButtonActivityAttributes.ContentState] { bySource.mapValues(\.content) }

    /// Await the queued card changes and token uploads (tests).
    func drain() async {
        await tail?.value
        while !uploads.isEmpty {
            let pending = uploads
            uploads = []
            for task in pending { await task.value }
        }
    }

    // MARK: - Internals

    static func staleDate(for state: ButtonLiveState) -> Date? {
        state.endsAt.map { $0.addingTimeInterval(staleGrace) }
    }

    /// One countdown of one state: a swipe-away holds until the state or its deadline changes.
    static func episode(_ state: ButtonLiveState) -> String {
        "\(state.id)|\(state.endsAt?.timeIntervalSinceReferenceDate ?? 0)"
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// ActivityKit's update / end are async; this keeps them in the order they were asked for.
    private func serial(_ work: @escaping @MainActor @Sendable () async -> Void) async {
        await enqueue(work).value
    }

    @discardableResult
    private func enqueue(_ work: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        return task
    }

    private func adopt(_ handle: any ButtonActivityHandle) {
        guard !watched.contains(handle.id), handle.isLive else { return }
        let source = handle.attributes.source
        if let existing = bySource[source], existing.id != handle.id {
            // A second card for this source (the app and the server both started one): keep the first.
            enqueue { await handle.end(nil, dismissAfter: nil) }
            return
        }
        watched.insert(handle.id)
        bySource[source] = handle
        let id = handle.id
        handle.watch(token: { [weak self] token in
            guard let self, self.bySource[source]?.id == id else { return }
            self.latestTokens[source] = token
            self.flushTokens()
        }, gone: { [weak self] byYou in
            guard let self else { return }
            self.watched.remove(id)
            guard self.bySource[source]?.id == id else { return }
            self.bySource[source] = nil
            if byYou { self.dismissed[source] = Self.episode(handle.content.state) }
        })
    }

    private func startTokenChanged(_ token: String) {
        startToken = token
        guard doorStartEnabled else { return }
        latestTokens[Self.doorStartSource] = token
        flushTokens()
    }

    /// POST every token the server hasn't taken yet, one at a time per source.
    private func flushTokens() {
        for (source, token) in latestTokens where sentTokens[source] != token && !inFlight.contains(source) {
            inFlight.insert(source)
            let upload = self.upload
            uploads.append(Task { [weak self] in
                let ok = await upload(source, token)
                guard let self else { return }
                self.inFlight.remove(source)
                guard ok else { return }
                self.sentTokens[source] = token
                // A newer token arrived while this one was on its way.
                if self.latestTokens[source] != token { self.flushTokens() }
            })
        }
    }

    private static let post: @MainActor @Sendable (String, String) async -> Bool = { source, token in
        do {
            _ = try await JarvisAPI.shared.post("/api/live/activity-token", json: ["source": source, "token": token])
            return true
        } catch {
            JcLog.dropped(JcLog.services, "button activity token", error)
            return false
        }
    }
}

// MARK: - ActivityKit, behind a protocol

/// One button card on screen. Behind a protocol so the controller is tested without ActivityKit.
@MainActor
protocol ButtonActivityHandle: AnyObject, Sendable {
    var id: String { get }
    var attributes: ButtonActivityAttributes { get }
    var content: ButtonActivityAttributes.ContentState { get }
    /// Still on screen (active or stale).
    var isLive: Bool { get }
    func update(_ content: ButtonActivityAttributes.ContentState, staleDate: Date?) async
    /// `dismissAfter` nil: gone now; else the final content stays that long.
    func end(_ content: ButtonActivityAttributes.ContentState?, dismissAfter: TimeInterval?) async
    /// Its push tokens (hex) as iOS hands them over, and its going (`byYou`: swiped away).
    func watch(token: @escaping @MainActor @Sendable (String) -> Void,
               gone: @escaping @MainActor @Sendable (Bool) -> Void)
}

/// What is on screen, starting a card, and the push-to-start token.
@MainActor
protocol ButtonActivitySystem: AnyObject {
    /// The phone's Live Activities switch for this app.
    var enabled: Bool { get }
    var running: [any ButtonActivityHandle] { get }
    func request(_ attributes: ButtonActivityAttributes, _ content: ButtonActivityAttributes.ContentState,
                 staleDate: Date?) -> (any ButtonActivityHandle)?
    /// Cards that appear later (the server push-started one).
    func watchNew(_ handler: @escaping @MainActor @Sendable (any ButtonActivityHandle) -> Void)
    /// The push-to-start token (hex), as it changes.
    func watchStartToken(_ handler: @escaping @MainActor @Sendable (String) -> Void)
}

@MainActor
final class ActivityKitButtonActivities: ButtonActivitySystem {
    var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    var running: [any ButtonActivityHandle] {
        Activity<ButtonActivityAttributes>.activities.map(KitButtonActivity.init)
    }

    func request(_ attributes: ButtonActivityAttributes, _ content: ButtonActivityAttributes.ContentState,
                 staleDate: Date?) -> (any ButtonActivityHandle)? {
        let content = ActivityContent(state: content, staleDate: staleDate)
        do {
            return KitButtonActivity(try Activity.request(attributes: attributes, content: content, pushType: .token))
        } catch {
            // A build without the Push Notifications capability can't ask for a token;
            // a token-less card still beats none.
            JcLog.dropped(JcLog.services, "button live activity request (push token)", error)
            do {
                return KitButtonActivity(try Activity.request(attributes: attributes, content: content))
            } catch {
                // Off for this app, or the system's limit on running activities.
                JcLog.dropped(JcLog.services, "button live activity request", error)
                return nil
            }
        }
    }

    func watchNew(_ handler: @escaping @MainActor @Sendable (any ButtonActivityHandle) -> Void) {
        Task { @MainActor in
            for await activity in Activity<ButtonActivityAttributes>.activityUpdates {
                handler(KitButtonActivity(activity))
            }
        }
    }

    func watchStartToken(_ handler: @escaping @MainActor @Sendable (String) -> Void) {
        guard #available(iOS 17.2, *) else { return }
        Task { @MainActor in
            for await data in Activity<ButtonActivityAttributes>.pushToStartTokenUpdates {
                handler(ButtonActivityController.hex(data))
            }
        }
    }
}

@MainActor
final class KitButtonActivity: ButtonActivityHandle {
    private let activity: Activity<ButtonActivityAttributes>

    init(_ activity: Activity<ButtonActivityAttributes>) { self.activity = activity }

    var id: String { activity.id }
    var attributes: ButtonActivityAttributes { activity.attributes }
    var content: ButtonActivityAttributes.ContentState { activity.content.state }
    var isLive: Bool { activity.activityState == .active || activity.activityState == .stale }

    func update(_ content: ButtonActivityAttributes.ContentState, staleDate: Date?) async {
        await activity.update(ActivityContent(state: content, staleDate: staleDate))
    }

    func end(_ content: ButtonActivityAttributes.ContentState?, dismissAfter: TimeInterval?) async {
        let final = content.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = dismissAfter.map { .after(Date().addingTimeInterval($0)) } ?? .immediate
        await activity.end(final, dismissalPolicy: policy)
    }

    func watch(token: @escaping @MainActor @Sendable (String) -> Void,
               gone: @escaping @MainActor @Sendable (Bool) -> Void) {
        let activity = self.activity
        Task { @MainActor in
            for await data in activity.pushTokenUpdates { token(ButtonActivityController.hex(data)) }
        }
        Task { @MainActor in
            for await state in activity.activityStateUpdates {
                // Ended for us (an end push, iOS's 8-hour limit), or swiped off the Lock Screen.
                if state == .ended || state == .dismissed {
                    gone(state == .dismissed)
                    return
                }
            }
        }
    }
}
