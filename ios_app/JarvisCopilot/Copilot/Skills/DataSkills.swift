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
    static func setAlarm(_ alarms: any AlarmScheduling,
                         notifier: any Notifying,
                         now: @escaping () -> Date = Date.init,
                         calendar: Calendar = .current) -> AnySkill {
        AnySkill(
            name: "set_alarm",
            description: "Set a REAL system alarm on the phone (rings through Silent mode and Focus, "
                + "full-screen with Stop/Snooze; iOS 26+). Give the time as 24h hour (+minute) for "
                + "the next occurrence, OR in_minutes from now. Optional label, repeat (weekday "
                + "names, 'weekdays', 'weekends', 'daily') and snooze_minutes. For a countdown "
                + "('timer for 10 minutes') use set_timer. Falls back to a notification alarm when "
                + "system alarms are unavailable or not permitted.",
            inputSchema: SkillSchema.object([
                "hour": SkillSchema.integer(min: 0, max: 23),
                "minute": SkillSchema.integer(min: 0, max: 59),
                "in_minutes": SkillSchema.integer(min: 1, max: 1440),
                "label": SkillSchema.string(),
                "repeat": ["type": "array", "items": ["type": "string"],
                           "description": "Weekday names to repeat on, e.g. [\"mon\", \"fri\"], or 'weekdays' / 'weekends' / 'daily'"],
                "snooze_minutes": SkillSchema.integer(min: 1, max: 60),
            ])
        ) { args in
            let label = SkillArgs.string(args, "label")
            let current = now()
            let snooze = SkillArgs.int(args, "snooze_minutes") ?? 9
            var repeatDays: [Int] = []
            if let raw = args["repeat"] as? [Any] {
                let words = raw.map { SkillArgs.text($0) }
                guard let parsed = AlarmWeekdays.parse(words) else {
                    throw SkillError.badArgument("unknown weekday in repeat: \(words)")
                }
                repeatDays = parsed
            }
            let when: Date
            var kind: AlarmSpec.Kind
            if let minutes = SkillArgs.int(args, "in_minutes") {
                guard minutes >= 1 else { throw SkillError.badArgument("in_minutes must be at least 1") }
                when = current.addingTimeInterval(TimeInterval(minutes * 60))
                kind = .fixed(when)
            } else if let hour = SkillArgs.int(args, "hour") {
                let minute = SkillArgs.int(args, "minute") ?? 0
                guard (0...23).contains(hour), (0...59).contains(minute) else {
                    throw SkillError.badArgument("hour must be 0-23 and minute 0-59")
                }
                guard let next = AlarmSpec.nextOccurrence(hour: hour, minute: minute, from: current,
                                                          calendar: calendar) else {
                    throw SkillError.badArgument("could not build that time")
                }
                when = next
                kind = repeatDays.isEmpty ? .fixed(next)
                                          : .daily(hour: hour, minute: minute, weekdays: repeatDays)
            } else {
                return ["scheduled": false, "error": "hour or in_minutes required"]
            }
            let spec = AlarmSpec(kind: kind, label: label, snoozeMinutes: snooze)
            switch await tryNative(alarms, spec) {
            case .scheduled(let alarm):
                var out: [String: Any] = ["scheduled": true, "native": true, "id": alarm.id,
                                          "label": alarm.label]
                if let fire = alarm.fireDate ?? (repeatDays.isEmpty ? when : nil) { out["at"] = isoString(fire) }
                if !repeatDays.isEmpty { out["repeat"] = repeatDays.map(AlarmWeekdays.name) }
                return out
            case .fallback(let note):
                guard repeatDays.isEmpty else {
                    return ["scheduled": false, "native": false,
                            "error": "repeating alarms need system alarm permission (\(note))"]
                }
                return try await notificationAlarm(notifier, label: label.isEmpty ? "Alarm" : label,
                                                   at: when, note: note)
            }
        }
    }

    // MARK: set_timer

    static func setTimer(_ alarms: any AlarmScheduling,
                         notifier: any Notifying,
                         now: @escaping () -> Date = Date.init) -> AnySkill {
        AnySkill(
            name: "set_timer",
            description: "Start a countdown timer on the phone: a REAL system timer with a live "
                + "countdown in the Dynamic Island / Lock Screen that rings through Silent mode "
                + "(iOS 26+). minutes and/or seconds; optional label. Falls back to a notification "
                + "when system alarms are unavailable or not permitted.",
            inputSchema: SkillSchema.object([
                "minutes": SkillSchema.integer(min: 0, max: 1440),
                "seconds": SkillSchema.integer(min: 0, max: 59),
                "label": SkillSchema.string(),
            ])
        ) { args in
            let label = SkillArgs.string(args, "label")
            let total = (SkillArgs.int(args, "minutes") ?? 0) * 60 + (SkillArgs.int(args, "seconds") ?? 0)
            guard total >= 1 else { return ["scheduled": false, "error": "minutes or seconds required"] }
            let current = now()
            let spec = AlarmSpec(kind: .timer(seconds: TimeInterval(total)), label: label)
            switch await tryNative(alarms, spec) {
            case .scheduled(let alarm):
                return ["scheduled": true, "native": true, "id": alarm.id, "label": alarm.label,
                        "seconds": total, "at": isoString(current.addingTimeInterval(TimeInterval(total)))]
            case .fallback(let note):
                var out = try await notificationAlarm(notifier, label: label.isEmpty ? "Timer" : label,
                                                      at: current.addingTimeInterval(TimeInterval(total)), note: note)
                out["seconds"] = total
                return out
            }
        }
    }

    // MARK: list_alarms

    static func listAlarms(_ alarms: any AlarmScheduling, notifier: any Notifying) -> AnySkill {
        AnySkill(
            name: "list_alarms",
            description: "List the alarms and timers JARVIS has set on this phone (system alarms "
                + "plus any notification-alarm fallbacks), with ids for cancel_alarm."
        ) { _ in
            var out: [[String: Any]] = []
            if alarms.isAvailable {
                for a in (try? await alarms.list()) ?? [] {
                    var row: [String: Any] = ["id": a.id, "label": a.label, "state": a.state, "native": true]
                    switch a.kind {
                    case .fixed(let d):
                        row["kind"] = "alarm"; row["at"] = isoString(d)
                    case .daily(let h, let m, let days):
                        row["kind"] = "alarm"
                        row["time"] = String(format: "%02d:%02d", h, m)
                        row["repeat"] = days.map(AlarmWeekdays.name)
                        if let f = a.fireDate { row["at"] = isoString(f) }
                    case .timer(let secs):
                        row["kind"] = "timer"; row["seconds"] = Int(secs)
                        if let f = a.fireDate { row["at"] = isoString(f) }
                    }
                    out.append(row)
                }
            }
            for id in await notifier.pending() where id.hasPrefix(notificationAlarmPrefix) {
                var row: [String: Any] = ["id": id, "label": "Alarm", "kind": "alarm",
                                          "state": "scheduled", "native": false]
                if let ts = TimeInterval(id.dropFirst(notificationAlarmPrefix.count)) {
                    row["at"] = isoString(Date(timeIntervalSince1970: ts))
                }
                out.append(row)
            }
            return ["alarms": out, "count": out.count]
        }
    }

    // MARK: cancel_alarm

    static func cancelAlarm(_ alarms: any AlarmScheduling, notifier: any Notifying) -> AnySkill {
        AnySkill(
            name: "cancel_alarm",
            description: "Cancel (or silence, if ringing) an alarm or timer by id from list_alarms, "
                + "or all of them with all=true.",
            inputSchema: SkillSchema.object([
                "id": SkillSchema.string("Alarm id from list_alarms / set_alarm / set_timer"),
                "all": SkillSchema.boolean,
            ])
        ) { args in
            if SkillArgs.bool(args, "all") == true {
                var count = 0
                if alarms.isAvailable {
                    for a in (try? await alarms.list()) ?? [] {
                        try? await alarms.stop(id: a.id)
                        if (try? await alarms.cancel(id: a.id)) != nil { count += 1 }
                    }
                }
                let pending = await notifier.pending().filter { $0.hasPrefix(notificationAlarmPrefix) }
                if !pending.isEmpty {
                    await notifier.cancel(identifiers: pending)
                    count += pending.count
                }
                return ["cancelled": true, "cancelled_count": count]
            }
            let id = SkillArgs.string(args, "id")
            guard !id.isEmpty else { return ["cancelled": false, "error": "id or all=true required"] }
            if id.hasPrefix(notificationAlarmPrefix) {
                await notifier.cancel(identifiers: [id])
                return ["cancelled": true, "id": id, "native": false]
            }
            do {
                try? await alarms.stop(id: id)
                try await alarms.cancel(id: id)
                return ["cancelled": true, "id": id, "native": true]
            } catch {
                return ["cancelled": false, "id": id, "error": error.localizedDescription]
            }
        }
    }

    // MARK: alarm helpers

    static let notificationAlarmPrefix = "jc-alarm-"

    private enum NativeAttempt {
        case scheduled(ScheduledAlarm)
        case fallback(String)
    }

    /// AlarmKit first; every way it can fail becomes a `fallback` with an honest
    /// note the skill puts in its result.
    private static func tryNative(_ alarms: any AlarmScheduling, _ spec: AlarmSpec) async -> NativeAttempt {
        guard alarms.isAvailable else { return .fallback("system alarms need iOS 26") }
        do {
            guard try await alarms.requestAuthorization() else {
                return .fallback("alarm permission denied — enable it in Settings > JarvisCopilot")
            }
            return .scheduled(try await alarms.schedule(spec))
        } catch {
            return .fallback(error.localizedDescription)
        }
    }

    /// The pre-AlarmKit alarm: a time-sensitive local notification with a sound.
    private static func notificationAlarm(_ notifier: any Notifying, label: String,
                                          at when: Date, note: String) async throws -> [String: Any] {
        let identifier = "\(notificationAlarmPrefix)\(Int(when.timeIntervalSince1970))"
        _ = try await notifier.post(LocalNotificationRequest(
            title: label,
            body: "JARVIS alarm",
            at: when,
            identifier: identifier,
            sound: true,
            timeSensitive: true))
        return ["scheduled": true, "native": false, "at": isoString(when), "id": identifier,
                "label": label,
                "note": "Notification alarm (respects Silent mode): \(note)"]
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
