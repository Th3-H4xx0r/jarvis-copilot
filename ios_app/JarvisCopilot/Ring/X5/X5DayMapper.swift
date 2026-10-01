import Foundation

/// Decoded X5 history, one sync's worth, waiting to be folded into the day store.
struct X5Batch: Equatable {
    var totals: [X5DayTotal] = []
    var blocks: [X5StepBlock] = []
    var sleep: [X5SleepChunk] = []
    var hr: [X5HRBlock] = []
    var singleHR: [X5Reading] = []
    var hrv: [X5HRV] = []
    var temperature: [X5Reading] = []
    var spo2: [X5Reading] = []
    var manualSpO2: [X5Reading] = []
    var workouts: [X5WorkoutRecord] = []

    var isEmpty: Bool {
        totals.isEmpty && blocks.isEmpty && sleep.isEmpty && hr.isEmpty && singleHR.isEmpty && hrv.isEmpty
            && temperature.isEmpty && spo2.isEmpty && manualSpO2.isEmpty && workouts.isEmpty
    }
}

/// Folds X5 records into `RingDay`, the shape the R12's charts, the Health tab and the server
/// payload already read. Applying the same batch twice changes nothing: every value lands in a
/// keyed place (a minute, a 5-minute bucket, an hour, a session start) rather than being added.
@MainActor
enum X5DayMapper {
    static let plausibleHeartRate = 30.0...220.0
    static let plausibleSpO2 = 70.0...100.0
    /// Chunks of one night arrive back to back; anything closer than this is the same sleep.
    static let sleepJoinGap: TimeInterval = 5 * 60
    /// A sleep shorter than this that ends in the daytime is a nap.
    static let napLongest: TimeInterval = 3 * 3600

    @discardableResult
    static func apply(_ batch: X5Batch, to store: RingHistoryStore, calendar: Calendar = .current) -> Set<String> {
        var days: [String: RingDay] = [:]
        func edit(_ key: String, _ body: (inout RingDay) -> Void) {
            var day = days[key] ?? store.day(key)
            body(&day)
            days[key] = day
        }
        func key(_ date: Date) -> String { RingDates.dayKey(date, calendar: calendar) }
        func minuteOfDay(_ date: Date) -> Int {
            let c = calendar.dateComponents([.hour, .minute], from: date)
            return (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }

        // Day totals: the ring's own figures for the whole day.
        for total in batch.totals {
            guard let y = total.day.year, let m = total.day.month, let d = total.day.day else { continue }
            edit(RingDates.dayKey(year: y, month: m, day: d)) { day in
                day.activity = RingActivity(steps: total.steps, runningSteps: 0, calories: total.calories100 * 10,
                                            distanceMeters: total.distanceMeters,
                                            sportMinutes: total.exerciseSeconds / 60)
            }
        }

        // Steps: each block's minutes land on their own minute; its energy and distance are
        // shared out by steps, the remainder on its last stepping minute.
        for block in batch.blocks {
            let stepping = block.perMinute.enumerated().filter { $0.element > 0 }
            let total = stepping.reduce(0) { $0 + $1.element }
            guard total > 0 else { continue }
            let calories = block.calories100 * 10
            var caloriesLeft = calories
            var distanceLeft = block.distanceMeters
            for (n, (offset, steps)) in stepping.enumerated() {
                let when = block.start.addingTimeInterval(TimeInterval(offset * 60))
                let last = n == stepping.count - 1
                let cal = last ? caloriesLeft : calories * steps / total
                let dist = last ? distanceLeft : block.distanceMeters * steps / total
                caloriesLeft -= cal
                distanceLeft -= dist
                edit(key(when)) { day in
                    var minutes = day.stepMinutes ?? [:]
                    minutes[minuteOfDay(when)] = RingStepMinute(steps: steps, calories: cal, distanceMeters: dist)
                    day.stepMinutes = minutes
                }
            }
        }

        // Heart rate every 5 s → the mean of each minute's readings.
        var hrSums: [String: [Int: (sum: Double, count: Int)]] = [:]
        for block in batch.hr {
            for (i, bpm) in block.bpm.enumerated() where plausibleHeartRate.contains(Double(bpm)) {
                let when = block.start.addingTimeInterval(TimeInterval(i * 5))
                let k = key(when), minute = minuteOfDay(when)
                let old = hrSums[k]?[minute] ?? (0, 0)
                hrSums[k, default: [:]][minute] = (old.sum + Double(bpm), old.count + 1)
            }
        }
        for (k, minutes) in hrSums {
            edit(k) { day in
                for (minute, acc) in minutes {
                    put(&day.heartRate, interval: 1, minute: minute, value: (acc.sum / Double(acc.count) * 10).rounded() / 10)
                }
            }
        }

        for reading in batch.singleHR where plausibleHeartRate.contains(reading.value) {
            edit(key(reading.date)) { day in
                day.manualHeartRate = RingDay.merged(day.manualHeartRate,
                                                     [RingTimedValue(minute: minuteOfDay(reading.date), value: reading.value)])
            }
        }

        for reading in batch.hrv {
            edit(key(reading.date)) { day in
                let minute = minuteOfDay(reading.date)
                if reading.hrv > 0 { put(&day.hrv, interval: 5, minute: minute, value: Double(reading.hrv)) }
                if reading.stress > 0 { put(&day.stress, interval: 5, minute: minute, value: Double(reading.stress)) }
                if reading.systolic > 0, reading.diastolic > 0 {
                    day.mergeBloodPressure([RingBloodPressureReading(time: reading.date, systolic: reading.systolic,
                                                                     diastolic: reading.diastolic)])
                }
            }
        }

        for reading in batch.temperature {
            edit(key(reading.date)) { day in
                put(&day.temperature, interval: 5, minute: minuteOfDay(reading.date), value: reading.value)
            }
        }

        for reading in batch.spo2 where plausibleSpO2.contains(reading.value) {
            edit(key(reading.date)) { day in
                let hour = minuteOfDay(reading.date) / 60
                var range = day.spo2 ?? RingMinMax(min: [Int](repeating: 0, count: 24), max: [Int](repeating: 0, count: 24))
                let value = Int(reading.value)
                range.min[hour] = range.min[hour] == 0 ? value : Swift.min(range.min[hour], value)
                range.max[hour] = Swift.max(range.max[hour], value)
                day.spo2 = range
            }
        }

        for reading in batch.manualSpO2 where plausibleSpO2.contains(reading.value) {
            edit(key(reading.date)) { day in
                day.manualSpO2 = RingDay.merged(day.manualSpO2,
                                                [RingTimedValue(minute: minuteOfDay(reading.date), value: reading.value)])
            }
        }

        applySleep(batch.sleep, store: store, days: &days, calendar: calendar)

        // Slots follow the minutes, whichever sync each minute came in.
        for (k, day) in days where day.stepMinutes != nil {
            days[k]?.stepSlots = slots(from: day.stepMinutes ?? [:])
        }

        let now = Date()
        for (k, day) in days {
            store.update(k) { stored in
                stored = day
                stored.syncedAt = now
            }
        }
        return Set(days.keys)
    }

    // MARK: Helpers

    /// Sets one bucket of a day-long series, creating the series at `interval` minutes.
    private static func put(_ series: inout RingSeries?, interval: Int, minute: Int, value: Double) {
        let count = 1440 / interval
        var s = series ?? RingSeries(intervalMinutes: interval, values: [Double](repeating: 0, count: count))
        if s.intervalMinutes != interval || s.values.count != count {
            s = RingSeries(intervalMinutes: interval, values: [Double](repeating: 0, count: count))
        }
        let index = max(0, min(count - 1, minute / interval))
        s.values[index] = value
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

    /// The ring's minute codes as the R12's stage numbering: 1 deep, 2 light, 3 REM, else awake.
    private static func stage(_ code: Int) -> Int {
        switch code {
        case 1: return RingSleepStage.deep
        case 2: return RingSleepStage.light
        case 3: return RingSleepStage.rem
        default: return RingSleepStage.awake
        }
    }

    /// `run` laid over the stored night minute by minute: the night up to where the run starts,
    /// awake across any gap, the run itself, and whatever of the night came after it.
    private static func overlay(_ run: (start: Date, stages: [RingSleepStage], end: Date),
                                onto night: RingSleepSession) -> (start: Date, stages: [RingSleepStage], end: Date) {
        var minutes: [Int] = night.stages.flatMap { [Int](repeating: $0.stage, count: max(0, $0.minutes)) }
        let offset = max(0, Int((run.start.timeIntervalSince(night.start) / 60).rounded()))
        let runMinutes = run.stages.flatMap { [Int](repeating: $0.stage, count: max(0, $0.minutes)) }
        if minutes.count < offset { minutes += [Int](repeating: RingSleepStage.awake, count: offset - minutes.count) }
        for (i, stage) in runMinutes.enumerated() {
            if offset + i < minutes.count { minutes[offset + i] = stage } else { minutes.append(stage) }
        }
        var stages: [RingSleepStage] = []
        for stage in minutes { append(stage, minutes: 1, to: &stages) }
        return (night.start, stages, night.start.addingTimeInterval(TimeInterval(minutes.count * 60)))
    }

    private static func append(_ stage: Int, minutes: Int, to stages: inout [RingSleepStage]) {
        guard minutes > 0 else { return }
        if let last = stages.last, last.stage == stage {
            stages[stages.count - 1].minutes += minutes
        } else {
            stages.append(RingSleepStage(stage: stage, minutes: minutes))
        }
    }

    /// Joins chunks that follow each other — and a night already stored that this sync's first
    /// chunk continues — into sessions, then files each under the day it ends: a night in
    /// `sleep`, a short daytime one in `naps`.
    private static func applySleep(_ chunks: [X5SleepChunk], store: RingHistoryStore, days: inout [String: RingDay],
                                   calendar: Calendar) {
        guard !chunks.isEmpty else { return }
        func key(_ date: Date) -> String { RingDates.dayKey(date, calendar: calendar) }
        func day(_ k: String) -> RingDay { days[k] ?? store.day(k) }

        var runs: [(start: Date, stages: [RingSleepStage], end: Date)] = []
        for chunk in chunks.sorted(by: { $0.start < $1.start }) where !chunk.codes.isEmpty {
            let chunkEnd = chunk.start.addingTimeInterval(TimeInterval(chunk.codes.count * 60))
            var stages: [RingSleepStage] = []
            for code in chunk.codes { append(stage(code), minutes: 1, to: &stages) }
            if var last = runs.last, chunk.start.timeIntervalSince(last.end) <= sleepJoinGap,
               chunk.start >= last.start {
                let gap = Int(max(0, chunk.start.timeIntervalSince(last.end)) / 60)
                append(RingSleepStage.awake, minutes: gap, to: &last.stages)
                for s in stages { append(s.stage, minutes: s.minutes, to: &last.stages) }
                last.end = max(last.end, chunkEnd)
                runs[runs.count - 1] = last
            } else if runs.last.map({ chunk.start < $0.end }) ?? false {
                continue // a chunk overlapping one already taken: the same minutes again
            } else {
                runs.append((chunk.start, stages, chunkEnd))
            }
        }

        for var run in runs {
            // A night stored by an earlier sync that this run carries on — or overlaps, because the
            // newest chunk is read again until the ring has finished writing it.
            let candidates = Set([key(run.start.addingTimeInterval(-sleepJoinGap)), key(run.start), key(run.end)])
            for k in candidates {
                var stored = day(k)
                guard let previous = stored.sleep.first(where: {
                    $0.start < run.start && run.start <= $0.end.addingTimeInterval(sleepJoinGap)
                }) else { continue }
                run = overlay(run, onto: previous)
                stored.sleep.removeAll { $0 == previous }
                days[k] = stored
            }

            let endKey = key(run.end)
            var target = day(endKey)
            let hour = calendar.component(.hour, from: run.end)
            if run.end.timeIntervalSince(run.start) < napLongest, (10..<20).contains(hour) {
                target.mergeNaps([RingNap(start: run.start, end: run.end)])
            } else {
                let startMinute = calendar.component(.hour, from: run.start) * 60 + calendar.component(.minute, from: run.start)
                target.mergeSleep(RingSleepSession(start: run.start, end: run.end, reportedStartMinute: startMinute,
                                                   stages: run.stages))
            }
            days[endKey] = target
        }
    }
}
