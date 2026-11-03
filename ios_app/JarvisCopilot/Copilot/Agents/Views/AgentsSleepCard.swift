import SwiftUI

/// "☾ MacBook went to sleep · 2:14 PM": the sessions a Mac left behind, one
/// compact row each with Continue, and one button that moves them all to the
/// server. A Mac that only went offline may still be running them, so moving
/// those asks first. ✕ hides the card without moving anything.
struct AgentsSleepCard: View {
    let card: AgentSleepCard
    let store: AgentsStore

    /// Sessions waiting on the "it may still be running" confirmation.
    @State private var confirming: [String] = []
    @State private var error: String?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: JcUnified.cardRadius, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(card.sessions) { s in
                Rectangle().fill(JcTheme.glassBorder).frame(height: 0.5)
                row(s)
            }
            if let all = AgentsListLayout.continueAllTitle(card) {
                Button {
                    go(card.sessions.map(\.ckey))
                } label: {
                    HStack(spacing: 6) {
                        if card.sessions.contains(where: { store.busy.contains($0.ckey) }) {
                            AgentSpinner(size: 11)
                        }
                        Text(all)
                    }
                }
                .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true, full: true))
                .disabled(!store.busy.isDisjoint(with: card.sessions.map(\.ckey)))
                .padding(.horizontal, JcUnified.cardPadding)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            if let error {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(JcTheme.danger)
                    .padding(.horizontal, JcUnified.cardPadding)
                    .padding(.bottom, 12)
            }
        }
        .background(JcTheme.glassFill, in: shape)
        .overlay(shape.strokeBorder(JcTheme.border, lineWidth: 1))
        .alert("Continue on the server?", isPresented: Binding(
            get: { !confirming.isEmpty }, set: { if !$0 { confirming = [] } })) {
            Button(confirming.count == 1 ? "Continue on server" : "Continue \(confirming.count) on server") {
                let ckeys = confirming
                confirming = []
                go(ckeys, confirmOffline: true)
            }
            Button("Cancel", role: .cancel) { confirming = [] }
        } message: {
            Text(AgentsListLayout.offlineWarning(card.deviceName, count: confirming.count))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            JcIcon(card.kind == .sleep ? "moon.fill" : "wifi.slash", size: 13)
                .foregroundStyle(AgentRowStatus.paused.color)
            Text(AgentsListLayout.cardTitle(card))
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
            if let since = card.since {
                Text(since.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundStyle(JcTheme.muted)
            }
            Spacer(minLength: 4)
            Button {
                Task { await store.dismissCard(card) }
            } label: {
                JcIcon("xmark", size: 11, weight: .semibold)
                    .foregroundStyle(JcTheme.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, JcUnified.cardPadding)
        .padding(.trailing, 6)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func row(_ s: AgentCardSession) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Text(AgentsListLayout.cardLine(s))
                    .font(.system(size: 12.5))
                    .foregroundStyle(s.was == "approval" || s.was == "question" ? JcTheme.amber : JcTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                go([s.ckey])
            } label: {
                if store.busy.contains(s.ckey) {
                    AgentSpinner(size: 11)
                } else {
                    Text("Continue")
                }
            }
            .buttonStyle(.jcGlass(tint: JcTheme.accent, compact: true))
            .disabled(store.busy.contains(s.ckey))
            .accessibilityLabel("Continue \(s.title) on the server")
        }
        .padding(.horizontal, JcUnified.cardPadding)
        .padding(.vertical, 9)
    }

    /// An offline Mac asks first; a sleeping one moves with one tap (and the
    /// server can still ask, if it saw the Mac drop without a word).
    private func go(_ ckeys: [String], confirmOffline: Bool = false) {
        if card.kind == .offline && !confirmOffline {
            confirming = ckeys
            return
        }
        error = nil
        Task {
            switch await store.continueOnServer(ckeys, confirmOffline: confirmOffline) {
            case .done: break
            case .needsConfirmation(let left): confirming = left
            case .failed(let message): error = message
            }
        }
    }
}

/// A project group's header, as the card's first row: a folder square, the name
/// and how many sessions it holds, an amber note when something in it waits on
/// you, and the chevron that turns as it opens.
struct AgentsProjectHeader: View {
    let group: AgentProjectGroup
    let open: Bool
    var waiting = false
    let toggle: () -> Void

    private var countLabel: String {
        "\(group.sessions.count) session\(group.sessions.count == 1 ? "" : "s")"
    }

    var body: some View {
        AgentsGroupHeader(symbol: "folder", name: group.name, detail: countLabel,
                          open: open, waiting: waiting, toggle: toggle)
            .accessibilityLabel("\(group.name), \(countLabel)")
    }
}

/// An integration's group header: its name, how many runs it holds and when the
/// newest last did something.
struct AgentsIntegrationHeader: View {
    let group: AgentIntegrationGroup
    let open: Bool
    var waiting = false
    let toggle: () -> Void

    private var countLabel: String {
        "\(group.sessions.count) run\(group.sessions.count == 1 ? "" : "s")"
    }

    var body: some View {
        AgentsGroupHeader(symbol: "puzzlepiece.extension", name: group.name,
                          detail: "\(countLabel) · \(AgentsPresentation.time(group.latestActivity))",
                          open: open, waiting: waiting, toggle: toggle)
            .accessibilityLabel("\(group.name), \(countLabel), last active \(AgentsPresentation.time(group.latestActivity))")
    }
}

/// The row both group headers are: `JcRow`'s shape with a turning chevron.
private struct AgentsGroupHeader: View {
    let symbol: String
    let name: String
    let detail: String
    let open: Bool
    let waiting: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                JcIconSquare(symbol: symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if waiting {
                    HStack(spacing: 5) {
                        Circle().fill(JcTheme.amber).frame(width: 6, height: 6)
                        Text("Needs you")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(JcTheme.amber)
                }
                JcRowChevron()
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.horizontal, JcUnified.cardPadding)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(AgentRowButtonStyle())
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isHeader)
    }
}
