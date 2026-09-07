import Foundation

/// The rest of the Clock app: stopwatch and world clock. (Alarms and timers
/// are in `DataSkills` on top of AlarmKit.)
enum ClockSkills {
    // MARK: stopwatch

    static func stopwatch(_ stopwatch: any Stopwatching,
                          now: @escaping () -> Date = Date.init) -> AnySkill {
        AnySkill(
            name: "stopwatch",
            description: "JARVIS's stopwatch: start, stop (pause), lap, reset, or read it. "
                + "Shows a live count-up in the Dynamic Island / Lock Screen while running, "
                + "even with the app closed. Returns elapsed seconds and laps.",
            inputSchema: SkillSchema.object([
                "action": SkillSchema.enumeration(StopwatchAction.allCases.map(\.rawValue)),
            ], required: ["action"])
        ) { args in
            let raw = SkillArgs.string(args, "action").lowercased()
            let action: StopwatchAction
            switch raw {
            case "pause": action = .stop
            case "resume", "begin": action = .start
            case "clear": action = .reset
            case "status", "elapsed", "": action = .read
            default:
                guard let a = StopwatchAction(rawValue: raw) else {
                    throw SkillError.badArgument("action must be one of start/stop/lap/reset/read")
                }
                action = a
            }
            let current = now()
            let state = stopwatch.perform(action, at: current)
            let elapsed = state.elapsed(at: current)
            var out: [String: Any] = [
                "action": action.rawValue,
                "running": state.isRunning,
                "elapsed_seconds": (elapsed * 10).rounded() / 10,
                "elapsed": StopwatchCore.format(elapsed),
                "laps": state.laps.map { StopwatchCore.format($0) },
                "lap_count": state.laps.count,
            ]
            if action == .lap, let last = state.laps.last { out["lap"] = StopwatchCore.format(last) }
            return out
        }
    }

    // MARK: world_time

    static func worldTime(now: @escaping () -> Date = Date.init) -> AnySkill {
        AnySkill(
            name: "world_time",
            description: "The current time in another place: give a city (\"Tokyo\", \"New York\") "
                + "or an IANA zone (\"Europe/Paris\"). Returns local time, date, UTC offset and the "
                + "difference from the phone's own zone.",
            inputSchema: SkillSchema.object([
                "place": SkillSchema.string("City or IANA time zone"),
            ], required: ["place"])
        ) { args in
            let place = SkillArgs.string(args, "place").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !place.isEmpty else { throw SkillError.badArgument("place is required") }
            guard let zone = WorldClock.zone(for: place) else {
                return ["found": false, "error": "no time zone known for \"\(place)\""]
            }
            let current = now()
            let f = DateFormatter()
            f.timeZone = zone
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "HH:mm"
            let time = f.string(from: current)
            f.dateFormat = "EEEE, d MMMM"
            let date = f.string(from: current)
            let offset = zone.secondsFromGMT(for: current)
            let localOffset = TimeZone.current.secondsFromGMT(for: current)
            let diffHours = Double(offset - localOffset) / 3600
            return [
                "found": true,
                "place": place,
                "zone": zone.identifier,
                "time": time,
                "date": date,
                "utc_offset": WorldClock.offsetString(offset),
                "hours_ahead_of_me": diffHours,
            ]
        }
    }
}

/// City → time zone. Exact IANA ids first, then the zone list's city names,
/// then a short table of common cities that IANA spells differently or lacks.
enum WorldClock {
    private static let aliases: [String: String] = [
        "nyc": "America/New_York", "new york": "America/New_York",
        "la": "America/Los_Angeles", "los angeles": "America/Los_Angeles",
        "san francisco": "America/Los_Angeles", "sf": "America/Los_Angeles",
        "seattle": "America/Los_Angeles", "boston": "America/New_York",
        "washington": "America/New_York", "dc": "America/New_York",
        "miami": "America/New_York", "dallas": "America/Chicago",
        "houston": "America/Chicago", "austin": "America/Chicago",
        "london": "Europe/London", "paris": "Europe/Paris", "berlin": "Europe/Berlin",
        "madrid": "Europe/Madrid", "rome": "Europe/Rome", "amsterdam": "Europe/Amsterdam",
        "zurich": "Europe/Zurich", "dublin": "Europe/Dublin", "moscow": "Europe/Moscow",
        "istanbul": "Europe/Istanbul", "dubai": "Asia/Dubai", "mumbai": "Asia/Kolkata",
        "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "bangalore": "Asia/Kolkata",
        "bengaluru": "Asia/Kolkata", "chennai": "Asia/Kolkata", "hyderabad": "Asia/Kolkata",
        "india": "Asia/Kolkata", "kolkata": "Asia/Kolkata", "calcutta": "Asia/Kolkata", "singapore": "Asia/Singapore", "hong kong": "Asia/Hong_Kong",
        "beijing": "Asia/Shanghai", "shanghai": "Asia/Shanghai", "china": "Asia/Shanghai",
        "tokyo": "Asia/Tokyo", "japan": "Asia/Tokyo", "seoul": "Asia/Seoul",
        "sydney": "Australia/Sydney", "melbourne": "Australia/Melbourne",
        "auckland": "Pacific/Auckland", "toronto": "America/Toronto",
        "vancouver": "America/Vancouver", "mexico city": "America/Mexico_City",
        "sao paulo": "America/Sao_Paulo", "são paulo": "America/Sao_Paulo",
        "buenos aires": "America/Argentina/Buenos_Aires", "cairo": "Africa/Cairo",
        "johannesburg": "Africa/Johannesburg", "lagos": "Africa/Lagos", "nairobi": "Africa/Nairobi",
        "utc": "UTC", "gmt": "GMT", "chicago": "America/Chicago", "denver": "America/Denver",
        "phoenix": "America/Phoenix", "honolulu": "Pacific/Honolulu", "anchorage": "America/Anchorage",
    ]

    static func zone(for place: String) -> TimeZone? {
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        if let z = TimeZone(identifier: trimmed) { return z }
        let lower = trimmed.lowercased()
        if let id = aliases[lower], let z = TimeZone(identifier: id) { return z }
        // "Kolkata", "Buenos Aires", "Ho Chi Minh" → last path component of an IANA id.
        let needle = lower.replacingOccurrences(of: " ", with: "_")
        if let id = TimeZone.knownTimeZoneIdentifiers.first(where: {
            $0.split(separator: "/").last?.lowercased() == needle
        }) {
            return TimeZone(identifier: id)
        }
        return nil
    }

    static func offsetString(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let abs = Swift.abs(seconds)
        return String(format: "UTC%@%02d:%02d", sign, abs / 3600, (abs % 3600) / 60)
    }
}
