import SwiftUI

/// Pick which chat voice talks into: a fresh session, the dedicated "Voice"
/// session, or any recent chat. Same list the Chat tab shows.
struct VoiceSessionPicker: View {
    let selection: VoiceSessionSelection
    var sessionsAPI = SessionsAPI()
    /// Called after the choice changes, so the store can rebind its socket.
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [ChatSessionSummary] = []
    @State private var loading = true
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    GlassGroup {
                        GlassRow(symbol: "plus.bubble", title: "New session",
                                 subtitle: "Start a fresh conversation and voice into it",
                                 subtitleLineLimit: 2, action: creating ? nil : { createNew() }) {
                            if creating { ProgressView().controlSize(.small) }
                        }
                        GlassRow(symbol: "waveform", title: "Voice",
                                 subtitle: "The dedicated voice session (default)",
                                 subtitleLineLimit: 2, last: true,
                                 action: { choose(.defaultVoice) }) {
                            if selection.target == .defaultVoice { check }
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        GlassQuietLabel("Recent chats")
                        if loading {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24)
                        } else if sessions.isEmpty {
                            JcEmptyState(symbol: "bubble.left.and.bubble.right", title: "No chats yet",
                                         subtitle: "Start one in the Chat tab or tap New session.")
                                .padding(.vertical, 12)
                        } else {
                            GlassGroup {
                                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, s in
                                    GlassRow(symbol: "bubble.left", title: s.displayTitle,
                                             subtitle: Self.when(s.updatedAt),
                                             last: index == sessions.count - 1,
                                             action: { choose(.session(id: s.id, title: s.displayTitle)) }) {
                                        if selection.target.sessionID == s.id { check }
                                    }
                                }
                            }
                        }
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(JcTheme.danger)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .jcScreen("Voice session")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task {
                do {
                    let list = try await sessionsAPI.list()
                    sessions = list.filter { !$0.archived }
                    selection.reconcile(with: list)
                } catch {
                    self.error = error.localizedDescription
                }
                loading = false
            }
        }
        .presentationDetents([.large])
    }

    private var check: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(JcTheme.cyan)
    }

    private func choose(_ target: VoiceSessionSelection.Target) {
        selection.select(target)
        onChange()
        dismiss()
    }

    private func createNew() {
        creating = true
        Task {
            do {
                try await selection.startNewSession(api: sessionsAPI)
                onChange()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            creating = false
        }
    }

    private static func when(_ epoch: Int?) -> String? {
        guard let epoch else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
