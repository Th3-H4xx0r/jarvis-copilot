import SwiftUI

/// Pushed from the pinned card at the top of the Integrations list.
struct IMessageMemoryRoute: Hashable {}

/// The pinned card on the Integrations list: the same card every integration wears,
/// leading with whether it is on.
struct IMessageMemoryCardRow: View {
    let card: IMessageMemoryCard?
    let failed: Bool

    private var subtitle: String {
        if let card { return card.subtitle }
        return failed ? "Couldn't load" : "Loading…"
    }

    private var on: Bool { card?.enabled == true && card?.macSeenAt != nil }

    var body: some View {
        IntegrationCardLayout(symbol: "bubble.left",
                              name: "iMessage memory",
                              subtitle: subtitle,
                              dimmed: !on,
                              pill: card?.activeJob != nil ? "BACKFILLING" : nil)
    }
}

/// iMessage memory — which chats Jarvis remembers, on what, and backfills of older messages.
struct IMessageMemoryView: View {
    @Bindable var store: IMessageMemoryStore

    @State private var query = ""
    @State private var forgetting: IMessageChat?
    @State private var addingSkip = false
    @State private var choosingChats = false
    @State private var from = IMessageBackfillPreset.week.range(endingAt: Date()).from
    @State private var to = Date()
    @State private var allTicked = true
    @State private var chosen: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let card = store.card {
                    statusSection(card)
                    agentSection(card)
                    chatsSection(card)
                    skipSection(card)
                    backfillSection(card)
                    jobsSection(card)
                } else if let message = store.errorMessage {
                    CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
                        .padding(.top, 100)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                }
            }
            .padding(.vertical, 16)
            .padding(.bottom, 24)
        }
        .refreshable { await store.refresh() }
        .loadErrorBanner(store.errorMessage, hasContent: store.card != nil)
        .jcScreen("iMessage memory")
        .onAppear { store.appeared() }
        .onDisappear { store.disappeared() }
        .moreToast($store.toast)
        .confirmationDialog(forgetting.map { "Forget memories from \($0.displayName)?" } ?? "",
                            isPresented: Binding(get: { forgetting != nil },
                                                 set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible,
                            presenting: forgetting) { chat in
            Button(chat.remembered == 1 ? "Forget 1 memory" : "Forget \(chat.remembered) memories",
                   role: .destructive) {
                Task { await store.forget(chat) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Deletes what Jarvis remembered from this chat. It keeps reading the chat while it's ticked.")
        }
        .sheet(isPresented: $addingSkip) {
            IMessageSkipPicker(people: store.card?.skippablePeople ?? []) { person in
                Task { await store.addSkip(person) }
            }
        }
        .sheet(isPresented: $choosingChats) {
            IMessageChatChooser(chats: store.card?.chats ?? [], chosen: $chosen)
        }
    }

    // MARK: 1. On/off + status

    private func statusSection(_ card: IMessageMemoryCard) -> some View {
        CardGroup {
            Row {
                Toggle(isOn: Binding(get: { card.enabled },
                                     set: { on in Task { await store.setEnabled(on) } })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Remember my iMessages")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(JcTheme.text)
                        Text("Jarvis reads new messages in the chats you tick and keeps what's worth remembering. "
                             + "Codes are never stored.")
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(JcTheme.accent)
            }
            RowDivider()
            statusLine("Mac last seen", card.macSeen.map(Self.relative) ?? "Never")
            RowDivider()
            statusLine("Memories stored", card.totals.pending > 0
                       ? "\(card.totals.memories) · \(card.totals.pending) messages waiting"
                       : "\(card.totals.memories)")
            RowDivider()
            statusLine("Runs on", card.runsOn.isEmpty ? "—" : card.runsOn)
            if let warning = card.warning {
                RowDivider()
                Row {
                    HStack(alignment: .top, spacing: 10) {
                        JcIcon("exclamationmark.triangle.fill", size: 14)
                            .foregroundStyle(JcTheme.amber)
                            .padding(.top, 1)
                        Text(warning)
                            .font(.system(size: 13))
                            .foregroundStyle(JcTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func statusLine(_ title: String, _ value: String) -> some View {
        Row(minHeight: 40) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 14)).foregroundStyle(JcTheme.muted)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // MARK: 2. Model or harness

    private func agentSection(_ card: IMessageMemoryCard) -> some View {
        CardGroup("Model or harness", footer: "What reads your messages and decides what to remember.") {
            NavigationLink {
                AgentChoicePage(title: "Model or harness", pick: AgentPick(card.agent)) { pick in
                    Task { await store.setAgent(pick.choice) }
                }
            } label: {
                Row {
                    HStack {
                        Text("Runs on").foregroundStyle(JcTheme.text)
                        Spacer()
                        Text(AgentPick(card.agent).label).foregroundStyle(JcTheme.muted).lineLimit(1)
                        JcIcon("chevron.right", size: 11).foregroundStyle(JcTheme.muted.opacity(0.6))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 3. Chats

    private func chatsSection(_ card: IMessageMemoryCard) -> some View {
        let shown = card.chats.filter { $0.matches(query) }
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Chats") {
                Text("\(card.tickedCount) of \(card.chats.count) ticked")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(JcTheme.muted)
            }
            if !card.chats.isEmpty {
                CodeMemorySearchField(text: $query, hint: "Search chats")
                    .padding(.bottom, 10)
            }
            InsetGroup {
                if card.chats.isEmpty {
                    CardEmptyBlock("Chats appear once your Mac reports.", symbol: "bubble.left")
                } else if shown.isEmpty {
                    CardEmptyBlock("Nothing matches “\(query)”", symbol: "magnifyingglass")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { chat in
                            chatRow(chat)
                            if chat.id != shown.last?.id { RowDivider() }
                        }
                    }
                }
            }
            Text("New chats with one person are on; group chats are off until you tick them. "
                 + "Press and hold a chat to forget what Jarvis remembered from it.")
                .font(.system(size: 11.5))
                .foregroundStyle(JcTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .padding(.top, 8)
        }
        .padding(.horizontal, 20)
    }

    private func chatRow(_ chat: IMessageChat) -> some View {
        Row(minHeight: 56) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(chat.displayName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        if chat.isGroup { StatusPill("Group", color: JcTheme.accent, dense: true) }
                    }
                    Text(Self.chatNote(chat))
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { chat.effective },
                                         set: { on in Task { await store.setTicked(chat, on) } }))
                    .labelsHidden()
                    .tint(JcTheme.accent)
                    .accessibilityLabel("Remember \(chat.displayName)")
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                forgetting = chat
            } label: {
                Label("Forget memories from this chat", systemImage: "trash")
            }
        }
    }

    static func chatNote(_ chat: IMessageChat) -> String {
        var parts: [String] = []
        if let last = chat.lastMessage {
            parts.append(last.formatted(.dateTime.day().month(.abbreviated).year()))
        }
        if chat.remembered > 0 {
            parts.append(chat.remembered == 1 ? "1 remembered" : "\(chat.remembered) remembered")
        }
        return parts.isEmpty ? "No messages yet" : parts.joined(separator: " · ")
    }

    // MARK: 4. Skip contacts

    private func skipSection(_ card: IMessageMemoryCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            IntegrationSection(title: "Skip contacts", count: card.skip.count,
                               action: .init(symbol: "plus") { addingSkip = true }) {
                InsetGroup {
                    if card.skip.isEmpty {
                        CardEmptyBlock("Nobody skipped", symbol: "person.crop.circle.badge.xmark")
                    } else {
                        ForEach(card.skip) { person in
                            Row {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(person.displayName)
                                            .font(.system(size: 15))
                                            .foregroundStyle(JcTheme.text)
                                            .lineLimit(1)
                                        if person.displayName != person.handle {
                                            Text(person.handle)
                                                .font(.system(size: 12))
                                                .foregroundStyle(JcTheme.muted)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Button {
                                        Task { await store.removeSkip(person) }
                                    } label: {
                                        JcIcon("xmark", size: 13)
                                            .foregroundStyle(JcTheme.muted)
                                            .frame(width: integrationTapTarget, height: integrationTapTarget)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Stop skipping \(person.displayName)")
                                }
                            }
                            if person.id != card.skip.last?.id { RowDivider() }
                        }
                    }
                }
            }
            Text("Messages from these people are never remembered, in any chat.")
                .font(.system(size: 11.5))
                .foregroundStyle(JcTheme.muted)
                .padding(.horizontal, 4)
                .padding(.top, 8)
        }
        .padding(.horizontal, 20)
    }

    // MARK: 5. Backfill

    private func backfillSection(_ card: IMessageMemoryCard) -> some View {
        CardGroup("Backfill", footer: "Reads older messages in that window from your Mac. "
                  + "Anything already remembered is skipped.") {
            Row {
                DatePicker("From", selection: $from, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .foregroundStyle(JcTheme.text)
                    .tint(JcTheme.accent)
            }
            RowDivider()
            Row {
                DatePicker("To", selection: $to, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .foregroundStyle(JcTheme.text)
                    .tint(JcTheme.accent)
            }
            RowDivider()
            Row {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(IMessageBackfillPreset.allCases) { preset in
                            Button(preset.rawValue) {
                                let range = preset.range(endingAt: Date())
                                from = range.from
                                to = range.to
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(JcTheme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(JcTheme.accent.opacity(0.12), in: Capsule())
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            RowDivider()
            Row {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Chats", selection: $allTicked) {
                        Text("All ticked").tag(true)
                        Text("Choose").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if !allTicked {
                        Button {
                            if chosen.isEmpty { chosen = Set(card.chats.filter(\.effective).map(\.guid)) }
                            choosingChats = true
                        } label: {
                            HStack {
                                Text(chosen.isEmpty ? "Choose chats" : "\(chosen.count) chosen")
                                    .foregroundStyle(JcTheme.text)
                                Spacer()
                                JcIcon("chevron.right", size: 11).foregroundStyle(JcTheme.muted.opacity(0.6))
                            }
                            .frame(minHeight: integrationTapTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            RowDivider()
            Row {
                GradientButton("Run backfill", symbol: "play.fill", busy: store.startingBackfill, full: true,
                               action: canRun(card) ? { run() } : nil)
            }
        }
    }

    private func canRun(_ card: IMessageMemoryCard) -> Bool {
        to > from && card.activeJob == nil && !store.startingBackfill && (allTicked || !chosen.isEmpty)
    }

    private func run() {
        let chats = allTicked ? nil : Array(chosen).sorted()
        Task { await store.runBackfill(from: from, to: to, chats: chats) }
    }

    // MARK: Jobs

    @ViewBuilder
    private func jobsSection(_ card: IMessageMemoryCard) -> some View {
        if let job = card.activeJob {
            CardGroup("Running now") {
                Row {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            StatusPill(job.status.title, color: JcTheme.accent, live: true)
                            Spacer()
                            Button("Stop", role: .destructive) { Task { await store.stop(job) } }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(JcTheme.danger)
                                .buttonStyle(.plain)
                                .frame(minHeight: integrationTapTarget)
                        }
                        Text(Self.range(job)).font(.system(size: 13)).foregroundStyle(JcTheme.text)
                        Text(Self.counts(job))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(JcTheme.muted)
                    }
                }
            }
        }
        let recent = Array(card.recentJobs.prefix(10))
        if !recent.isEmpty {
            CardGroup("Recent backfills") {
                ForEach(recent) { job in
                    Row {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(Self.range(job))
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(JcTheme.text)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                StatusPill(job.status.title, color: Self.color(job.status), dense: true)
                            }
                            Text(Self.counts(job))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(JcTheme.muted)
                            if let error = job.error, !error.isEmpty {
                                Text(error)
                                    .font(.system(size: 12))
                                    .foregroundStyle(JcTheme.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if job.id != recent.last?.id { RowDivider() }
                }
            }
        }
    }

    static func range(_ job: IMessageBackfillJob) -> String {
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute()
        let scope = job.chats.map { $0.count == 1 ? " · 1 chat" : " · \($0.count) chats" } ?? ""
        return "\(job.startDate.formatted(style)) – \(job.endDate.formatted(style))\(scope)"
    }

    static func counts(_ job: IMessageBackfillJob) -> String {
        "\(job.received) messages · \(job.stored) stored · \(job.skipped) skipped"
    }

    static func color(_ status: IMessageBackfillJob.Status) -> Color {
        switch status {
        case .done: return JcTheme.success
        case .error: return JcTheme.danger
        case .stopped: return JcTheme.muted
        case .pending, .running: return JcTheme.accent
        }
    }

    static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Sheets

/// Pick someone from the uploaded chats to skip.
private struct IMessageSkipPicker: View {
    let people: [IMessagePerson]
    let onPick: (IMessagePerson) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var shown: [IMessagePerson] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return people }
        return people.filter { $0.label.localizedCaseInsensitiveContains(q) || $0.handle.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if people.isEmpty {
                    Text("Nobody to add yet — people appear once your Mac reports its chats.")
                        .foregroundStyle(JcTheme.muted)
                } else if shown.isEmpty {
                    Text("Nobody matches “\(query)”").foregroundStyle(JcTheme.muted)
                }
                ForEach(shown) { person in
                    Button {
                        onPick(person)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(person.displayName).foregroundStyle(JcTheme.text)
                            if person.displayName != person.handle {
                                Text(person.handle).font(.caption).foregroundStyle(JcTheme.muted)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search people")
            .navigationTitle("Skip a contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

/// Tick the chats one backfill covers.
private struct IMessageChatChooser: View {
    let chats: [IMessageChat]
    @Binding var chosen: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let shown = chats.filter { $0.matches(query) }
        NavigationStack {
            List {
                ForEach(shown) { chat in
                    Button {
                        if chosen.contains(chat.guid) { chosen.remove(chat.guid) } else { chosen.insert(chat.guid) }
                    } label: {
                        HStack(spacing: 12) {
                            JcIcon(chosen.contains(chat.guid) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen.contains(chat.guid) ? JcTheme.accent : JcTheme.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chat.displayName).foregroundStyle(JcTheme.text).lineLimit(1)
                                if chat.isGroup {
                                    Text("Group").font(.caption).foregroundStyle(JcTheme.muted)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
            .navigationTitle("\(chosen.count) chosen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(chosen.isEmpty ? "All" : "None") {
                        chosen = chosen.isEmpty ? Set(chats.map(\.guid)) : []
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
