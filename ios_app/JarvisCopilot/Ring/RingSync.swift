import Foundation

struct RingSyncReport: Codable, Equatable {
    var days: Int
    var updated: [String] = []
    var failed: [String: String] = [:]
    var startedAt: Date
    var finishedAt: Date?
}

/// Pulls the ring's stored history into `RingHistoryStore`.
///
/// Event-driven only — after setup, on foreground, on the ring's own "new data" pushes, on
/// skill reads and on request. Nothing polls. One sync runs at a time; a request for at least
/// as many days as the running one simply waits for it.
@MainActor
final class RingSync: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var lastFullSync: Date?
    @Published private(set) var lastTodaySync: Date?
    @Published private(set) var lastReport: RingSyncReport?
    @Published private(set) var currentStep: String?

    /// QRing's history window: today plus six days.
    let historyDays = 6
    var todayStaleness: TimeInterval = 15 * 60
    var now: () -> Date = { Date() }
    /// Follows the phone's time zone as it changes; day keys and minutes are local.
    var calendar = Calendar.autoupdatingCurrent

    private let session: RingSession
    private let storeProvider: () -> RingHistoryStore?
    private var running: (id: UUID, days: Int, task: Task<RingSyncReport, Never>)?
    private var pendingMetrics = Set<RingMetric>()
    private var metricDebounce: Task<Void, Never>?

    init(session: RingSession, store: @escaping () -> RingHistoryStore?) {
        self.session = session
        self.storeProvider = store
        session.onDataUpdated = { [weak self] metric in self?.syncMetricToday(metric) }
        session.onLiveActivity = { [weak self] activity in
            guard let self, let store = self.storeProvider() else { return }
            store.update(self.todayKey) { day in
                // Live pushes carry steps, calories and distance only.
                var totals = day.activity ?? activity
                totals.steps = max(totals.steps, activity.steps)
                totals.calories = max(totals.calories, activity.calories)
                totals.distanceMeters = max(totals.distanceMeters, activity.distanceMeters)
                day.activity = totals
            }
        }
        session.onLiveReading = { [weak self] metric, reading in
            guard let self, let store = self.storeProvider() else { return }
            let value = RingTimedValue(minute: self.minuteOfDay(reading.date), value: reading.value)
            store.update(RingDates.dayKey(reading.date, calendar: self.calendar)) { day in
                switch metric {
                case .heartRate: day.instantHeartRate = RingDay.merged(day.instantHeartRate, [value])
                case .spo2: day.instantSpO2 = RingDay.merged(day.instantSpO2, [value])
                case .temperature: day.instantTemperature = RingDay.merged(day.instantTemperature, [value])
                default: break
                }
            }
        }
        session.onMeasurementFinished = { [weak self] state in
            guard let self, let store = self.storeProvider() else { return }
            let time = state.finishedAt ?? state.startedAt
            let record = RingMeasurementRecord(type: state.type.name, time: time, outcome: state.phase.rawValue,
                                               value: state.value, systolic: state.systolic,
                                               diastolic: state.diastolic, celsius: state.celsius)
            let reading = RingTimedValue(minute: self.minuteOfDay(time), value: Double(state.value ?? 0))
            store.update(RingDates.dayKey(time, calendar: self.calendar)) { day in
                day.measurements.append(record)
                guard state.phase == .done else { return }
                switch state.type {
                case .heartRate: day.instantHeartRate = RingDay.merged(day.instantHeartRate, [reading])
                case .spo2: day.instantSpO2 = RingDay.merged(day.instantSpO2, [reading])
                case .temperature:
                    if let celsius = state.celsius {
                        day.instantTemperature = RingDay.merged(day.instantTemperature,
                                                                [RingTimedValue(minute: reading.minute, value: celsius)])
                    }
                case .bloodPressure:
                    if let sys = state.systolic, let dia = state.diastolic {
                        day.mergeBloodPressure([RingBloodPressureReading(time: time, systolic: sys, diastolic: dia)])
                    }
                default: break
                }
            }
        }
    }

    var isFullSyncDue: Bool {
        guard let last = lastFullSync else { return true }
        return last < calendar.startOfDay(for: now())
    }

    var isTodayStale: Bool {
        guard let last = lastTodaySync else { return true }
        return now().timeIntervalSince(last) > todayStaleness
    }

    var isStale: Bool { isFullSyncDue || isTodayStale }

    func syncIfStale() {
        guard isStale else { return }
        let days = isFullSyncDue ? historyDays : 0
        Task { _ = await sync(days: days) }
    }

    /// Syncs today plus `days` earlier days (clamped to the history window).
    @discardableResult
    func sync(days requested: Int) async -> RingSyncReport {
        let days = max(0, min(historyDays, requested))
        if let current = running {
            let report = await current.task.value
            if current.days >= days { return report }
        }
        if let current = running, current.days >= days {
            return await current.task.value
        }
        let id = UUID()
        let task = Task { () -> RingSyncReport in
            let report = await self.perform(days: days)
            if self.running?.id == id { self.running = nil }
            return report
        }
        running = (id, days, task)
        return await task.value
    }

    /// A ring push said this metric changed; batch pushes that arrive together.
    func syncMetricToday(_ metric: RingMetric) {
        pendingMetrics.insert(metric)
        metricDebounce?.cancel()
        metricDebounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, let store = self.storeProvider() else { return }
            let metrics = self.pendingMetrics
            self.pendingMetrics.removeAll()
            let today = self.now()
            for metric in RingMetric.allCases where metrics.contains(metric) {
                try? await self.run(metric, store: store, days: 0, now: today)
            }
        }
    }

    // MARK: Run

    private var todayKey: String { RingDates.dayKey(now(), calendar: calendar) }

    private func minuteOfDay(_ date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func dayKey(_ daysAgo: Int, _ now: Date) -> String {
        RingDates.dayKey(RingDates.midnight(daysAgo: daysAgo, now: now, calendar: calendar), calendar: calendar)
    }

    private func perform(days: Int) async -> RingSyncReport {
        isSyncing = true
        defer {
            isSyncing = false
            currentStep = nil
        }
        let today = now()
        var report = RingSyncReport(days: days, startedAt: today)
        guard let store = storeProvider() else {
            report.failed["store"] = "the ring has no identity yet"
            report.finishedAt = now()
            lastReport = report
            return report
        }
        guard session.transport.link?.isLinkReady == true else {
            report.failed["link"] = RingError.notConnected.localizedDescription
            report.finishedAt = now()
            lastReport = report
            return report
        }

        currentStep = "battery"
        await session.refreshBattery()
        let historyWanted = (0...days).filter { needsHistory(store, daysAgo: $0, now: today) }
        for metric in RingMetric.allCases where session.supports(metric) {
            currentStep = metric.rawValue
            do {
                try await run(metric, store: store, days: days, now: today)
                report.updated.append(metric.rawValue)
            } catch {
                report.failed[metric.rawValue] = error.localizedDescription
                JcLog.devices.notice("ring sync \(metric.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if case RingError.notConnected = error { break }
            }
        }

        let finished = now()
        report.finishedAt = finished
        if !report.updated.isEmpty {
            lastTodaySync = finished
            if days >= historyDays { lastFullSync = finished }
        }
        // A past day is done only once every metric has read it; until then each sync retries it.
        if !report.updated.isEmpty, report.failed.isEmpty {
            for daysAgo in historyWanted {
                store.update(dayKey(daysAgo, today)) { $0.syncedAt = finished }
            }
        }
        if days >= historyDays { store.prune(now: today, calendar: calendar) }
        lastReport = report
        return report
    }

    /// Past days are re-read until a sync lands after the day ended.
    private func needsHistory(_ store: RingHistoryStore, daysAgo: Int, now: Date) -> Bool {
        guard daysAgo > 0 else { return true }
        guard let synced = store.day(dayKey(daysAgo, now)).syncedAt else { return true }
        return synced < RingDates.midnight(daysAgo: daysAgo - 1, now: now, calendar: calendar)
    }

    private func run(_ metric: RingMetric, store: RingHistoryStore, days: Int, now: Date) async throws {
        let caps = session.capabilities
        switch metric {
        case .activity:
            try await syncActivity(store, days: days, now: now)
        case .sleep:
            try await syncSleep(store, days: days, now: now)
        case .heartRate:
            try await syncHeartRate(store, days: days, now: now)
            // QRing also takes 0x3C's heart bit as manual heart-rate support.
            if session.probe.works(.manualHeartRate) ?? (caps.manualHeartRate || caps.heart) {
                try await syncManual(store, spo2: false, all: days > 0, now: now)
            }
        case .spo2:
            if session.probe.works(.spo2) ?? caps.bloodOxygen {
                try await syncHourly(store, request: .bigSpO2, spo2: true, now: now)
            }
            if session.probe.works(.manualSpO2) ?? caps.manualBloodOxygen {
                try await syncManual(store, spo2: true, all: days > 0, now: now)
            }
        case .hrv:
            try await syncDaySeries(store, hrv: true, days: days, now: now)
        case .stress:
            try await syncDaySeries(store, hrv: false, days: days, now: now)
        case .temperature:
            guard session.probe.works(.temperature) ?? caps.intervalTemperature else { return }
            for daysAgo in 0...days where needsHistory(store, daysAgo: daysAgo, now: now) {
                if let series = try await intervalSeries(RingRequest.bigIntervalTemperature(dayOffset:packet:),
                                                         dayOffset: daysAgo, wide: true),
                   series.values.contains(where: { $0 > 0 }) {
                    store.update(dayKey(daysAgo, now)) { $0.temperature = series }
                }
            }
        case .bloodPressure:
            try await syncBloodPressure(store)
        case .bloodSugar:
            try await syncHourly(store, request: .bigBloodSugar, spo2: false, now: now)
        }
    }

    private func syncActivity(_ store: RingHistoryStore, days: Int, now: Date) async throws {
        if let reply = try await session.transport.perform(.todayActivity, until: .single).first,
           let totals = RingDecode.activity(reply.payload) {
            store.update(dayKey(0, now)) { $0.activity = totals }
        }
        for daysAgo in 0...days where needsHistory(store, daysAgo: daysAgo, now: now) {
            var first = true
            let frames = try await session.transport.perform(.stepDetail(dayOffset: daysAgo), until: .packets { inbound in
                defer { first = false }
                return RingDecode.isSlotReplyLast(inbound.payload, first: first)
            })
            let slots = RingDecode.stepDetail(frames.map(\.payload))
            for (key, group) in Dictionary(grouping: slots, by: \.dayKey) {
                store.update(key) { $0.mergeStepSlots(group.map(\.slot)) }
            }
        }
    }

    private func syncSleep(_ store: RingHistoryStore, days: Int, now: Date) async throws {
        let caps = session.capabilities
        // The R12 answers large-data sleep without advertising it, so what it answered wins.
        if session.probe.works(.sleep) ?? (caps.newSleepProtocol || !caps.isKnown) {
            let frames = try await session.transport.perform(.bigSleep(all: days > 0),
                                                             accepting: [RingOp.bigSleep, RingOp.bigNaps], until: .idle)
            for frame in frames {
                if frame.cmd == RingOp.bigSleep {
                    for entry in RingDecode.sleep(frame.payload, now: now, calendar: calendar) {
                        store.update(RingDates.dayKey(entry.session.end, calendar: calendar)) { $0.mergeSleep(entry.session) }
                    }
                } else {
                    for entry in RingDecode.naps(frame.payload, now: now, calendar: calendar) where !entry.naps.isEmpty {
                        store.update(dayKey(entry.dayOffset, now)) { $0.mergeNaps(entry.naps) }
                    }
                }
            }
            return
        }
        for daysAgo in 0...days where needsHistory(store, daysAgo: daysAgo, now: now) {
            var first = true
            let frames = try await session.transport.perform(.legacySleep(dayOffset: daysAgo), until: .packets { inbound in
                defer { first = false }
                return RingDecode.isSlotReplyLast(inbound.payload, first: first)
            })
            for (key, slots) in RingDecode.legacySleep(frames.map(\.payload)) {
                store.update(key) { $0.legacySleepSlots.merge(slots) { _, new in new } }
            }
        }
    }

    private func syncHeartRate(_ store: RingHistoryStore, days: Int, now: Date) async throws {
        for daysAgo in 0...days where needsHistory(store, daysAgo: daysAgo, now: now) {
            let series: RingSeries?
            if session.probe.works(.heartRateSeries) ?? session.capabilities.realTimeHeartRate {
                series = try await intervalSeries(RingRequest.bigIntervalHeartRate(dayOffset:packet:),
                                                  dayOffset: daysAgo, wide: false)
            } else {
                // The legacy request carries the day's midnight in local seconds.
                let midnight = RingDates.midnight(daysAgo: daysAgo, now: now, calendar: calendar)
                let local = midnight.timeIntervalSince1970 + TimeInterval(calendar.timeZone.secondsFromGMT(for: midnight))
                var count = 0
                let frames = try await session.transport.perform(
                    .heartRateHistory(timestamp: UInt32(clamping: Int64(local))),
                    until: .packets { RingDecode.isDaySeriesLast($0.payload, count: &count) })
                series = RingDecode.heartRateHistory(frames.map(\.payload))
            }
            if let series, series.values.contains(where: { $0 > 0 }) {
                store.update(dayKey(daysAgo, now)) { $0.heartRate = series }
            }
        }
    }

    private func syncDaySeries(_ store: RingHistoryStore, hrv: Bool, days: Int, now: Date) async throws {
        for daysAgo in 0...days where needsHistory(store, daysAgo: daysAgo, now: now) {
            var count = 0
            let request: RingRequest = hrv ? .hrvHistory(dayOffset: daysAgo) : .stressHistory(dayOffset: daysAgo)
            let frames = try await session.transport.perform(request, until: .packets {
                RingDecode.isDaySeriesLast($0.payload, count: &count)
            })
            guard let series = RingDecode.hrvOrStress(frames.map(\.payload)),
                  series.values.contains(where: { $0 > 0 }) else { continue }
            store.update(dayKey(daysAgo, now)) { day in
                if hrv { day.hrv = series } else { day.stress = series }
            }
        }
    }

    /// Large-data interval series, one packet per request until the last.
    private func intervalSeries(_ build: (Int, Int) -> RingRequest, dayOffset: Int, wide: Bool) async throws -> RingSeries? {
        var values: [Double] = []
        var interval = 0
        var packet = 0
        for _ in 0..<64 {
            guard let reply = try await session.transport.perform(build(dayOffset, packet), until: .single).first,
                  let decoded = RingDecode.intervalPacket(reply.payload, wide: wide) else { break }
            interval = decoded.intervalMinutes
            values += decoded.values
            if decoded.count == 0 || decoded.index >= decoded.count - 1 { break }
            packet = decoded.index + 1
        }
        guard interval > 0 else { return nil }
        return RingSeries(intervalMinutes: interval, values: values)
    }

    private func syncManual(_ store: RingHistoryStore, spo2: Bool, all: Bool, now: Date) async throws {
        let request: RingRequest = spo2 ? .bigManualSpO2(all: all) : .bigManualHeartRate(all: all)
        let frames = try await session.transport.perform(request, until: .idle)
        for frame in frames {
            guard let list = RingDecode.manualList(frame.payload), !list.values.isEmpty else { continue }
            store.update(dayKey(list.dayOffset, now)) { day in
                if spo2 {
                    day.manualSpO2 = RingDay.merged(day.manualSpO2, list.values)
                } else {
                    day.manualHeartRate = RingDay.merged(day.manualHeartRate, list.values)
                }
            }
        }
    }

    private func syncHourly(_ store: RingHistoryStore, request: RingRequest, spo2: Bool, now: Date) async throws {
        let frames = try await session.transport.perform(request, until: .idle)
        for frame in frames {
            for record in RingDecode.hourlyMinMax(frame.payload)
            where record.value.max.contains(where: { $0 > 0 }) && record.dayOffset >= 0 {
                store.update(dayKey(record.dayOffset, now)) { day in
                    if spo2 { day.spo2 = record.value } else { day.bloodSugar = record.value }
                }
            }
        }
    }

    private func syncBloodPressure(_ store: RingHistoryStore) async throws {
        var count = 0
        let frames = try await session.transport.perform(.bloodPressureHistory, until: .packets { inbound in
            count += 1
            return RingDecode.isBloodPressureEnd(inbound.payload) || count >= 50
        })
        let readings = frames.compactMap { RingDecode.bloodPressureRecord($0.payload, timeZone: calendar.timeZone) }
        for (key, group) in Dictionary(grouping: readings, by: { RingDates.dayKey($0.time, calendar: calendar) }) {
            store.update(key) { $0.mergeBloodPressure(group) }
        }
    }
}
