import SwiftUI

/// The fleet: the Projects→Sessions tree with live status dots, host badges and
/// per-project actions. Port of `_buildList` + `_ProjectGroup` + `_SessionRow`
/// from `pages/coding_page.dart`.
struct CodingFleetList: View {
    let store: CodingStore
    /// Account quota, fetched by the page (the Flutter build only showed this in
    /// the Live Activity; on the phone it belongs at the top of the fleet).
    var usage: CodingUsage?
    let onSelect: (String) -> Void
    let onResume: (String) async -> Void
    let onNewSession: (CodingProject) -> Void
    let onProjectSettings: (CodingProject) -> Void

    private var groups: [CodingSessionGroup] {
        CodingUI.groups(projects: store.projects, ungrouped: store.ungrouped,
                        sessions: store.sessions)
    }

    var body: some View {
        Group {
            if store.loading && store.sessions.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.error, store.sessions.isEmpty {
                CodingErrorState(message: error) { Task { await store.loadSessions() } }
            } else {
                list
            }
        }
        // A refresh that fails with the fleet already on screen is otherwise
        // silent: `CodingErrorState` only shows when there are no sessions, so
        // the tree just goes stale while the poll keeps failing.
        .loadErrorBanner(store.error, hasContent: !store.sessions.isEmpty)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let usage { CodingUsageCard(usage: usage) }
                if let d = CodingUI.desktopIndicator(store.devices) {
                    CodingDesktopIndicator(label: d.label, online: d.online)
                }
                if groups.isEmpty {
                    CodingEmptyHint().padding(.top, 90)
                } else {
                    ForEach(groups) { group in
                        CodingProjectGroup(
                            group: group,
                            selectedId: store.selectedId,
                            collapsed: store.isCollapsed(group.key),
                            onToggle: { store.toggleCollapsed(group.key) },
                            onSelect: onSelect,
                            onResume: onResume,
                            onNewSession: group.project.map { p in { onNewSession(p) } },
                            onSettings: group.project.map { p in { onProjectSettings(p) } })
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            // Clear of the floating nav pill and the two action buttons.
            .padding(.bottom, 160)
        }
        .refreshable { await store.loadSessions() }
    }
}

// MARK: - Project group

/// A collapsible project header (caret + name + count + "+" / ⚙) over its
/// session rows. Ungrouped passes no project, so it shows no header actions.
struct CodingProjectGroup: View {
    let group: CodingSessionGroup
    let selectedId: String?
    let collapsed: Bool
    let onToggle: () -> Void
    let onSelect: (String) -> Void
    let onResume: (String) async -> Void
    let onNewSession: (() -> Void)?
    let onSettings: (() -> Void)?

    var body: some View {
        GlassCard(padding: 0, blur: false) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !collapsed {
                    if group.sessions.isEmpty {
                        Text("No sessions yet.")
                            .font(.system(size: 13))
                            .foregroundStyle(JcTheme.muted)
                            .padding(.leading, 20)
                            .padding(.trailing, 16)
                            .padding(.bottom, 14)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(group.sessions) { s in
                                CodingSessionRow(session: s,
                                                 selected: selectedId == s.id,
                                                 onTap: { onSelect(s.id) },
                                                 onResume: { await onResume(s.id) })
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
    }

    /// The caret + name is one button (collapse); "+" and ⚙ are siblings, NOT
    /// nested inside it — a Button inside another Button's label swallows taps.
    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JcTheme.muted)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.name)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        if let subtitle = group.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(JcTheme.muted)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer(minLength: 8)
                    CodingCountChip(count: group.sessions.count)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onNewSession {
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(JcTheme.muted)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New session in this project")
            }
            if let onSettings {
                Button(action: onSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(JcTheme.muted)
                        .frame(width: 30, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Project settings")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 12)
    }
}

/// The session count badge in a project header.
struct CodingCountChip: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(JcTheme.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(JcTheme.glassFill, in: Capsule())
            .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }
}

// MARK: - Session row

/// One session: status dot, title, host/source badge, path and recency. A
/// transcript-idle row can't open a live terminal, so it offers Resume instead
/// of a tap-through.
struct CodingSessionRow: View {
    let session: CodingSession
    let selected: Bool
    let onTap: () -> Void
    let onResume: () async -> Void

    @State private var resuming = false

    private var transcriptIdle: Bool { session.isTranscriptIdle }

    /// Resume is a SIBLING of the row button, never nested in its label — a
    /// Button inside another Button's label swallows taps.
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button { onTap() } label: { row }
                .buttonStyle(.plain)
                // An idle transcript has no live tmux to open — Resume it first.
                .disabled(transcriptIdle)
            if transcriptIdle {
                CodingResumeButton(busy: resuming) {
                    guard !resuming else { return }
                    resuming = true
                    Task { await onResume(); resuming = false }
                }
                .padding(.trailing, 10)
                .padding(.top, 10)
            }
        }
        .background(selected ? JcTheme.primaryBlue.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            dot.padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    // Forgotten (detached + idle) sessions are de-emphasised.
                    .foregroundStyle(session.isDim ? JcTheme.muted : JcTheme.text)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    CodingSourceBadge(badge: session.badge)
                    let cwd = (session.cwd ?? "").trimmingCharacters(in: .whitespaces)
                    if !cwd.isEmpty {
                        Text(cwd)
                            .font(.system(size: 12))
                            .foregroundStyle(JcTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                    let age = CodingUI.relativeTime(session.recencyTs, now: Date())
                    if !age.isEmpty {
                        Text(age).font(.system(size: 11)).foregroundStyle(JcTheme.muted.opacity(0.8))
                    }
                }
            }
            if !transcriptIdle {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.top, 2)
            }
        }
        .padding(10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.displayTitle), \(CodingUI.stateLabel(session.fleetState))")
    }

    private var dot: some View {
        Circle()
            .fill(CodingUI.stateColor(session.fleetState))
            .frame(width: 9, height: 9)
            .overlay(session.statusClass == "running"
                     ? nil
                     : Circle().strokeBorder(JcTheme.muted.opacity(0.5), lineWidth: 1))
    }
}

/// The host/source badge: server / desktop / discovered (or live) / history.
struct CodingSourceBadge: View {
    let badge: SessionBadge

    var body: some View {
        let c = CodingUI.badgeColor(kind: badge.kind)
        Text(badge.label)
            .font(.system(size: 11, weight: .bold))
            .kerning(0.2)
            .foregroundStyle(c)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(c.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(c.opacity(0.35), lineWidth: 1))
    }
}

/// Inline Resume for an idle discovered-transcript session.
struct CodingResumeButton: View {
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if busy {
                    ProgressView().controlSize(.mini).tint(JcTheme.primaryBlueHi)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                }
                Text(busy ? "Resuming…" : "Resume")
                    .font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(JcTheme.primaryBlueHi)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(JcTheme.primaryBlue.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(JcTheme.primaryBlue.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

// MARK: - Header cards

/// The account-quota rings (5-hour + weekly). Hidden entirely when the server
/// couldn't compute either window (`-1`, the "unknown" sentinel).
struct CodingUsageCard: View {
    let usage: CodingUsage

    private var rows: [(String, Int, String)] {
        [("5-hour", usage.fiveHourPct, usage.fiveHourResets),
         ("Weekly", usage.weeklyPct, usage.weeklyResets)].filter { $0.1 >= 0 }
    }

    var body: some View {
        if !rows.isEmpty {
            GlassCard(padding: 14, blur: false) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ACCOUNT USAGE")
                        .font(.system(size: 10.5, weight: .bold))
                        .kerning(1.1)
                        .foregroundStyle(JcTheme.muted)
                    ForEach(rows, id: \.0) { row in
                        bar(title: row.0, pct: row.1, resets: row.2)
                    }
                }
            }
        }
    }

    private func bar(title: String, pct: Int, resets: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Spacer()
                Text(CodingUI.usageLabel(pct: pct, resets: resets) ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(JcTheme.muted)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(JcTheme.glassBorder)
                    Capsule().fill(CodingUI.usageColor(pct: pct))
                        .frame(width: max(2, geo.size.width * min(1, Double(pct) / 100)))
                }
            }
            .frame(height: 5)
        }
    }
}

/// "Your Mac is reachable" indicator, so a desktop-hosted launch or a sync
/// setting isn't configured blind.
struct CodingDesktopIndicator: View {
    let label: String
    let online: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: online ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                .font(.system(size: 13))
                .foregroundStyle(online ? JcTheme.success : JcTheme.muted)
            Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(JcTheme.text)
                .lineLimit(1)
            Text(online ? "online" : "offline")
                .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
    }
}

// MARK: - Empty / error

struct CodingEmptyHint: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "terminal").font(.system(size: 38)).foregroundStyle(JcTheme.muted)
            Text("No coding sessions yet")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(JcTheme.text)
                .padding(.top, 14)
            Text("Launch a Claude Code session on a project to get started.")
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }
}

struct CodingErrorState: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        GlassCard {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28)).foregroundStyle(JcTheme.danger)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.danger)
                    .multilineTextAlignment(.center)
                GradientButton("Retry", symbol: "arrow.clockwise", action: onRetry)
            }
        }
        .padding(24)
    }
}

/// The inline red strip used inside the session detail for a recoverable error.
struct CodingInlineError: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 15)).foregroundStyle(JcTheme.danger)
            Text(message).font(.system(size: 13)).foregroundStyle(JcTheme.danger)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(JcTheme.danger.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(JcTheme.danger.opacity(0.30), lineWidth: 1))
    }
}
