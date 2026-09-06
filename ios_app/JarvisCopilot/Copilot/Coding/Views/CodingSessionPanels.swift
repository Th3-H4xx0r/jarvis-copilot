import SwiftUI

/// The session detail's cards: cross-device sync status, the ended-session
/// recovery panel and the slim banner chat shows once a session has ended.
/// Ported from `_SyncCard`, `_EndedPanel` and `_EndedChatBanner`.

// MARK: - Sync

/// Cross-device sync panel (parity with the WebUI): a coloured dot + device +
/// online/disconnected, a status label, a progress bar while syncing, Refresh.
struct CodingSyncCard: View {
    let sync: CodingSyncStatus
    let onRefresh: () async -> Void

    @State private var refreshing = false

    var body: some View {
        GlassCard(padding: 16, blur: false) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Sync").font(.system(size: 14, weight: .bold))
                        .foregroundStyle(JcTheme.text)
                    Spacer()
                    Button {
                        guard !refreshing else { return }
                        refreshing = true
                        Task { await onRefresh(); refreshing = false }
                    } label: {
                        HStack(spacing: 6) {
                            if refreshing {
                                ProgressView().controlSize(.mini).tint(JcTheme.muted)
                            } else {
                                Image(systemName: "arrow.clockwise").font(.system(size: 12))
                                    .foregroundStyle(JcTheme.muted)
                            }
                            Text("Refresh").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(JcTheme.text)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(JcTheme.glassFill,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(refreshing)
                }
                deviceLine
                if sync.isSyncing { progress }
            }
        }
    }

    private var deviceLine: some View {
        HStack(spacing: 8) {
            Circle().fill(sync.deviceOnline ? JcTheme.success : JcTheme.muted)
                .frame(width: 9, height: 9)
            Text((sync.device ?? "").isEmpty ? "device" : sync.device!)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
            Text(sync.deviceOnline ? "online" : "disconnected")
                .font(.system(size: 12)).foregroundStyle(JcTheme.muted)
            Spacer(minLength: 8)
            Text(CodingUI.syncLabel(sync))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(sync.status == "error" ? JcTheme.danger : JcTheme.text)
                .lineLimit(1)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(JcTheme.glassFill)
                    Capsule().fill(JcTheme.primaryBlue)
                        .frame(width: max(2, geo.size.width * min(1, Double(sync.pct) / 100)))
                }
            }
            .frame(height: 6)
            if let label = CodingUI.syncProgressLabel(sync) {
                Text(label).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
            }
        }
    }
}

// MARK: - Ended session

/// Shown instead of the live terminal when a session has ENDED (claude quit /
/// its tmux is gone). A SERVER session offers Restart / Delete; a DISCOVERED
/// Mac session offers Relaunch on device / Resume on server / Reopen terminal.
struct CodingEndedPanel: View {
    let session: CodingSession
    let busy: Bool
    let onRelaunchDevice: () -> Void
    let onResumeServer: () -> Void
    let onReopenTerminal: () -> Void
    let onRestart: () -> Void
    let onDelete: () -> Void

    private var isServer: Bool {
        (session.host ?? "server") == "server" && !(session.source ?? "").hasPrefix("discovered")
    }

    private var hint: String {
        isServer
            ? "The claude for this session has stopped (you quit it / its tmux ended). "
              + "There’s no live terminal — Restart launches it again in the same folder on the server."
            : "The live claude for this session has stopped (its tmux session ended). "
              + "There’s no live terminal to attach. Relaunch it on the device to keep working there, "
              + "or resume it on the server (it continues from the synced transcript)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "power").font(.system(size: 16)).foregroundStyle(JcTheme.muted)
                Text("Session ended")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(JcTheme.text)
            }
            Text(hint)
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
                .padding(.top, 8)
            VStack(spacing: 10) {
                if isServer {
                    GradientButton("Restart", symbol: "arrow.clockwise", full: true,
                                   action: busy ? nil : onRestart)
                    GlassButton(title: "Delete", symbol: "trash", ghost: true, full: true,
                                action: busy ? nil : onDelete)
                } else {
                    GradientButton("Relaunch on device", symbol: "desktopcomputer", full: true,
                                   action: busy ? nil : onRelaunchDevice)
                    GlassButton(title: "Resume on server", symbol: "arrow.triangle.2.circlepath",
                                ghost: true, full: true, action: busy ? nil : onResumeServer)
                    GlassButton(title: "Reopen terminal", symbol: "arrow.clockwise",
                                ghost: true, full: true, action: busy ? nil : onReopenTerminal)
                }
            }
            .padding(.top, 14)
        }
        .padding(16)
        .background(JcTheme.surface.opacity(0.40),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(JcTheme.muted.opacity(0.20), lineWidth: 1))
    }
}

/// Chat stays readable after a session ends; this banner says so and links to
/// the Terminal view, where the recovery panel lives.
struct CodingEndedChatBanner: View {
    let onRecover: () -> Void

    var body: some View {
        Button(action: onRecover) {
            HStack(spacing: 8) {
                Image(systemName: "power").font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                Text("Session ended — chat is read-only. Tap for recovery options.")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(JcTheme.glassFill,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
