import SwiftUI

/// More → Security: the Security Advisor's page. Status (a headline over three figures) and what it
/// is watching, open alerts with Block / Allow (Face ID) / Dismiss, the event feed filtered by source
/// and level, active blocks with Undo, recent digests and the advisor's settings.
///
/// Quiet chrome on the unified black-and-white design; the only colour is the status dots — green
/// watching, amber medium, red high — so an alert reads at a glance.
struct SecurityPage: View {
    @ObservedObject private var store: SecurityStore
    @State private var draft: SecuritySettings?
    @State private var model: SecurityModelOption?
    @State private var showAllEvents = false
    @State private var expanded: Set<String> = []

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated.
    init(store: SecurityStore? = nil) {
        _store = ObservedObject(wrappedValue: store ?? MainActor.assumeIsolated { SecurityStore.shared })
    }

    var body: some View {
        JcPage("Security") {
            if let problem = store.problem, !store.loaded || store.status == nil {
                JcSectionLabel("Status", first: true)
                JcCard { Text(problem).font(.system(size: 15)).foregroundStyle(JcTheme.danger) }
            } else {
                statusSection
                watchingSection
            }
            alertsSection
            eventsSection
            blocksSection
            digestsSection
            settingsSection
        } actions: {
            JcPageButton("arrow.clockwise", label: "Refresh") { Task { await store.load() } }
        }
        .refreshable { await store.load() }
        .task { await store.load() }
        .onChange(of: store.settings, initial: true) { _, fresh in
            guard let fresh else { return }
            draft = fresh.settings
            model = fresh.model
        }
        .moreToast($store.notice, seconds: 2)
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Status", first: true)
            JcCard(padding: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            StatusDot(color: headlineColor)
                            Text(store.loaded ? store.statusLine : "Loading")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(JcTheme.text)
                        }
                        if let last = store.status?.lastEventTime {
                            Text("Last event \(Self.short(last))")
                                .font(.system(size: 13))
                                .foregroundStyle(JcTheme.muted)
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        figure(store.status?.openAlerts ?? store.openAlerts.count, "Open alerts")
                        figure(store.status?.blocks ?? store.blocks.count, "Blocked")
                        figure(eventsToday, "Events today")
                    }
                }
            }
        }
    }

    private func figure(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)")
                .font(.system(size: 22, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(JcTheme.text)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Red while a high alert is open, amber for any other open alert, green when all is quiet.
    private var headlineColor: Color {
        let open = store.openAlerts
        if open.contains(where: { Self.isHigh($0.severity) }) { return JcTheme.danger }
        if !open.isEmpty || (store.status?.openAlerts ?? 0) > 0 { return JcTheme.amber }
        return JcTheme.success
    }

    private var eventsToday: Int {
        store.events.filter { $0.ts.flatMap(Self.date).map(Calendar.current.isDateInToday) ?? false }.count
    }

    // MARK: Watching

    private var watchingSection: some View {
        let sources = store.status?.sources ?? [:]
        let ssh = sources["ssh"]
        let chain = store.status?.chainOK
        return VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Watching")
            JcCard(padding: 0) {
                JcRow(symbol: "terminal", title: "SSH and sudo", subtitle: "Logins and root commands on the server") {
                    sourceState(ssh == "running" ? "Watching" : (ssh?.capitalized ?? "Waiting"),
                                ok: ssh == "running")
                }
                JcRow(symbol: "doc.text.magnifyingglass", title: "Code and config",
                      subtitle: "Keys, services, schedules and the repo") {
                    let files = sources["files"]
                    let checked = files.flatMap { Self.date($0) == nil ? nil : Self.short($0) }
                    sourceState(checked.map { "Checked \($0)" } ?? (files == "running" ? "Watching" : "Waiting"),
                                ok: checked != nil || files == "running")
                }
                JcRow(symbol: "checkmark.shield", title: "Event log", subtitle: "Every event, chained so edits show",
                      last: true) {
                    sourceState(chain == false ? "Changed" : chain == true ? "Intact" : "Checking",
                                ok: chain != false, warn: chain == false)
                }
            }
        }
    }

    private func sourceState(_ text: String, ok: Bool, warn: Bool = false) -> some View {
        HStack(spacing: 6) {
            StatusDot(color: warn ? JcTheme.danger : ok ? JcTheme.success : JcTheme.muted, size: 7)
            Text(text).font(.system(size: 13)).foregroundStyle(JcTheme.muted).lineLimit(1)
        }
        .fixedSize()
    }

    // MARK: Alerts

    @ViewBuilder
    private var alertsSection: some View {
        let open = store.openAlerts
        if !open.isEmpty {
            JcSectionLabel("Open alerts") { Text("\(open.count)").monospacedDigit() }
            VStack(spacing: 12) {
                ForEach(open) { alert in alertCard(alert) }
            }
        }
    }

    private func alertCard(_ alert: SecurityAlert) -> some View {
        let (headline, detail) = Self.split(alert.title)
        let body = alert.explanation ?? alert.summary
        let isExpanded = expanded.contains(alert.id)
        let busy = store.busy == alert.id
        return JcCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    StatusDot(color: Self.severityColor(alert.severity), size: 7)
                    Text((alert.severity ?? "Alert").capitalized)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(JcTheme.text.opacity(0.75))
                    Spacer(minLength: 8)
                    Text(alertMeta(alert))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let body {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(body)
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(JcTheme.text.opacity(0.8))
                            .lineLimit(isExpanded ? nil : 3)
                            .fixedSize(horizontal: false, vertical: true)
                        if body.count > 150 {
                            Button(isExpanded ? "Show less" : "Show more") {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    if isExpanded { expanded.remove(alert.id) } else { expanded.insert(alert.id) }
                                }
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(JcTheme.muted)
                            .buttonStyle(.plain)
                        }
                    }
                }
                HStack(spacing: 8) {
                    JcSmallAction("Block", symbol: "faceid", tint: JcTheme.danger) {
                        Task { await store.resolve(alert.id, .block) }
                    }
                    JcSmallAction("Allow", symbol: "faceid", tint: JcTheme.text) {
                        Task { await store.resolve(alert.id, .allow) }
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { await store.resolve(alert.id, .dismiss) }
                    } label: {
                        if busy {
                            ProgressView().controlSize(.mini).tint(JcTheme.muted)
                        } else {
                            Text("Dismiss").font(.system(size: 14, weight: .medium)).foregroundStyle(JcTheme.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                }
                .disabled(busy)
            }
        }
    }

    private func alertMeta(_ alert: SecurityAlert) -> String {
        var parts: [String] = []
        if alert.count > 1 { parts.append("\(alert.count) times") }
        if let at = alert.updated ?? alert.created { parts.append(Self.short(at)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Events

    private var eventsSection: some View {
        let list = store.filteredEvents
        let shown = showAllEvents ? list : Array(list.prefix(15))
        return VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Events") {
                Menu {
                    Picker("Level", selection: $store.level) {
                        ForEach(SecurityStore.LevelFilter.allCases, id: \.self) { Text($0.levelTitle).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.level.levelTitle.uppercased()).tracking(0.8)
                        JcIcon("chevron.down", size: 9, weight: .semibold)
                    }
                }
            }
            JcSegmentedPicker(SecurityStore.SourceFilter.allCases.map { (value: $0, label: $0.label) },
                              selection: $store.source)
                .padding(.bottom, 12)
            JcCard(padding: 0) {
                if shown.isEmpty {
                    Text(store.loaded ? "No events match" : "Loading")
                        .font(.system(size: 14)).foregroundStyle(JcTheme.muted)
                        .padding(20)
                } else {
                    ForEach(shown) { event in
                        JcRow(symbol: Self.symbol(for: event.source), title: Self.readable(event.displayTitle),
                              subtitle: [event.ts.map(Self.short), event.actor].compactMap { $0 }.joined(separator: " · "),
                              subtitleLines: 1,
                              last: event.id == shown.last?.id && (showAllEvents || list.count <= shown.count)) {
                            outcomeLabel(event.outcome)
                        }
                    }
                    if !showAllEvents && list.count > shown.count {
                        JcShowAllRow { showAllEvents = true }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func outcomeLabel(_ outcome: String?) -> some View {
        switch outcome {
        case "block":
            Text("Blocked").font(.system(size: 12, weight: .medium)).foregroundStyle(JcTheme.danger)
        case "alert":
            Text("Alert").font(.system(size: 12, weight: .medium)).foregroundStyle(JcTheme.text.opacity(0.8))
        default:
            EmptyView()
        }
    }

    private static func symbol(for source: String) -> String {
        switch source {
        case "device": return "iphone"
        case "host": return "server.rack"
        case "agent": return "cpu"
        default: return "circle"
        }
    }

    // MARK: Blocks

    @ViewBuilder
    private var blocksSection: some View {
        if !store.blocks.isEmpty {
            JcSectionLabel("Blocked") { Text("\(store.blocks.count)").monospacedDigit() }
            JcCard(padding: 0) {
                ForEach(store.blocks) { block in
                    JcRow(symbol: "hand.raised", title: block.ip,
                          subtitle: [block.reason, block.until.map { "Until " + Self.short($0) }]
                            .compactMap { $0 }.joined(separator: " · "),
                          last: block.id == store.blocks.last?.id) {
                        JcSmallAction("Undo", tint: JcTheme.text, busy: store.busy == block.ip) {
                            Task { await store.undo(block.ip) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Digests

    @ViewBuilder
    private var digestsSection: some View {
        if !store.digests.isEmpty {
            let recent = Array(store.digests.prefix(7))
            JcSectionLabel("Daily digests")
            JcCard(padding: 0) {
                ForEach(recent) { digest in
                    VStack(alignment: .leading, spacing: 6) {
                        if let date = digest.date {
                            Text(Self.day(date))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(JcTheme.muted)
                        }
                        Text(digest.text)
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .foregroundStyle(JcTheme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, JcUnified.cardPadding)
                    .padding(.vertical, 16)
                    if digest.id != recent.last?.id { JcRowSeparator() }
                }
            }
        }
    }

    // MARK: Settings

    @ViewBuilder
    private var settingsSection: some View {
        if let payload = store.settings, let draft {
            JcSectionLabel("Alerts")
            JcCard(padding: 0) {
                JcRow(symbol: "text.bubble", title: "Model", subtitle: "Explains flagged events") {
                    Picker("Model", selection: Binding(get: { model?.id ?? "" },
                                                       set: { id in model = payload.models.first { $0.id == id } })) {
                        ForEach(payload.models) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu).tint(JcTheme.muted).lineLimit(1)
                }
                JcRow(symbol: "bell", title: "Phone alerts per hour", subtitle: "The rest wait here and in the digest") {
                    Stepper("\(draft.alertCapPerHour)", value: binding(\.alertCapPerHour), in: 0...60)
                        .monospacedDigit().fixedSize()
                }
                JcRow(symbol: "moon", title: "Quiet hours", subtitle: "Only blocks reach the phone") {
                    hourRange(\.quietHours)
                }
                JcRow(symbol: "newspaper", title: "Daily digest") { hourPicker(binding(\.digestHour)) }
                JcRow(symbol: "car", title: "Usual car and door hours", subtitle: "Use outside these is flagged") {
                    hourRange(\.usualHours)
                }
                JcRow(symbol: "hourglass", title: "Block an address for", last: true) {
                    Stepper("\(draft.blockTTLHours) h", value: binding(\.blockTTLHours), in: 1...720)
                        .monospacedDigit().fixedSize()
                }
            }
            if !payload.rules.isEmpty {
                JcSectionLabel("Rules")
                JcCard(padding: 0) {
                    ForEach(payload.rules, id: \.id) { rule in
                        JcRow(title: Self.readable(rule.title), last: rule.id == payload.rules.last?.id) {
                            Toggle(rule.title, isOn: Binding(
                                get: { !(self.draft?.disabledRules.contains(rule.id) ?? false) },
                                set: { on in
                                    self.draft?.disabledRules.removeAll { $0 == rule.id }
                                    if !on { self.draft?.disabledRules.append(rule.id) }
                                }))
                            .labelsHidden()
                            .toggleStyle(.jcSwitch)
                        }
                    }
                }
            }
            if draft != payload.settings || model != payload.model {
                GradientButton("Save settings", busy: store.busy == "settings", full: true) {
                    Task { await store.save(draft, model: model) }
                }
                .padding(.top, 16)
            }
        }
    }

    private func binding(_ key: WritableKeyPath<SecuritySettings, Int>) -> Binding<Int> {
        Binding(get: { draft?[keyPath: key] ?? 0 }, set: { draft?[keyPath: key] = $0 })
    }

    /// A from–to pair of hours as one compact menu ("11 PM – 7 AM") with From and To inside: two
    /// pickers side by side don't fit beside a row's title on a phone.
    private func hourRange(_ key: WritableKeyPath<SecuritySettings, [Int]>) -> some View {
        let pair = draft?[keyPath: key] ?? [0, 0]
        func end(_ i: Int) -> Binding<Int> {
            Binding(get: { pair.count == 2 ? pair[i] : 0 },
                    set: { v in if var p = draft?[keyPath: key], p.count == 2 { p[i] = v; draft?[keyPath: key] = p } })
        }
        return Menu {
            Picker("From", selection: end(0)) { ForEach(0..<24, id: \.self) { Text(Self.hour($0)).tag($0) } }
                .pickerStyle(.menu)
            Picker("To", selection: end(1)) { ForEach(0..<24, id: \.self) { Text(Self.hour($0)).tag($0) } }
                .pickerStyle(.menu)
        } label: {
            HStack(spacing: 4) {
                Text(pair.count == 2 ? "\(Self.hour(pair[0])) – \(Self.hour(pair[1]))" : "Not set")
                JcIcon("chevron.up.chevron.down", size: 11, weight: .semibold)
            }
            .font(.system(size: 15))
            .foregroundStyle(JcTheme.muted)
            .fixedSize()
        }
    }

    private func hourPicker(_ value: Binding<Int>) -> some View {
        Picker("Hour", selection: value) {
            ForEach(0..<24, id: \.self) { Text(Self.hour($0)).tag($0) }
        }
        .labelsHidden().pickerStyle(.menu).tint(JcTheme.muted)
    }

    // MARK: Text helpers

    /// "Server file added: /etc/x.service" → ("Server file added", "/etc/x.service");
    /// "SSH login from a new IP (198.51.100.4)" → ("SSH login from a new IP", "198.51.100.4").
    /// The headline stays short; the path or address goes on its own mono line.
    static func split(_ title: String) -> (String, String?) {
        if let r = title.range(of: ": "), !title[r.upperBound...].isEmpty {
            return (String(title[..<r.lowerBound]), String(title[r.upperBound...]))
        }
        if title.hasSuffix(")"), let open = title.range(of: " (", options: .backwards) {
            let inner = title[open.upperBound..<title.index(before: title.endIndex)]
            if !inner.isEmpty { return (String(title[..<open.lowerBound]), String(inner)) }
        }
        return (title, nil)
    }

    /// A raw id that reached the page without a label ("ssh.new_ip", "auth.failed") in plain words
    /// ("Ssh new ip" → "SSH new IP"); real labels pass through untouched.
    static func readable(_ text: String) -> String {
        guard !text.contains(" "), text.contains(where: { $0 == "." || $0 == "_" }) else { return text }
        let words = text.split(whereSeparator: { $0 == "." || $0 == "_" }).map { word -> String in
            let w = String(word)
            return ["ssh", "ip", "api", "tui", "ui"].contains(w.lowercased()) ? w.uppercased() : w.lowercased()
        }
        guard let first = words.first else { return text }
        let head = first == first.uppercased() ? first : first.prefix(1).uppercased() + first.dropFirst()
        return ([head] + words.dropFirst()).joined(separator: " ")
    }

    private static func isHigh(_ severity: String?) -> Bool {
        ["high", "critical"].contains((severity ?? "").lowercased())
    }

    private static func severityColor(_ severity: String?) -> Color {
        switch (severity ?? "").lowercased() {
        case "high", "critical": return JcTheme.danger
        case "medium": return JcTheme.amber
        default: return JcTheme.muted
        }
    }

    // MARK: Formatting

    private static func hour(_ h: Int) -> String {
        var c = DateComponents()
        c.hour = h
        guard let date = Calendar.current.date(from: c) else { return "\(h):00" }
        return date.formatted(.dateTime.hour())
    }

    /// An ISO 8601 time (or epoch seconds); nil if it doesn't parse.
    static func date(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        if let seconds = Double(text) { return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds) }
        return nil
    }

    /// An ISO 8601 time (or epoch seconds) as "Nov 8, 3:04 AM"; the raw text if it doesn't parse.
    static func when(_ text: String) -> String {
        guard let date = date(text) else { return text }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Today as just the time ("9:25 AM"), other days with the date ("Nov 8, 9:25 AM").
    static func short(_ text: String) -> String {
        guard let date = date(text) else { return text }
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : when(text)
    }

    /// A digest's day ("2026-11-08" or a full time) as "Sun, Nov 8".
    private static func day(_ text: String) -> String {
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.dateFormat = "yyyy-MM-dd"
        guard let date = plain.date(from: text) ?? date(text) else { return text }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// The page's one signature detail: a small solid status dot.
private struct StatusDot: View {
    let color: Color
    var size: CGFloat = 9

    var body: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

private extension SecurityStore.LevelFilter {
    /// The level menu's wording ("All levels", "Alerts", "Blocks", "Digest").
    var levelTitle: String { self == .all ? "All levels" : label }
}
