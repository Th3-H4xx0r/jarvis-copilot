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
    /// Set when this sheet changes an existing integration's UI instead of building
    /// a new integration: nothing gets created, so backing out has nothing to undo.
    var editing: Integration? = nil

    init(onFinish: @escaping () async -> Void) {
        self.onFinish = onFinish
    }

    init(editingUIOf integration: Integration, onFinish: @escaping () async -> Void) {
        self.onFinish = onFinish
        self.editing = integration
    }

    @Environment(\.dismiss) private var dismiss
    @State private var setup = MainActor.assumeIsolated { IntegrationSetupStore() }
    @State private var chat = MainActor.assumeIsolated { ChatStore.production() }
    @State private var confirmingExit = false

    var body: some View {
        NavigationStack {
            ChatConversationView(store: chat,
                                 placeholder: editing == nil ? "Tell Jarvis what to track\u{2026}"
                                                             : "Tell Jarvis what to show\u{2026}",
                                 // Close replaces the composer only once there is
                                 // nothing left to say.
                                 showsComposer: setup.finished == nil) {
                if setup.finished != nil { closeBar }
            }
            .memoryChipsHidden()
            .jcScreen(editing.map { "\($0.name) UI" } ?? "New integration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Editing a UI saves as it goes: leaving is Done, not Cancel.
                    Button(editing == nil ? "Cancel" : "Done") { close(askFirst: true) }
                        .foregroundStyle(JcTheme.muted)
                }
                // The same capsule and picker the Chat tab has, over this session.
                ToolbarItem(placement: .topBarTrailing) { ChatModelButton(store: chat) }
            }
        }
        .task { await begin() }
        // The agent calls integration_ready when it is done; that is the only
        // thing that ends this screen's conversation.
        .onChange(of: chat.messagesTick) { _, _ in setup.noticeReady(in: chat.messages) }
        .alert("Stop setting this up?", isPresented: $confirmingExit) {
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

    private var closeBar: some View {
        // The app's primary CTA, like every other one — not a slab of accent.
        GradientButton("Close", symbol: "checkmark", full: true) {
            Task { await leave() }
        }
        .padding(16)
    }

    private func begin() async {
        guard chat.sessionID == nil else { return }
        guard let sessionID = await setup.begin(uiOf: editing?.id, name: editing?.name ?? "") else { return }
        await chat.openSession(sessionID)
        // The agent opens, so the sheet is never a blank box with a cursor.
        if let editing {
            await chat.send("Help me design the UI for my \(editing.name) integration.")
        } else {
            await chat.send("Help me set up a new integration.")
        }
    }

    private func close(askFirst: Bool) {
        // Editing a UI creates nothing new, so there is nothing to offer to undo.
        if askFirst, editing == nil, setup.createdSpaceID != nil, setup.finished == nil {
            confirmingExit = true
        } else if editing != nil {
            // Done: a save Jarvis is still making finishes on the server.
            Task { await leave() }
        } else {
            Task { await chat.cancel(); await leave() }
        }
    }

    private func leave() async {
        await onFinish()
        dismiss()
    }
}
