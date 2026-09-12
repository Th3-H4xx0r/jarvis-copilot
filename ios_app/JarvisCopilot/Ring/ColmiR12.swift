import Foundation

/// What `ColmiR12` needs from the app: the link, the protocol session, sync and history.
@MainActor
protocol RingBackend: AnyObject {
    var deviceID: String? { get }
    var isConnected: Bool { get }
    var connectionText: String { get }
    var displayName: String? { get }
    var session: RingSession { get }
    var sync: RingSync { get }
    var store: RingHistoryStore? { get }
    func ensureConnected(timeout: TimeInterval) async -> Bool
    func waitForSetup(timeout: TimeInterval) async
    func releaseIfIdle()
}

extension RingManager: RingBackend {
    var isConnected: Bool { state == .ready }
    var connectionText: String { state.text }
    var displayName: String? { connected?.name }
}

/// Exposes a QRing ring (Colmi R12 and the rest of the R series) to Jarvis as `ring_*` skills.
///
/// Reads work offline from the history store and cached state; everything that touches the
/// ring reconnects on demand. No skill blocks longer than ~25 s — the bridge gives an invoke 30.
@MainActor
final class ColmiR12: WearableDevice {
    static let model = "Colmi R12"

    private unowned let backend: RingBackend

    init(backend: RingBackend) {
        self.backend = backend
    }

    convenience init(manager: RingManager) {
        self.init(backend: manager)
    }

    var deviceID: String { backend.deviceID ?? "ring" }
    var isConnected: Bool { backend.isConnected }
    private var session: RingSession { backend.session }

    // MARK: Catalogue

    var capabilities: [DeviceCapability] {
        let metricNames = RingMetric.allCases.map(\.rawValue)
        let metricsSchema: [String: Any] = [
            "type": "array", "items": ["type": "string", "enum": metricNames],
            "description": "Which metrics to include. Omit for all.",
        ]
        let time: [String: Any] = ["type": "string", "description": "24-hour HH:MM"]
        return [
            DeviceCapability(
                name: "ring_get_status",
                description: "Smart ring status: connection, battery and charging, firmware, which metrics and "
                    + "measurements this ring supports, every current setting (monitoring switches and intervals, "
                    + "touch/gesture modes, goals, profile, do-not-disturb), last sync, the last on-demand "
                    + "measurement, and today's summary. Works while the ring is away (cached).",
                inputSchema: DeviceCapability.schema()),
            DeviceCapability(
                name: "ring_get_day",
                description: "One day of ring data — steps, calories, distance, sleep stages, heart rate, SpO₂, "
                    + "HRV, stress, temperature — as a summary, plus full series when detail is true. Syncs "
                    + "from the ring first when it is connected and the data is stale.",
                inputSchema: DeviceCapability.schema([
                    "date": ["type": "string", "description": "YYYY-MM-DD. Defaults to today."],
                    "metrics": metricsSchema,
                    "detail": ["type": "boolean", "description": "Include time series, sleep stages and step slots."],
                ])),
            DeviceCapability(
                name: "ring_get_history",
                description: "Daily summaries for recent days from the phone's ring history (steps, sleep, "
                    + "heart rate min/avg/max, SpO₂, HRV, stress, temperature).",
                inputSchema: DeviceCapability.schema([
                    "days": ["type": "integer", "description": "1–30, default 7. Today first."],
                    "metrics": metricsSchema,
                ])),
            DeviceCapability(
                name: "ring_sync",
                description: "Pull stored data from the ring now. days 0 = today only, up to 6 for the week the "
                    + "ring keeps. Returns what updated; a long sync finishes in the background.",
                inputSchema: DeviceCapability.schema([
                    "days": ["type": "integer", "minimum": 0, "maximum": 6],
                ])),
            DeviceCapability(
                name: "ring_measure",
                description: "Take a reading now with the ring's sensors (the ring must be worn). Returns the "
                    + "value, status not_worn, or status measuring — then read ring_get_status.last_measurement.",
                inputSchema: DeviceCapability.schema([
                    "metric": ["type": "string",
                               "enum": RingMeasurementType.allCases.map(\.name)],
                    "wait_seconds": ["type": "integer", "description": "How long to wait for the result, 0–25. Default 25."],
                ], required: ["metric"])),
            DeviceCapability(
                name: "ring_find",
                description: "Make the ring vibrate or flash so the user can find it.",
                inputSchema: DeviceCapability.schema()),
            DeviceCapability(
                name: "ring_set_monitoring",
                description: "Turn the ring's automatic background measurement on or off for one metric, and set "
                    + "how often it measures. Frequent heart-rate intervals cost ring battery.",
                inputSchema: DeviceCapability.schema([
                    "metric": ["type": "string", "enum": ["heart_rate", "spo2", "hrv", "stress", "temperature"]],
                    "enabled": ["type": "boolean"],
                    "interval_minutes": ["type": "integer",
                                         "description": "heart_rate 1–60; hrv 10–60; temperature 10, 30, 60 or 120."],
                ], required: ["metric", "enabled"])),
            DeviceCapability(
                name: "ring_set_touch_mode",
                description: "Choose what a tap/swipe (touch) or a double-tap gesture on the ring controls — "
                    + "music, short video, page turning, the camera shutter, a heart-rate reading — or off. "
                    + "ring_get_status.touch_modes lists what this ring offers.",
                inputSchema: DeviceCapability.schema([
                    "control": ["type": "string", "enum": ["touch", "gesture"]],
                    "mode": ["type": "string", "enum": RingTouchMode.offerable.map(\.name)],
                    "strength": ["type": "integer", "description": "Gesture sensitivity, 0–10."],
                ], required: ["control", "mode"])),
            DeviceCapability(
                name: "ring_set_goals",
                description: "Set daily goals on the ring. Unspecified goals keep their current values.",
                inputSchema: DeviceCapability.schema([
                    "steps": ["type": "integer"],
                    "calories": ["type": "integer", "description": "kcal"],
                    "distance_m": ["type": "integer"],
                    "sport_minutes": ["type": "integer"],
                    "sleep_minutes": ["type": "integer"],
                ])),
            DeviceCapability(
                name: "ring_set_profile",
                description: "Body profile and display units the ring uses for calories and distance. Unspecified "
                    + "fields keep their current values.",
                inputSchema: DeviceCapability.schema([
                    "sex": ["type": "string", "enum": ["male", "female"]],
                    "age": ["type": "integer"],
                    "height_cm": ["type": "integer"],
                    "weight_kg": ["type": "integer"],
                    "use_24h": ["type": "boolean"],
                    "metric_units": ["type": "boolean"],
                ])),
            DeviceCapability(
                name: "ring_set_preferences",
                description: "Temperature unit, do-not-disturb window and sedentary reminder. Only what is given changes.",
                inputSchema: DeviceCapability.schema([
                    "temperature_unit": ["type": "string", "enum": ["celsius", "fahrenheit"]],
                    "dnd": ["type": "object", "properties": [
                        "enabled": ["type": "boolean"], "start": time, "end": time,
                    ]],
                    "sedentary": ["type": "object", "properties": [
                        "enabled": ["type": "boolean"], "start": time, "end": time,
                        "interval_minutes": ["type": "integer", "enum": [30, 60, 90]],
                    ]],
                ])),
            DeviceCapability(
                name: "ring_power",
                description: "Power the ring off (it wakes on its charger) or factory-reset it, erasing its data "
                    + "and settings. confirm must be true.",
                inputSchema: DeviceCapability.schema([
                    "action": ["type": "string", "enum": ["power_off", "factory_reset"]],
                    "confirm": ["type": "boolean"],
                ], required: ["action", "confirm"])),
            DeviceCapability(
                name: "ring_get_log",
                description: "The ring's recent command and input log, decoded: what the phone sent, what "
                    + "the ring answered, and every tap it reported with the gap since the one before. "
                    + "Read this to diagnose gestures — whether a press reached the phone at all, and how "
                    + "far apart two of them landed.",
                inputSchema: DeviceCapability.schema([
                    "limit": ["type": "integer", "description": "Entries, newest first. 1–200, default 60."],
                ])),
            DeviceCapability(
                name: "ring_raw_command",
                description: "Protocol work only: send raw bytes and get the ring's replies as hex. hex = a command "
                    + "frame (opcode + payload; checksum added), or big_data_cmd + payload_hex for the large-data "
                    + "channel. See RING_PROTOCOL.md. confirm must be true.",
                inputSchema: DeviceCapability.schema([
                    "hex": ["type": "string"],
                    "big_data_cmd": ["type": "integer", "minimum": 0, "maximum": 255],
                    "payload_hex": ["type": "string"],
                    "confirm": ["type": "boolean"],
                ], required: ["confirm"])),
            DeviceCapability(
                name: "ring_firmware_update",
                description: "Flash a firmware image to the ring over its own BLE updater. image_b64 = the "
                    + ".bin (base64), or url to download it. The ring stages the image and only commits after "
                    + "its own checks, so a failed transfer leaves the running firmware intact. Takes minutes and "
                    + "runs in the background — watch ring_get_log; the ring reboots into the new image when done. "
                    + "confirm must be true.",
                inputSchema: DeviceCapability.schema([
                    "image_b64": ["type": "string", "description": "Firmware .bin as base64."],
                    "url": ["type": "string", "description": "HTTPS URL to download the .bin from instead."],
                    "confirm": ["type": "boolean"],
                ], required: ["confirm"])),
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
        case "ring_get_status": return status()
        case "ring_get_day": return try await day(args)
        case "ring_get_history": return try history(args)
        case "ring_sync": return try await syncNow(args)
        case "ring_measure": return try await measure(args)
        case "ring_find":
            return try await live { _ in
                try await self.session.findRing()
                return ["ok": true]
            }
        case "ring_set_monitoring": return try await setMonitoring(args)
        case "ring_set_touch_mode": return try await setTouchMode(args)
        case "ring_set_goals": return try await setGoals(args)
        case "ring_set_profile": return try await setProfile(args)
        case "ring_set_preferences": return try await setPreferences(args)
        case "ring_power": return try await power(args)
        case "ring_get_log": return recentLog(args)
        case "ring_raw_command": return try await raw(args)
        case "ring_firmware_update": return try await firmwareUpdate(args)
        default: throw DeviceError.unknownCommand(name)
        }
    }

    /// Runs `body` on a live link: reconnect on demand, wait for setup, release afterwards.
    /// The bridge gives an invoke 30 s, so connecting and setup come out of one 25 s budget and
    /// `body` gets the seconds left — at least 10 once the ring is connected.
    private func live<T>(_ body: (_ secondsLeft: TimeInterval) async throws -> T) async throws -> T {
        let deadline = Date().addingTimeInterval(25)
        guard await backend.ensureConnected(timeout: 10) else { throw DeviceError.notConnected }
        defer { backend.releaseIfIdle() }
        await backend.waitForSetup(timeout: max(0, min(8, deadline.timeIntervalSinceNow - 10)))
        return try await body(max(0, deadline.timeIntervalSinceNow))
    }

    /// Starts `work` and waits at most `seconds`; the work carries on if it takes longer.
    private func runBounded(_ seconds: TimeInterval, _ work: @escaping @MainActor () async -> Void) async -> Bool {
        var finished = false
        Task { @MainActor in
            await work()
            finished = true
        }
        let deadline = Date().addingTimeInterval(seconds)
        while !finished, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return finished
    }

    private func status() -> [String: Any] {
        let caps = session.capabilities
        var out: [String: Any] = [
            "device_id": deviceID,
            "model": Self.model,
            "connected": isConnected,
            "connection_state": backend.connectionText,
            "capabilities_known": caps.isKnown,
            "supported_metrics": RingMetric.allCases.filter { caps.supports($0) }.map(\.rawValue),
            "supported_measurements": caps.supportedMeasurements.map(\.name),
            "touch_modes": caps.touchModes.map(\.name),
            "settings": settingsJSON(),
        ]
        if let name = backend.displayName { out["name"] = name }
        if let battery = session.battery {
            out["battery_percent"] = battery.percent
            out["charging"] = battery.charging
        }
        if let firmware = session.firmware { out["firmware_version"] = firmware }
        if let hardware = session.hardware { out["hardware_version"] = hardware }
        if let measurement = session.measurement { out["last_measurement"] = measurementJSON(measurement) }
        if let last = backend.sync.lastTodaySync { out["last_sync"] = iso(last) }
        if backend.sync.isSyncing { out["syncing"] = true }
        if let store = backend.store {
            out["today"] = summaryJSON(store.day(RingDates.dayKey(Date())).summary, metrics: nil)
        }
        if let live = session.liveActivity { out["live_steps"] = live.steps }
        return out
    }

    private func day(_ args: [String: Any]) async throws -> [String: Any] {
        let key = (args["date"] as? String)?.trimmingCharacters(in: .whitespaces) ?? RingDates.dayKey(Date())
        guard let daysAgo = RingDates.daysAgo(key: key) else {
            throw DeviceError.badArgument("'date' must be YYYY-MM-DD")
        }
        let metrics = try parseMetrics(args["metrics"])
        let detail = args["detail"] as? Bool ?? false
        guard let store = backend.store else {
            return ["date": key, "connected": isConnected, "note": "no ring data yet — the ring has never connected"]
        }
        if (0...backend.sync.historyDays).contains(daysAgo), backend.isConnected, backend.sync.isStale {
            _ = await runBounded(20) { [backend] in _ = await backend.sync.sync(days: daysAgo) }
        }
        let value = store.day(key)
        var out: [String: Any] = ["date": key, "connected": isConnected,
                                  "summary": summaryJSON(value.summary, metrics: metrics)]
        if let synced = value.syncedAt { out["synced_at"] = iso(synced) }
        if detail { out["detail"] = detailJSON(value, metrics: metrics) }
        return out
    }

    /// The decoded log, so gesture behaviour can be read from here rather than relayed by hand.
    private func recentLog(_ args: [String: Any]) -> [String: Any] {
        let limit = max(1, min(200, args["limit"] as? Int ?? 60))
        let rows = session.log.entries.prefix(limit).map { entry -> [String: Any] in
            var row: [String: Any] = [
                "at": iso(entry.date),
                "what": entry.title,
                "direction": entry.frame.cmd == 0 ? "note" : (entry.frame.outbound ? "out" : "in"),
            ]
            if !entry.detail.isEmpty { row["detail"] = entry.detail }
            if entry.frame.cmd != 0 { row["hex"] = entry.hex }
            return row
        }
        return ["entries": Array(rows), "connected": isConnected,
                "gesture_mode": session.inputMode.rawValue]
    }

    private func history(_ args: [String: Any]) throws -> [String: Any] {
        let days = max(1, min(30, args["days"] as? Int ?? 7))
        let metrics = try parseMetrics(args["metrics"])
        guard let store = backend.store else { return ["days": [Any](), "connected": isConnected] }
        let rows: [[String: Any]] = store.recentDays(days).map {
            ["date": $0.date, "summary": summaryJSON($0.summary, metrics: metrics)]
        }
        var out: [String: Any] = ["days": rows, "connected": isConnected]
        if let last = backend.sync.lastTodaySync { out["last_sync"] = iso(last) }
        return out
    }

    private func syncNow(_ args: [String: Any]) async throws -> [String: Any] {
        let days = args["days"] as? Int ?? 0
        guard (0...6).contains(days) else { throw DeviceError.badArgument("'days' must be 0–6") }
        return try await live { secondsLeft in
            var report: RingSyncReport?
            let finished = await runBounded(max(2, secondsLeft)) { [backend] in
                report = await backend.sync.sync(days: days)
            }
            guard finished, let report else {
                return ["finished": false, "note": "still syncing in the background — check ring_get_status.last_sync"]
            }
            return ["finished": true, "days": days, "updated": report.updated, "failed": report.failed]
        }
    }

    private func measure(_ args: [String: Any]) async throws -> [String: Any] {
        guard let name = args["metric"] as? String, let type = RingMeasurementType(name: name) else {
            throw DeviceError.badArgument("'metric' must be one of: "
                + RingMeasurementType.allCases.map(\.name).joined(separator: ", "))
        }
        let caps = session.capabilities
        if caps.isKnown, !caps.supportedMeasurements.contains(type) {
            throw DeviceError.badArgument("this ring can't measure \(type.label.lowercased())")
        }
        let wait = TimeInterval(max(0, min(25, args["wait_seconds"] as? Int ?? 25)))
        return try await live { secondsLeft in
            let deadline = Date().addingTimeInterval(secondsLeft)
            try await self.session.startMeasurement(type)
            let remaining = max(0, min(wait, deadline.timeIntervalSinceNow))
            let state = await self.session.awaitMeasurement(timeout: remaining)
            return state.map(measurementJSON) ?? ["metric": type.name, "status": "measuring"]
        }
    }

    private func setMonitoring(_ args: [String: Any]) async throws -> [String: Any] {
        guard let metric = args["metric"] as? String else {
            throw DeviceError.badArgument("'metric' is required")
        }
        guard let enabled = args["enabled"] as? Bool else {
            throw DeviceError.badArgument("'enabled' must be a boolean")
        }
        let interval = args["interval_minutes"] as? Int
        let allowed: ClosedRange<Int>?
        switch metric {
        case "heart_rate": allowed = 1...60
        case "hrv": allowed = 10...60
        case "temperature": allowed = 10...120
        case "spo2", "stress": allowed = nil
        default:
            throw DeviceError.badArgument("'metric' must be heart_rate, spo2, hrv, stress or temperature")
        }
        if let interval, let allowed, !allowed.contains(interval) {
            throw DeviceError.badArgument("\(metric) interval must be \(allowed.lowerBound)–\(allowed.upperBound) minutes")
        }
        if metric == "temperature", let interval, ![10, 30, 60, 120].contains(interval) {
            throw DeviceError.badArgument("temperature interval must be 10, 30, 60 or 120 minutes")
        }
        return try await live { _ in
            switch metric {
            case "heart_rate": try await self.session.setHeartRateMonitoring(enabled: enabled, intervalMinutes: interval)
            case "spo2": try await self.session.setSpO2Monitoring(enabled: enabled)
            case "hrv": try await self.session.setHRVMonitoring(enabled: enabled, intervalMinutes: interval)
            case "stress": try await self.session.setStressMonitoring(enabled: enabled)
            default: try await self.session.setTemperatureMonitoring(enabled: enabled, intervalMinutes: interval)
            }
            return ["settings": self.settingsJSON()]
        }
    }

    private func setTouchMode(_ args: [String: Any]) async throws -> [String: Any] {
        guard let control = args["control"] as? String, ["touch", "gesture"].contains(control) else {
            throw DeviceError.badArgument("'control' must be touch or gesture")
        }
        guard let name = args["mode"] as? String, let mode = RingTouchMode(name: name),
              RingTouchMode.offerable.contains(mode) else {
            throw DeviceError.badArgument("'mode' must be one of: " + RingTouchMode.offerable.map(\.name).joined(separator: ", "))
        }
        let strength = args["strength"] as? Int
        if let strength, !(0...10).contains(strength) {
            throw DeviceError.badArgument("'strength' must be 0–10")
        }
        let caps = session.capabilities
        if caps.isKnown, !caps.touchModes.contains(mode) {
            throw DeviceError.badArgument("this ring offers: " + caps.touchModes.map(\.name).joined(separator: ", "))
        }
        return try await live { _ in
            if control == "touch" {
                try await self.session.setTouchMode(mode)
            } else {
                try await self.session.setGestureMode(mode, strength: strength)
            }
            return ["settings": self.settingsJSON()]
        }
    }

    private func setGoals(_ args: [String: Any]) async throws -> [String: Any] {
        let keys = ["steps", "calories", "distance_m", "sport_minutes", "sleep_minutes"]
        let given = keys.compactMap { key in (args[key] as? Int).map { (key, $0) } }
        guard !given.isEmpty else { throw DeviceError.badArgument("give at least one of: \(keys.joined(separator: ", "))") }
        for (key, value) in given where value < 0 || value > 1_000_000 {
            throw DeviceError.badArgument("'\(key)' is out of range")
        }
        return try await live { _ in
            var goals = self.session.settings.goals
                ?? RingGoals(steps: 8000, calories: 300_000, distanceMeters: 5000, sportMinutes: 60, sleepMinutes: 480)
            for (key, value) in given {
                switch key {
                case "steps": goals.steps = value
                case "calories": goals.calories = value * 1000
                case "distance_m": goals.distanceMeters = value
                case "sport_minutes": goals.sportMinutes = value
                default: goals.sleepMinutes = value
                }
            }
            try await self.session.setGoals(goals)
            return ["settings": self.settingsJSON()]
        }
    }

    private func setProfile(_ args: [String: Any]) async throws -> [String: Any] {
        var sex: Int?
        if let raw = args["sex"] {
            switch (raw as? String)?.lowercased() {
            case "male": sex = 0
            case "female": sex = 1
            default: throw DeviceError.badArgument("'sex' must be male or female")
            }
        }
        let ranges: [(String, ClosedRange<Int>)] = [("age", 1...120), ("height_cm", 50...250), ("weight_kg", 20...250)]
        for (key, range) in ranges {
            if let value = args[key] as? Int, !range.contains(value) {
                throw DeviceError.badArgument("'\(key)' must be \(range.lowerBound)–\(range.upperBound)")
            }
        }
        return try await live { _ in
            var profile = self.session.settings.profile
                ?? RingProfile(use24Hour: true, metric: true, sex: 0, age: 30, heightCm: 170, weightKg: 70,
                               systolic: 120, diastolic: 90, heartRateWarning: 0, open: 0)
            if let sex { profile.sex = sex }
            if let age = args["age"] as? Int { profile.age = age }
            if let height = args["height_cm"] as? Int { profile.heightCm = height }
            if let weight = args["weight_kg"] as? Int { profile.weightKg = weight }
            if let use24 = args["use_24h"] as? Bool { profile.use24Hour = use24 }
            if let metric = args["metric_units"] as? Bool { profile.metric = metric }
            try await self.session.setProfile(profile)
            return ["settings": self.settingsJSON()]
        }
    }

    private func setPreferences(_ args: [String: Any]) async throws -> [String: Any] {
        var celsius: Bool?
        if let unit = args["temperature_unit"] {
            switch (unit as? String)?.lowercased() {
            case "celsius": celsius = true
            case "fahrenheit": celsius = false
            default: throw DeviceError.badArgument("'temperature_unit' must be celsius or fahrenheit")
            }
        }
        let dnd = try args["dnd"].map { raw -> RingDND in
            guard let object = raw as? [String: Any] else { throw DeviceError.badArgument("'dnd' must be an object") }
            let current = session.settings.dnd
            let start = try clock(object["start"], fallback: (current?.startHour ?? 22, current?.startMinute ?? 0))
            let end = try clock(object["end"], fallback: (current?.endHour ?? 7, current?.endMinute ?? 0))
            return RingDND(enabled: object["enabled"] as? Bool ?? current?.enabled ?? true,
                           startHour: start.0, startMinute: start.1, endHour: end.0, endMinute: end.1, manual: false)
        }
        let sedentary = try args["sedentary"].map { raw -> RingSedentary in
            guard let object = raw as? [String: Any] else { throw DeviceError.badArgument("'sedentary' must be an object") }
            let current = session.settings.sedentary
            let start = try clock(object["start"], fallback: (current?.startHour ?? 9, current?.startMinute ?? 0))
            let end = try clock(object["end"], fallback: (current?.endHour ?? 18, current?.endMinute ?? 0))
            let interval = object["interval_minutes"] as? Int ?? current?.cycleMinutes ?? 60
            guard [30, 60, 90].contains(interval) else {
                throw DeviceError.badArgument("sedentary interval must be 30, 60 or 90 minutes")
            }
            let enabled = object["enabled"] as? Bool ?? current?.enabled ?? true
            return RingSedentary(startHour: start.0, startMinute: start.1, endHour: end.0, endMinute: end.1,
                                 weekMask: enabled ? 0x7F : 0, cycleMinutes: interval)
        }
        guard celsius != nil || dnd != nil || sedentary != nil else {
            throw DeviceError.badArgument("give temperature_unit, dnd or sedentary")
        }
        return try await live { _ in
            if let celsius { try await self.session.setTemperatureUnit(celsius: celsius) }
            if let dnd { try await self.session.setDND(dnd) }
            if let sedentary { try await self.session.setSedentary(sedentary) }
            return ["settings": self.settingsJSON()]
        }
    }

    private func power(_ args: [String: Any]) async throws -> [String: Any] {
        guard let action = args["action"] as? String, ["power_off", "factory_reset"].contains(action) else {
            throw DeviceError.badArgument("'action' must be power_off or factory_reset")
        }
        guard args["confirm"] as? Bool == true else {
            throw DeviceError.badArgument(action == "factory_reset"
                ? "'confirm' must be true — a factory reset erases the ring's data and settings"
                : "'confirm' must be true — the ring turns off until it is put on its charger")
        }
        return try await live { _ in
            if action == "factory_reset" {
                try await self.session.factoryReset()
            } else {
                try await self.session.powerOff()
            }
            return ["ok": true, "action": action]
        }
    }

    private func raw(_ args: [String: Any]) async throws -> [String: Any] {
        guard args["confirm"] as? Bool == true else {
            throw DeviceError.badArgument("'confirm' must be true — raw commands can change ring state")
        }
        if let hex = args["hex"] as? String {
            guard let bytes = Data(hexString: hex).map({ [UInt8]($0) }), !bytes.isEmpty else {
                throw DeviceError.badArgument("'hex' must be an even-length hex string")
            }
            return try await live { _ in
                let replies = try await self.session.sendRaw(bytes)
                return ["replies": replies.map(self.inboundJSON)]
            }
        }
        guard let cmd = args["big_data_cmd"] as? Int, (0...255).contains(cmd) else {
            throw DeviceError.badArgument("give 'hex', or 'big_data_cmd' (0–255) with optional 'payload_hex'")
        }
        let payloadHex = args["payload_hex"] as? String ?? ""
        guard let payload = Data(hexString: payloadHex) else {
            throw DeviceError.badArgument("'payload_hex' must be an even-length hex string")
        }
        return try await live { _ in
            let replies = try await self.session.sendRawBigData(cmd: UInt8(cmd), payload: [UInt8](payload))
            return ["replies": replies.map(self.inboundJSON)]
        }
    }

    /// Flash a firmware image over the ring's own BLE updater. The transfer takes minutes —
    /// longer than one bridge invoke — so we validate, start it, and let it run in the
    /// background; every OTA frame and ack shows up in ring_get_log, and the ring reboots into
    /// the new image once it commits. A failed/aborted transfer leaves the running image intact.
    private func firmwareUpdate(_ args: [String: Any]) async throws -> [String: Any] {
        guard args["confirm"] as? Bool == true else {
            throw DeviceError.badArgument("'confirm' must be true — this reflashes the ring")
        }
        let image = try await firmwareImage(args)
        if let bad = RingFirmwareUpdate.precondition(image) {
            throw DeviceError.badArgument("this image won't flash: \(bad.reason)")
        }
        let pockets = RingFirmwareUpdate.pocketCount(image)
        return try await live { secondsLeft in
            var failure: String?
            let finished = await self.runBounded(max(2, secondsLeft)) { [backend] in
                do {
                    try await RingFirmwareUpdate.run(
                        image: image,
                        send: { cmd, payload, until in
                            try await backend.session.sendRawBigData(cmd: cmd, payload: payload, until: until)
                        })
                } catch {
                    failure = (error as? RingFirmwareUpdate.Failure)?.reason ?? String(describing: error)
                }
            }
            if let failure {
                throw DeviceError.badArgument("firmware update failed: \(failure) (the ring kept the old image)")
            }
            if finished {
                return ["finished": true, "pockets": pockets, "bytes": image.count]
            }
            return ["started": true, "finished": false, "pockets": pockets, "bytes": image.count,
                    "note": "flashing in the background — watch ring_get_log; the ring reboots into the new image when it commits"]
        }
    }

    /// The image bytes from `image_b64` or a downloaded `url`.
    private func firmwareImage(_ args: [String: Any]) async throws -> [UInt8] {
        if let b64 = args["image_b64"] as? String, !b64.isEmpty {
            guard let data = Data(base64Encoded: b64) else {
                throw DeviceError.badArgument("'image_b64' is not valid base64")
            }
            return [UInt8](data)
        }
        if let urlString = args["url"] as? String, let url = URL(string: urlString) {
            let (data, _) = try await URLSession.shared.data(from: url)
            return [UInt8](data)
        }
        throw DeviceError.badArgument("give 'image_b64' (base64 of the .bin) or 'url'")
    }

    // MARK: Encoding

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private func json<T: Encodable>(_ value: T) -> Any {
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [:] }
        return object
    }

    /// The ring's settings, with the goal's small calories as kcal like every other energy value
    /// a caller sees — and like `ring_set_goals` takes them.
    private func settingsJSON() -> Any {
        guard var dict = json(session.settings) as? [String: Any] else { return [:] }
        if var goals = dict["goals"] as? [String: Any], let small = goals.removeValue(forKey: "calories") as? Int {
            goals["kilocalories"] = small / 1000
            dict["goals"] = goals
        }
        return dict
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func parseMetrics(_ raw: Any?) throws -> Set<RingMetric>? {
        guard let raw else { return nil }
        let names: [String]
        if let list = raw as? [String] {
            names = list
        } else if let single = raw as? String {
            names = [single]
        } else {
            throw DeviceError.badArgument("'metrics' must be a list of metric names")
        }
        var out = Set<RingMetric>()
        for name in names {
            guard let metric = RingMetric(rawValue: name.lowercased()) else {
                throw DeviceError.badArgument("unknown metric '\(name)'. Use: "
                    + RingMetric.allCases.map(\.rawValue).joined(separator: ", "))
            }
            out.insert(metric)
        }
        return out.isEmpty ? nil : out
    }

    private static let summaryKeys: [RingMetric: [String]] = [
        .activity: ["steps", "kilocalories", "distance_meters", "active_minutes"],
        .sleep: ["sleep_minutes", "deep_minutes", "light_minutes", "rem_minutes", "awake_minutes"],
        .heartRate: ["heart_rate_min", "heart_rate_avg", "heart_rate_max", "heart_rate_latest"],
        .spo2: ["spo2_min", "spo2_avg", "spo2_latest"],
        .hrv: ["hrv_avg", "hrv_latest"],
        .stress: ["stress_avg", "stress_latest"],
        .temperature: ["temperature_avg", "temperature_latest"],
        .bloodPressure: ["blood_pressure_systolic", "blood_pressure_diastolic"],
        .bloodSugar: ["blood_sugar_min", "blood_sugar_max"],
    ]

    private func summaryJSON(_ summary: RingDaySummary, metrics: Set<RingMetric>?) -> [String: Any] {
        guard var dict = json(summary) as? [String: Any] else { return [:] }
        if let metrics {
            let keep = Set(metrics.flatMap { Self.summaryKeys[$0] ?? [] })
            dict = dict.filter { keep.contains($0.key) }
        }
        return dict
    }

    private func detailJSON(_ day: RingDay, metrics: Set<RingMetric>?) -> [String: Any] {
        let wants = { (metric: RingMetric) in metrics?.contains(metric) ?? true }
        let timed = { (values: [RingTimedValue]) in values.map { [$0.minute, $0.value] as [Any] } }
        var out: [String: Any] = [:]
        if wants(.activity) {
            if let activity = day.activity { out["activity"] = json(activity) }
            out["step_slots"] = [
                "fields": ["slot_15min", "steps", "calories_small", "distance_m"],
                "rows": day.stepSlots.map { [$0.slot, $0.steps, $0.calories, $0.distanceMeters] },
            ]
        }
        if wants(.sleep) {
            out["sleep"] = day.sleep.map { session -> [String: Any] in
                ["start": iso(session.start), "end": iso(session.end), "asleep_minutes": session.asleepMinutes,
                 "stages": session.stages.map { [$0.stage, $0.minutes] }]
            }
            out["sleep_stage_codes"] = ["2": "light", "3": "deep", "4": "rem", "5": "awake"]
            out["naps"] = day.naps.map { ["start": iso($0.start), "end": iso($0.end)] }
        }
        if wants(.heartRate) {
            if let series = day.heartRate { out["heart_rate_series"] = json(series) }
            out["heart_rate_manual"] = timed(day.manualHeartRate)
            out["heart_rate_instant"] = timed(day.instantHeartRate)
        }
        if wants(.spo2) {
            if let spo2 = day.spo2 { out["spo2_hourly"] = json(spo2) }
            out["spo2_manual"] = timed(day.manualSpO2)
            out["spo2_instant"] = timed(day.instantSpO2)
        }
        if wants(.hrv), let hrv = day.hrv { out["hrv_series"] = json(hrv) }
        if wants(.stress), let stress = day.stress { out["stress_series"] = json(stress) }
        if wants(.temperature) {
            if let temperature = day.temperature { out["temperature_series_c"] = json(temperature) }
            out["temperature_instant_c"] = timed(day.instantTemperature)
        }
        if wants(.bloodPressure) { out["blood_pressure"] = json(day.bloodPressure) }
        if wants(.bloodSugar), let sugar = day.bloodSugar { out["blood_sugar_hourly"] = json(sugar) }
        out["measurements"] = json(day.measurements)
        out["timed_value_fields"] = ["minute_of_day", "value"]
        return out
    }

    private func measurementJSON(_ state: RingMeasurementState) -> [String: Any] {
        var out: [String: Any] = ["metric": state.type.name, "status": state.phase.rawValue,
                                  "started_at": iso(state.startedAt)]
        switch state.type {
        case .temperature:
            if let celsius = state.celsius { out["value_celsius"] = celsius }
        case .bloodPressure:
            if let sys = state.systolic { out["systolic"] = sys }
            if let dia = state.diastolic { out["diastolic"] = dia }
        default:
            if let value = state.value { out["value"] = value }
            if state.type == .healthCheck {
                if let sys = state.systolic { out["systolic"] = sys }
                if let dia = state.diastolic { out["diastolic"] = dia }
            }
        }
        let units: [RingMeasurementType: String] = [.heartRate: "bpm", .spo2: "%", .hrv: "ms", .stress: "score",
                                                    .temperature: "°C", .bloodPressure: "mmHg", .bloodSugar: "raw"]
        if let unit = units[state.type] { out["unit"] = unit }
        if let finished = state.finishedAt { out["finished_at"] = iso(finished) }
        if let detail = state.detail { out["detail"] = detail }
        return out
    }

    private func inboundJSON(_ inbound: RingInbound) -> [String: Any] {
        ["channel": inbound.channel.rawValue, "cmd": Int(inbound.cmd), "error": inbound.isError,
         "payload_hex": Data(inbound.payload).hexString]
    }

    /// "HH:MM" → (hour, minute); missing → fallback.
    private func clock(_ raw: Any?, fallback: (Int, Int)) throws -> (Int, Int) {
        guard let raw else { return fallback }
        let parts = (raw as? String)?.split(separator: ":").compactMap { Int($0) } ?? []
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
            throw DeviceError.badArgument("times must be HH:MM (24-hour)")
        }
        return (parts[0], parts[1])
    }
}
