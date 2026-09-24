import SwiftUI

/// Which chat and model the Pod talks to — its own choice, like the phone's Voice
/// settings. Kept on the server (`/api/devices/pod/voice`), so it can be changed
/// while the Pod is offline and applies from the Pod's next turn.
@Observable @MainActor
final class PodVoiceChoice {
    let podID: String
    private(set) var voice = JarvisPodVoice()
    private(set) var sessions: [ChatSessionSummary] = []
    private(set) var catalog: ModelCatalog?
    private(set) var loaded = false
    private(set) var error: String?

    @ObservationIgnored private let api = JarvisPodAPI()

    init(podID: String) { self.podID = podID }

    func load() async {
        do {
            voice = try await api.voice(podID)
            loaded = true
            error = nil
        } catch {
            self.error = apiErrorMessage(error)
        }
        if let list = try? await SessionsAPI().list() { sessions = list.filter { !$0.archived } }
        if catalog == nil { catalog = try? await ModelsAPI().list() }
    }

    var chatTitle: String {
        if voice.sessionID.isEmpty { return "Voice" }
        return sessions.first { $0.id == voice.sessionID }?.displayTitle ?? "A chat"
    }

    var modelTitle: String {
        if voice.model.isEmpty { return "Auto" }
        return catalog?.models.first { $0.id == voice.model }?.label ?? voiceModelShortLabel(voice.model)
    }

    func chooseChat(_ sessionID: String) async { await save { $0.sessionID = sessionID } }

    func chooseModel(_ model: ChatModel?) async {
        await save {
            $0.model = model?.id ?? ""
            $0.provider = model?.providerID ?? ""
        }
    }

    func newChat() async {
        do {
            let id = try await SessionsAPI().create()
            await chooseChat(id)
            if let list = try? await SessionsAPI().list() { sessions = list.filter { !$0.archived } }
        } catch {
            self.error = apiErrorMessage(error)
        }
    }

    private func save(_ change: (inout JarvisPodVoice) -> Void) async {
        let old = voice
        change(&voice)
        do {
            voice = try await api.setVoice(podID, voice)
            error = nil
        } catch {
            voice = old
            self.error = apiErrorMessage(error)
        }
    }
}

/// Pick the Pod's chat: a new one, the shared Voice chat, or any recent chat.
struct PodChatPicker: View {
    let choice: PodVoiceChoice
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GlassGroup {
                    GlassRow(symbol: "plus.bubble", title: "New chat",
                             subtitle: "Start a fresh conversation for the Pod",
                             subtitleLineLimit: 2, action: creating ? nil : { newChat() }) {
                        if creating { ProgressView().controlSize(.small) }
                    }
                    GlassRow(symbol: "waveform", title: "Voice",
                             subtitle: "The shared voice chat (default)",
                             subtitleLineLimit: 2, last: true,
                             action: { pick("") }) {
                        VoicePickerCheck(on: choice.voice.sessionID.isEmpty)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    GlassQuietLabel("Recent chats")
                    if choice.sessions.isEmpty {
                        JcEmptyState(symbol: "bubble.left.and.bubble.right", title: "No chats yet",
                                     subtitle: "Start one in the Chat tab or tap New chat.")
                            .padding(.vertical, 12)
                    } else {
                        GlassGroup {
                            ForEach(Array(choice.sessions.enumerated()), id: \.element.id) { index, s in
                                GlassRow(symbol: "bubble.left", title: s.displayTitle,
                                         last: index == choice.sessions.count - 1,
                                         action: { pick(s.id) }) {
                                    VoicePickerCheck(on: choice.voice.sessionID == s.id)
                                }
                            }
                        }
                    }
                }
                if let error = choice.error {
                    Text(error).font(.footnote).foregroundStyle(JcTheme.danger)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .jcScreen("Pod chat")
        .task { await choice.load() }
    }

    private func pick(_ sessionID: String) {
        Task {
            await choice.chooseChat(sessionID)
            if choice.error == nil { dismiss() }
        }
    }

    private func newChat() {
        creating = true
        Task {
            await choice.newChat()
            creating = false
            if choice.error == nil { dismiss() }
        }
    }
}

/// Pick the Pod's model: "Auto" (the voice default), or any model the server has.
struct PodModelPicker: View {
    let choice: PodVoiceChoice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GlassGroup {
                    GlassRow(symbol: "wand.and.stars", title: "Auto",
                             subtitle: "The same model phone voice uses by default",
                             subtitleLineLimit: 2, last: true,
                             action: { pick(nil) }) {
                        VoicePickerCheck(on: choice.voice.model.isEmpty)
                    }
                }
                if let catalog = choice.catalog {
                    ForEach(catalog.providers, id: \.self) { provider in
                        let group = catalog.models(for: provider)
                        VStack(alignment: .leading, spacing: 0) {
                            GlassQuietLabel(provider.isEmpty ? "Models" : provider)
                                .padding(.top, 16)
                            GlassGroup {
                                ForEach(Array(group.enumerated()), id: \.element.id) { index, model in
                                    GlassRow(symbol: "cpu", title: model.label,
                                             subtitle: model.label == model.id ? nil : model.id,
                                             last: index == group.count - 1,
                                             action: { pick(model) }) {
                                        VoicePickerCheck(on: model.id == choice.voice.model)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                if let error = choice.error {
                    Text(error).font(.footnote).foregroundStyle(JcTheme.danger).padding(.top, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .jcScreen("Pod model")
        .task { await choice.load() }
    }

    private func pick(_ model: ChatModel?) {
        Task {
            await choice.chooseModel(model)
            if choice.error == nil { dismiss() }
        }
    }
}
