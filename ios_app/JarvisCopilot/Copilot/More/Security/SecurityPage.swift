import SwiftUI

/// More → Security: the Security Advisor's page — the status line, open alerts with Block / Allow
/// (Face ID) / Dismiss, the event feed with Source and Level filters, active blocks with Undo,
/// recent digests and the advisor's settings. Same sections as the web page.
struct SecurityPage: View {
    @ObservedObject private var store: SecurityStore
    @State private var draft: SecuritySettings?
    @State private var model: SecurityModelOption?
    @State private var showAllEvents = false

    /// See `SettingsPage.init` — a view's `init` isn't main-actor-isolated.
    init(store: SecurityStore? = nil) {
        _store = ObservedObject(wrappedValue: store ?? MainActor.assumeIsolated { SecurityStore.shared })
    }

    var body: some View {
        JcPage("Security") {
            if let problem = store.problem, !store.loaded || store.status == nil {
                JcSectionLabel("Status", first: true)
                JcCard { Text(problem).font(.system(size: 14)).foregroundStyle(JcTheme.danger) }
            } else {
                statusSection
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
            JcCard {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.loaded ? store.statusLine : "Loading…")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                    if let facts = statusFacts, !facts.isEmpty {
                        Text(facts).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    }
                    if let warning = store.status?.chainOK, warning == false {
                        Text("The event log's chain is broken: a row was changed or removed.")
                            .font(.system(size: 12)).foregroundStyle(JcTheme.amber)
                    }
                    if let last = store.status?.lastEventTime {
                        Text("Last event \(Self.when(last))").font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    }
                }
            }
        }
    }

    private var statusFacts: String? {
        guard let s = store.status else { return nil }
        var parts: [String] = []
        if let ssh = s.sources["ssh"] { parts.append("SSH watch \(ssh)") }
        if let files = s.sources["files"] { parts.append("file watch \(files)") }
        if s.chainOK == true { parts.append("event log intact") }
        if s.blocks > 0 { parts.append(s.blocks == 1 ? "1 IP blocked" : "\(s.blocks) IPs blocked") }
        return parts.joined(separator: " · ")
    }

    // MARK: Alerts

    @ViewBuilder
    private var alertsSection: some View {
        let open = store.openAlerts
        if !open.isEmpty {
            JcSectionLabel("Open alerts") { Text("\(open.count)") }
            VStack(spacing: 10) {
                ForEach(open) { alert in alertCard(alert) }
            }
        }
    }

    private func alertCard(_ alert: SecurityAlert) -> some View {
        JcCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(alert.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(JcTheme.text)
                    Spacer(minLength: 8)
                    if let severity = alert.severity { chip(severity.capitalized) }
                    if alert.count > 1 { chip("×\(alert.count)") }
                }
                if let summary = alert.summary, alert.explanation != nil {
                    Text(summary).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
                if let text = alert.explanation ?? alert.summary {
                    Text(text).font(.system(size: 14)).foregroundStyle(JcTheme.text.opacity(0.85))
                }
                if let at = alert.updated ?? alert.created {
                    Text(Self.when(at)).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                }
                let busy = store.busy == alert.id
                HStack(spacing: 8) {
                    JcSmallAction("Block", symbol: "faceid", tint: JcTheme.danger) {
                        Task { await store.resolve(alert.id, .block) }
                    }
                    JcSmallAction("Allow", symbol: "faceid", tint: JcTheme.text) {
                        Task { await store.resolve(alert.id, .allow) }
                    }
                    JcSmallAction("Dismiss", tint: JcTheme.text, busy: busy) {
                        Task { await store.resolve(alert.id, .dismiss) }
                    }
                }
                .disabled(busy)
                .padding(.top, 4)
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(JcTheme.text.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.09), in: Capsule())
    }

    // MARK: Events

    private var eventsSection: some View {
        let list = store.filteredEvents
        let shown = showAllEvents ? list : Array(list.prefix(25))
        return VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Events") { Text(store.events.isEmpty ? "" : "\(list.count) of \(store.events.count)") }
            VStack(spacing: 8) {
                JcSegmentedPicker(SecurityStore.SourceFilter.allCases.map { (value: $0, label: $0.label) },
                                  selection: $store.source)
                JcSegmentedPicker(SecurityStore.LevelFilter.allCases.map { (value: $0, label: $0.label) },
                                  selection: $store.level)
            }
            .padding(.bottom, 8)
            JcCard(padding: 0) {
                if shown.isEmpty {
                    Text(store.loaded ? "No events match." : "Loading…")
                        .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                        .padding(JcUnified.cardPadding)
                } else {
                    ForEach(shown) { event in
                        JcRow(symbol: Self.symbol(for: event.source), title: event.displayTitle,
                              subtitle: [event.displayTitle == event.kind ? nil : event.kind, event.actor, event.ts.map(Self.when)].compactMap { $0 }.joined(separator: " · "),
                              last: event.id == shown.last?.id && (showAllEvents || list.count <= shown.count)) {
                            if let outcome = event.outcome, outcome != "ignore" { chip(outcome.capitalized) }
                        }
                    }
                    if !showAllEvents && list.count > shown.count {
                        JcShowAllRow { showAllEvents = true }
                    }
                }
            }
        }
    }

    private static func symbol(for source: String) -> String {
        switch source {
        case "device": return "iphone"
        case "host": return "server.rack"
        case "agent": return "sparkles"
        default: return "circle"
        }
    }

    // MARK: Blocks

    private var blocksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            JcSectionLabel("Blocked")
            JcCard(padding: 0) {
                if store.blocks.isEmpty {
                    Text("Nothing is blocked.")
                        .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                        .padding(JcUnified.cardPadding)
                } else {
                    ForEach(store.blocks) { block in
                        JcRow(symbol: "hand.raised", title: block.ip,
                              subtitle: [block.reason, block.until.map { "until " + Self.when($0) }]
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
    }

    // MARK: Digests

    @ViewBuilder
    private var digestsSection: some View {
        if !store.digests.isEmpty {
            JcSectionLabel("Digests")
            JcCard {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.digests.prefix(7)) { digest in
                        VStack(alignment: .leading, spacing: 4) {
                            if let date = digest.date {
                                Text(date.count == 10 ? date : Self.when(date))
                                    .font(.system(size: 15, weight: .medium)).foregroundStyle(JcTheme.text)
                            }
                            Text(digest.text).font(.system(size: 14)).foregroundStyle(JcTheme.text.opacity(0.85))
                        }
                    }
                }
            }
        }
    }

    // MARK: Settings

    @ViewBuilder
    private var settingsSection: some View {
        if let payload = store.settings, let draft {
            JcSectionLabel("Settings")
            JcCard(padding: 0) {
                JcRow(symbol: "cpu", title: "Model", subtitle: "Explains flagged events. Blocks never wait for it.") {
                    Picker("Model", selection: Binding(get: { model?.id ?? "" },
                                                       set: { id in model = payload.models.first { $0.id == id } })) {
                        ForEach(payload.models) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden().pickerStyle(.menu).tint(JcTheme.muted).lineLimit(1)
                }
                JcRow(symbol: "bell.badge", title: "Phone alerts per hour",
                      subtitle: "The rest wait here and in the digest.") {
                    Stepper("\(draft.alertCapPerHour)", value: binding(\.alertCapPerHour), in: 0...60).fixedSize()
                }
                JcRow(symbol: "newspaper", title: "Daily digest") { hourPicker(binding(\.digestHour)) }
                JcRow(symbol: "moon", title: "Quiet hours", subtitle: "No phone alerts between these hours.") {
                    hourRange(\.quietHours)
                }
                JcRow(symbol: "car", title: "Usual car and door hours",
                      subtitle: "Car or door use outside these is flagged.") {
                    hourRange(\.usualHours)
                }
                JcRow(symbol: "hourglass", title: "Block an IP for", last: payload.rules.isEmpty) {
                    Stepper("\(draft.blockTTLHours) h", value: binding(\.blockTTLHours), in: 1...720).fixedSize()
                }
                ForEach(payload.rules, id: \.id) { rule in
                    JcRow(symbol: "checklist", title: rule.title, subtitle: rule.title == rule.id ? nil : rule.id,
                          last: rule.id == payload.rules.last?.id) {
                        Toggle(rule.title, isOn: Binding(
                            get: { !(self.draft?.disabledRules.contains(rule.id) ?? false) },
                            set: { on in
                                self.draft?.disabledRules.removeAll { $0 == rule.id }
                                if !on { self.draft?.disabledRules.append(rule.id) }
                            }))
                        .labelsHidden()
                    }
                }
            }
            GradientButton("Save settings", busy: store.busy == "settings", full: true) {
                Task { await store.save(draft, model: model) }
            }
            .padding(.top, 12)
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
                Text(pair.count == 2 ? "\(Self.hour(pair[0])) – \(Self.hour(pair[1]))" : "—")
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

    // MARK: Formatting

    private static func hour(_ h: Int) -> String {
        var c = DateComponents()
        c.hour = h
        guard let date = Calendar.current.date(from: c) else { return "\(h):00" }
        return date.formatted(.dateTime.hour())
    }

    /// An ISO 8601 time (or epoch seconds) as "Nov 8, 3:04 AM"; the raw text if it doesn't parse.
    static func when(_ text: String) -> String {
        let iso = ISO8601DateFormatter()
        var date = iso.date(from: text)
        if date == nil {
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = iso.date(from: text)
        }
        if date == nil, let seconds = Double(text) { date = Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds) }
        guard let date else { return text }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
