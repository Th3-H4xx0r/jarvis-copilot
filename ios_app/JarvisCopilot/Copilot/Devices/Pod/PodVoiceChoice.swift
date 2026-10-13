import SwiftUI

/// Which chat and agent harness the Pod talks to — its own choice, like the phone's
/// Voice settings. Kept on the server (`/api/devices/pod/voice`), so it can be changed
/// while the Pod is offline and applies from the Pod's next turn.
@Observable @MainActor
final class PodVoiceChoice {
    let podID: String
    private(set) var voice = JarvisPodVoice()
    private(set) var sessions: [ChatSessionSummary] = []
    private(set) var harnesses: [AgentHarness] = []
    /// The harness Voice runs (its own pick, else the one default) — what the
    /// Pod's "" choice follows.
    private(set) var voiceDefaultID: String?
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
        if let snapshot = try? await HarnessAPI().snapshot() {
            harnesses = snapshot.harnesses
            voiceDefaultID = snapshot.assignments["voice"]
        }
    }

    var chatTitle: String {
        if voice.sessionID.isEmpty { return "Voice" }
        return sessions.first { $0.id == voice.sessionID }?.displayTitle ?? "A chat"
    }

    var harnessTitle: String { Self.harnessTitle(voice.harnessID, names: names, voiceDefaultID: voiceDefaultID) }

    /// The "" row: "Voice default (Fast + Claude)".
    var voiceDefaultTitle: String { Self.harnessTitle("", names: names, voiceDefaultID: voiceDefaultID) }

    private var names: [String: String] {
        Dictionary(harnesses.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// "Voice default (Name)" for no choice — Name is what Voice runs (its own
    /// pick, else the one default), bare until the harnesses load. A harness
    /// deleted since reads "A harness" (the server then runs the Voice harness).
    static func harnessTitle(_ id: String, names: [String: String], voiceDefaultID: String? = nil) -> String {
        if id.isEmpty {
            guard let voice = voiceDefaultID, !voice.isEmpty else { return "Voice default" }
            return "Voice default (\(names[voice] ?? voice))"
        }
        return names[id] ?? "A harness"
    }

    func chooseChat(_ sessionID: String) async { await save { $0.sessionID = sessionID } }

    func chooseHarness(_ harnessID: String) async { await save { $0.harnessID = harnessID } }

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

/// Pick the Pod's harness: "Voice default" (whatever Voice uses), or any harness —
/// Single answers with the chat's own model.
struct PodHarnessPicker: View {
    let choice: PodVoiceChoice
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GlassGroup {
                    GlassRow(symbol: "waveform", title: choice.voiceDefaultTitle,
                             subtitle: "The harness Voice uses (Settings → Default, Harnesses)",
                             subtitleLineLimit: 2, last: true,
                             action: { pick("") }) {
                        VoicePickerCheck(on: choice.voice.harnessID.isEmpty)
                    }
                }
                if choice.loaded || !choice.harnesses.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        GlassQuietLabel("Harnesses").padding(.top, 16)
                        GlassGroup {
                            ForEach(Array(choice.harnesses.enumerated()), id: \.element.id) { index, harness in
                                GlassRow(symbol: "point.3.connected.trianglepath.dotted",
                                         title: [harness.icon, harness.name].compactMap { $0 }
                                             .filter { !$0.isEmpty }.joined(separator: " "),
                                         subtitle: harness.id == "single" ? "Answers with the chat's own model" : nil,
                                         last: index == choice.harnesses.count - 1,
                                         action: { pick(harness.id) }) {
                                    VoicePickerCheck(on: harness.id == choice.voice.harnessID)
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
        .jcScreen("Pod harness")
        .task { await choice.load() }
    }

    private func pick(_ harnessID: String) {
        Task {
            await choice.chooseHarness(harnessID)
            if choice.error == nil { dismiss() }
        }
    }
}
