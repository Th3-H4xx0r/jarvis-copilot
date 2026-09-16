import SwiftUI

/// Setting up an integration by talking to Jarvis.
///
/// Full screen, because this is a conversation rather than a form — and it is the
/// same conversation the Chat tab has: `ChatConversationView` brings the
/// transcript, the markdown, the tool cards, the streaming and the scrolling with
/// it, so this file is only the chrome and the one rule this screen adds.
///
/// That rule: when the agent says the integration is ready, the composer is
/// replaced by a single Close button. There is nothing left to say.
struct IntegrationSetupSheet: View {
    let onFinish: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var setup = MainActor.assumeIsolated { IntegrationSetupStore() }
    @State private var chat = MainActor.assumeIsolated { ChatStore.production() }
    @State private var confirmingExit = false

    var body: some View {
        NavigationStack {
            ChatConversationView(store: chat,
                                 placeholder: "Tell Jarvis what to track\u{2026}",
                                 // The composer goes away only once there is
                                 // nothing left to say.
                                 showsComposer: setup.finished == nil) {
                if setup.finished != nil { doneNote }
            }
            .jcScreen("New integration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                // Once it is built there is nothing to cancel, and the way out
                // becomes Done — where a sheet's way out belongs.
                if setup.finished == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { close(askFirst: true) }
                            .foregroundStyle(JcTheme.muted)
                    }
                    // The same capsule and picker the Chat tab has, over this session.
                    ToolbarItem(placement: .topBarTrailing) { ChatModelButton(store: chat) }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { Task { await leave() } }
                            .fontWeight(.semibold)
                            .tint(JcTheme.accent)
                    }
                }
            }
        }
        .task { await begin() }
        // The agent calls integration_ready when it is done; that is the only
        // thing that ends this screen's conversation.
        .onChange(of: chat.messagesTick) { _, _ in setup.noticeReady(in: chat.messages) }
        .confirmationDialog("Stop setting this up?", isPresented: $confirmingExit,
                            titleVisibility: .visible) {
            Button("Delete what was created", role: .destructive) {
                Task {
                    await chat.cancel()          // it builds as it goes; stop it first
                    await setup.discard()
                    await leave()
                }
            }
            Button("Keep it") { Task { await chat.cancel(); await leave() } }
            Button("Carry on", role: .cancel) {}
        } message: {
            Text("Some of this integration already exists — it is built as you go, not at the end.")
        }
    }

    /// Where the composer was: a line saying it is done, not a slab of a button.
    /// Done is in the navigation bar, which is where a sheet's way out lives.
    private var doneNote: some View {
        Label("Set up and running", jcIcon: "checkmark")
            .font(IntegrationType.small)
            .foregroundStyle(JcTheme.success)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
    }

    private func begin() async {
        guard chat.sessionID == nil else { return }
        guard let sessionID = await setup.begin() else { return }
        await chat.openSession(sessionID)
        // The agent opens, so the sheet is never a blank box with a cursor.
        await chat.send("Help me set up a new integration.")
    }

    private func close(askFirst: Bool) {
        if askFirst, setup.createdSpaceID != nil, setup.finished == nil {
            confirmingExit = true
        } else {
            Task { await chat.cancel(); await leave() }
        }
    }

    private func leave() async {
        await onFinish()
        dismiss()
    }
}
