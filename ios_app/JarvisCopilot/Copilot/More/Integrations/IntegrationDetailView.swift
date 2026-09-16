import SwiftUI

/// One integration: what it runs, and then what it keeps and knows.
///
/// Schedules come first and carry the answer to the only question this screen is
/// opened with — is it working? The header says so ("2 of 3 running"), and data
/// and skills collapse into a row each, because they are what the schedules work
/// with rather than things that happen on their own.
///
/// An inset-grouped `List`: swipe a schedule to pause or delete it, and the
/// integration's own controls (pause, delete) live in the nav bar's ⋯.
///
/// Schedules come from `/api/crons` rather than the integration payload, because
/// tapping one opens the same detail sheet the Tasks screen used, with the prompt,
/// the run history and the run/pause/edit/delete bar.
struct IntegrationDetailView: View {
    let pushed: Integration
    @Bindable var store: IntegrationsStore
    @Environment(\.dismiss) private var dismiss

    @State private var crons = MainActor.assumeIsolated { CronsStore() }
    @State private var route: TasksRoute?
    @State private var pendingDelete: CronJob?
    @State private var confirming: IntegrationConfirm?
    @State private var deletingIntegration = false

    init(integration: Integration, store: IntegrationsStore) {
        self.pushed = integration
        self.store = store
    }

    /// The value this screen was pushed with never changes; the store's copy does.
    /// Pause has to read the live one or Resume is unreachable.
    private var integration: Integration { store.current(pushed.id) ?? pushed }

    /// What the store holds, but only once it holds *this* integration — otherwise
    /// the previous screen's collections draw under this one's title.
    private var detail: IntegrationDetail? {
        store.detailID == pushed.id ? store.detail : nil
    }

    private var schedules: [CronJob] {
        crons.jobs.filter { $0.integrationID == pushed.id }
    }

    var body: some View {
        // A real inset-grouped List, wearing the app's palette: native row metrics,
        // separators, section headers and footers, swipe actions and Dynamic Type,
        // none of which a stack of hand-built cards gets for free.
        List {
            if !integration.summary.isEmpty {
                Section {
                    Text(integration.summary)
                        .font(IntegrationType.body)
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
                        .listRowSeparator(.hidden)
                }
            }
            schedulesSection
            holdingsSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, integrationTapTarget)
        .refreshable {
            await store.open(pushed.id)
            await crons.refresh()
        }
        .jcScreen(integration.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { integrationMenu }
        }
        .task {
            if !crons.hasLoaded { crons.load() }   // its own endpoint; don't wait on the detail
            await store.open(pushed.id)
        }
        .onDisappear { crons.onDisappear() }
        .moreToast($store.toast)
        .sheet(item: $route) { sheet(for: $0) }
        .sheet(isPresented: $deletingIntegration) {
            IntegrationDeleteSheet(
                integration: integration,
                scheduleCount: schedules.count,
                collectionCount: detail?.collections.count ?? 0,
                documentCount: detail?.documents.count ?? 0,
                skillCount: detail?.skills.count ?? 0
            ) { parts in
                let outcome = await store.delete(integration, parts: parts)
                await crons.refresh()          // the schedules live in another store
                if outcome.spaceRemoved {
                    // After the sheet dismisses itself: popping the presenter out
                    // from under a sheet that is still up swallows the pop.
                    afterSheetDismissal { dismiss() }
                }
                return outcome.succeeded
            }
        }
        .alert("Delete \(pendingDelete?.name ?? "Schedule")?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { job in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await crons.delete(job)
                    await store.reloadDetail()
                    await store.refresh()
                }
            }
        } message: { _ in
            Text("It stops running and its history goes with it. This cannot be undone.")
        }
        .integrationConfirm($confirming, store: store)
    }

    // MARK: The integration itself

    private var integrationMenu: some View {
        Menu {
            Button {
                Task { await store.togglePause(integration) }
            } label: {
                Label(integration.isPaused ? "Resume" : "Pause",
                      jcIcon: integration.isPaused ? "play.fill" : "pause.fill")
            }
            Button { route = .create } label: { Label("New Schedule", jcIcon: "plus") }
            Divider()
            Button(role: .destructive) { deletingIntegration = true } label: {
                Label("Delete\u{2026}", jcIcon: "trash")
            }
        } label: {
            JcIcon("ellipsis", size: 16)
                .frame(width: integrationTapTarget, height: integrationTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Integration actions")
    }

    // MARK: What runs

    /// First, and with its state in the header: an integration is a thing that runs
    /// for you, and "is it working?" is the question this screen exists to answer.
    @ViewBuilder
    private var schedulesSection: some View {
        Section {
            if !crons.hasLoaded {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(rowBackground)
            } else if schedules.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Nothing runs in this integration yet. A schedule is what does its work.")
                        .font(IntegrationType.small)
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("New Schedule") { route = .create }
                        .font(IntegrationType.label)
                        .foregroundStyle(JcTheme.accent)
                }
                .padding(.vertical, 4)
                .listRowBackground(rowBackground)
            } else {
                ForEach(schedules) { job in
                    Button { route = .detail(job) } label: { scheduleRow(job) }
                        .buttonStyle(.plain)
                        .listRowBackground(rowBackground)
                        // Swipe on a row is how iOS expects this to work.
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { pendingDelete = job } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                Task { await crons.togglePause(job); await store.refresh() }
                            } label: {
                                Label(job.isPaused ? "Resume" : "Pause",
                                      systemImage: job.isPaused ? "play.fill" : "pause.fill")
                            }
                            .tint(JcTheme.accent)
                        }
                }
            }
        } header: {
            HStack {
                Text("Schedules")
                Spacer()
                if crons.hasLoaded, !schedules.isEmpty {
                    Text(runningSummary)
                        .foregroundStyle(allPaused ? JcTheme.muted : JcTheme.accent)
                }
            }
            .font(IntegrationType.small)
            .textCase(.uppercase)
            .foregroundStyle(JcTheme.muted)
        } footer: {
            if crons.hasLoaded, allPaused, !schedules.isEmpty {
                Text("Paused schedules don't run. Swipe a row to resume one.")
                    .font(IntegrationType.small)
                    .foregroundStyle(JcTheme.muted)
            }
        }
    }

    private func scheduleRow(_ job: CronJob) -> some View {
        HStack(spacing: 12) {
            // State as shape and colour, never colour alone.
            JcIcon(job.isPaused ? "pause.fill" : "play.fill", size: 11)
                .foregroundStyle(job.isPaused ? JcTheme.muted : JcTheme.accent)
                .fixedSize()
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name.isEmpty ? job.id : job.name)
                    .font(IntegrationType.body)
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Text(scheduleLine(job))
                    .font(IntegrationType.small)
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            JcIcon("chevron.right", size: 11)
                .foregroundStyle(JcTheme.muted.opacity(0.7))
                .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// "every 15m · next 9:40 PM" — when it runs, and when that next happens.
    private func scheduleLine(_ job: CronJob) -> String {
        var parts = [job.schedule].filter { !$0.isEmpty }
        if job.isPaused {
            parts.append("paused")
        } else {
            let next = job.nextRunLabel()
            if !next.isEmpty { parts.append("next \(next)") }
        }
        return parts.joined(separator: " · ")
    }

    private var allPaused: Bool {
        !schedules.isEmpty && schedules.allSatisfy(\.isPaused)
    }

    private var runningSummary: String {
        let off = schedules.filter(\.isPaused).count
        if off == schedules.count { return schedules.count == 1 ? "paused" : "all paused" }
        if off > 0 { return "\(schedules.count - off) of \(schedules.count) running" }
        return schedules.count == 1 ? "running" : "\(schedules.count) running"
    }

    // MARK: What it keeps and knows

    /// Data and skills are what the schedules work with — supporting, so one row
    /// each rather than two more lists competing with the thing that runs.
    @ViewBuilder
    private var holdingsSection: some View {
        let collections = detail?.collections.count ?? integration.collectionCount
        let documents = detail?.documents.count ?? integration.documentCount
        let skills = detail?.skills.count ?? integration.skillCount

        Section {
            NavigationLink(value: IntegrationDataRoute.data(pushed.id)) {
                holdingRow("Data", note: dataNote(collections: collections, documents: documents),
                           count: collections + documents)
            }
            .listRowBackground(rowBackground)
            NavigationLink(value: IntegrationDataRoute.skills(pushed.id)) {
                holdingRow("Skills",
                           note: skills == 0 ? "Nothing claims this integration yet"
                                             : "What Jarvis knows about doing this work",
                           count: skills)
            }
            .listRowBackground(rowBackground)
        } header: {
            Text("Holdings")
                .font(IntegrationType.small)
                .textCase(.uppercase)
                .foregroundStyle(JcTheme.muted)
        }
    }

    private func holdingRow(_ title: String, note: String, count: Int) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(IntegrationType.body).foregroundStyle(JcTheme.text)
                Text(note).font(IntegrationType.small).foregroundStyle(JcTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(count)")
                .font(IntegrationType.body.monospacedDigit())
                .foregroundStyle(JcTheme.muted)
        }
        .padding(.vertical, 4)
    }

    private func dataNote(collections: Int, documents: Int) -> String {
        if collections + documents == 0 { return "Nothing stored yet" }
        var parts: [String] = []
        if collections > 0 { parts.append("\(collections) collection\(collections == 1 ? "" : "s")") }
        if documents > 0 { parts.append("\(documents) document\(documents == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    /// The app's card surface, as a list row background.
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 0).fill(JcTheme.surface)
    }

    // MARK: Schedule sheets — the same ones the Tasks screen used

    @ViewBuilder
    private func sheet(for route: TasksRoute) -> some View {
        switch route {
        case .create:
            CronFormSheet(existing: nil, allSkills: crons.skillOptions()) { form in
                await crons.save(prompt: form.prompt, schedule: form.schedule,
                                 name: form.name, deliver: form.deliver,
                                 skills: form.skills, model: form.model,
                                 profile: form.profile,
                                 toastNotifications: form.toastNotifications,
                                 integration: pushed.id)
            }
        case .edit(let job):
            CronFormSheet(existing: job, allSkills: crons.skillOptions(including: Set(job.skills))) { form in
                await crons.save(prompt: form.prompt, schedule: form.schedule,
                                 name: form.name, deliver: form.deliver,
                                 skills: form.skills, model: form.model,
                                 profile: form.profile,
                                 toastNotifications: form.toastNotifications,
                                 existing: job)
            }
        case .detail(let job):
            CronDetailView(job: job, history: crons.historyStore(for: job)) { action in
                handle(action, on: job)
            }
        }
    }

    private func handle(_ action: CronJobAction, on job: CronJob) {
        route = nil
        switch action {
        case .run:         Task { await crons.run(job) }
        case .pauseResume: Task { await crons.togglePause(job) }
        case .edit:        afterSheetDismissal { route = .edit(job) }
        case .delete:      afterSheetDismissal { pendingDelete = job }
        }
    }
}

/// Where a Data row goes: a collection's records, or one document's contents.
enum IntegrationDataRoute: Hashable {
    /// Everything this integration keeps: its collections and its documents.
    case data(String)
    /// Every skill that claims it.
    case skills(String)
    case records(String, String)
    case document(String, String)
    case skill(String, String)
}
