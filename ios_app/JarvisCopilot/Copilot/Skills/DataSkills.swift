import Foundation

/// Personal-data + scheduling skills: contacts, calendars, alarms, health.
///
/// Port of the matching entries in `mobile_client/lib/skills/common.dart` and
/// `read_healthkit` from `skills/ios.dart`.
enum DataSkills {

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The server sends plain ISO-8601; accept both with and without fractional
    /// seconds, and a bare `yyyy-MM-dd'T'HH:mm:ss` with no zone (local time).
    static func parseDate(_ text: String) -> Date? {
        if let d = iso.date(from: text) { return d }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: text) { return d }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let d = local.date(from: text) { return d }
        }
        return nil
    }

    static func isoString(_ date: Date) -> String { iso.string(from: date) }

    // MARK: read_contacts

    static func readContacts(_ store: any ContactsStore) -> AnySkill {
        AnySkill(
            name: "read_contacts",
            description: "Search the device contacts by name or phone-number substring. "
                + "Returns up to 20 matches. Requires contacts permission.",
            inputSchema: SkillSchema.object([
                "query": SkillSchema.string(),
                "limit": SkillSchema.integer(min: 1, max: 100),
            ])
        ) { args in
            let query = SkillArgs.string(args, "query")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Clamped to the schema's own bounds: an out-of-range limit from a
            // mis-generated tool call must not turn into an unbounded scan.
            let limit = min(max(SkillArgs.int(args, "limit") ?? 20, 1), 100)
            guard try await store.requestAccess() else {
                return ["error": "contacts permission denied"]
            }
            let all = try await store.contacts()
            let matches = query.isEmpty ? all : all.filter { contact in
                if contact.name.lowercased().contains(query) { return true }
                return contact.phones.contains { phone in
                    phone.filter { $0.isNumber || $0 == "+" }.contains(query)
                }
            }
            let out = matches.prefix(limit).map { contact in
                [
                    "display_name": contact.name,
                    "phones": contact.phones,
                    "emails": contact.emails,
                ] as [String: Any]
            }
            return ["contacts": Array(out), "total": matches.count]
        }
    }

    // MARK: add_calendar_event

    /// DEVIATION from the Flutter skill: that one opened the system "add event"
    /// sheet (`add_2_calendar`) and returned `{opened}`. EventKit lets us write
    /// the event directly once the user has granted full calendar access, so
    /// this saves it and reports the identifier — no sheet to dismiss, which is
    /// what a headless invoke over the bridge actually needs. The schema is
    /// unchanged and `opened` is still reported for prompt compatibility.
    static func addCalendarEvent(_ calendars: any CalendarAccessing) -> AnySkill {
        AnySkill(
            name: "add_calendar_event",
            description: "Add an event to the default calendar with title / start / end. "
                + "Requires calendar access.",
            inputSchema: SkillSchema.object([
                "title": SkillSchema.string(),
                "description": SkillSchema.string(),
                "location": SkillSchema.string(),
                "start_iso": SkillSchema.string(),
                "end_iso": SkillSchema.string(),
                "all_day": SkillSchema.boolean,
            ], required: ["title", "start_iso", "end_iso"])
        ) { args in
            let title = SkillArgs.string(args, "title")
            guard !title.isEmpty else { throw SkillError.badArgument("title required") }
            guard let start = parseDate(SkillArgs.string(args, "start_iso")) else {
                throw SkillError.badArgument("start_iso must be an ISO-8601 timestamp")
            }
            guard let end = parseDate(SkillArgs.string(args, "end_iso")) else {
                throw SkillError.badArgument("end_iso must be an ISO-8601 timestamp")
            }
            guard try await calendars.requestAccess() else {
                return ["error": "calendar permission denied"]
            }
            let identifier = try await calendars.add(CalendarEventDraft(
                title: title,
                notes: SkillArgs.string(args, "description"),
                location: SkillArgs.string(args, "location"),
                start: start,
                end: end,
                allDay: SkillArgs.bool(args, "all_day") ?? false))
            return ["saved": true, "opened": true, "event_id": identifier]
        }
    }

    // MARK: list_calendar_events

    static func listCalendarEvents(_ calendars: any CalendarAccessing) -> AnySkill {
        AnySkill(
            name: "list_calendar_events",
            description: "List calendar events between two ISO timestamps across all visible "
                + "calendars. Requires calendar read permission.",
            inputSchema: SkillSchema.object([
                "start_iso": SkillSchema.string(),
                "end_iso": SkillSchema.string(),
                "limit": SkillSchema.integer(min: 1, max: 200),
            ], required: ["start_iso", "end_iso"])
        ) { args in
            guard let start = parseDate(SkillArgs.string(args, "start_iso")) else {
                throw SkillError.badArgument("start_iso must be an ISO-8601 timestamp")
            }
            guard let end = parseDate(SkillArgs.string(args, "end_iso")) else {
                throw SkillError.badArgument("end_iso must be an ISO-8601 timestamp")
            }
            let limit = min(max(SkillArgs.int(args, "limit") ?? 50, 1), 200)
            guard try await calendars.requestAccess() else {
                return ["error": "calendar permission denied"]
            }
            let events = try await calendars.events(from: start, to: end, limit: limit)
            let out = events.map { event in
                [
                    "title": event.title,
                    "description": event.notes,
                    "location": event.location,
                    "start_iso": event.start.map(isoString) ?? "",
                    "end_iso": event.end.map(isoString) ?? "",
                    "all_day": event.allDay,
                    "calendar": event.calendar,
                ] as [String: Any]
            }
            return ["events": out, "count": out.count]
        }
    }

    // MARK: set_alarm

    /// A local notification with a sound that fires at the given time even if
    /// the app is closed. iOS has no public API for a true Clock alarm, so this
    /// respects Silent / Do-Not-Disturb — same caveat the Flutter skill carried.
    static func setAlarm(_ notifier: any Notifying,
                         now: @escaping () -> Date = Date.init) -> AnySkill {
        AnySkill(
            name: "set_alarm",
            description: "Schedule an on-device alarm: a local notification with an alarm sound "
                + "that fires at the given time even if the app is closed. Give the time as 24h "
                + "hour (+minute) for the next occurrence, OR in_minutes from now. Optional "
                + "label. Note: it respects the OS Silent / Do-Not-Disturb settings (iOS has no "
                + "public API for a true Clock alarm).",
            inputSchema: SkillSchema.object([
                "hour": SkillSchema.integer(min: 0, max: 23),
                "minute": SkillSchema.integer(min: 0, max: 59),
                "in_minutes": SkillSchema.integer(min: 1, max: 1440),
                "label": SkillSchema.string(),
            ])
        ) { args in
            let label = SkillArgs.string(args, "label")
            let current = now()
            let when: Date
            if let minutes = SkillArgs.int(args, "in_minutes") {
                when = current.addingTimeInterval(TimeInterval(minutes * 60))
            } else if let hour = SkillArgs.int(args, "hour") {
                let minute = SkillArgs.int(args, "minute") ?? 0
                let calendar = Calendar.current
                var parts = calendar.dateComponents([.year, .month, .day], from: current)
                parts.hour = hour
                parts.minute = minute
                parts.second = 0
                guard var candidate = calendar.date(from: parts) else {
                    throw SkillError.badArgument("could not build that time")
                }
                if candidate <= current {
                    candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
                }
                when = candidate
            } else {
                return ["scheduled": false, "error": "hour or in_minutes required"]
            }
            let identifier = "jc-alarm-\(Int(when.timeIntervalSince1970))"
            _ = try await notifier.post(LocalNotificationRequest(
                title: label.isEmpty ? "Alarm" : label,
                body: "JARVIS alarm",
                at: when,
                identifier: identifier,
                sound: true,
                timeSensitive: true))
            return ["scheduled": true, "at": isoString(when), "id": identifier]
        }
    }

    // MARK: read_healthkit

    static func readHealth(_ health: any HealthReading) -> AnySkill {
        AnySkill(
            name: "read_healthkit",
            description: "Read steps / heart-rate / sleep / workouts over the last N days.",
            inputSchema: SkillSchema.object([
                "metric": SkillSchema.enumeration(["steps", "heart_rate", "sleep", "workouts"]),
                "days": SkillSchema.integer(min: 1, max: 30),
            ], required: ["metric"])
        ) { args in
            let metric = SkillArgs.string(args, "metric")
            guard !metric.isEmpty else { throw SkillError.badArgument("metric required") }
            let days = min(max(SkillArgs.int(args, "days") ?? 1, 1), 30)
            do {
                let samples = try await health.read(metric: metric, days: days)
                return ["samples": samples.map(\.json), "count": samples.count]
            } catch {
                // Same graceful shape the Flutter skill used, so the server can
                // pick another tool instead of treating this as a hard failure.
                return ["error": SystemSkills.message(error)]
            }
        }
    }
}
