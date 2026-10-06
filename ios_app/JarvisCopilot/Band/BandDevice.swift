import Foundation

/// What `BandDevice` needs from the app: the link, the session, sync and history.
@MainActor
protocol BandBackend: AnyObject {
    var deviceID: String? { get }
    var isConnected: Bool { get }
    var connectionText: String { get }
    var displayName: String? { get }
    var session: BandSession { get }
    var sync: BandSync { get }
    var store: RingHistoryStore? { get }
    /// The workout controller, when the app runs one.
    var workouts: RingWorkoutController? { get }
    func ensureConnected(timeout: TimeInterval) async -> Bool
    func waitForSetup(timeout: TimeInterval) async
    func releaseIfIdle()
}

extension BandManager: BandBackend {
    var isConnected: Bool { state == .ready }
    var connectionText: String { state.text }
    var displayName: String? { connected?.name }
}

/// Exposes the HBand (Veepoo) band to Jarvis as `band_*` skills.
///
/// Day, health-day and history answer in the R12's `ring_*` shapes (every ring and the band
/// store `RingDay`s), so the server reads them through one adapter. Reads work with the band
/// away; anything that touches it reconnects on demand within the bridge's 30 s. A function the
/// band reports it doesn't have says so instead of pretending.
@MainActor
final class BandDevice: WearableDevice {
    static let model = "HBand smart band"
    static let fallbackName = "Smart band"

    private unowned let backend: BandBackend

    init(backend: BandBackend) {
        self.backend = backend
    }

    var deviceID: String { backend.deviceID ?? WearableKeepAlive.band }
    var isConnected: Bool { backend.isConnected }
    private var session: BandSession { backend.session }

    static let weekdays = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    // MARK: Catalogue

    var capabilities: [DeviceCapability] {
        let metricNames = RingMetric.allCases.map(\.rawValue)
        let metrics: [String: Any] = ["type": "array", "items": ["type": "string", "enum": metricNames],
                                      "description": "Which metrics to include. Omit for all."]
        let date: [String: Any] = ["type": "string", "description": "YYYY-MM-DD; today if omitted"]
        let clock: [String: Any] = ["type": "string", "description": "24-hour HH:MM"]
        return [
            DeviceCapability(
                name: "band_get_status",
                description: "Smart band status: connection, battery (percent, charging), firmware, MAC, the functions it "
                    + "supports, its settings, the last spot measurement, last sync and today's summary. Works with the band away.",
                inputSchema: DeviceCapability.schema()),
            DeviceCapability(
                name: "band_get_day",
                description: "One local day of band data: summary (steps, energy, sleep stages, heart rate, SpO2, HRV, "
                    + "temperature, blood pressure); detail=true adds the series.",
                inputSchema: DeviceCapability.schema(["date": date, "metrics": metrics, "detail": ["type": "boolean"]])),
            DeviceCapability(
                name: "band_get_health_day",
                description: "One local day of band data in the health SDK's wire shape (as ring_get_health_day).",
                inputSchema: DeviceCapability.schema(["date": date])),
            DeviceCapability(
                name: "band_get_history",
                description: "Daily summaries for the last N days (max 30) from the phone's band history.",
                inputSchema: DeviceCapability.schema(["days": ["type": "integer", "minimum": 1, "maximum": 30],
                                                      "metrics": metrics])),
            DeviceCapability(
                name: "band_sync",
                description: "Pull new history off the band now (it keeps three days: steps, sleep, heart rate, blood "
                    + "pressure, SpO2, temperature).",
                inputSchema: DeviceCapability.schema(["days": ["type": "integer", "minimum": 1, "maximum": 3]])),
            DeviceCapability(
                name: "band_measure",
                description: "Take a spot reading on the band: " + BandMeasure.allCases.map(\.name).joined(separator: ", ")
                    + ". Heart rate and SpO2 take 10-30 s, blood pressure about 55 s, ECG and body composition up to 2 min "
                    + "(a finger on the band's electrode). Answers the result (status done, failed, busy or not_worn, with "
                    + "failure saying why), or still_measuring with check_again_in_seconds: then band_get_status's "
                    + "last_measurement has it.",
                inputSchema: DeviceCapability.schema(["type": ["type": "string", "enum": BandMeasure.allCases.map(\.name)]],
                                                     required: ["type"])),
            DeviceCapability(
                name: "band_workout",
                description: "Run a workout on the band: start (with sport), pause, resume, end, status. Opens the live "
                    + "workout screen on the phone and saves it to Jarvis Health.",
                inputSchema: DeviceCapability.schema([
                    "action": ["type": "string", "enum": ["start", "pause", "resume", "end", "status"]],
                    "sport": ["type": "string", "description": "For start: "
                        + RingSport.all.map { $0.name.lowercased() }.joined(separator: ", ") + ". Default walk."],
                ], required: ["action"])),
            DeviceCapability(
                name: "band_find",
                description: "Make the band easy to find: it vibrates until found (pressed), stopped or "
                    + "timed out. stop: true stops it.",
                inputSchema: DeviceCapability.schema(["stop": ["type": "boolean"]])),
            DeviceCapability(
                name: "band_set_alerts",
                description: "Which phone alerts vibrate the band: calls, messages, and apps by name "
                    + "(whatsapp, wechat, telegram, instagram, facebook, messenger…). apps: [] turns every app off.",
                inputSchema: DeviceCapability.schema([
                    "calls": ["type": "boolean"], "messages": ["type": "boolean"],
                    "apps": ["type": "array", "items": ["type": "string"]],
                ])),
            DeviceCapability(
                name: "band_set_alarm",
                description: "The band's silent vibration alarms: list, add (time, days, enabled) or delete (id). No days "
                    + "means a one-off alarm.",
                inputSchema: DeviceCapability.schema([
                    "action": ["type": "string", "enum": ["list", "add", "delete"]],
                    "time": clock, "days": ["type": "array", "items": ["type": "string", "enum": Self.weekdays]],
                    "id": ["type": "integer"], "enabled": ["type": "boolean"],
                ], required: ["action"])),
            DeviceCapability(
                name: "band_set_sedentary",
                description: "The band's 'you've been sitting' nudge: on/off, how long a sit counts (minutes) and the "
                    + "hours it's active.",
                inputSchema: DeviceCapability.schema([
                    "enabled": ["type": "boolean"], "interval_minutes": ["type": "integer", "minimum": 30, "maximum": 240],
                    "start": clock, "end": clock,
                ], required: ["enabled"])),
            DeviceCapability(
                name: "band_set_profile",
                description: "Set the band's profile (its steps, calories and sleep use it): sex (male/female), age, "
                    + "height_cm, weight_kg.",
                inputSchema: DeviceCapability.schema([
                    "sex": ["type": "string", "enum": ["male", "female"]], "age": ["type": "integer"],
                    "height_cm": ["type": "integer"], "weight_kg": ["type": "integer"],
                ])),
            DeviceCapability(
                name: "band_set_monitoring",
                description: "Turn one of the band's automatic measurements on/off: heart rate, HRV, PPG, blood "
                    + "pressure, SpO2 (a start/end window, overnight by default), the low-SpO2 alert, blood glucose, "
                    + "blood components, temperature, stress or MET. The band picks its own interval (about 10 minutes).",
                inputSchema: DeviceCapability.schema([
                    "metric": ["type": "string", "enum": ["spo2"] + BandDevice.monitorSwitches.keys.sorted()],
                    "enabled": ["type": "boolean"], "interval_minutes": ["type": "integer"],
                    "start": clock, "end": clock,
                ], required: ["metric", "enabled"])),
            DeviceCapability(
                name: "band_set_heart_rate_alarm",
                description: "Vibrate when heart rate goes above high or below low (bpm).",
                inputSchema: DeviceCapability.schema([
                    "enabled": ["type": "boolean"], "high": ["type": "integer", "minimum": 80, "maximum": 220],
                    "low": ["type": "integer", "minimum": 30, "maximum": 100],
                ], required: ["enabled"])),
            DeviceCapability(
                name: "band_set_raise_to_wake",
                description: "Turn the band's raise-the-wrist wake on or off.",
                inputSchema: DeviceCapability.schema(["enabled": ["type": "boolean"]], required: ["enabled"])),
            DeviceCapability(
                name: "band_set_skin_tone",
                description: "Tell the band's optical sensor the wearer's skin tone, 1 (lightest) to 6 (darkest).",
                inputSchema: DeviceCapability.schema(["level": ["type": "integer", "minimum": 1, "maximum": 6]],
                                                     required: ["level"])),
            DeviceCapability(
                name: "band_camera",
                description: "Put the band in camera-remote mode (on) or out of it (off).",
                inputSchema: DeviceCapability.schema(["on": ["type": "boolean"]], required: ["on"])),
            DeviceCapability(
                name: "band_clear_data",
                description: "Factory-reset the band: erases its stored history and settings (the phone's copy of the "
                    + "history stays). Only when the user explicitly asks for it.",
                inputSchema: DeviceCapability.schema(["confirm": ["type": "boolean", "description": "Must be true"]],
                                                     required: ["confirm"])),
            DeviceCapability(
                name: "band_get_log",
                description: "The band's raw command log (hex frames both ways), newest first.",
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
        case "band_get_status": return status()
        case "band_get_day": return try await day(args)
        case "band_get_health_day": return try await healthDay(args)
        case "band_get_history": return try history(args)
        case "band_sync": return await syncNow(args)
        case "band_measure": return try await measure(args)
        case "band_workout": return try await workout(args)
        case "band_find":
            let stop = args["stop"] as? Bool ?? false
            return try await live { _ in
                try await self.session.find(!stop)
                return ["ok": true, "finding": self.session.finding]
            }
        case "band_set_alerts": return try await setAlerts(args)
        case "band_set_alarm": return try await alarm(args)
        case "band_set_sedentary": return try await sedentary(args)
        case "band_set_profile": return try await setProfile(args)
        case "band_set_monitoring": return try await monitoring(args)
        case "band_set_heart_rate_alarm":
            try requires("heartRateAlarmType", "a heart-rate alarm")
            guard let enabled = args["enabled"] as? Bool else { throw DeviceError.badArgument("'enabled' is required") }
            let high = max(80, min(220, args["high"] as? Int ?? 150))
            let low = max(30, min(100, args["low"] as? Int ?? 50))
            return try await live { _ in
                try await self.session.setHeartRateAlarm(enabled: enabled, high: high, low: low)
                return ["ok": true, "enabled": enabled, "high": high, "low": low]
            }
        case "band_set_raise_to_wake":
            guard let enabled = args["enabled"] as? Bool else { throw DeviceError.badArgument("'enabled' is required") }
            return try await live { _ in
                try await self.session.setRaiseToWake(enabled)
                return ["ok": true, "enabled": enabled]
            }
        case "band_set_skin_tone":
            try requires("skinColorType", "a skin-tone setting")
            guard let level = args["level"] as? Int, (1...6).contains(level) else {
                throw DeviceError.badArgument("'level' must be 1-6")
            }
            return try await live { _ in
                try await self.session.setSkinTone(level)
                return ["ok": true, "level": level]
            }
        case "band_camera":
            try requires("cameraType", "a camera remote")
            guard let on = args["on"] as? Bool else { throw DeviceError.badArgument("'on' is required") }
            return try await live { _ in
                try await self.session.setCamera(on)
                return ["ok": true, "on": on]
            }
        case "band_clear_data":
            guard args["confirm"] as? Bool == true else {
                throw DeviceError.badArgument("this factory-resets the band — pass confirm: true only if the user asked")
            }
            return try await live { _ in
                try await self.session.clearData()
                return ["ok": true]
            }
        case "band_get_log": return recentLog(args)
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

    /// A function the band reported it doesn't have is refused plainly.
    private func requires(_ feature: String, _ what: String) throws {
        guard session.supports(feature) else { throw DeviceError.badArgument("this band doesn't have \(what)") }
    }

    private func iso(_ date: Date) -> String { RingDayJSON.iso(date) }

    // MARK: Reads

    private func status() -> [String: Any] {
        var out: [String: Any] = [
            "device_id": deviceID,
            "model": Self.model,
            "connected": isConnected,
            "connection_state": backend.connectionText,
        ]
        out["name"] = backend.displayName ?? WearableNames.shared.name(WearableKeepAlive.band, fallback: Self.fallbackName)
        if let battery = session.battery {
            out["battery_percent"] = battery.percent
            out["charging"] = battery.charging
        }
        if let shake = session.handshake {
            out["firmware_version"] = shake.firmware
            out["mac"] = shake.mac
        }
        if let features = session.features { out["features"] = features.json }
        if let settings = session.settings { out["settings"] = settings.json }
        if let alerts = session.alerts { out["alerts"] = alerts.json }
        if let reading = session.lastReading { out["last_measurement"] = reading.json }
        if let running = session.measuring { out["measuring"] = running.name }
        if let hr = session.liveHeartRate { out["live_heart_rate"] = hr }
        if session.finding { out["finding"] = true }
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

    /// Recent days are synced first when stale and the band is here, for up to `seconds`.
    private func freshen(daysAgo: Int, seconds: TimeInterval) async {
        guard daysAgo <= 2, backend.isConnected, backend.sync.isStale else { return }
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
            return ["date": key, "connected": isConnected, "note": "no band data yet — the band has never connected"]
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
        return HealthDayPayload.make(store.day(key), key: key, source: WearableKeepAlive.band, battery: session.battery)
    }

    private func history(_ args: [String: Any]) throws -> [String: Any] {
        let days = max(1, min(30, args["days"] as? Int ?? 7))
        let metrics = try RingDayJSON.parseMetrics(args["metrics"])
        guard let store = backend.store else { return ["days": [Any](), "connected": isConnected] }
        let rows: [[String: Any]] = store.recentDays(days).map {
            ["date": $0.date, "timezone": TimeZone.current.identifier,
             "summary": RingDayJSON.summary($0.summary, metrics: metrics)]
        }
        var out: [String: Any] = ["days": rows, "connected": isConnected]
        if let last = backend.sync.lastSync { out["last_sync"] = iso(last) }
        return out
    }

    /// `ok: false` when the band can't be reached — how the server tells that from an empty day.
    private func syncNow(_ args: [String: Any]) async -> [String: Any] {
        let days = max(1, min(3, args["days"] as? Int ?? 3))
        guard await backend.ensureConnected(timeout: 10) else {
            return ["ok": false, "error": "the band isn't reachable — bring it close and try again"]
        }
        defer { backend.releaseIfIdle() }
        await backend.waitForSetup(timeout: 8)
        // Three days of history can outlast the bridge's 30 s: answer within 15 s either way.
        var keys: Set<String>?
        let sync = backend.sync
        Task { @MainActor in keys = await sync.sync(days: days) }
        let deadline = Date().addingTimeInterval(15)
        while keys == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
        guard let keys else {
            return ["ok": true, "finished": false, "note": "still syncing in the background — check band_get_status.last_sync"]
        }
        guard sync.lastReached else {
            return ["ok": false, "error": "the band didn't answer the history reads — try again with it close"]
        }
        var out: [String: Any] = ["ok": true, "finished": true, "days_changed": keys.sorted()]
        if let last = sync.lastSync { out["last_sync"] = iso(last) }
        return out
    }

    // MARK: Measure

    private func measure(_ args: [String: Any]) async throws -> [String: Any] {
        guard let name = args["type"] as? String, let type = BandMeasure.allCases.first(where: { $0.name == name }) else {
            throw DeviceError.badArgument("'type' must be one of " + BandMeasure.allCases.map(\.name).joined(separator: ", "))
        }
        guard !(backend.workouts?.holdsLink(for: WearableKeepAlive.band) ?? false) else {
            throw DeviceError.badArgument("a workout is using the band's sensor — readings wait until it ends")
        }
        return try await live { secondsLeft in
            // The reading runs on the phone for as long as it takes (blood pressure ~55 s, ECG up
            // to 2 min — longer than a skill may wait), holding the link while it does; the skill
            // answers with it if it ends in time, else says it's still going.
            let started = Date()
            let outcome = MeasureOutcome()
            Task { @MainActor in
                do { outcome.result = .success(try await self.session.measure(type)) } catch { outcome.result = .failure(error) }
            }
            let wait = max(3, secondsLeft - 2)
            while outcome.result == nil, Date().timeIntervalSince(started) < wait {
                try? await Task.sleep(for: .milliseconds(250))
            }
            switch outcome.result {
            case .success(let reading): return ["ok": true, "measurement": reading.json]
            case .failure(let error): throw error
            case nil:
                var out: [String: Any] = ["ok": true, "still_measuring": true,
                                          "check_again_in_seconds": max(5, min(30, Int(type.timeout - Date().timeIntervalSince(started))))]
                if let now = self.session.lastReading, now.measure == type, now.date >= started { out["measurement"] = now.json }
                return out
            }
        }
    }

    /// What a reading the skill started ended as, once it has.
    private final class MeasureOutcome { var result: Result<BandReading, Error>? }

    // MARK: Workout

    /// Through the workout controller, as `ring_workout` does.
    private func workout(_ args: [String: Any]) async throws -> [String: Any] {
        guard let controller = backend.workouts else { throw DeviceError.badArgument("workouts aren't available here") }
        let action = args["action"] as? String ?? "status"
        if action == "start" {
            let asked = args["sport"] as? String ?? "walk"
            guard let sport = RingSport.named(asked) else {
                throw DeviceError.badArgument("no sport called \(asked); try " + RingSport.common.map(\.name).joined(separator: ", "))
            }
            if controller.isActive { return Self.workoutStatus(controller, note: "a workout is already running") }
            controller.nextStartWearable = WearableKeepAlive.band
            controller.nextStartUsesRing = true
            controller.start(sport)
            return ["ok": true, "action": action, "status": "starting", "sport": sport.name,
                    "note": "3-second countdown, then the band starts; the live workout screen opens on the phone"]
        }
        if controller.isActive, controller.wearable.kind != WearableKeepAlive.band {
            return Self.workoutStatus(controller, note: "the workout running is not on the band")
        }
        switch action {
        case "pause": controller.pause()
        case "resume": controller.resume()
        case "end": controller.end()
        default: break
        }
        return Self.workoutStatus(controller)
    }

    static func workoutStatus(_ controller: RingWorkoutController, note: String? = nil) -> [String: Any] {
        var out: [String: Any] = ["ok": true, "phase": "\(controller.phase)".components(separatedBy: "(").first ?? "idle"]
        if let sport = controller.sport { out["sport"] = sport.name }
        if let tick = controller.tick {
            out["elapsed_seconds"] = tick.elapsed
            out["steps"] = tick.steps
            out["distance_m"] = controller.gpsDistance ?? Double(tick.distanceMeters)
            if let hr = tick.heartRate { out["heart_rate"] = hr }
        }
        if let note { out["note"] = note }
        return out
    }

    // MARK: Settings

    private func setAlerts(_ args: [String: Any]) async throws -> [String: Any] {
        try requires("informationPushType", "phone alerts")
        // The band reports its switches in the handshake: change only the ones asked for.
        return try await live { _ in
            guard let current = self.session.alerts else { throw DeviceError.notConnected }
            guard let switches = BandAlertSwitches(json: args, base: current) else {
                throw DeviceError.badArgument("pass calls, messages and/or apps")
            }
            try await self.session.setAlerts(switches)
            return ["ok": true, "alerts": switches.json]
        }
    }

    private func alarm(_ args: [String: Any]) async throws -> [String: Any] {
        try requires("alarmClockType", "alarms")
        switch args["action"] as? String {
        case "list":
            return try await live { _ in
                ["ok": true, "alarms": try await self.session.readAlarms().map(\.json)]
            }
        case "add":
            guard let time = args["time"] as? String, (try? Self.clock(time)) != nil else {
                throw DeviceError.badArgument("'time' must be HH:MM (24-hour)")
            }
            if let days = args["days"] as? [String], let bad = days.first(where: { !Self.weekdays.contains($0) }) {
                throw DeviceError.badArgument("unknown day \(bad); use " + Self.weekdays.joined(separator: ", "))
            }
            return try await live { _ in
                let existing = try await self.session.readAlarms()
                var json = args
                json["id"] = json["id"] ?? ((existing.compactMap { $0.json["id"] as? Int }.max() ?? 0) + 1)
                guard let alarm = BandAlarm(json: json) else { throw DeviceError.badArgument("couldn't read that alarm") }
                try await self.session.setAlarm(alarm)
                return ["ok": true, "alarm": alarm.json]
            }
        case "delete":
            guard let id = args["id"] as? Int else { throw DeviceError.badArgument("'id' is required (from list)") }
            return try await live { _ in
                let existing = try await self.session.readAlarms()
                guard let alarm = existing.first(where: { $0.json["id"] as? Int == id }) else {
                    throw DeviceError.badArgument("no alarm with id \(id)")
                }
                try await self.session.deleteAlarm(alarm)
                return ["ok": true, "deleted": id]
            }
        default:
            throw DeviceError.badArgument("'action' must be list, add or delete")
        }
    }

    private func sedentary(_ args: [String: Any]) async throws -> [String: Any] {
        guard args["enabled"] is Bool else { throw DeviceError.badArgument("'enabled' is required") }
        for key in ["start", "end"] {
            if let value = args[key] as? String { _ = try Self.clock(value) }
        }
        guard let reminder = BandSedentary(json: args) else { throw DeviceError.badArgument("couldn't read that reminder") }
        return try await live { _ in
            try await self.session.setSedentary(reminder)
            return ["ok": true, "sedentary": reminder.json]
        }
    }

    private func setProfile(_ args: [String: Any]) async throws -> [String: Any] {
        var profile = BandProfile.current() ?? BandProfile(heightCm: 170, weightKg: 70, age: 30, male: true,
                                                           stepGoal: 10_000, sleepGoalMinutes: 480)
        if let sex = args["sex"] as? String {
            guard sex == "male" || sex == "female" else { throw DeviceError.badArgument("'sex' must be male or female") }
            profile.male = sex == "male"
        }
        if let age = args["age"] as? Int {
            guard (5...110).contains(age) else { throw DeviceError.badArgument("'age' must be 5-110") }
            profile.age = age
        }
        if let h = args["height_cm"] as? Int {
            guard (80...250).contains(h) else { throw DeviceError.badArgument("'height_cm' must be 80-250") }
            profile.heightCm = h
        }
        if let w = args["weight_kg"] as? Int {
            guard (20...250).contains(w) else { throw DeviceError.badArgument("'weight_kg' must be 20-250") }
            profile.weightKg = w
        }
        let chosen = profile
        return try await live { _ in
            try await self.session.setProfile(chosen)
            return ["ok": true, "profile": ["sex": chosen.male ? "male" : "female", "age": chosen.age,
                                            "height_cm": chosen.heightCm, "weight_kg": chosen.weightKg]]
        }
    }

    private func monitoring(_ args: [String: Any]) async throws -> [String: Any] {
        guard let metric = args["metric"] as? String else { throw DeviceError.badArgument("'metric' is required") }
        guard let enabled = args["enabled"] as? Bool else { throw DeviceError.badArgument("'enabled' is required") }
        if metric == "spo2" {
            try requires("bloodOxygenType", "SpO2")
            let start = try Self.clock(args["start"] as? String ?? "22:00")
            let end = try Self.clock(args["end"] as? String ?? "07:00")
            return try await live { _ in
                try await self.session.setBloodOxygenAuto(enabled: enabled, start: start, end: end)
                return ["ok": true, "metric": metric, "enabled": enabled]
            }
        }
        guard let name = Self.monitorSwitches[metric] else {
            throw DeviceError.badArgument("'metric' is one of spo2, \(Self.monitorSwitches.keys.sorted().joined(separator: ", "))")
        }
        return try await live { _ in
            guard let current = self.session.settings else { throw DeviceError.notConnected }
            var json: [String: Any] = [name: enabled]
            if let interval = args["interval_minutes"] as? Int { json["interval_minutes"] = interval }
            guard let updated = BandSettings(json: json, base: current) else {
                throw DeviceError.badArgument("the band has no automatic \(metric.replacingOccurrences(of: "_", with: " "))")
            }
            try await self.session.writeSettings(updated)
            return ["ok": true, "metric": metric, "enabled": enabled, "settings": updated.json]
        }
    }

    /// `band_set_monitoring`'s metrics → the `B8` switch each one is.
    static let monitorSwitches: [String: String] = [
        "heart_rate": "auto_heart_rate", "hrv": "auto_hrv", "ppg": "auto_ppg", "blood_pressure": "auto_blood_pressure",
        "low_spo2_alert": "low_spo2_alert", "blood_glucose": "auto_blood_glucose",
        "blood_component": "auto_blood_component", "temperature": "auto_temperature", "stress": "auto_stress",
        "met": "met",
    ]

    private func recentLog(_ args: [String: Any]) -> [String: Any] {
        let limit = max(1, min(200, args["limit"] as? Int ?? 60))
        let rows = session.log.prefix(limit).map { entry -> [String: Any] in
            ["at": iso(entry.date), "direction": entry.outgoing ? "out" : "in", "hex": entry.hex]
        }
        return ["entries": Array(rows), "connected": isConnected]
    }

    static func clock(_ text: String) throws -> (h: Int, m: Int) {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
            throw DeviceError.badArgument("times are 24-hour HH:MM")
        }
        return (parts[0], parts[1])
    }
}
