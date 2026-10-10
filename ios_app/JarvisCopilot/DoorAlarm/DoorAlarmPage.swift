import SwiftUI

/// The Door Alarm page: the hub and the alarm state, Away / Home / Disarm, each door, the history,
/// the alarm's own settings, every setting the hub has (its data points), readings, the links to
/// the hub (ESP32 at home, Tuya's cloud), firmware, and setup. Live while open (3 s refresh).
struct DoorAlarmPage: View {
    @ObservedObject private var store: DoorAlarmStore = .shared
    @ObservedObject private var bridge: BridgeClient = .shared
    @State private var editing: DoorContact?
    @State private var renaming = false
    @State private var shared = BridgeClient.isExposed(DoorAlarmDevice.shared.deviceID)

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                if let state = store.state, state.setup.hub {
                    controls(state)
                    doors(state)
                    history
                    DoorAlarmSettingsCard(store: store, state: state)
                    hubSettings(state)
                    readings(state)
                    DoorLinksCard(state: state)
                } else {
                    notSetUp
                }
                CardGroup("Setup") {
                    NavigationLink { DoorAlarmSetupView() } label: {
                        Row { Label("Tuya cloud, hub and ESP32 proxy", systemImage: "gearshape") }
                    }
                    .buttonStyle(.plain)
                }
                sharing
            }
            .padding(.vertical, 12)
        }
        .refreshable { await store.load(); await store.loadHistory() }
        .onAppear { store.watch() }
        .onDisappear { store.unwatch() }
        .task {
            await store.loadHistory()
            // Ask for the alarm-sound permission now, on screen: iOS can't ask while the app is in
            // the background, which is exactly when the alarm would need it.
            await DoorAlarmDevice.shared.prepareAlarmSound()
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle(DoorAlarmDevice.shared.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { WearableMoreMenu(onRename: { renaming = true }) }
        }
        .wearableRename(isPresented: $renaming, current: DoorAlarmDevice.shared.name) { name in
            WearableNames.shared.rename(DoorAlarmDevice.kind, to: name)
        }
        .sheet(item: $editing) { contact in DoorContactEditor(store: store, contact: contact) }
        .confirmationDialog(store.refusal?.message ?? "", isPresented: Binding(
            get: { store.refusal != nil }, set: { if !$0 { store.refusal = nil } }), titleVisibility: .visible) {
            if let refusal = store.refusal {
                Button("Arm anyway, ignoring \(refusal.open.map(\.name).joined(separator: ", "))") {
                    Task { await store.arm(refusal.mode, bypass: refusal.open.map(\.id)) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .overlay(alignment: .bottom) { noticeBanner }
    }

    // MARK: Header

    private var header: some View {
        let alarm = store.state?.alarm
        return VStack(spacing: 8) {
            DoorHubView(state: DoorHubView.Look(alarm), compact: false)
                .frame(height: 210)
                .allowsHitTesting(false)
            Text(alarm?.title ?? "Door Alarm")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(alarm?.isAlerting == true ? JcTheme.danger : .primary)
            if let alarm, alarm.state == "arming" || alarm.state == "entry" {
                DoorCountdown(alarm: alarm, size: 88)
                Text(alarm.state == "entry" ? "\(alarm.contactName ?? "A door") opened — seconds to disarm"
                                            : "seconds until armed away")
                    .font(.headline)
                    .foregroundStyle(alarm.state == "entry" ? JcTheme.danger : .secondary)
            } else if let alarm, alarm.state == "triggered" {
                Text("\(alarm.contactName ?? "A door") opened\(alarm.sirenOn ? " — siren on" : "")")
                    .font(.headline)
                    .foregroundStyle(JcTheme.danger)
            } else if let problem = store.problem {
                Text(problem).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: Arm / disarm

    private func controls(_ state: DoorState) -> some View {
        let alarm = state.alarm
        return VStack(spacing: 10) {
            if alarm.state == "triggered" && alarm.sirenOn {
                Button { Task { await store.silence() } } label: {
                    Label("Silence siren", systemImage: "speaker.slash.fill").frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.jcGlass(tint: JcTheme.amber, full: true))
            }
            if alarm.state == "arming" {
                exitDelayRow(alarm)
            } else {
            HStack(spacing: 10) {
                armButton("Away", icon: "figure.walk.departure", mode: "away", on: alarm.mode == "away" && alarm.isArmed)
                armButton("Home", icon: "house.fill", mode: "home", on: alarm.mode == "home" && alarm.isArmed)
                Button { Task { await store.disarm() } } label: {
                    VStack(spacing: 4) {
                        if store.busy == "disarm" { ProgressView() } else { Image(systemName: "faceid") }
                        Text("Disarm").font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.jcGlass(tint: alarm.isAlerting ? JcTheme.danger : JcTheme.accent, full: true))
                // Never greyed out by another action in flight: this is the button that matters in an entry delay.
                .disabled(!alarm.isArmed || store.busy == "disarm")
            }
            }
        }
        .padding(.horizontal, 20)
    }

    /// During the Away exit delay: the Away button with a ring that drains from full to empty as
    /// the delay runs out, then Arm now and Cancel.
    private func exitDelayRow(_ alarm: DoorAlarmInfo) -> some View {
        HStack(spacing: 10) {
            Button {} label: {
                VStack(spacing: 4) {
                    Image(systemName: "figure.walk.departure")
                    Text("Away").font(.footnote.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.jcGlass(tint: JcTheme.accent, full: true))
            .allowsHitTesting(false)
            .overlay {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    Capsule()
                        .trim(from: 0, to: Self.exitFraction(alarm, at: context.date))
                        .stroke(JcTheme.accent, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                        .padding(-4)
                }
                .allowsHitTesting(false)
            }
            .accessibilityLabel("Arming away")
            Button { Task { await store.armNow() } } label: {
                VStack(spacing: 4) {
                    if store.busy == "arm_now" { ProgressView() } else { Image(systemName: "lock.shield.fill") }
                    Text("Arm now").font(.footnote.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.jcGlass(tint: JcTheme.accent, full: true))
            .disabled(store.busy != nil)
            Button { Task { await store.cancelArming() } } label: {
                VStack(spacing: 4) {
                    if store.busy == "cancel_arming" { ProgressView() } else { Image(systemName: "xmark") }
                    Text("Cancel").font(.footnote.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.jcGlass(tint: .secondary, full: true))
            .disabled(store.busy != nil)
        }
    }

    /// 1 when the exit delay starts, 0 when it ends.
    static func exitFraction(_ alarm: DoorAlarmInfo, at now: Date) -> CGFloat {
        guard let deadline = alarm.deadline, alarm.exitDelay > 0 else { return 0 }
        return CGFloat(min(1, max(0, deadline.timeIntervalSince(now) / Double(alarm.exitDelay))))
    }

    private func armButton(_ title: String, icon: String, mode: String, on: Bool) -> some View {
        Button { Task { await store.arm(mode) } } label: {
            VStack(spacing: 4) {
                if store.busy == "arm" { ProgressView() } else { Image(systemName: icon) }
                Text(title).font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.jcGlass(tint: on ? JcTheme.accent : .secondary, full: true))
        .disabled(store.busy != nil || store.state?.alarm.isAlerting == true)
    }

    // MARK: Doors

    private func doors(_ state: DoorState) -> some View {
        CardGroup("Doors", footer: state.contacts.isEmpty
                  ? "No door sensor reported yet. Open a door: it appears here once the hub tells Jarvis." : nil) {
            ForEach(Array(state.contacts.enumerated()), id: \.element.id) { index, contact in
                if index > 0 { RowDivider() }
                Button { editing = contact } label: {
                    Row {
                        HStack {
                            Image(systemName: contact.open == true ? "door.left.hand.open" : "door.left.hand.closed")
                                .foregroundStyle(contact.open == true ? JcTheme.amber : .secondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name)
                                Text(Self.doorLine(contact)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if contact.instant { tag("Instant") }
                            if !contact.activeHome { tag("Away only") }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    static func doorLine(_ c: DoorContact) -> String {
        let when = c.lastOpen.map { "opened " + $0.formatted(.relative(presentation: .named)) }
        switch c.open {
        case true?: return "Open" + (when.map { " · \($0)" } ?? "")
        case false?: return "Closed" + (when.map { " · \($0)" } ?? "")
        default: return when.map { "Last \($0)" } ?? "No openings yet"
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3)
            .background(.white.opacity(0.08), in: Capsule())
    }

    // MARK: History

    private var history: some View {
        CardGroup("History") {
            if store.events.isEmpty {
                Row { Text("Nothing yet").foregroundStyle(.secondary) }
            }
            ForEach(Array(store.events.prefix(12).enumerated()), id: \.element.id) { index, event in
                if index > 0 { RowDivider() }
                DoorEventRow(event: event)
            }
            if store.events.count > 12 {
                RowDivider()
                NavigationLink { DoorHistoryView() } label: {
                    Row { Text("All history").foregroundStyle(JcTheme.accent) }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Hub settings + readings

    @ViewBuilder private func hubSettings(_ state: DoorState) -> some View {
        if !state.settings.isEmpty {
            CardGroup("Hub settings", footer: "The hub's own settings, as Smart Life shows them. Changes are confirmed by the hub.") {
                ForEach(Array(state.settings.enumerated()), id: \.element.id) { index, point in
                    if index > 0 { RowDivider() }
                    DoorPointControl(store: store, point: point)
                }
            }
        }
    }

    @ViewBuilder private func readings(_ state: DoorState) -> some View {
        if !state.readings.isEmpty {
            CardGroup("Readings") {
                ForEach(Array(state.readings.enumerated()), id: \.element.id) { index, point in
                    if index > 0 { RowDivider() }
                    Row {
                        HStack {
                            Text(point.name)
                            Spacer()
                            Text(point.shown + (point.unit.isEmpty || point.display != nil ? "" : " \(point.unit)"))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    // MARK: Misc

    private var notSetUp: some View {
        CardGroup(footer: "Link your Tuya cloud project, pick the hub, then choose the ESP32 at home that keeps a local line to it.") {
            NavigationLink { DoorAlarmSetupView() } label: {
                Row {
                    Label("Set up the door alarm", systemImage: "wand.and.stars")
                        .foregroundStyle(JcTheme.accent)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var sharing: some View {
        CardGroup("Jarvis Copilot", footer: "Lets the alarm ring this iPhone and ask you for Face ID when Jarvis is asked to disarm.") {
            Row {
                Toggle("Share with Jarvis", isOn: Binding(
                    get: { shared },
                    set: { on in
                        shared = on
                        BridgeClient.setExposed(on, for: DoorAlarmDevice.shared.deviceID)
                        DoorAlarmDevice.shared.start()
                    }))
            }
            .disabled(!bridge.isPaired)
        }
    }

    @ViewBuilder private var noticeBanner: some View {
        if let notice = store.notice {
            Text(notice)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .jcLiquidGlass(in: Capsule())
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(3))
                    if store.notice == notice { store.notice = nil }
                }
        }
    }
}

struct DoorEventRow: View {
    let event: DoorEvent

    private var icon: (String, Color) {
        switch event.kind {
        case "door": return (event.open == false ? "door.left.hand.closed" : "door.left.hand.open",
                             event.open == false ? .secondary : JcTheme.amber)
        case "alarm": return ("lock.shield", JcTheme.accent)
        case "health": return ("exclamationmark.triangle", JcTheme.amber)
        default: return ("circle.fill", .secondary)
        }
    }

    var body: some View {
        Row {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: icon.0).foregroundStyle(icon.1).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.text).font(.subheadline)
                    Text(event.time.formatted(date: .abbreviated, time: .shortened)
                         + (event.source.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct DoorHistoryView: View {
    @ObservedObject private var store: DoorAlarmStore = .shared

    var body: some View {
        ScrollView {
            CardGroup {
                ForEach(Array(store.events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { RowDivider() }
                    DoorEventRow(event: event)
                }
            }
            .padding(.vertical, 12)
        }
        .refreshable { await store.loadHistory() }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One hub data point as a control: a switch, a choice, a stepper, or text.
struct DoorPointControl: View {
    @ObservedObject var store: DoorAlarmStore
    let point: DoorDataPoint

    var body: some View {
        Row {
            HStack {
                Text(point.name)
                Spacer()
                if store.busy == point.code {
                    ProgressView()
                } else {
                    control
                }
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch point.type {
        case "bool":
            Toggle("", isOn: Binding(get: { point.value == .bool(true) },
                                     set: { on in Task { await store.set(point, to: on) } }))
                .labelsHidden()
        case "enum":
            Menu {
                ForEach(point.range, id: \.self) { option in
                    Button(point.label(for: option)) { Task { await store.set(point, to: option) } }
                }
            } label: {
                Text(point.shown).foregroundStyle(JcTheme.accent)
            }
        case "value":
            let lo = point.min ?? 0
            let hi = Swift.max(lo, point.max ?? 100)
            let current: Int = {
                if case .number(let n) = point.value, abs(n) < 1e9 { return Swift.min(hi, Swift.max(lo, Int(n))) }
                return lo
            }()
            Stepper(value: Binding(get: { current }, set: { v in Task { await store.set(point, to: v) } }),
                    in: lo...hi, step: point.step) {
                Text("\(current)\(point.unit.isEmpty ? "" : " \(point.unit)")").monospacedDigit()
            }
            .fixedSize()
        default:
            Text(point.shown).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The alarm's own settings: delays and the siren.
struct DoorAlarmSettingsCard: View {
    @ObservedObject var store: DoorAlarmStore
    let state: DoorState

    var body: some View {
        CardGroup("Alarm", footer: "Exit delay: time to leave after arming Away. Entry delay: time to disarm after a door opens.") {
            stepper("Exit delay", value: state.alarm.exitDelay, range: 0...300, step: 10, key: "exit_delay")
            RowDivider()
            stepper("Entry delay", value: state.alarm.entryDelay, range: 0...300, step: 5, key: "entry_delay")
            RowDivider()
            stepper("Siren length", value: state.alarm.sirenDuration, range: 10...900, step: 30, key: "siren_duration")
        }
    }

    private func stepper(_ title: String, value: Int, range: ClosedRange<Int>, step: Int, key: String) -> some View {
        Row {
            Stepper(value: Binding(get: { value }, set: { v in Task { await store.updateAlarm([key: v]) } }),
                    in: range, step: step) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(value >= 60 && value % 60 == 0 ? "\(value / 60) min" : "\(value) s")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

/// The hub's links: the ESP32 at home and Tuya's cloud.
struct DoorLinksCard: View {
    let state: DoorState

    var body: some View {
        let l = state.links
        return CardGroup("Connection", footer: "The ESP32 at home talks to the hub on your Wi-Fi; Tuya's cloud is the backup.") {
            line("ESP32 proxy", l.localAlive ? "Connected" : Self.localText(l.localState), ok: l.localAlive)
            if let ip = l.localIP {
                RowDivider()
                line("Hub on the LAN", ip + (l.localVersion.map { " · v\($0)" } ?? ""), ok: nil)
            }
            if let rtt = l.rttMs, rtt >= 0 {
                RowDivider()
                line("Round trip", "\(rtt) ms" + (l.rssi.map { " · Wi-Fi \($0) dBm" } ?? ""), ok: nil)
            }
            RowDivider()
            line("Tuya cloud", l.cloudAlive ? "Connected" : (l.cloudError ?? l.cloudState.capitalized), ok: l.cloudAlive)
            if let product = state.productName {
                RowDivider()
                line("Device", product, ok: nil)
            }
        }
    }

    static func localText(_ state: String) -> String {
        switch state {
        case "handshake_failed": return "Can't open the hub (key)"
        case "unreachable": return "Can't reach the hub"
        case "connecting": return "Connecting…"
        case "unconfigured": return "Not set up"
        default: return state.capitalized
        }
    }

    private func line(_ title: String, _ value: String, ok: Bool?) -> some View {
        Row {
            HStack {
                if let ok {
                    Circle().fill(ok ? JcTheme.success : JcTheme.amber).frame(width: 8, height: 8)
                }
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// One door's settings: name, instant, active at home, notify when disarmed, run a prompt when it opens.
struct DoorContactEditor: View {
    @ObservedObject var store: DoorAlarmStore
    let contact: DoorContact
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instant = false
    @State private var activeHome = true
    @State private var notify = false
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Name", text: $name) }
                Section(footer: Text("Instant: no entry delay for this door. Away only: Armed Home ignores it.")) {
                    Toggle("Instant alarm", isOn: $instant)
                    Toggle("Watched at home", isOn: $activeHome)
                    Toggle("Notify when disarmed", isOn: $notify)
                }
                Section(header: Text("When it opens"), footer: Text("Jarvis runs this every time the door opens, armed or not.")) {
                    TextField("e.g. Turn on the hall light", text: $prompt, axis: .vertical)
                }
            }
            .scrollContentBackground(.hidden)
            .background(JcTheme.bg)
            .navigationTitle(contact.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await store.updateContact(contact.id, ["name": name, "instant": instant, "active_home": activeHome,
                                                                   "notify_disarmed": notify, "on_open_prompt": prompt])
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear {
            name = contact.name
            instant = contact.instant
            activeHome = contact.activeHome
            notify = contact.notifyDisarmed
            prompt = contact.onOpenPrompt
        }
        .presentationDetents([.medium, .large])
    }
}
