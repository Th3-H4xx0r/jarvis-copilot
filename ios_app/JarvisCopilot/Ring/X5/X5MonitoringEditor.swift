import SwiftUI

/// How the settings screen shows and edits one automatic-measurement schedule.
extension X5Monitoring {
    static let intervals = [5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240]
    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// The menu's choices, keeping a value set somewhere else (an agent, an older build).
    static func intervalChoices(including current: Int) -> [Int] {
        Array(Set(intervals + [current])).sorted()
    }

    static func label(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(minutes) min" }
        if rest > 0 { return "\(hours) h \(rest) min" }
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// What the list row shows on the right.
    var value: String { on ? Self.label(minutes: intervalMinutes) : "Off" }

    /// The row's caption: only when it isn't all day, every day.
    var window: String? {
        let days: String?
        switch weekdays & 0x7F {
        case 0x7F: days = nil
        case 0b0111110: days = "weekdays"
        case 0b1000001: days = "weekends"
        case 0: days = "no days"
        default: days = (0..<7).filter(has(weekday:)).map { Self.dayNames[$0] }.joined(separator: ", ")
        }
        if isAllDay && days == nil { return nil }
        let hours = isAllDay ? "All day"
            : String(format: "%02d:%02d–%02d:%02d", startHour, startMinute, endHour, endMinute)
        return [hours, days].compactMap { $0 }.joined(separator: " · ")
    }

    /// 0 = Sunday … 6 = Saturday, the ring's own bit order.
    func has(weekday: Int) -> Bool { weekdays & (1 << weekday) != 0 }

    mutating func toggle(weekday: Int) { weekdays ^= UInt8(1 << weekday) }

    var isAllDay: Bool {
        get { startHour == 0 && startMinute == 0 && endHour == 23 && endMinute == 59 }
        set {
            (startHour, startMinute, endHour, endMinute) = newValue ? (0, 0, 23, 59) : (7, 0, 22, 0)
        }
    }

    /// An end before the start runs through midnight — how the ring reads 22:00–08:00.
    var isOvernight: Bool { (endHour, endMinute) < (startHour, startMinute) }
}

/// One automatic measurement: on/off, how often, which hours and which days.
struct X5MonitoringEditor: View {
    @ObservedObject var manager: X5Manager
    let title: String
    let original: X5Monitoring

    @State private var draft: X5Monitoring
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(manager: X5Manager, title: String, schedule: X5Monitoring) {
        self.manager = manager
        self.title = title
        self.original = schedule
        _draft = State(initialValue: schedule)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                CardGroup {
                    Row { Toggle("Measure automatically", isOn: $draft.on) }
                }
                if draft.on {
                    CardGroup("How often", footer: oftenFooter) {
                        Row {
                            Picker("Every", selection: $draft.intervalMinutes) {
                                ForEach(X5Monitoring.intervalChoices(including: draft.intervalMinutes), id: \.self) {
                                    Text(X5Monitoring.label(minutes: $0)).tag($0)
                                }
                            }
                        }
                    }
                    CardGroup("When", footer: draft.isOvernight ? "Runs through midnight." : nil) {
                        Row { Toggle("All day", isOn: $draft.isAllDay) }
                        if !draft.isAllDay {
                            RowDivider()
                            Row { DatePicker("From", selection: time(\.startHour, \.startMinute), displayedComponents: .hourAndMinute) }
                            RowDivider()
                            Row { DatePicker("Until", selection: time(\.endHour, \.endMinute), displayedComponents: .hourAndMinute) }
                        }
                        RowDivider()
                        Row { days }
                    }
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 30)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save", action: save)
                    .disabled(draft == original || saving)
            }
        }
    }

    private var oftenFooter: String {
        draft.type == .heartRate
            ? "Each reading takes about a minute. While you sleep the ring checks every 5 minutes whatever this says."
            : "Each reading takes about a minute."
    }

    private var days: some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { day in
                let on = draft.has(weekday: day)
                Button { draft.toggle(weekday: day) } label: {
                    Text(Calendar.current.veryShortWeekdaySymbols[day])
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(on ? Color.black : Color.secondary)
                        .background(on ? JcAccent.color : Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[day])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    /// A clock time on today's date, read from and written back to two of the schedule's fields.
    private func time(_ hour: WritableKeyPath<X5Monitoring, Int>,
                      _ minute: WritableKeyPath<X5Monitoring, Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: draft[keyPath: hour], minute: draft[keyPath: minute],
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft[keyPath: hour] = parts.hour ?? 0
                draft[keyPath: minute] = parts.minute ?? 0
            })
    }

    private func save() {
        saving = true
        error = nil
        let schedule = draft
        Task {
            do {
                guard await manager.ensureConnected(timeout: 12) else { throw DeviceError.notConnected }
                try await manager.session.setMonitoring(schedule)
                manager.releaseIfIdle()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                manager.releaseIfIdle()
            }
            saving = false
        }
    }
}
