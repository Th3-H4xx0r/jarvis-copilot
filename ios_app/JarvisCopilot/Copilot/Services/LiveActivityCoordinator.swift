import Foundation

/// The SINGLE owner of the JARVIS Live Activity. Voice and coding both report to
/// it; it picks the mode, builds the merged state, dedupes and pushes.
///
/// Port of `live_activity/live_activity_coordinator.dart`. Having two independent
/// pushers over one activity was the dueling-pusher bug class the Flutter version
/// was written to end, so `VoiceStore` still only produces snapshots — it never
/// touches ActivityKit.
///
/// The poll deliberately does NOT run at a fixed 5 s: `LivePollPolicy` drops it
/// to 60 s discovery whenever nothing is live, because two HTTP calls every five
/// seconds from launch was this app's single biggest always-on battery cost.
@MainActor
final class LiveActivityCoordinator {

    static let shared = LiveActivityCoordinator()

    /// The timer's own cadence. Each tick then decides whether enough time has
    /// passed for a fetch, per `LivePollPolicy`.
    static let tickInterval: TimeInterval = 5
    /// While backgrounded (and still alive, thanks to the audio/BLE modes) poll
    /// much less often — the activity stays fresh enough and the battery survives.
    static let backgroundInterval: TimeInterval = 30
    /// The island catalog changes rarely, and on its OWN cadence so a layout edit
    /// applies live even when the coding poll is throttled to 60 s.
    static let islandInterval: TimeInterval = 5

    // MARK: Dependencies

    private let coding: CodingSessionsAPI
    private let islandAPI: IslandDesignsAPI
    private let islandSync: IslandSync
    private let plan: IslandPlanNotifier
    private let lifecycle: AppLifecycle
    private let preferences: KeyValueStore
    private let isPaired: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private var controller: any ActivityControlling

    // MARK: State

    private(set) var enabled = true
    /// Set by the Coding tab's visibility hook: while the user is looking at
    /// Coding we keep the fast cadence even before a session goes live.
    var codingVisible = false

    private var voice = VoiceLiveActivitySnapshot(
        state: "idle", transcript: "", activity: "", connected: true, devices: [])
    private var fleet = LiveFleet.empty
    private var usage = CodingUsage()
    private var catalog = IslandCatalog.empty

    private var lastPushed: LiveActivityState?
    private var lastFetch = Date(timeIntervalSince1970: 0)
    private var lastUsageFetch = Date(timeIntervalSince1970: 0)
    private var lastBackgroundPoll = Date(timeIntervalSince1970: 0)
    private var lastIslandFetch = Date(timeIntervalSince1970: 0)
    private var lastToken = ""

    private let pollHandle = TaskHandle()

    init(coding: CodingSessionsAPI = CodingSessionsAPI(),
         islandAPI: IslandDesignsAPI = IslandDesignsAPI(),
         islandCache: IslandDesignCache? = nil,
         controller: (any ActivityControlling)? = nil,
         plan: IslandPlanNotifier? = nil,
         lifecycle: AppLifecycle = .shared,
         preferences: KeyValueStore = UserDefaults.standard,
         isPaired: (@MainActor () -> Bool)? = nil,
         now: (@MainActor () -> Date)? = nil,
         sleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil) {
        self.coding = coding
        self.islandAPI = islandAPI
        self.islandSync = IslandSync(cache: islandCache ?? AppGroupIslandDesignCache())
        self.controller = controller ?? DefaultActivityController()
        self.plan = plan ?? IslandPlanNotifier()
        self.lifecycle = lifecycle
        self.preferences = preferences
        self.isPaired = isPaired ?? { BridgeClient.shared.isPaired }
        self.now = now ?? { Date() }
        self.sleeper = sleeper ?? { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        // `credentials.dart` read this as `!= '0'` — on unless explicitly off.
        self.enabled = preferences.bool(SettingsStore.Keys.liveActivities) ?? true
        self.controller.onPushToken = { [weak self] token in
            Task { @MainActor in self?.registerPushToken(token) }
        }
    }

    deinit { pollHandle.cancel() }

    // MARK: - Lifecycle

    /// Begin coordinating. No-op (and no activity) when the user has Live
    /// Activities switched off.
    func start() {
        enabled = preferences.bool(SettingsStore.Keys.liveActivities) ?? true
        guard enabled else { return }
        startPoll()
        Task { await refreshCoding() }
    }

    /// The settings toggle. Off → end the activity and stop polling entirely;
    /// leaving a stale island on the Lock Screen after the user turned the
    /// feature off is the one outcome that is never acceptable.
    func setEnabled(_ on: Bool) {
        enabled = on
        if on {
            startPoll()
            Task { await refreshCoding() }
        } else {
            pollHandle.cancel()
            lastPushed = nil
            controller.end()
        }
    }

    /// The app came to the foreground — refresh and re-push.
    func onResume() {
        guard enabled else { return }
        startPoll()
        Task { await refreshCoding() }
    }

    func stop() { pollHandle.cancel() }

    func setCodingVisible(_ visible: Bool) { codingVisible = visible }

    /// `VoiceStore` reports here (through `VoiceLiveActivityThrottle.onPush`)
    /// rather than pushing ActivityKit itself.
    func reportVoice(_ snapshot: VoiceLiveActivitySnapshot) {
        voice = snapshot
        push()
    }

    // MARK: - Poll

    private func startPoll() {
        pollHandle.replace(Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await self.sleeper(Self.tickInterval)
                if Task.isCancelled { return }
                await self.tick()
            }
        })
    }

    /// One poll tick. Exposed so a test can drive the cadence without a clock.
    func tick() async {
        guard enabled else { return }
        guard lifecycle.isForeground else {
            // Backgrounded but still alive (audio / bluetooth-central keep the
            // process running). Poll slowly so the activity keeps updating; a
            // fully suspended app relies on the server's APNs push-to-update.
            let moment = now()
            guard moment.timeIntervalSince(lastBackgroundPoll) >= Self.backgroundInterval else { return }
            lastBackgroundPoll = moment
            await refreshCoding()
            return
        }
        await refreshIslandIfDue()
        let want = LivePollPolicy.pollInterval(voiceActive: voice.state != "idle",
                                               codingVisible: codingVisible,
                                               sessionTotal: fleet.sessionTotal)
        guard now().timeIntervalSince(lastFetch) >= want else { return }
        await refreshCoding()
    }

    /// Fetch the fleet (and, on its own slower gate, usage), then re-push.
    func refreshCoding() async {
        guard isPaired() else { return }
        // Stamped BEFORE the awaits so the manual refreshes in start()/onResume()
        // also advance the cadence gate — otherwise the next tick double-fetches.
        lastFetch = now()
        do {
            let view = try await coding.listProjectsExpanded()
            if LivePollPolicy.shouldFetchUsage(now: now(), lastUsageFetch: lastUsageFetch) {
                // `/api/coding/usage` is slow-moving quota; it does not need the
                // fleet's cadence.
                if let fresh = try await coding.usage() { usage = fresh }
                lastUsageFetch = now()
            }
            fleet = LiveFleet.from(view)
        } catch {
            return   // transient — keep the last snapshot and retry next tick
        }
        await refreshIslandIfDue()
        push()
    }

    /// Fetch the design catalog on its own gate and cache changed trees into the
    /// App Group. Best-effort: an older server or being offline keeps the last
    /// catalog (empty → the legacy voice/coding behaviour).
    private func refreshIslandIfDue() async {
        guard isPaired() else { return }
        guard now().timeIntervalSince(lastIslandFetch) >= Self.islandInterval else { return }
        lastIslandFetch = now()
        await fetchIsland()
    }

    /// Force an immediate catalog refresh + re-push, bypassing the gate. The
    /// designs screen calls this right after a selection change so the island
    /// switches NOW instead of waiting out the (idle-throttled) poll.
    func refreshIslandNow() async {
        guard enabled else { return }
        lastIslandFetch = Date(timeIntervalSince1970: 0)
        await fetchIsland()
        push()
    }

    private func fetchIsland() async {
        guard let fresh = try? await islandAPI.catalog() else { return }
        catalog = fresh
        await islandSync.sync(fresh.designs)
        push()
    }

    // MARK: - Push tokens

    private func registerPushToken(_ token: String) {
        guard token != lastToken else { return }   // tokens rotate; only register changes
        lastToken = token
        let coding = self.coding
        let deviceID = PushHandler.shared.deviceID
        Task { try? await coding.registerLaToken(token, deviceId: deviceID) }
    }

    // MARK: - Compose

    /// The live source values the auto-engine and the binding resolver can read.
    /// Per-design `jarvis.*` values come from the server, not here.
    private func sources() -> IslandBindings.Sources {
        var out: IslandBindings.Sources = [
            "time.now": Int(now().timeIntervalSince1970),
            "coding.sessions": fleet.sessionTotal,
        ]
        if usage.fiveHourPct >= 0 { out["coding.usage5"] = usage.fiveHourPct }
        if usage.weeklyPct >= 0 { out["coding.usageWeek"] = usage.weeklyPct }
        return out
    }

    /// Build the state the island should show right now. Pure given the
    /// coordinator's snapshots, so the mode-selection rules can be asserted.
    func compose() -> LiveActivityState {
        let voiceActive = voice.state != "idle"
        let codingLive = fleet.sessionTotal > 0

        var state = LiveActivityState()
        state.state = voice.state
        state.transcript = voice.transcript
        state.activity = voice.activity
        state.connected = voice.connected
        state.devices = voice.devices

        var showCoding = false
        var activeDesign: IslandDesign?

        if catalog.entries.isEmpty {
            // Catalog not loaded yet (or an older server) → legacy behaviour:
            // voice wins, else coding when sessions are live, else the voice-idle
            // launcher.
            state.mode = voiceActive ? "voice" : (codingLive ? "coding" : "voice")
            showCoding = state.mode == "coding"
        } else {
            let live = sources()
            let active = IslandAuto.selectActiveDesign(
                catalog: catalog, voiceActive: voiceActive, codingLive: codingLive,
                sources: live, now: now())
            if active.isCustom, let id = active.id, let design = catalog.design(id: id) {
                state.mode = "custom"
                state.designId = design.id
                // The CONTENT signature, not `version`: any layout edit must
                // change the pushed state so the widget re-renders and re-reads
                // the fresh cached tree, even when Jarvis didn't bump the version.
                state.designVersion = design.contentSignature
                activeDesign = design
                let base = IslandBindings.resolveData(design, sources: live,
                                                      serverData: catalog.data(for: design.id))
                // Overlay the current offline-timeline keyframe on top of the
                // resolved data, so discrete phases advance by the clock with no
                // network at all.
                let keyframe = IslandOffline.currentKeyframeData(
                    design.timeline, Int(now().timeIntervalSince1970))
                let merged = keyframe.isEmpty ? base : base.merging(keyframe) { _, new in new }
                state.data = MoreJSON.canonicalJSON(merged)
            } else if active.kind == "coding" {
                state.mode = "coding"
                showCoding = true
            } else {
                state.mode = "voice"
            }
        }

        plan.sync(activeDesign)

        if showCoding {
            state.sessions = fleet.sessions
            state.sessionTotal = fleet.sessionTotal
            state.entryTotal = fleet.entryTotal
            state.waitingCount = fleet.waitingCount
            state.usage5 = usage.fiveHourPct
            state.usageWeek = usage.weeklyPct
            state.usage5Resets = usage.fiveHourResets
            state.usageWeekResets = usage.weeklyResets
        }
        return state
    }

    /// Compose, dedupe and hand to the controller. Nothing changed → don't churn
    /// the activity (iOS budgets updates, and flooding it made the island stick
    /// on a stale state).
    func push() {
        guard enabled else { return }
        let state = compose()
        guard state != lastPushed else { return }
        lastPushed = state
        controller.update(state)
    }

    /// The state most recently handed to the controller (tests, diagnostics).
    var pushedState: LiveActivityState? { lastPushed }
}
