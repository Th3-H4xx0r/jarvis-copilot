import Foundation
import SwiftUI
#if canImport(AlarmKit)
import AlarmKit
#endif

/// AlarmKit behind `AlarmScheduling`. Real system alarms: full-screen alert,
/// a siren that breaks through Silent mode and Focus, Stop + Snooze, and a
/// Live Activity countdown the widget extension draws
/// (`JarvisAlarmActivity`). Everything is behind `#available(iOS 26, *)`; the
/// deployment target is iOS 17.
///
/// AlarmKit hands back no title, so labels are kept in UserDefaults by alarm
/// id and pruned on `list()`.
final class DefaultAlarmScheduler: AlarmScheduling, @unchecked Sendable {
    private static let labelsKey = "jc.alarm.labels"
    private static let kindsKey = "jc.alarm.kinds"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isAvailable: Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    func requestAuthorization() async throws -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: return true
            case .denied: return false
            case .notDetermined: break
            @unknown default: break
            }
            return try await AlarmManager.shared.requestAuthorization() == .authorized
        }
        #endif
        return false
    }

    func schedule(_ spec: AlarmSpec) async throws -> ScheduledAlarm {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let id = UUID()
            let kindName: String
            if case .timer = spec.kind { kindName = "timer" } else { kindName = "alarm" }
            let label = spec.label.isEmpty ? (kindName == "timer" ? "Timer" : "Alarm") : spec.label
            let attributes = AlarmAttributes<JarvisAlarmMetadata>(
                presentation: Self.presentation(label: label),
                metadata: JarvisAlarmMetadata(label: label, kind: kindName),
                tintColor: Color(red: 0.31, green: 0.45, blue: 1.0))
            let snooze = TimeInterval(max(1, spec.snoozeMinutes) * 60)
            let configuration: AlarmManager.AlarmConfiguration<JarvisAlarmMetadata>
            switch spec.kind {
            case .fixed(let date):
                configuration = AlarmManager.AlarmConfiguration(
                    countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: snooze),
                    schedule: .fixed(date),
                    attributes: attributes)
            case .daily(let hour, let minute, let weekdays):
                let time = Alarm.Schedule.Relative.Time(hour: hour, minute: minute)
                let recurrence: Alarm.Schedule.Relative.Recurrence =
                    weekdays.isEmpty ? .never : .weekly(weekdays.compactMap(Self.weekday))
                configuration = AlarmManager.AlarmConfiguration(
                    countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: snooze),
                    schedule: .relative(Alarm.Schedule.Relative(time: time, repeats: recurrence)),
                    attributes: attributes)
            case .timer(let seconds):
                configuration = AlarmManager.AlarmConfiguration(
                    countdownDuration: Alarm.CountdownDuration(preAlert: max(1, seconds), postAlert: snooze),
                    schedule: nil,
                    attributes: attributes)
            }
            let alarm = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
            remember(id: id.uuidString, label: label, kind: kindName)
            return Self.describe(alarm, label: label, kind: kindName)
        }
        #endif
        throw SkillError.unavailable("system alarms need iOS 26")
    }

    func list() async throws -> [ScheduledAlarm] {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            let alarms = try AlarmManager.shared.alarms
            let labels = storedLabels(), kinds = storedKinds()
            let out = alarms.map { alarm -> ScheduledAlarm in
                let key = alarm.id.uuidString
                let kind = kinds[key] ?? (alarm.schedule == nil ? "timer" : "alarm")
                return Self.describe(alarm, label: labels[key] ?? (kind == "timer" ? "Timer" : "Alarm"), kind: kind)
            }
            prune(keeping: Set(alarms.map { $0.id.uuidString }))
            return out
        }
        #endif
        return []
    }

    func cancel(id: String) async throws {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            guard let uuid = UUID(uuidString: id) else { throw SkillError.badArgument("bad alarm id") }
            try AlarmManager.shared.cancel(id: uuid)
            forget(id: id)
            return
        }
        #endif
        throw SkillError.unavailable("system alarms need iOS 26")
    }

    func stop(id: String) async throws {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            guard let uuid = UUID(uuidString: id) else { throw SkillError.badArgument("bad alarm id") }
            try AlarmManager.shared.stop(id: uuid)
            return
        }
        #endif
        throw SkillError.unavailable("system alarms need iOS 26")
    }

    // MARK: - AlarmKit mapping

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private static func presentation(label: String) -> AlarmPresentation {
        let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill")
        let snooze = AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz")
        let pause = AlarmButton(text: "Pause", textColor: .white, systemImageName: "pause.fill")
        let resume = AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.fill")
        let title = LocalizedStringResource(stringLiteral: label)
        return AlarmPresentation(
            alert: AlarmPresentation.Alert(title: title, stopButton: stop,
                                           secondaryButton: snooze, secondaryButtonBehavior: .countdown),
            countdown: AlarmPresentation.Countdown(title: title, pauseButton: pause),
            paused: AlarmPresentation.Paused(title: "Paused", resumeButton: resume))
    }

    @available(iOS 26.0, *)
    private static func weekday(_ n: Int) -> Locale.Weekday? {
        switch n {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return nil
        }
    }

    @available(iOS 26.0, *)
    private static func weekdayNumber(_ d: Locale.Weekday) -> Int {
        switch d {
        case .sunday: return 1
        case .monday: return 2
        case .tuesday: return 3
        case .wednesday: return 4
        case .thursday: return 5
        case .friday: return 6
        case .saturday: return 7
        @unknown default: return 0
        }
    }

    @available(iOS 26.0, *)
    private static func describe(_ alarm: Alarm, label: String, kind: String) -> ScheduledAlarm {
        let state: String
        switch alarm.state {
        case .scheduled: state = "scheduled"
        case .countdown: state = "countdown"
        case .paused: state = "paused"
        case .alerting: state = "alerting"
        @unknown default: state = "unknown"
        }
        let specKind: AlarmSpec.Kind
        var fire: Date?
        switch alarm.schedule {
        case .fixed(let date):
            specKind = .fixed(date)
            fire = date
        case .relative(let rel):
            var days: [Int] = []
            if case .weekly(let list) = rel.repeats { days = list.map(weekdayNumber).sorted() }
            specKind = .daily(hour: rel.time.hour, minute: rel.time.minute, weekdays: days)
            fire = AlarmSpec.nextOccurrence(hour: rel.time.hour, minute: rel.time.minute, from: Date())
        case .none:
            specKind = .timer(seconds: alarm.countdownDuration?.preAlert ?? 0)
        @unknown default:
            specKind = .timer(seconds: 0)
        }
        return ScheduledAlarm(id: alarm.id.uuidString, label: label, kind: specKind, state: state, fireDate: fire)
    }
    #endif

    // MARK: - Label store

    private func storedLabels() -> [String: String] {
        defaults.dictionary(forKey: Self.labelsKey) as? [String: String] ?? [:]
    }
    private func storedKinds() -> [String: String] {
        defaults.dictionary(forKey: Self.kindsKey) as? [String: String] ?? [:]
    }
    private func remember(id: String, label: String, kind: String) {
        var l = storedLabels(); l[id] = label; defaults.set(l, forKey: Self.labelsKey)
        var k = storedKinds(); k[id] = kind; defaults.set(k, forKey: Self.kindsKey)
    }
    private func forget(id: String) {
        var l = storedLabels(); l[id] = nil; defaults.set(l, forKey: Self.labelsKey)
        var k = storedKinds(); k[id] = nil; defaults.set(k, forKey: Self.kindsKey)
    }
    private func prune(keeping ids: Set<String>) {
        defaults.set(storedLabels().filter { ids.contains($0.key) }, forKey: Self.labelsKey)
        defaults.set(storedKinds().filter { ids.contains($0.key) }, forKey: Self.kindsKey)
    }
}
