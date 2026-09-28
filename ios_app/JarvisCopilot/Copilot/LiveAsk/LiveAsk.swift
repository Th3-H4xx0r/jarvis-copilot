import SwiftUI
import Observation

/// Ask Jarvis about the conversation Live is recording. A question typed on the
/// Live screen goes to Jarvis (through the app's own chat with the server) with
/// the recent transcript — who said what — and the question and Jarvis's reply
/// show on the Live screen as their own bubbles.
@MainActor
@Observable
final class LiveAsk {
    static let shared = LiveAsk()

    struct Exchange: Identifiable, Equatable {
        let id = UUID()
        var question: String
        /// Jarvis's turn as the chat streams it: text, tool calls, reasoning.
        var reply: ChatMessage?
        var pending = true
        var error: String?
    }

    private(set) var exchanges: [Exchange] = []
    /// Transcript characters sent with a question (newest kept).
    static let transcriptBudget = 8000

    func ask(_ question: String, store: LiveStore) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let exchange = Exchange(question: text)
        exchanges.append(exchange)
        let prompt = Self.prompt(question: text, segments: store.transcript.segments)
        let key = "liveAsk." + (store.liveSessionID.isEmpty ? "default" : store.liveSessionID)
        Task { [weak self] in
            do {
                let chat = BoardChat()
                let session = try await chat.sessionID(for: key, title: "Live · questions")
                let turn = try await chat.run(sessionID: session, message: prompt, joinRunningTurn: true) { state in
                    self?.update(exchange.id, reply: state.message, pending: true)
                }
                self?.update(exchange.id, reply: turn.message, pending: false)
            } catch {
                self?.update(exchange.id, reply: nil, pending: false,
                             error: "Couldn't ask Jarvis: \(error.localizedDescription)")
            }
        }
    }

    func clear() { exchanges.removeAll() }

    private func update(_ id: UUID, reply: ChatMessage?, pending: Bool, error: String? = nil) {
        guard let i = exchanges.firstIndex(where: { $0.id == id }) else { return }
        if let reply { exchanges[i].reply = reply }
        exchanges[i].pending = pending
        exchanges[i].error = error
    }

    static func prompt(question: String, segments: [LiveSegment]) -> String {
        var lines: [String] = []
        var total = 0
        for segment in segments.reversed() {
            let name = LiveFormat.speakerLabel(id: segment.speakerID, name: segment.speakerName)
            var line = "\(name): \(segment.text)"
            if let translation = segment.translation, !translation.isEmpty { line += " [\(translation)]" }
            total += line.count
            if total > transcriptBudget { break }
            lines.insert(line, at: 0)
        }
        return """
        I'm in a live conversation that Jarvis is transcribing. Answer my question about it, using the \
        transcript below; keep it short unless I ask for more.

        Transcript so far (oldest first):
        \(lines.isEmpty ? "(nothing transcribed yet)" : lines.joined(separator: "\n"))

        My question: \(question)
        """
    }
}

/// The Ask button, the text box, and the question/answer bubbles on the Live screen.
struct LiveAskPanel: View {
    let store: LiveStore
    private let ask = LiveAsk.shared
    @State private var open = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !ask.exchanges.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(ask.exchanges.suffix(8)) { exchange in bubbles(exchange).id(exchange.id) }
                        }
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: ask.exchanges) { _, list in
                        if let last = list.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }
            if open {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Ask Jarvis about this conversation…", text: $draft, axis: .vertical)
                        .focused($focused)
                        .lineLimit(1...4)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(JcTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Button(action: send) {
                        JcIcon("arrow.up.circle.fill", size: 30).foregroundStyle(JcTheme.accent)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button { open = false; focused = false } label: {
                        JcIcon("xmark", size: 16).foregroundStyle(JcTheme.muted).padding(8)
                    }
                }
            } else {
                HStack {
                    if !ask.exchanges.isEmpty {
                        Button("Clear", jcIcon: "trash") { ask.clear() }
                            .buttonStyle(.jcGlass(tint: JcTheme.muted, compact: true))
                    }
                    Spacer()
                    Button {
                        open = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
                    } label: {
                        Label("Ask about this", jcIcon: "bubble.left.and.text.bubble.right")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.jcGlass(compact: true))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        ask.ask(text, store: store)
    }

    /// One card: what you asked on top, a divider, and Jarvis's reply below —
    /// drawn by the chat screen's own assistant card (streaming text, tool calls).
    @ViewBuilder private func bubbles(_ exchange: LiveAsk.Exchange) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                JcIcon("person.fill", size: 13).foregroundStyle(JcTheme.accent).padding(.top, 2)
                Text(exchange.question).font(.subheadline.weight(.medium)).foregroundStyle(JcTheme.text)
                Spacer(minLength: 0)
            }
            .padding(12)
            Divider().overlay(JcTheme.accent.opacity(0.35))
            Group {
                if let error = exchange.error {
                    Text(error).font(.subheadline).foregroundStyle(.red)
                } else if let reply = exchange.reply, !(reply.plainText.isEmpty && reply.tools.isEmpty) {
                    ChatAssistantTurnCard(message: reply)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Jarvis is thinking…").font(.caption).foregroundStyle(JcTheme.muted)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(JcTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(JcTheme.accent.opacity(0.35), lineWidth: 1))
    }
}