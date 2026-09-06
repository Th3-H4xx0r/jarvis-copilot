import SwiftUI

/// "Program with Jarvis": a chat with the Jarvis agent scoped to one board. The agent
/// writes a Lua script and installs it through the `esp32_upload_script` device skill —
/// from the phone's bridge, or straight over the board's own link when it has one.
/// Below the chat is the board's console: print() lines, errors and relayed `jarvis.*`
/// calls.
struct Esp32ChatView: View {
    @ObservedObject var manager: Esp32Manager
    let board: DiscoveredEsp32

    @StateObject private var bridge = BridgeClient.shared
    /// Conversation state outlives this screen, so a reply keeps streaming while the
    /// user is elsewhere and reopening the screen just shows where things stand.
    @ObservedObject private var chat: Esp32ChatStore
    @State private var draft = ""
    /// Bumped on every send: a multi-line TextField keeps stale text on screen when the
    /// binding is cleared while it's focused, so the field is recreated instead.
    @State private var composerGeneration = 0
    @State private var showConsole = false
    @State private var models: [JarvisChatClient.Model] = []
    @State private var defaultModel = ""
    @State private var selectedModelID = ""
    @FocusState private var focused: Bool

    typealias ChatMessage = Esp32ChatStore.ChatMessage

    init(manager: Esp32Manager, board: DiscoveredEsp32) {
        self.manager = manager
        self.board = board
        let id = manager.info?.deviceID ?? board.record?.deviceID ?? board.id
        _chat = ObservedObject(wrappedValue: Esp32ChatStore.store(for: id))
    }

    private var deviceID: String { chat.deviceID }
    private var messages: [ChatMessage] { chat.messages }
    private var sending: Bool { chat.sending }
    private var error: String? { chat.error }
    private var modelKey: String { "esp32ChatModel.\(deviceID)" }
    private var boardOnOwnLink: Bool { manager.cloud?.cloudMode == true && manager.cloud?.state == .connected }
    private var shared: Bool { boardOnOwnLink || (BridgeClient.isExposed(deviceID) && bridge.enabled) }
    private var selectedModel: JarvisChatClient.Model? { models.first { $0.id == selectedModelID } }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty && !sending && bridge.isPaired }
    /// A muted slate blue: reads as "mine" without shouting, and sits well on the dark
    /// card material the replies use.
    private let userTint = Color(red: 0.33, green: 0.40, blue: 0.54)

    var body: some View {
        VStack(spacing: 0) {
            if !bridge.isPaired {
                banner("Pair with Jarvis Copilot in Settings first.", icon: "link.badge.plus")
            } else if !shared {
                banner("Turn on Bridge mode and \"Share with Jarvis\" for this board so Jarvis can install scripts.", icon: "exclamationmark.triangle.fill")
            }
            transcript
            console
            composer
        }
        .background(Color.black.opacity(0.001))  // makes the whole area tappable for keyboard dismissal
        .navigationTitle(board.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) { titleView }
            ToolbarItem(placement: .topBarTrailing) { modelMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showConsole.toggle() } label: {
                        Label(showConsole ? "Hide console" : "Show console", systemImage: "terminal")
                    }
                    Button { manager.clearScriptLog() } label: { Label("Clear console", systemImage: "eraser") }
                    Divider()
                    Button(role: .destructive) {
                        chat.newConversation()
                    } label: { Label("New conversation", systemImage: "square.and.pencil") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear {
            selectedModelID = UserDefaults.standard.string(forKey: modelKey) ?? ""
            Task { await loadModels() }
        }
        .onChange(of: selectedModelID) { _, id in UserDefaults.standard.set(id, forKey: modelKey) }
        .onChange(of: chat.restoreDraft) { _, text in
            if let text { draft = text; chat.restoreDraft = nil }
        }
    }

    // MARK: Chrome

    private var titleView: some View {
        VStack(spacing: 1) {
            Text("Program with Jarvis").font(.headline)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        if boardOnOwnLink { return "\(board.name) · direct link" }
        if let link = manager.activeLink { return "\(board.name) · via \(link.label)" }
        return board.name
    }

    private var modelMenu: some View {
        Menu {
            if models.isEmpty {
                Text("Loading models…")
            } else {
                Button {
                    selectedModelID = ""
                } label: {
                    Label("Default" + (defaultModel.isEmpty ? "" : " (\(shortName(defaultModel)))"),
                          systemImage: selectedModelID.isEmpty ? "checkmark" : "")
                }
                ForEach(Dictionary(grouping: models, by: \.provider).keys.sorted(), id: \.self) { provider in
                    Section(provider.isEmpty ? "Models" : provider) {
                        ForEach(models.filter { $0.provider == provider }) { m in
                            Button {
                                selectedModelID = m.id
                            } label: {
                                Label(m.label, systemImage: selectedModelID == m.id ? "checkmark" : "")
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(selectedModel.map { shortName($0.label) } ?? "Auto")
                    .font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
    }

    private func shortName(_ s: String) -> String {
        let trimmed = s.split(separator: "/").last.map(String.init) ?? s
        return trimmed.count > 18 ? String(trimmed.prefix(17)) + "…" : trimmed
    }

    private func banner(_ text: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(text).font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if messages.isEmpty { intro }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, m in
                        // Consecutive messages from the same side stay close; a change of
                        // speaker gets clear air.
                        let previous = index > 0 ? messages[index - 1] : nil
                        bubble(m)
                            .id(m.id)
                            .padding(.top, previous == nil ? 0 : (previous?.role == m.role ? 6 : 26))
                    }
                    if let error {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                        .padding(.horizontal, 16)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { focused = false }
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: messages) { _, _ in withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: focused) { _, f in if f { withAnimation { proxy.scrollTo("bottom") } } }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.title3).foregroundStyle(Color.accentColor)
                Text("Tell Jarvis what this board should do.").font(.headline)
            }
            Text("Jarvis writes a small script, installs it on the board, and it keeps running there — with or without the phone.")
                .font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                suggestion("Blink the onboard LED twice every 5 seconds.")
                suggestion("Act as a door sensor: reed switch on GPIO 4 to ground. Notify me when it opens.")
                suggestion("Read the button on GPIO 27 and toggle GPIO 16 each press.")
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            draft = text
            focused = true
        } label: {
            HStack {
                Text(text).font(.footnote).multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.left").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func bubble(_ m: ChatMessage) -> some View {
        if m.role == .user {
            HStack(alignment: .bottom) {
                Spacer(minLength: 48)
                Text(m.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(userTint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.18)).frame(width: 26, height: 26)
                    Image(systemName: "sparkles").font(.caption).foregroundStyle(Color.accentColor)
                }
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    if !m.tools.isEmpty { toolList(m.tools) }
                    if m.text.isEmpty {
                        HStack(spacing: 8) {
                            ThinkingDots()
                            if m.reasoning {
                                Text("Thinking…").font(.footnote).foregroundStyle(.secondary)
                            } else if let last = m.tools.last, !last.done {
                                Text("Running \(last.name)…").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    } else {
                        Text(rendered(m.text))
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
            if let st = m.stats, st.totalMs != nil {
                statsLine(st).padding(.leading, 52).padding(.top, 4)
            }
          }
        }
    }

    /// Small, grey, out of the way: tokens in and out, time to first text, total time,
    /// generation speed when the server reports it.
    private func statsLine(_ st: Esp32ChatStore.Stats) -> some View {
        var parts: [String] = []
        if st.tokensIn > 0 || st.tokensOut > 0 {
            parts.append("\(st.estimated ? "~" : "")\(compact(st.tokensIn)) in · \(compact(st.tokensOut)) out")
        }
        if let t = st.totalMs { parts.append(seconds(t)) }
        return Text(parts.joined(separator: "  ·  "))
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
    }

    private func compact(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    private func seconds(_ ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }

    /// Tool calls the agent made for this reply, live: a spinner while one runs, a check
    /// when it finished, and its arguments or result in one line.
    private func toolList(_ tools: [Esp32ChatStore.ToolCall]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(tools) { t in
                HStack(alignment: .top, spacing: 8) {
                    if t.done {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).font(.footnote)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.name.replacingOccurrences(of: "device_", with: ""))
                            .font(.system(.footnote, design: .monospaced).weight(.medium))
                        let detail = t.done && !t.snippet.isEmpty ? t.snippet : t.preview
                        if !detail.isEmpty {
                            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }

    /// Inline markdown (bold, code, links) the way the web UI shows it; code blocks
    /// stay verbatim in a monospaced run.
    private func rendered(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if var a = try? AttributedString(markdown: text, options: options) {
            for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
                a[run.range].font = .system(.body, design: .monospaced)
            }
            return a
        }
        return AttributedString(text)
    }

    // MARK: Console

    @ViewBuilder private var console: some View {
        if showConsole {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Board console", systemImage: "terminal").font(.footnote.weight(.semibold))
                    if let s = manager.script {
                        Text("· \(s.name.isEmpty ? s.state.label : "\(s.name) · \(s.state.label)")")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = manager.scriptLog.joined(separator: "\n")
                    } label: {
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                    .disabled(manager.scriptLog.isEmpty)
                    .padding(.trailing, 6)
                    Button { withAnimation { showConsole = false } } label: {
                        Image(systemName: "chevron.down").font(.caption)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            if manager.scriptLog.isEmpty { Text("No output yet.").foregroundStyle(.tertiary) }
                            ForEach(Array(manager.scriptLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .foregroundStyle(line.hasPrefix("error") ? .red : line.hasPrefix("→") || line.hasPrefix("←") || line.hasPrefix("—") ? .secondary : .primary)
                                    .textSelection(.enabled)
                                    .contextMenu {
                                        Button { UIPasteboard.general.string = line } label: { Label("Copy line", systemImage: "doc.on.doc") }
                                        Button { UIPasteboard.general.string = manager.scriptLog.joined(separator: "\n") } label: { Label("Copy all", systemImage: "doc.on.doc.fill") }
                                    }
                            }
                            Color.clear.frame(height: 1).id("logEnd")
                        }
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                    }
                    .frame(height: 130)
                    .onChange(of: manager.scriptLog.count) { _, _ in proxy.scrollTo("logEnd") }
                }
            }
            .background(Color.black.opacity(0.28))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .id(composerGeneration)
                .lineLimit(1...6)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit { if canSend { send() } }
                .padding(.leading, 6)
                .padding(.vertical, 8)
            Button {
                if sending { cancel() } else { send() }
            } label: {
                Image(systemName: sending ? "stop.fill" : "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(sending ? Color.white.opacity(0.14) : (canSend ? userTint : Color.white.opacity(0.14)), in: Circle())
            }
            .disabled(!sending && !canSend)
            .animation(.smooth(duration: 0.2), value: sending)
            .animation(.smooth(duration: 0.2), value: canSend)
            .padding(.bottom, 4)
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 4)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
    }

    // MARK: Chat

    /// Every turn is prefixed with the board's identity so the agent picks the right
    /// device and skill; the server has no per-session system prompt to hold it.
    private func context() -> String {
        var pins = manager.pins.map { p -> String in
            var caps: [String] = []
            if p.capabilities.contains(.output) { caps.append("out") } else { caps.append("input-only") }
            if p.capabilities.contains(.pwm) { caps.append("pwm") }
            if p.capabilities.contains(.strapping) { caps.append("strapping") }
            if p.capabilities.contains(.led) { caps.append("onboard LED") }
            return "\(p.gpio)(\(caps.joined(separator: ",")))"
        }.joined(separator: " ")
        if pins.isEmpty { pins = "unknown — call esp32_get_state" }
        let script = manager.script.map { "\($0.name.isEmpty ? "-" : $0.name) [\($0.state.label.lowercased())]" } ?? "unknown"
        let recent = manager.scriptLog.suffix(8).map { String($0.prefix(160)) }
        let console = recent.isEmpty ? "" : " Recent board console: " + recent.map { "«\($0)»" }.joined(separator: " ") + ". Full log via esp32_script_status."
        let route = boardOnOwnLink
            ? "The board is paired with you directly (device named \"\(Esp32Protocol.namePrefix) board\"); use its own esp32_* skills."
            : "Its skills are advertised by the JarvisCopilot phone app, device_id \(deviceID)."
        return """
        [JarvisCopilot board programming. Board: "\(board.name)", model Jarvis ESP32 DevKit V1. \(route) \
        Use the `jarvis-esp32` skill. To program it, write Lua and call `esp32_upload_script` \
        (args: source, name, autostart). Start the source with `--` comment lines describing what it does and the wiring. \
        Pins: \(pins). Current script: \(script).\(console) Keep replies short; say what you installed and how to test it.]
        """
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        draft = ""
        composerGeneration += 1
        focused = true
        chat.send(text, context: context(), title: "ESP32 \(board.name)", model: selectedModel) {
            try? await manager.refreshScript()
        }
    }

    private func cancel() { chat.cancel() }

    private func loadModels() async {
        guard bridge.isPaired else { return }
        if let result = try? await JarvisChatClient.shared.models() {
            defaultModel = result.defaultModel
            models = result.models
        }
    }

}

/// Three dots rising in sequence — the "thinking" indicator.
struct ThinkingDots: View {
    var size: CGFloat = 7
    @State private var phase = false

    var body: some View {
        HStack(spacing: size * 0.7) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: size, height: size)
                    .offset(y: phase ? -size * 0.6 : size * 0.3)
                    .opacity(phase ? 1 : 0.45)
                    .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.16), value: phase)
            }
        }
        .onAppear { phase = true }
    }
}


/// One conversation per board, kept for the app's lifetime so navigation never
/// interrupts a reply. Persists the transcript per board.
@MainActor
final class Esp32ChatStore: ObservableObject {
    struct ToolCall: Codable, Identifiable, Equatable {
        var id: String
        var name: String
        var preview: String
        var done: Bool
        var snippet: String
    }

    struct ChatMessage: Codable, Identifiable, Equatable {
        enum Role: String, Codable { case user, assistant }
        var id = UUID()
        let role: Role
        var text: String
        var date = Date()
        var tools: [ToolCall] = []
        /// True while the model is reasoning and no text has arrived yet.
        var reasoning: Bool = false
        var stats: Stats? = nil
    }

    struct Stats: Codable, Equatable {
        var tokensIn: Int = 0
        var tokensOut: Int = 0
        var estimated: Bool = false
        var tokensPerSecond: Double? = nil
        /// Milliseconds from send to first visible text, and to the end of the turn.
        var firstTokenMs: Int? = nil
        var totalMs: Int? = nil
    }

    private static var stores: [String: Esp32ChatStore] = [:]
    static func store(for deviceID: String) -> Esp32ChatStore {
        if let s = stores[deviceID] { return s }
        let s = Esp32ChatStore(deviceID: deviceID)
        stores[deviceID] = s
        return s
    }

    let deviceID: String
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var sending = false
    @Published private(set) var error: String?
    /// Text of a message that could not be sent, for the composer to restore.
    @Published var restoreDraft: String?
    private var task: Task<Void, Never>?
    private var historyKey: String { "esp32Chat.\(deviceID)" }

    private init(deviceID: String) {
        self.deviceID = deviceID
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            // A reply that was mid-stream when the app died can't be resumed.
            messages = saved.map { m in
                var m = m
                if m.role == .assistant && m.text.isEmpty { m.text = "(interrupted)" }
                m.reasoning = false
                for i in m.tools.indices { m.tools[i].done = true }
                return m
            }
        }
    }

    func send(_ text: String, context: String, title: String, model: JarvisChatClient.Model?,
              onFinished: @escaping () async -> Void) {
        guard !sending else { return }
        error = nil
        sending = true
        messages.append(ChatMessage(role: .user, text: text))
        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)
        save()
        let startedAt = Date()
        task = Task { [weak self] in
            guard let self else { return }
            let apply: (JarvisChatClient.StreamEvent) -> Void = { [weak self] event in
                guard let self, let i = self.messages.firstIndex(where: { $0.id == reply.id }) else { return }
                if self.messages[i].stats == nil { self.messages[i].stats = Stats() }
                switch event {
                case .usage(let tin, let tout, let tps, let estimated):
                    self.messages[i].stats?.tokensIn = tin
                    self.messages[i].stats?.tokensOut = tout
                    self.messages[i].stats?.tokensPerSecond = tps
                    self.messages[i].stats?.estimated = estimated
                case .token(let t):
                    if self.messages[i].text.isEmpty, self.messages[i].stats?.firstTokenMs == nil {
                        self.messages[i].stats?.firstTokenMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    }
                    self.messages[i].text += t
                    self.messages[i].reasoning = false
                case .reasoning:
                    if self.messages[i].text.isEmpty { self.messages[i].reasoning = true }
                case .toolStarted(let id, let name, let preview):
                    self.messages[i].reasoning = false
                    if !self.messages[i].tools.contains(where: { $0.id == id }) {
                        self.messages[i].tools.append(ToolCall(id: id, name: name, preview: preview, done: false, snippet: ""))
                    }
                case .toolFinished(let id, let name, let snippet):
                    if let t = self.messages[i].tools.lastIndex(where: { !$0.done && ($0.id == id || $0.name == name) }) {
                        self.messages[i].tools[t].done = true
                        self.messages[i].tools[t].snippet = snippet
                    }
                }
            }
            do {
                let chat = JarvisChatClient.shared
                let sid = try await chat.sessionID(for: deviceID, title: title)
                var full = ""
                var attempts = 0
                var sent = false
                while true {
                    do {
                        if !sent {
                            full = try await chat.send(sessionID: sid, message: context + "\n\n" + text, model: model, onEvent: apply)
                            sent = true
                        }
                        break
                    } catch JarvisChatClient.ChatError.busy where !sent {
                        // A turn is already running on this session (maybe our own, if the
                        // phone's stream broke): ride along with it instead of failing.
                        let snap = try await chat.snapshot(sessionID: sid)
                        guard let stream = snap.activeStreamID else { throw JarvisChatClient.ChatError.busy }
                        sent = true
                        full = try await chat.attach(streamID: stream, onEvent: apply)
                        break
                    } catch JarvisChatClient.ChatError.stalled {
                        attempts += 1
                        guard attempts <= 12 else { throw JarvisChatClient.ChatError.stalled }  // ~10 min
                        let snap = try await chat.snapshot(sessionID: sid)
                        if let stream = snap.activeStreamID {
                            do { full = try await chat.attach(streamID: stream, onEvent: apply); break }
                            catch JarvisChatClient.ChatError.stalled { continue }
                        }
                        // The turn finished while we weren't listening: take its text.
                        full = snap.lastAssistantText ?? ""
                        break
                    }
                }
                // Whatever we streamed, the server's record is authoritative.
                if let i = messages.firstIndex(where: { $0.id == reply.id }) {
                    if messages[i].text.isEmpty {
                        if full.isEmpty, let snap = try? await chat.snapshot(sessionID: sid), let t = snap.lastAssistantText {
                            full = t
                        }
                        messages[i].text = full.isEmpty ? (messages[i].tools.isEmpty ? "(no reply)" : "Done.") : full
                    }
                    messages[i].reasoning = false
                    for t in messages[i].tools.indices { messages[i].tools[t].done = true }
                    if messages[i].stats == nil { messages[i].stats = Stats() }
                    messages[i].stats?.totalMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                }
                await onFinished()
            } catch is CancellationError {
                if let i = messages.firstIndex(where: { $0.id == reply.id }), messages[i].text.isEmpty {
                    messages[i].text = "(stopped)"
                }
            } catch {
                self.error = error.localizedDescription
                // Nothing was said: take the user bubble back so a retry doesn't duplicate it.
                if let i = messages.firstIndex(where: { $0.id == reply.id }), messages[i].text.isEmpty, messages[i].tools.isEmpty {
                    messages.remove(at: i)
                    if let u = messages.lastIndex(where: { $0.role == .user && $0.text == text }) {
                        messages.remove(at: u)
                        restoreDraft = text
                    }
                }
            }
            sending = false
            task = nil
            save()
        }
    }

    func cancel() { task?.cancel() }

    func newConversation() {
        cancel()
        messages.removeAll()
        error = nil
        save()
        JarvisChatClient.shared.forgetSession(for: deviceID)
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(messages.suffix(60)), forKey: historyKey)
    }
}
