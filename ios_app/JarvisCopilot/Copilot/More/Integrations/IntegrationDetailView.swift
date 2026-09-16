import SwiftUI

/// One integration: the schedules it runs, the data it keeps, the skills
/// written for it — and the switch that turns the whole thing off.
///
/// Schedules come from `/api/crons` rather than the integration payload, because
/// tapping one has to open the same detail sheet the Tasks screen used, with the
/// prompt, the run history and the run/pause/edit/delete bar.
struct IntegrationDetailView: View {
    let pushed: Integration
    @Bindable var store: IntegrationsStore
    @Environment(\.dismiss) private var dismiss

    @State private var crons = MainActor.assumeIsolated { CronsStore() }
    @State private var route: TasksRoute?
    @State private var pendingDelete: CronJob?
    @State private var confirmingDelete = false

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
            VStack(alignment: .leading, spacing: 20) {
                header
                schedulesSection
                dataSection
                skillsSection
                dangerZone
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .refreshable {
            await store.open(pushed.id)
            await crons.refresh()
        }
        .jcScreen(integration.name)
        .task {
            if !crons.hasLoaded { crons.load() }   // its own endpoint; don't wait on the detail
            await store.open(pushed.id)
        }
        .onDisappear { crons.onDisappear() }
        .moreToast($store.toast)
        .sheet(item: $route) { sheet(for: $0) }
        .alert("Delete task?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { job in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await crons.delete(job) } }
        } message: { job in
            Text("This removes \"\(job.name.isEmpty ? job.id : job.name)\" permanently.")
        }
        .alert("Delete \(integration.name)?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { if await store.delete(integration) { dismiss() } }
            }
        } message: {
            Text(schedules.isEmpty
                 ? "Everything it has stored goes with it. This cannot be undone."
                 : "Its \(schedules.count) \(schedules.count == 1 ? "schedule" : "schedules") "
                   + "and everything it has stored go with it. This cannot be undone.")
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !integration.summary.isEmpty {
                Text(integration.summary)
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                GlassButton(title: "New schedule", symbol: "plus") { route = .create }
                GlassButton(title: integration.isPaused ? "Resume" : "Pause",
                            symbol: integration.isPaused ? "play.fill" : "pause.fill") {
                    Task { await store.togglePause(integration) }
                }
            }
        }
    }

    @ViewBuilder
    private var schedulesSection: some View {
        IntegrationSection(title: "Schedules", count: schedules.count) {
            if !crons.hasLoaded {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
            } else if schedules.isEmpty {
                IntegrationEmptyRow(text: "No schedules yet.")
            } else {
                ForEach(schedules) { job in
                    CronJobCard(job: job, starting: crons.isStarting(job),
                                onTap: { route = .detail(job) },
                                onRun: { Task { await crons.run(job) } })
                }
            }
        }
    }

    @ViewBuilder
    private var dataSection: some View {
        IntegrationSection(title: "Data",
                           count: (detail?.collections.count ?? 0) + (detail?.documents.count ?? 0)) {
            if let message = store.detailError {
                IntegrationEmptyRow(text: message)
            } else if let detail {
                if detail.hasNothingStored {
                    IntegrationEmptyRow(text: "Nothing stored yet.")
                } else {
                    ForEach(detail.collections) { collection in
                        NavigationLink(value: IntegrationDataRoute.records(pushed.id, collection.name)) {
                            IntegrationRow(name: collection.name,
                                           note: collection.summary.isEmpty ? "no description yet" : collection.summary,
                                           trailing: collection.count.formatted())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(detail.documents) { document in
                        NavigationLink(value: IntegrationDataRoute.document(pushed.id, document.key)) {
                            IntegrationRow(name: document.key,
                                           note: document.summary.isEmpty ? "a stored document" : document.summary,
                                           trailing: document.sizeLabel)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
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
                    ForEach(skills) { skill in
                        IntegrationRow(name: skill.name, note: skill.summary, trailing: "")
                    }
                }
            } else if store.detailError == nil {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 16)
            }
        }
    }

    private var dangerZone: some View {
        Button(role: .destructive) { confirmingDelete = true } label: {
            HStack(spacing: 8) {
                JcIcon("trash", size: 14).fixedSize()
                Text("Delete integration").font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(JcTheme.danger)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
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
}

// MARK: - Pieces

/// A titled section with a count chip, so every section reads the same.
struct IntegrationSection<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(JcTheme.muted)
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(JcTheme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(JcTheme.accent.opacity(0.12)))
            }
            content
        }
    }
}

struct IntegrationRow: View {
    let name: String
    let note: String
    let trailing: String

    var body: some View {
        GlassCard(padding: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                    if !note.isEmpty {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                if !trailing.isEmpty {
                    Text(trailing)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(JcTheme.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct IntegrationEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(JcTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }
}
