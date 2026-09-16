import SwiftUI

/// One integration: what it is, what it runs, what it keeps, what it knows.
///
/// Grouped inset cards — each section is a single rounded card with hairline
/// separators, and every row carries its own ⋯ for Open and Delete. The
/// integration's own controls (pause, delete) live in the nav bar's ⋯, so the
/// content starts at the content.
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // No identity card: the navigation bar already says the name, and
                // a box under it repeating the name is the screen's wasted space.
                if !integration.summary.isEmpty {
                    Text(integration.summary)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                schedulesSection
                dataSection
                skillsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 32)
        }
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
                // The schedules live in a different store; without this the card
                // keeps listing jobs that are gone.
                await crons.refresh()
                if outcome.spaceRemoved {
                    // After the sheet has dismissed itself: popping the presenter
                    // out from under a sheet that is still up swallows the pop.
                    afterSheetDismissal { dismiss() }
                }
                return outcome.succeeded
            }
        }
        .alert("Delete schedule?",
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
        } message: { job in
            Text("\"\(job.name.isEmpty ? job.id : job.name)\" stops running and its history goes with it. This cannot be undone.")
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
            Button { route = .create } label: { Label("New schedule", jcIcon: "plus") }
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

    // MARK: Sections

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

    /// What the header says instead of the status pill the identity card carried.
    private var runningSummary: String? {
        if schedules.isEmpty { return nil }
        let off = schedules.filter(\.isPaused).count
        if off == schedules.count { return schedules.count == 1 ? "paused" : "all paused" }
        if off > 0 { return "\(schedules.count - off) running" }
        return schedules.count == 1 ? "running" : "all running"
    }

    @ViewBuilder
    private var schedulesSection: some View {
        // First, and with its state in the header: an integration is a thing that
        // runs for you, and "is it working?" is what this screen is opened to answer.
        IntegrationSection(title: "Schedules", count: schedules.count,
                           status: crons.hasLoaded ? runningSummary : nil,
                           statusColor: allPaused ? JcTheme.muted : JcTheme.success,
                           action: .init(symbol: "plus") { route = .create }) {
            if !crons.hasLoaded {
                IntegrationLoadingRow()
            } else if schedules.isEmpty {
                IntegrationEmptyRow(text: "Nothing runs in this integration yet — a schedule is what does its work.",
                                    actionTitle: "New schedule") { route = .create }
            } else {
                InsetRows(schedules) { job in
                    IntegrationRow(name: job.name.isEmpty ? job.id : job.name,
                                   note: scheduleLine(job),
                                   trailing: "",
                                   leading: job.isPaused ? "pause.fill" : "play.fill",
                                   leadingColor: job.isPaused ? JcTheme.muted : JcTheme.success,
                                   onTap: { route = .detail(job) }) {
                        Button { route = .detail(job) } label: { Label("Open", jcIcon: "arrow.right") }
                        Button {
                            Task { await crons.togglePause(job); await store.refresh() }
                        } label: {
                            Label(job.isPaused ? "Resume" : "Pause",
                                  jcIcon: job.isPaused ? "play.fill" : "pause.fill")
                        }
                        Button(role: .destructive) { pendingDelete = job } label: {
                            Label("Delete", jcIcon: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var dataSection: some View {
        let collections = detail?.collections ?? []
        let documents = detail?.documents ?? []
        IntegrationSection(title: "Data", count: collections.count + documents.count) {
            if let message = store.detailError {
                IntegrationEmptyRow(text: message)
            } else if detail == nil {
                IntegrationLoadingRow()
            } else if collections.isEmpty && documents.isEmpty {
                IntegrationEmptyRow(text: "Nothing stored yet.")
            } else {
                InsetGroup {
                    ForEach(collections) { collection in
                        IntegrationRow(name: collection.name,
                                       note: collection.summary.isEmpty
                                           ? "no description yet" : collection.summary,
                                       trailing: collection.count.formatted(),
                                       route: .records(pushed.id, collection.name)) {
                            Button(role: .destructive) {
                                confirming = .collection(collection)
                            } label: { Label("Delete", jcIcon: "trash") }
                        }
                        if collection.id != collections.last?.id || !documents.isEmpty {
                            InsetDivider()
                        }
                    }
                    ForEach(documents) { document in
                        IntegrationRow(name: document.key,
                                       note: document.summary.isEmpty
                                           ? "a stored document" : document.summary,
                                       trailing: document.sizeLabel,
                                       route: .document(pushed.id, document.key)) {
                            Button(role: .destructive) {
                                confirming = .document(document)
                            } label: { Label("Delete", jcIcon: "trash") }
                        }
                        if document.id != documents.last?.id { InsetDivider() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var skillsSection: some View {
        let skills = detail?.skills
        IntegrationSection(title: "Skills", count: skills?.count ?? 0) {
            if let skills {
                if skills.isEmpty {
                    IntegrationEmptyRow(
                        text: "No skills claim this integration. A skill joins one by naming it "
                            + "in its front matter: integration: \(pushed.id)")
                } else {
                    InsetRows(skills) { skill in
                        IntegrationRow(name: skill.name, note: skill.summary, trailing: "",
                                       route: .skill(pushed.id, skill.name)) {
                            Button(role: .destructive) {
                                confirming = .skill(skill)
                            } label: { Label("Delete\u{2026}", jcIcon: "trash") }
                        }
                    }
                }
            } else if store.detailError == nil {
                IntegrationLoadingRow()
            }
        }
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
    case records(String, String)
    case document(String, String)
    case skill(String, String)
}
