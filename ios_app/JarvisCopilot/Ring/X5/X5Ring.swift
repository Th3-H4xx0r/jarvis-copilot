import Foundation

/// What `X5Ring` needs from the app: the link, the protocol session, sync, history and inputs.
@MainActor
protocol X5Backend: AnyObject {
    var deviceID: String? { get }
    var isConnected: Bool { get }
    var connectionText: String { get }
    var displayName: String? { get }
    var session: X5Session { get }
    var sync: X5Sync { get }
    var store: RingHistoryStore? { get }
    var inputs: RingInputStore? { get }
    var awakePolicy: X5AwakePolicy { get }
    func setAwakePolicy(_ policy: X5AwakePolicy)
    /// Puts the touch surface in the mode the inputs store asks for.
    func applyInputMode() async
    func ensureConnected(timeout: TimeInterval) async -> Bool
    func waitForSetup(timeout: TimeInterval) async
    func releaseIfIdle()
    /// The workout controller, when the app runs one (the live sheet, Jarvis Health).
    var workouts: RingWorkoutController? { get }
}

extension X5Backend {
    var workouts: RingWorkoutController? { nil }
}

extension X5Manager: X5Backend {
    var isConnected: Bool { state == .ready }
    var connectionText: String { state.text }
    var displayName: String? { connected?.name }
}

/// Exposes the X5 touch ring to Jarvis as `x5_*` skills.
///
/// The day, health-day and history skills answer in exactly the R12's `ring_*` shapes (both
/// rings store `RingDay`s), so the server reads either through one adapter. Reads work with the
/// ring away; everything that touches it reconnects on demand within the bridge's 30 s.
@MainActor
final class X5Ring: WearableDevice {
    static let model = "X5 smart ring"

    private unowned let backend: X5Backend

    init(backend: X5Backend) {
        self.backend = backend
    }

    var deviceID: String { backend.deviceID ?? WearableKeepAlive.x5ring }
    var isConnected: Bool { backend.isConnected }
    private var session: X5Session { backend.session }

    static let gestureNames: [String: RingInput] = [
        "swipe_up": .swipeUp, "swipe_down": .swipeDown, "swipe_left": .swipeLeft, "swipe_right": .swipeRight,
        "tap": .tap, "double_tap": .doubleTap, "long_press": .longPress, "hold_5s": .holdFiveSeconds,
        "hold_10s": .holdTenSeconds,
    ]
    static let measurementNames: [String: RingMeasurementType] = [
        "heart_rate": .heartRate, "spo2": .spo2, "temperature": .temperature,
    ]
    static let monitorNames: [String: X5MonitorType] = ["heart_rate": .heartRate, "hrv": .hrv, "spo2": .spo2]

    // MARK: Catalogue

    var capabilities: [DeviceCapability] {
        let metricNames = RingMetric.allCases.map(\.rawValue)
        let metrics: [String: Any] = ["type": "array", "items": ["type": "string", "enum": metricNames],
                                      "description": "Which metrics to include. Omit for all."]
        let date: [String: Any] = ["type": "string", "description": "YYYY-MM-DD; today if omitted"]
        let modes = RingInputMode.x5.map(\.rawValue)
        return [
            DeviceCapability(
                name: "x5_get_status",
                description: "X5 smart ring status: connection, battery (percent, charging, voltage), firmware, MAC, "
                    + "features it answered for, gesture mode and touch-awake time, monitoring schedules, the live "
                    + "readings, the last spot measurement, last sync and today's summary. Works with the ring away.",
                inputSchema: DeviceCapability.schema()),
            DeviceCapability(
                name: "x5_get_day",
                description: "One local day of X5 data: summary (steps, energy, sleep stages, heart rate, SpO2, HRV, "
                    + "stress, temperature, blood-pressure estimate); detail=true adds the series.",
                inputSchema: DeviceCapability.schema(["date": date, "metrics": metrics,
                                                      "detail": ["type": "boolean"]])),
            DeviceCapability(
                name: "x5_get_health_day",
                description: "One local day of X5 data in the health SDK's wire shape (as ring_get_health_day).",
                inputSchema: DeviceCapability.schema(["date": date])),
            DeviceCapability(
                name: "x5_get_history",
                description: "Daily summaries for the last N days (max 30) from the phone's X5 history.",
                inputSchema: DeviceCapability.schema(["days": ["type": "integer", "minimum": 1, "maximum": 30],
                                                      "metrics": metrics])),
            DeviceCapability(
                name: "x5_sync",
                description: "Pull new history off the X5 now (steps, sleep, heart rate, HRV, temperature, SpO2).",
                inputSchema: DeviceCapability.schema(["days": ["type": "integer"]])),
            DeviceCapability(
                name: "x5_measure",
                description: "Take a spot reading on the X5. heart_rate and spo2 take about 30 s and may return "
                    + "status 'measuring' — read the result from x5_get_status.last_measurement.",
                inputSchema: DeviceCapability.schema(["type": ["type": "string", "enum": Array(Self.measurementNames.keys).sorted()]],
                                                     required: ["type"])),
            DeviceCapability(
                name: "x5_workout",
                description: "Run a workout on the X5: start (with sport), pause, resume, end, status. Opens the "
                    + "live workout screen on the phone and saves it to Jarvis Health.",
                inputSchema: DeviceCapability.schema([
                    "action": ["type": "string", "enum": ["start", "pause", "resume", "end", "status"]],
                    "sport": ["type": "string", "enum": X5Sport.allCases.map(\.name)],
                ], required: ["action"])),
            DeviceCapability(
                name: "x5_set_monitoring",
                description: "Turn the X5's automatic heart-rate, HRV or SpO2 measuring on/off and set its interval.",
                inputSchema: DeviceCapability.schema([
                    "metric": ["type": "string", "enum": ["heart_rate", "hrv", "spo2"]],
                    "enabled": ["type": "boolean"],
                    "interval_minutes": ["type": "integer", "minimum": 1, "maximum": 1440],
                    "start": ["type": "string", "description": "24-hour HH:MM"],
                    "end": ["type": "string", "description": "24-hour HH:MM"],
                ], required: ["metric", "enabled"])),
            DeviceCapability(
                name: "x5_set_gesture_mode",
                description: "What the X5's touch surface does: jarvis (each gesture runs its action), short_videos, "
                    + "music and camera (the ring acts as a Bluetooth keyboard for iOS), or off; and how long touch "
                    + "stays awake (1, 5, 30 minutes or 'always').",
                inputSchema: DeviceCapability.schema([
                    "mode": ["type": "string", "enum": modes],
                    "touch_awake": ["description": "1, 5, 30 or \"always\""],
                ], required: ["mode"])),
            DeviceCapability(
                name: "x5_set_gesture_action",
                description: "Set what one X5 gesture runs in jarvis mode: a Jarvis prompt, one of the phone's actions "
                    + "(skill = an action id such as play_pause, next_track, previous_track, set_timer), or none.",
                inputSchema: DeviceCapability.schema([
                    "gesture": ["type": "string", "enum": Array(Self.gestureNames.keys).sorted()],
                    "prompt": ["type": "string"],
                    "skill": ["type": "string"],
                    "arguments": ["type": "object"],
                    "none": ["type": "boolean"],
                ], required: ["gesture"])),
            DeviceCapability(
                name: "x5_find",
                description: "Make the X5 easy to find: lights its green sensor for 30 seconds.",
                inputSchema: DeviceCapability.schema()),
            DeviceCapability(
                name: "x5_set_profile",
                description: "Set the X5's profile: sex (male/female), age, height_cm, weight_kg, stride_cm.",
                inputSchema: DeviceCapability.schema([
                    "sex": ["type": "string", "enum": ["male", "female"]], "age": ["type": "integer"],
                    "height_cm": ["type": "integer"], "weight_kg": ["type": "integer"], "stride_cm": ["type": "integer"],
                ])),
            DeviceCapability(
                name: "x5_restart",
                description: "Restart the X5 (keeps its data).",
                inputSchema: DeviceCapability.schema()),
            DeviceCapability(
                name: "x5_get_log",
                description: "The X5's decoded command and gesture log, newest first.",
                inputSchema: DeviceCapability.schema(["limit": ["type": "integer", "minimum": 1, "maximum": 200]])),
        ]
    }

    func snapshot() -> [String: Any] {
        var out: [String: Any] = ["device_id": deviceID, "model": Self.model, "connected": isConnected]
        if let battery = session.battery { out["battery_percent"] = battery.percent }
        return out
    }

    // MARK: Invoke

    func invoke(_ name: String, args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "x5_get_status": return status()
        case "x5_get_day": return try await day(args)
        case "x5_get_health_day": return try await healthDay(args)
        case "x5_get_history": return try history(args)
        case "x5_sync": return try await syncNow()
        case "x5_measure": return try await measure(args)
        case "x5_workout": return try await workout(args)
        case "x5_set_monitoring": return try await setMonitoring(args)
        case "x5_set_gesture_mode": return try await setGestureMode(args)
        case "x5_set_gesture_action": return try setGestureAction(args)
        case "x5_find": return try await find()
        case "x5_set_profile": return try await setProfile(args)
        case "x5_restart":
            return try await live { _ in
                try await self.session.restart()
                return ["ok": true]
            }
        case "x5_get_log": return recentLog(args)
        default: throw DeviceError.unknownCommand(name)
        }
    }

    /// Runs `body` on a live link: reconnect on demand, wait for setup, release afterwards.
    private func live<T>(_ body: (_ secondsLeft: TimeInterval) async throws -> T) async throws -> T {
        let deadline = Date().addingTimeInterval(25)
        guard await backend.ensureConnected(timeout: 10) else { throw DeviceError.notConnected }
        defer { backend.releaseIfIdle() }
        await backend.waitForSetup(timeout: max(0, min(8, deadline.timeIntervalSinceNow - 10)))
        return try await body(max(0, deadline.timeIntervalSinceNow))
    }

    private func iso(_ date: Date) -> String { RingDayJSON.iso(date) }

    // MARK: Reads

    private func status() -> [String: Any] {
        var out: [String: Any] = [
            "device_id": deviceID,
            "model": Self.model,
            "connected": isConnected,
            "connection_state": backend.connectionText,
            "features": session.features.map(\.rawValue).sorted(),
            "gesture_mode": (backend.inputs?.wantedMode ?? .off).rawValue,
            "touch_awake": awakeJSON(backend.awakePolicy),
            "touch_asleep": session.touchAsleep,
            "wear": session.wear.rawValue,
            "monitoring": session.monitoring.values.sorted { $0.type.rawValue < $1.type.rawValue }.map(monitoringJSON),
        ]
        if let name = backend.displayName { out["name"] = name }
        if let battery = session.battery {
            out["battery_percent"] = battery.percent
            out["charging"] = battery.charging
        }
        if let mv = session.millivolts { out["battery_millivolts"] = mv }
        if let firmware = session.firmware { out["firmware_version"] = firmware.version }
        if let mac = session.mac { out["mac"] = mac }
        if let goal = session.goal { out["step_goal"] = goal }
        if let p = session.profile {
            out["profile"] = ["sex": p.male ? "male" : "female", "age": p.age, "height_cm": p.heightCm,
                              "weight_kg": p.weightKg, "stride_cm": p.strideCm]
        }
        if let l = session.live {
            out["live"] = ["steps": l.steps, "kilocalories": l.kcal, "distance_km": l.km, "heart_rate": l.heartRate,
                           "spo2": l.spo2, "temperature_c": l.celsius, "exercise_minutes": l.exerciseMinutes]
        }
        if let m = session.measurement { out["last_measurement"] = measurementJSON(m) }
        if let last = backend.sync.lastSync { out["last_sync"] = iso(last) }
        if backend.sync.isSyncing { out["syncing"] = true }
        if let store = backend.store {
            out["today"] = RingDayJSON.summary(store.day(RingDates.dayKey(Date())).summary, metrics: nil)
        }
        return out
    }

    private func dayKey(_ args: [String: Any]) throws -> (key: String, daysAgo: Int) {
        let key = (args["date"] as? String)?.trimmingCharacters(in: .whitespaces) ?? RingDates.dayKey(Date())
        guard let daysAgo = RingDates.daysAgo(key: key) else { throw DeviceError.badArgument("'date' must be YYYY-MM-DD") }
        return (key, daysAgo)
    }

    /// Today's data is synced first when it is stale and the ring is here, for up to `seconds`.
    private func freshen(daysAgo: Int, seconds: TimeInterval) async {
        guard daysAgo == 0, backend.isConnected, backend.sync.isStale else { return }
        var done = false
        Task { @MainActor in
            _ = await self.backend.sync.sync()
            done = true
        }
        let deadline = Date().addingTimeInterval(seconds)
        while !done, Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    private func day(_ args: [String: Any]) async throws -> [String: Any] {
        let (key, daysAgo) = try dayKey(args)
        let metrics = try RingDayJSON.parseMetrics(args["metrics"])
        let detail = args["detail"] as? Bool ?? false
        guard let store = backend.store else {
            return ["date": key, "connected": isConnected, "note": "no X5 data yet — the ring has never connected"]
        }
        await freshen(daysAgo: daysAgo, seconds: 20)
        let value = store.day(key)
        var out: [String: Any] = ["date": key, "connected": isConnected,
                                  "summary": RingDayJSON.summary(value.summary, metrics: metrics)]
        if let synced = value.syncedAt { out["synced_at"] = iso(synced) }
        if detail { out["detail"] = RingDayJSON.detail(value, metrics: metrics) }
        return out
    }

    private func healthDay(_ args: [String: Any]) async throws -> [String: Any] {
        let (key, daysAgo) = try dayKey(args)
        guard let store = backend.store else { throw DeviceError.notConnected }
        await freshen(daysAgo: daysAgo, seconds: 25)
        return HealthDayPayload.make(store.day(key), key: key, source: WearableKeepAlive.x5ring, battery: session.battery)
    }

    private func history(_ args: [String: Any]) throws -> [String: Any] {
        let days = max(1, min(30, args["days"] as? Int ?? 7))
        let metrics = try RingDayJSON.parseMetrics(args["metrics"])
        guard let store = backend.store else { return ["days": [Any](), "connected": isConnected] }
        let rows: [[String: Any]] = store.recentDays(days).map {
            ["date": $0.date, "summary": RingDayJSON.summary($0.summary, metrics: metrics)]
        }
        var out: [String: Any] = ["days": rows, "connected": isConnected]
        if let last = backend.sync.lastSync { out["last_sync"] = iso(last) }
        return out
    }

    private func syncNow() async throws -> [String: Any] {
        try await live { _ in
            switch await self.backend.sync.sync() {
            case .success(let keys):
                var out: [String: Any] = ["ok": true, "days_changed": keys.sorted()]
                if let last = self.backend.sync.lastSync { out["last_sync"] = self.iso(last) }
                return out
            case .failure(let error):
                throw error
            }
        }
    }

    private func recentLog(_ args: [String: Any]) -> [String: Any] {
        let limit = max(1, min(200, args["limit"] as? Int ?? 60))
        let rows = session.log.entries.prefix(limit).map { entry -> [String: Any] in
            var row: [String: Any] = ["at": iso(entry.date), "what": entry.title,
                                      "direction": entry.frame.cmd == 0 ? "note" : (entry.frame.outbound ? "out" : "in")]
            if !entry.detail.isEmpty { row["detail"] = entry.detail }
            if entry.frame.cmd != 0 { row["hex"] = entry.hex }
            return row
        }
        return ["entries": Array(rows), "connected": isConnected,
                "gesture_mode": (backend.inputs?.wantedMode ?? .off).rawValue]
    }

    // MARK: Ring actions

    private func measure(_ args: [String: Any]) async throws -> [String: Any] {
        guard let name = args["type"] as? String, let type = Self.measurementNames[name] else {
            throw DeviceError.badArgument("'type' must be one of " + Self.measurementNames.keys.sorted().joined(separator: ", "))
        }
        return try await live { secondsLeft in
            var result: Double?
            var finished = false
            Task { @MainActor in
                result = try? await self.session.measure(type)
                finished = true
            }
            let deadline = Date().addingTimeInterval(max(1, secondsLeft - 1))
            while !finished, Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard finished else { return ["status": "measuring", "type": name] }
            guard let result else {
                return ["status": "failed", "type": name, "detail": self.session.measurement?.failed ?? "no reading"]
            }
            return ["status": "done", "type": name, "value": result]
        }
    }

    private func find() async throws -> [String: Any] {
        try await live { _ in
            guard self.session.measurement?.isActive != true else { return ["ok": true, "note": "already measuring"] }
            Task { @MainActor in _ = try? await self.session.measure(.heartRate) }
            return ["ok": true, "note": "the X5's green sensor is lit for 30 seconds"]
        }
    }

    private func workout(_ args: [String: Any]) async throws -> [String: Any] {
        let actions: [String: UInt8] = ["start": 1, "pause": 2, "resume": 3, "end": 4, "status": 5]
        guard let name = args["action"] as? String, let action = actions[name] else {
            throw DeviceError.badArgument("'action' must be start, pause, resume, end or status")
        }
        let sport = (args["sport"] as? String).flatMap(X5Sport.named) ?? .walk
        if action == 1, args["sport"] != nil, X5Sport.named(args["sport"] as? String ?? "") == nil {
            throw DeviceError.badArgument("unknown sport. Use: " + X5Sport.allCases.map(\.name).joined(separator: ", "))
        }
        if let controller = backend.workouts { return workout(name, sport: sport, controller) }
        return try await live { _ in
            let reply = try await self.session.workout(action, sport: sport)
            var out: [String: Any] = ["ok": reply.ok, "action": name]
            if action == 1 { out["sport"] = sport.name }
            if let start = reply.start { out["started_at"] = self.iso(start) }
            if !reply.ok, action == 1 { out["detail"] = "the ring is busy — a measurement or another workout is running" }
            return out
        }
    }

    /// Through the workout controller, as `ring_workout` does: a 3-second countdown, the live
    /// sheet on the phone, and the workout saved to Jarvis Health at the end.
    private func workout(_ action: String, sport: X5Sport, _ controller: RingWorkoutController) -> [String: Any] {
        if action == "start" {
            if controller.isActive { return Self.status(controller, note: "a workout is already running") }
            controller.nextStartWearable = WearableKeepAlive.x5ring
            controller.nextStartUsesRing = true
            controller.start(X5WorkoutWearable.sport(for: sport))
            return ["ok": true, "action": action, "status": "starting", "sport": sport.name,
                    "note": "3-second countdown, then the X5 starts; the live workout screen opens on the phone"]
        }
        if controller.isActive, controller.wearable.kind != WearableKeepAlive.x5ring {
            return Self.status(controller, note: "the workout running is not on the X5")
        }
        switch action {
        case "pause": controller.pause()
        case "resume": controller.resume()
        case "end": controller.end()
        default: break
        }
        return Self.status(controller)
    }

    private static func status(_ controller: RingWorkoutController, note: String? = nil) -> [String: Any] {
        var out: [String: Any] = ["ok": true, "phase": "\(controller.phase)".components(separatedBy: "(").first ?? "idle"]
        if let sport = controller.sport { out["sport"] = sport.name }
        if let tick = controller.tick {
            out["elapsed_seconds"] = tick.elapsed
            out["steps"] = tick.steps
            out["kilocalories"] = tick.kilocalories
            out["distance_m"] = controller.gpsDistance ?? Double(tick.distanceMeters)
            if let hr = tick.heartRate { out["heart_rate"] = hr }
        }
        if let note { out["note"] = note }
        return out
    }

    private func setMonitoring(_ args: [String: Any]) async throws -> [String: Any] {
        guard let name = args["metric"] as? String, let type = Self.monitorNames[name] else {
            throw DeviceError.badArgument("'metric' must be heart_rate, hrv or spo2")
        }
        guard let enabled = args["enabled"] as? Bool else { throw DeviceError.badArgument("'enabled' is required") }
        var m = session.monitoring[type] ?? X5Session.defaultMonitoring.first { $0.type == type }!
        m.on = enabled
        if let interval = args["interval_minutes"] as? Int { m.intervalMinutes = max(1, min(1440, interval)) }
        if let start = args["start"] as? String { (m.startHour, m.startMinute) = try clock(start) }
        if let end = args["end"] as? String { (m.endHour, m.endMinute) = try clock(end) }
        let monitoring = m
        return try await live { _ in
            try await self.session.setMonitoring(monitoring)
            return ["ok": true, "monitoring": self.monitoringJSON(monitoring)]
        }
    }

    private func setGestureMode(_ args: [String: Any]) async throws -> [String: Any] {
        guard let raw = args["mode"] as? String, let mode = RingInputMode(rawValue: raw), RingInputMode.x5.contains(mode) else {
            throw DeviceError.badArgument("'mode' must be one of " + RingInputMode.x5.map(\.rawValue).joined(separator: ", "))
        }
        guard let inputs = backend.inputs else { throw DeviceError.notConnected }
        if let awake = args["touch_awake"] {
            guard let policy = Self.awakePolicy(awake) else {
                throw DeviceError.badArgument("'touch_awake' must be 1, 5, 30 or \"always\"")
            }
            backend.setAwakePolicy(policy)
        }
        inputs.setMode(mode)
        await backend.applyInputMode()
        return ["ok": true, "gesture_mode": mode.rawValue, "touch_awake": awakeJSON(backend.awakePolicy),
                "note": mode == .jarvis || mode == .off ? "" : "pair the ring in iOS Settings → Bluetooth for this mode"]
    }

    private func setGestureAction(_ args: [String: Any]) throws -> [String: Any] {
        guard let name = args["gesture"] as? String, let input = Self.gestureNames[name] else {
            throw DeviceError.badArgument("'gesture' must be one of " + Self.gestureNames.keys.sorted().joined(separator: ", "))
        }
        guard let inputs = backend.inputs else { throw DeviceError.notConnected }
        let action: RingAction
        if let prompt = args["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            action = .prompt(prompt)
        } else if let skill = args["skill"] as? String {
            guard RingActionCatalogue.option(skill) != nil else {
                throw DeviceError.badArgument("unknown action '\(skill)'. Use: "
                    + RingActionCatalogue.options.map(\.id).joined(separator: ", "))
            }
            let raw = args["arguments"] as? [String: Any] ?? [:]
            action = .skill(id: skill, arguments: raw.mapValues { "\($0)" })
        } else if args["none"] as? Bool == true {
            action = .none
        } else {
            throw DeviceError.badArgument("give one of 'prompt', 'skill' or 'none': true")
        }
        inputs.set(action, for: input)
        return ["ok": true, "gesture": name, "action": action.summary]
    }

    private func setProfile(_ args: [String: Any]) async throws -> [String: Any] {
        var p = session.profile ?? X5Profile(male: true, age: 30, heightCm: 175, weightKg: 70, strideCm: 70)
        if let sex = args["sex"] as? String { p.male = sex.lowercased() == "male" }
        if let v = args["age"] as? Int { p.age = v }
        if let v = args["height_cm"] as? Int { p.heightCm = v }
        if let v = args["weight_kg"] as? Int { p.weightKg = v }
        if let v = args["stride_cm"] as? Int { p.strideCm = v }
        let profile = p
        return try await live { _ in
            try await self.session.setProfile(profile)
            return ["ok": true]
        }
    }

    // MARK: Helpers

    static func awakePolicy(_ raw: Any) -> X5AwakePolicy? {
        if let s = raw as? String {
            if s.lowercased() == "always" { return .always }
            return Int(s).flatMap { [1, 5, 30].contains($0) ? .minutes($0) : nil }
        }
        if let n = raw as? Int, [1, 5, 30].contains(n) { return .minutes(n) }
        return nil
    }

    private func awakeJSON(_ policy: X5AwakePolicy) -> Any {
        switch policy {
        case .always: return "always"
        case .minutes(let m): return m
        }
    }

    private func monitoringJSON(_ m: X5Monitoring) -> [String: Any] {
        let name = Self.monitorNames.first { $0.value == m.type }?.key ?? "\(m.type)"
        return ["metric": name, "enabled": m.on, "interval_minutes": m.intervalMinutes,
                "start": String(format: "%02d:%02d", m.startHour, m.startMinute),
                "end": String(format: "%02d:%02d", m.endHour, m.endMinute)]
    }

    private func measurementJSON(_ m: X5Measurement) -> [String: Any] {
        var out: [String: Any] = ["metric": m.type.name, "status": m.isActive ? "measuring" : (m.result != nil ? "done" : "failed"),
                                  "started_at": iso(m.startedAt)]
        if let r = m.result { out[m.type == .temperature ? "value_celsius" : "value"] = r }
        if let latest = m.latest, m.isActive { out["latest"] = latest }
        if let failed = m.failed { out["detail"] = failed }
        return out
    }

    private func clock(_ raw: String) throws -> (Int, Int) {
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
            throw DeviceError.badArgument("times must be HH:MM (24-hour)")
        }
        return (parts[0], parts[1])
    }

    // MARK: Default gestures

    /// What a fresh X5 does in Jarvis mode, until the user changes it: play/pause on a tap, a
    /// heart-rate check on a double tap, tracks on left/right, a check-in on a long press.
    static func seedDefaultInputs(_ store: RingInputStore?, deviceID: String? = nil) {
        guard let store, !store.isConfigured else { return }
        store.set(.skill(id: "play_pause", arguments: [:]), for: .tap)
        store.set(.skill(id: "previous_track", arguments: [:]), for: .swipeLeft)
        store.set(.skill(id: "next_track", arguments: [:]), for: .swipeRight)
        store.set(.prompt("How am I doing today?"), for: .longPress)
        if let deviceID {
            store.set(.wearable(deviceID: deviceID, skill: "x5_measure", arguments: ["type": "heart_rate"]), for: .doubleTap)
        }
    }
}

extension X5Sport {
    /// The snake_case name skills use ("ping_pong", "rope_jump").
    var name: String {
        String(describing: self).reduce(into: "") { out, c in
            if c.isUppercase { out += "_" + c.lowercased() } else { out.append(c) }
        }
    }

    static func named(_ raw: String) -> X5Sport? {
        let wanted = raw.lowercased().filter { $0.isLetter }
        return allCases.first { $0.name.filter(\.isLetter) == wanted || $0.label.lowercased().filter(\.isLetter) == wanted }
    }
}
