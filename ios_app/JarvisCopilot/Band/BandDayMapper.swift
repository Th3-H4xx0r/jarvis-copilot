import Foundation

/// Folds the band's 5-minute records and sleep segments into `RingDay`, the shape the ring
/// charts, the Health tab and the server payload already read. Every value lands in a keyed
/// place (a minute, a 5-minute bucket, an hour, a session start), so applying the same records
/// twice changes nothing and records that reach a day in different syncs never count twice.
enum BandDayMapper {
    static let plausibleHeartRate = 30...250
    static let plausibleSpO2 = 70...100
    static let plausibleTemperature = 30.0...45.0
    /// A record with at least this many steps counts its five minutes as active.
    static let activeSteps = 60
    /// A sleep shorter than this that ends in the daytime is a nap.
    static let napLongest: TimeInterval = 3 * 3600

    /// `existing` (the stored day for `date`) with every record and sleep segment that belongs
    /// to that day laid over it: records by their slot's day, sleep by the day it ended.
    static func day(_ existing: RingDay, records: [BandDailyRecord], sleep: [BandSleep], date: Date,
                    calendar: Calendar) -> RingDay {
        var day = existing
        let key = RingDates.dayKey(date, calendar: calendar)
        day.date = key
        let mine = records.filter { RingDates.dayKey($0.date, calendar: calendar) == key }

        if !mine.isEmpty {
            // Steps, energy and distance: one entry per record at its start minute; the
            // 15-minute slots and the day's totals are rebuilt from all of them.
            var minutes = day.stepMinutes ?? [:]
            for r in mine where r.steps > 0 || r.calories > 0 || r.distanceMeters > 0 {
                minutes[r.minuteOfDay] = RingStepMinute(steps: r.steps, calories: r.calories, distanceMeters: r.distanceMeters)
            }
            day.stepMinutes = minutes
            day.stepSlots = slots(from: minutes)
            let steps = minutes.values.reduce(0) { $0 + $1.steps }
            let active = minutes.values.filter { $0.steps >= activeSteps }.count * 5
            day.activity = RingActivity(steps: max(steps, day.activity?.steps ?? 0), runningSteps: 0,
                                        calories: max(minutes.values.reduce(0) { $0 + $1.calories }, day.activity?.calories ?? 0),
                                        distanceMeters: max(minutes.values.reduce(0) { $0 + $1.distanceMeters },
                                                            day.activity?.distanceMeters ?? 0),
                                        sportMinutes: max(active, day.activity?.sportMinutes ?? 0))

            for r in mine {
                // Heart rate: one value per minute of the slot.
                for (i, bpm) in r.heartRates.prefix(5).enumerated() where plausibleHeartRate.contains(bpm) {
                    put(&day.heartRate, interval: 1, minute: r.minuteOfDay + i, value: Double(bpm))
                }
                if let mean = mean(r.hrv.filter { $0 > 0 }) { put(&day.hrv, interval: 5, minute: r.minuteOfDay, value: mean) }
                if let mean = mean(r.stress.filter { $0 > 0 }) { put(&day.stress, interval: 5, minute: r.minuteOfDay, value: mean) }
                if let t = r.temperatureC, plausibleTemperature.contains(t) {
                    put(&day.temperature, interval: 5, minute: r.minuteOfDay, value: t)
                }
                let oxygen = r.spo2.filter { plausibleSpO2.contains($0) }
                if !oxygen.isEmpty {
                    let hour = min(23, r.minuteOfDay / 60)
                    var range = day.spo2 ?? RingMinMax(min: [Int](repeating: 0, count: 24), max: [Int](repeating: 0, count: 24))
                    let low = oxygen.min() ?? 0, high = oxygen.max() ?? 0
                    range.min[hour] = range.min[hour] == 0 ? low : Swift.min(range.min[hour], low)
                    range.max[hour] = Swift.max(range.max[hour], high)
                    day.spo2 = range
                }
                if let s = r.systolic, let d = r.diastolic {
                    day.mergeBloodPressure([RingBloodPressureReading(time: r.date, systolic: s, diastolic: d)])
                }
                // The band's automatic readings in its history become the day's readings too, so
                // Jarvis Health has every one, not only those taken in the app.
                for reading in readings(r) { upsert(&day, reading) }
            }
        }

        for s in sleep where RingDates.dayKey(s.end, calendar: calendar) == key {
            let stages = stages(s)
            guard !stages.isEmpty else { continue }
            let hour = calendar.component(.hour, from: s.end)
            if s.end.timeIntervalSince(s.start) < napLongest, (10..<20).contains(hour) {
                day.mergeNaps([RingNap(start: s.start, end: s.end)])
            } else {
                let c = calendar.dateComponents([.hour, .minute], from: s.start)
                day.mergeSleep(RingSleepSession(start: s.start, end: s.end,
                                                reportedStartMinute: (c.hour ?? 0) * 60 + (c.minute ?? 0), stages: stages))
            }
        }
        return day
    }

    /// Every day the records and sleep touch, folded into `store`. Returns the day keys written.
    @MainActor
    @discardableResult
    static func apply(records: [BandDailyRecord], sleep: [BandSleep], to store: RingHistoryStore,
                      calendar: Calendar = .current) -> Set<String> {
        var dates: [String: Date] = [:]
        for r in records { dates[RingDates.dayKey(r.date, calendar: calendar)] = r.date }
        for s in sleep { dates[RingDates.dayKey(s.end, calendar: calendar)] = s.end }
        let now = Date()
        for (key, date) in dates {
            let updated = day(store.day(key), records: records, sleep: sleep, date: date, calendar: calendar)
            store.update(key) { stored in
                stored = updated
                stored.syncedAt = now
            }
        }
        return Set(dates.keys)
    }

    /// The band's running totals (`D8`) for today, when they are ahead of the 5-minute records.
    static func steps(_ s: BandSteps, into day: RingDay) -> RingDay {
        var d = day
        let old = d.activity
        d.activity = RingActivity(steps: max(s.steps, old?.steps ?? 0), runningSteps: old?.runningSteps ?? 0,
                                  calories: max(s.calories ?? 0, old?.calories ?? 0),
                                  distanceMeters: max(s.distanceMeters ?? 0, old?.distanceMeters ?? 0),
                                  sportMinutes: old?.sportMinutes ?? 0)
        return d
    }

    // MARK: Helpers

    /// A 5-minute record's blood pressure, glucose and blood components, as readings.
    static func readings(_ r: BandDailyRecord) -> [RingMeasurementRecord] {
        var out: [RingMeasurementRecord] = []
        if let s = r.systolic, let d = r.diastolic, (60...260).contains(s), (30...160).contains(d), d < s {
            out.append(RingMeasurementRecord(type: BandMeasure.bloodPressure.name, time: r.date, outcome: "done",
                                             value: nil, systolic: s, diastolic: d, celsius: nil))
        }
        if let g = r.bloodGlucose, (1.0...35.0).contains(g) {
            out.append(RingMeasurementRecord(type: BandMeasure.bloodGlucose.name, time: r.date, outcome: "done", value: nil,
                                             systolic: nil, diastolic: nil, celsius: nil, extra: ["blood_glucose_mmol_l": g]))
        }
        if let c = r.bloodComponent, c.uricAcid > 0 || c.cholesterol > 0 || c.triglycerides > 0 {
            var extra: [String: Double] = [:]
            for (k, v) in c.json { if let d = v as? Double, d > 0 { extra[k] = d } }
            out.append(RingMeasurementRecord(type: BandMeasure.bloodComponent.name, time: r.date, outcome: "done",
                                             value: nil, systolic: nil, diastolic: nil, celsius: nil, extra: extra))
        }
        return out
    }

    /// One reading per kind and time: a sync that brings it again replaces it.
    static func upsert(_ day: inout RingDay, _ record: RingMeasurementRecord) {
        day.measurements.removeAll { $0.type == record.type && abs($0.time.timeIntervalSince(record.time)) < 1 }
        day.measurements.append(record)
        day.measurements.sort { $0.time < $1.time }
    }

    /// The band's curve as the ring's stage numbering, one run per change: 0 deep, 1 light,
    /// 2 REM, 3 insomnia and 4 awake → awake. The points share the segment's span evenly
    /// (one a minute when they match it).
    static func stages(_ s: BandSleep) -> [RingSleepStage] {
        guard !s.curve.isEmpty else { return [] }
        let span = max(1, Int((s.end.timeIntervalSince(s.start) / 60).rounded()))
        var out: [RingSleepStage] = []
        var assigned = 0
        for (i, point) in s.curve.enumerated() {
            let upTo = Int((Double(span) * Double(i + 1) / Double(s.curve.count)).rounded())
            let minutes = upTo - assigned
            assigned = upTo
            guard minutes > 0 else { continue }
            let stage: Int
            switch point {
            case 0: stage = RingSleepStage.deep
            case 1: stage = RingSleepStage.light
            case 2: stage = RingSleepStage.rem
            default: stage = RingSleepStage.awake
            }
            if let last = out.last, last.stage == stage { out[out.count - 1].minutes += minutes } else {
                out.append(RingSleepStage(stage: stage, minutes: minutes))
            }
        }
        return out
    }

    private static func mean(_ values: [Int]) -> Double? {
        values.isEmpty ? nil : (Double(values.reduce(0, +)) / Double(values.count) * 10).rounded() / 10
    }

    /// Sets one bucket of a day-long series, creating the series at `interval` minutes.
    private static func put(_ series: inout RingSeries?, interval: Int, minute: Int, value: Double) {
        let count = 1440 / interval
        var s = series ?? RingSeries(intervalMinutes: interval, values: [Double](repeating: 0, count: count))
        if s.intervalMinutes != interval || s.values.count != count {
            s = RingSeries(intervalMinutes: interval, values: [Double](repeating: 0, count: count))
        }
        s.values[max(0, min(count - 1, minute / interval))] = value
        series = s
    }

    private static func slots(from minutes: [Int: RingStepMinute]) -> [RingStepSlot] {
        var bySlot: [Int: RingStepSlot] = [:]
        for (minute, m) in minutes {
            let slot = minute / 15
            var s = bySlot[slot] ?? RingStepSlot(slot: slot, steps: 0, calories: 0, distanceMeters: 0)
            s.steps += m.steps
            s.calories += m.calories
            s.distanceMeters += m.distanceMeters
            bySlot[slot] = s
        }
        return bySlot.values.sorted { $0.slot < $1.slot }
    }
}
