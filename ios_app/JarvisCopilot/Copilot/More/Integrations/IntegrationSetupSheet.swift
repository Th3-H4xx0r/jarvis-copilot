import SwiftUI

/// Setting up an integration by talking to Jarvis.
///
/// Full screen, because this is a conversation rather than a form. Jarvis asks
/// for what it needs, builds each piece as it is settled, and drops a card in as
/// each one appears. When it says the integration is ready the composer collapses
/// into a single Close button — there is nothing left to say.
struct IntegrationSetupSheet: View {
    let onFinish: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var store = MainActor.assumeIsolated { IntegrationSetupStore() }
    @State private var draft = ""
    @State private var confirmingExit = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                Divider().overlay(JcTheme.border)
                footer
            }
            .background(JcTheme.bg.ignoresSafeArea())
            .jcScreen("New integration")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { close(askFirst: true) }
                        .foregroundStyle(JcTheme.muted)
                }
            }
        }
        .task { await store.begin() }
        .interactiveDismissDisabled(store.createdSpaceID != nil && store.finished == nil)
        .confirmationDialog("Stop setting this up?", isPresented: $confirmingExit,
                            titleVisibility: .visible) {
            Button("Delete what was created", role: .destructive) {
                Task {
                    // Stop the agent first: it creates as it goes, so anything it
                    // writes after this would land in a space we are removing.
                    await store.close()
                    await store.discard()
                    await onFinish()
                    dismiss()
                }
            }
            Button("Keep it") { Task { await store.close(); await onFinish(); dismiss() } }
            Button("Carry on", role: .cancel) {}
        } message: {
            Text("Some of this integration already exists — it is built as you go, not at the end.")
        }
    }

    // MARK: The conversation

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.turns) { turn in
                        SetupTurnView(turn: turn)
                            .id(turn.id)
                    }
                    if store.streaming, store.turns.last?.isEmpty != false {
                        ThinkingDots().padding(.leading, 4)
                    }
                    if let message = store.errorMessage {
                        Text(message)
                            .font(.system(size: 12.5))
                            .foregroundStyle(JcTheme.danger)
                    }
                    if let finished = store.finished {
                        SetupDoneCard(finish: finished)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
            .onChange(of: store.turns.count) { _, _ in scroll(proxy) }
            .onChange(of: store.finished) { _, _ in scroll(proxy) }
        }
    }

    private let bottomID = "setup-bottom"

    private func scroll(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(bottomID, anchor: .bottom) }
    }

    // MARK: What you can do about it

    @ViewBuilder
    private var footer: some View {
        if store.finished != nil {
            Button {
                Task { await store.close(); await onFinish(); dismiss() }
            } label: {
                Text("Close")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(JcTheme.accent, in: RoundedRectangle(cornerRadius: 14,
                                                                     style: .continuous))
                    .foregroundStyle(JcTheme.bg)
            }
            .buttonStyle(.plain)
            .padding(16)
        } else {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Tell Jarvis what to track\u{2026}", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 15))
                    .foregroundStyle(JcTheme.text)
                    .focused($composerFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(JcTheme.surface, in: RoundedRectangle(cornerRadius: 18,
                                                                      style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(JcTheme.border, lineWidth: 0.5))
                    .disabled(!store.canSend)
                    .overlay(alignment: .trailing) {
                        if store.needsRetry {
                            Button("Retry") { Task { await store.begin() } }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(JcTheme.accent)
                                .padding(.trailing, 12)
                        }
                    }

                Button {
                    let text = draft
                    draft = ""
                    store.startSend(text)
                } label: {
                    JcIcon("arrow.up", size: 16)
                        .foregroundStyle(JcTheme.bg)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(sendable ? JcTheme.accent
                                                           : JcTheme.muted.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .disabled(!sendable)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var sendable: Bool {
        store.canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func close(askFirst: Bool) {
        if askFirst, store.createdSpaceID != nil, store.finished == nil {
            confirmingExit = true
        } else {
            Task { await store.close(); await onFinish(); dismiss() }
        }
    }
}

/// One turn, with the pieces it created underneath it.
struct SetupTurnView: View {
    let turn: SetupTurn

    var body: some View {
        VStack(alignment: turn.role == .user ? .trailing : .leading, spacing: 8) {
            if !turn.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(turn.text)
                    .font(.system(size: 15))
                    .foregroundStyle(JcTheme.text)
                    .multilineTextAlignment(turn.role == .user ? .trailing : .leading)
                    .padding(.horizontal, turn.role == .user ? 14 : 0)
                    .padding(.vertical, turn.role == .user ? 10 : 0)
                    .background {
                        if turn.role == .user {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(JcTheme.accent.opacity(0.14))
                        }
                    }
            }
            ForEach(turn.cards) { SetupCardView(card: $0) }
        }
        .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
    }
}

/// A piece of the integration, the moment it exists.
struct SetupCardView: View {
    let card: SetupCard

    private var symbol: String {
        switch card.kind {
        case .integration: return "square.grid.2x2"
        case .data:        return "tray.full"
        case .schedule:    return "clock"
        case .skill:       return "sparkles"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            JcIcon(symbol, size: 14).foregroundStyle(JcTheme.success).fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                if !card.detail.isEmpty {
                    Text(card.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Text(card.kind.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold))
                .kerning(0.7)
                .foregroundStyle(JcTheme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(JcTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(JcTheme.success.opacity(0.25), lineWidth: 0.5))
    }
}

struct SetupDoneCard: View {
    let finish: SetupFinish

    var body: some View {
        HStack(spacing: 10) {
            JcIcon("checkmark.circle", size: 18).foregroundStyle(JcTheme.success).fixedSize()
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                Text(finish.summary.isEmpty ? finish.spaceID : finish.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(JcTheme.success.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
