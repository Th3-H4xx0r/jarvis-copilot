import SwiftUI

/// The Coding tab's root: a control plane for tmux-backed Claude Code sessions.
/// Port of `pages/coding_page.dart`'s shell — the Projects→Sessions fleet, the
/// approval banner, the launch/project sheets, and the push into one session.
///
/// Every tab stays alive for the life of the shell, so all network work is gated
/// on `router.selectedTab == .coding && scenePhase == .active` (the Flutter
/// build's `activeTabIndex` + `AppLifecycle.isForeground` gate). Where Flutter
/// swapped the body between list and detail, this pushes a real screen so the
/// system back gesture works — the selection still lives in the store, so the
/// detail poll and the terminal attach/detach behave exactly as before.
struct CodingPage: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase

    @State private var flag: CodingVisibilityFlag
    @State private var store: CodingStore
    @State private var usage: CodingUsage?
    @State private var launch: CodingLaunchTarget?
    @State private var newProject = false
    @State private var projectSettings: CodingProject?

    /// `store` is injectable for tests; the production path builds one whose
    /// visibility closure reads `flag`, which the view keeps in step with the
    /// tab + scene phase.
    init(store: CodingStore? = nil) {
        let flag = CodingVisibilityFlag()
        _flag = State(initialValue: flag)
        _store = State(initialValue: store ?? MainActor.assumeIsolated {
            CodingStore(isVisible: { flag.isVisible })
        })
    }

    private var visible: Bool { router.selectedTab == .coding && scenePhase == .active }

    private var visibility: CodingVisibility { CodingVisibility(flag: flag, store: store) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                CodingApprovalBanner(store: store)
                if let error = store.error, !store.sessions.isEmpty {
                    CodingInlineError(message: error).padding(.horizontal, 16).padding(.top, 8)
                }
                CodingFleetList(
                    store: store,
                    usage: usage,
                    onSelect: { id in Task { await store.select(id) } },
                    onResume: { id in await resume(id) },
                    onNewSession: { launch = .project($0) },
                    onProjectSettings: { projectSettings = $0 })
            }
            .overlay(alignment: .bottomTrailing) { actionButtons }
            .jcScreen("Coding")
            .toolbar { toolbar }
            .navigationDestination(item: Binding(
                get: { store.selectedId },
                // Swiping back is a deselect: it hands the single-viewer PTY
                // back and stops the detail poll.
                set: { if $0 == nil { store.deselect() } })) { id in
                    CodingSessionRoute(sessionId: id, coding: store)
                }
        }
        .sheet(item: $launch) { target in
            CodingLaunchSheet(store: store, project: target.project)
        }
        .sheet(isPresented: $newProject) {
            CodingNewProjectSheet(store: store)
        }
        .sheet(item: $projectSettings) { project in
            CodingProjectSettingsSheet(store: store, project: project)
        }
        .onChange(of: visible, initial: true) { _, isVisible in
            visibility.set(isVisible)
            if isVisible { Task { await appear() } }
        }
        .onDisappear { visibility.set(false) }
        .onChange(of: DeepLinkTargets.shared.generation, initial: true) { _, _ in
            if let id = DeepLinkTargets.shared.consumeCoding() {
                Task { await store.select(id) }
            }
        }
    }

    // MARK: Chrome

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink { CodeMasterSettingsPage() } label: {
                Image(systemName: "gearshape").font(.system(size: 17))
            }
            .tint(JcTheme.text)
            .accessibilityLabel("Code Master settings")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await store.discoverRefresh() } } label: {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 17))
            }
            .tint(store.busyProjects ? JcTheme.muted : JcTheme.text)
            .disabled(store.busyProjects)
            .accessibilityLabel("Rescan discovered sessions")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await store.loadSessions() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 17))
            }
            .tint(store.loading ? JcTheme.muted : JcTheme.text)
            .disabled(store.loading)
            .accessibilityLabel("Refresh sessions")
        }
    }

    private var actionButtons: some View {
        VStack(alignment: .trailing, spacing: 12) {
            Button { newProject = true } label: {
                Label("Project", systemImage: "folder.badge.plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(JcTheme.surfaceAlt, in: Capsule())
                    .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(store.busyProjects)

            Button { launch = .fleet } label: {
                Label("Launch", systemImage: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(JcTheme.blueGradient, in: Capsule())
                    .shadow(color: JcTheme.primaryBlue.opacity(0.4), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(store.launching)
        }
        .padding(.trailing, 18)
        .padding(.bottom, 18)
    }

    // MARK: Actions

    /// Becoming visible reloads the fleet (the spinner only shows when there is
    /// nothing on screen yet, so a re-entry is a quiet refresh). The devices list
    /// feeds the sync pickers and usage is the quota card — both best-effort.
    private func appear() async {
        await store.loadSessions()
        await store.loadDevices()
        do { usage = try await store.api.usage() } catch {
            JcLog.dropped(JcLog.coding, "account usage", error)
        }
    }

    private func resume(_ id: String) async {
        if let openId = await store.resumeSession(id) { await store.select(openId) }
    }
}

/// Telling the Live Activity that the user is looking at Coding.
@MainActor
protocol CodingVisibilityReporting: AnyObject {
    func setCodingVisible(_ visible: Bool)
}

extension LiveActivityCoordinator: CodingVisibilityReporting {}

/// Everything that has to hear about the Coding tab becoming (in)visible, in one
/// place so it can be asserted without rendering a view.
///
/// Three listeners: the flag `CodingStore`'s `isVisible` closure reads, the
/// store's own list poll, and the Live Activity coordinator — which keeps its
/// fast poll cadence while Coding is on screen even before a session goes live
/// (`LivePollPolicy.pollInterval(codingVisible:)`), and drops back to 60 s
/// discovery when it isn't.
@MainActor
struct CodingVisibility {
    let flag: CodingVisibilityFlag
    let store: CodingStore
    let liveActivity: any CodingVisibilityReporting

    init(flag: CodingVisibilityFlag, store: CodingStore,
         liveActivity: (any CodingVisibilityReporting)? = nil) {
        self.flag = flag
        self.store = store
        self.liveActivity = liveActivity ?? LiveActivityCoordinator.shared
    }

    func set(_ visible: Bool) {
        flag.set(visible)
        store.setListPolling(visible)
        liveActivity.setCodingVisible(visible)
    }
}

/// A thread-safe one-field box so `CodingStore`'s `isVisible` closure can be
/// built in the view's `init`, before the tab and scene phase are readable.
final class CodingVisibilityFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) {
        lock.lock(); value = newValue; lock.unlock()
    }

    var isVisible: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// What the launch sheet is launching into: the fleet at large, or one project.
enum CodingLaunchTarget: Identifiable {
    case fleet
    case project(CodingProject)

    var project: CodingProject? {
        if case .project(let p) = self { return p }
        return nil
    }

    var id: String { project?.id ?? "__fleet__" }
}

/// Resolves the per-session store OUTSIDE `body`.
///
/// `CodingStore.sessionStore(_:)` caches into an observed dictionary, so calling
/// it while a body is being evaluated would read-then-write the same observed
/// property and re-invalidate the view forever. `.task` runs after the render.
struct CodingSessionRoute: View {
    let sessionId: String
    let coding: CodingStore

    @State private var session: CodingSessionStore?

    var body: some View {
        Group {
            if let session {
                CodingSessionScreen(coding: coding, session: session)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: sessionId) { session = coding.sessionStore(sessionId) }
    }
}
