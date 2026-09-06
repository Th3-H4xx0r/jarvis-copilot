import SwiftUI

/// "Tasks (cron)" — the scheduled jobs the agent runs on a timer. Ported from
/// `tasks_page.dart`.
///
/// Job cards carry the status badge, the schedule and the next/last run; the
/// detail sheet adds the prompt, the full field grid, run history and the
/// run/pause/edit/delete bar. `CronsStore` polls every 4 s but only while
/// something is actually running, so `onDisappear()` must stop it.
struct TasksPage: View {
    @State private var store: CronsStore
    @State private var route: TasksRoute?
    @State private var pendingDelete: CronJob?

    init(store: CronsStore? = nil) {
        _store = State(initialValue: store ?? MainActor.assumeIsolated { CronsStore() })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable { await store.refresh() }
        .loadErrorBanner(store.errorMessage, hasContent: !store.jobs.isEmpty)
        .jcScreen("Tasks")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                GlassIconButton(symbol: "plus", size: 34, iconSize: 16) { route = .create }
            }
        }
        .task { if !store.hasLoaded { store.load() } }
        .onDisappear { store.onDisappear() }
        .moreToast($store.toast)
        .sheet(item: $route) { sheet(for: $0) }
        .alert("Delete task?",
               isPresented: Binding(get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { job in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { Task { await store.delete(job) } }
        } message: { job in
            Text("This removes \"\(job.name.isEmpty ? job.id : job.name)\" permanently.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let message = store.errorMessage, store.jobs.isEmpty {
            CenteredMessage(text: message, color: JcTheme.danger) { store.load() }
                .padding(.top, 100)
        } else if !store.hasLoaded {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
        } else if store.isEmpty {
            CenteredMessage(text: "No scheduled tasks yet.").padding(.top, 100)
        } else {
            ForEach(store.jobs) { job in
                CronJobCard(job: job, starting: store.isStarting(job),
                            onTap: { route = .detail(job) },
                            onRun: { Task { await store.run(job) } })
            }
        }
    }

    @ViewBuilder
    private func sheet(for route: TasksRoute) -> some View {
        switch route {
        case .create:
            CronFormSheet(existing: nil, allSkills: store.skillOptions()) { form in
                await store.save(prompt: form.prompt, schedule: form.schedule,
                                 name: form.name, deliver: form.deliver,
                                 skills: form.skills, model: form.model,
                                 profile: form.profile,
                                 toastNotifications: form.toastNotifications,
                                 existing: nil)
            }
        case .edit(let job):
            CronFormSheet(existing: job,
                          allSkills: store.skillOptions(including: Set(job.skills))) { form in
                await store.save(prompt: form.prompt, schedule: form.schedule,
                                 name: form.name, deliver: form.deliver,
                                 skills: form.skills, model: form.model,
                                 profile: form.profile,
                                 toastNotifications: form.toastNotifications,
                                 existing: job)
            }
        case .detail(let job):
            CronDetailView(job: job, history: store.historyStore(for: job)) { action in
                handle(action, on: job)
            }
        }
    }

    /// Detail-sheet actions run after the sheet has dismissed itself, so the
    /// follow-up presentation isn't fighting an in-flight dismissal.
    private func handle(_ action: CronJobAction, on job: CronJob) {
        route = nil
        switch action {
        case .run:         Task { await store.run(job) }
        case .pauseResume: Task { await store.togglePause(job) }
        case .edit:        after { route = .edit(job) }
        case .delete:      after { pendingDelete = job }
        }
    }

    private func after(_ work: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            work()
        }
    }
}

/// The screen's three presentations, behind one sheet.
enum TasksRoute: Identifiable {
    case create
    case edit(CronJob)
    case detail(CronJob)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let job): return "edit:\(job.id)"
        case .detail(let job): return "detail:\(job.id)"
        }
    }
}

/// What the detail sheet asks the list to do once it has dismissed.
enum CronJobAction {
    case run, pauseResume, edit, delete
}

// MARK: - Job card

/// One scheduled job: name, status pill, run control, schedule, next/last run.
struct CronJobCard: View {
    let job: CronJob
    let starting: Bool
    let onTap: () -> Void
    let onRun: () -> Void

    private var running: Bool { job.isRunning || starting }
    private var tone: Color { running ? JcTheme.primaryBlue : Color(tone: job.statusTone) }

    var body: some View {
        Button(action: onTap) {
            GlassCard(padding: 0, blur: false,
                      borderColor: running ? JcTheme.primaryBlue.opacity(0.5) : nil) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Text(job.name.isEmpty ? "(unnamed)" : job.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        StatusPill(starting ? "STARTING" : job.statusLabel,
                                   color: tone, live: running, dense: true)
                        CronRunButton(running: job.isRunning, starting: starting, onRun: onRun)
                    }
                    if !job.schedule.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                            Text(job.schedule)
                                .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                                .lineLimit(1)
                        }
                        .padding(.top, 10)
                    }
                    let next = job.nextRunLabel()
                    let last = job.lastRunLabel()
                    if !next.isEmpty || !last.isEmpty {
                        HStack(spacing: 14) {
                            if !next.isEmpty {
                                CronMetaChip(symbol: "arrow.right", label: "Next", value: next)
                            }
                            if !last.isEmpty {
                                CronMetaChip(symbol: "clock.arrow.circlepath",
                                             label: "Last", value: last)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 7)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 15)
            }
        }
        .buttonStyle(.plain)
    }
}

/// "Next in 4m" — a leading glyph, a dim label and the value.
struct CronMetaChip: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11)).foregroundStyle(JcTheme.muted.opacity(0.8))
            Text(label)
                .font(.system(size: 12)).foregroundStyle(JcTheme.muted.opacity(0.7))
            Text(value)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(JcTheme.muted)
        }
    }
}

/// The 36pt run control: a blue play glyph, a spinner while starting, and a
/// muted (disabled) refresh glyph while the job is running.
struct CronRunButton: View {
    let running: Bool
    let starting: Bool
    let onRun: () -> Void

    private var active: Bool { running || starting }

    var body: some View {
        Button { if !active { onRun() } } label: {
            Group {
                if starting {
                    ProgressView().controlSize(.small).tint(JcTheme.primaryBlue)
                } else {
                    Image(systemName: running ? "arrow.triangle.2.circlepath" : "play.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(running ? JcTheme.muted : JcTheme.primaryBlue)
                }
            }
            .frame(width: 36, height: 36)
            .background(active ? JcTheme.glassFill : JcTheme.primaryBlue.opacity(0.16),
                        in: Circle())
            .overlay(Circle().strokeBorder(
                active ? JcTheme.glassBorder : JcTheme.primaryBlue.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(active)
    }
}
