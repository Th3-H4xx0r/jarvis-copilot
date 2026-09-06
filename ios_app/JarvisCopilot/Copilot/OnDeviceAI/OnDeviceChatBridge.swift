import Foundation

/// ``OnDeviceChatHandler`` on top of ``LocalRouter`` + an on-device engine, so a
/// chat turn can be answered without the server.
///
/// `ChatStore` calls `answer(_:emit:)` first for every text-only turn; returning
/// `.escalate` falls straight through to the normal server stream, which is what
/// makes this safe to wire in unconditionally — with the tier off, or with no
/// engine, every turn escalates exactly as before.
///
/// Port of the chat half of `voice_controller._tryLocalTurn` / the Flutter chat
/// controller's local lane.
@MainActor
final class OnDeviceChatBridge: OnDeviceChatHandler {

    /// Streams the model's full reply for one turn.
    typealias Streaming = @MainActor (String) -> AsyncThrowingStream<String, Error>
    /// Runs one client-dispatchable tool.
    typealias ToolRunning = @MainActor (String, [String: Any]) async -> InvokeRunner.Outcome

    private let router: LocalRouter
    private let settings: LocalAiSettings
    private let stream: Streaming
    private let runTool: ToolRunning

    init(router: LocalRouter,
         settings: LocalAiSettings,
         stream: @escaping Streaming,
         runTool: @escaping ToolRunning) {
        self.router = router
        self.settings = settings
        self.stream = stream
        self.runTool = runTool
    }

    func answer(_ text: String, emit: (String) -> Void) async -> OnDeviceReply {
        switch await router.handle(text, surface: .chat) {
        case .escalate:
            return .escalate

        case .toolCall(let plan):
            return await runLocalTool(plan, text: text, emit: emit)

        case .directAnswer:
            // Always stream the FULL reply: the router's inline answer field is a
            // short one, and a long answer would be truncated.
            return await streamAnswer(text, emit: emit)
        }
    }

    // MARK: - Lanes

    private func runLocalTool(_ plan: ToolCallPlan, text: String,
                              emit: (String) -> Void) async -> OnDeviceReply {
        // Outward/destructive actions defer to the server's approval flow, and
        // anything the server has to run obviously can't be done here.
        if plan.requiresConfirm && settings.confirmLocalActions { return .escalate }
        guard plan.execClass != .serverOnly else { return .escalate }

        let outcome = await runTool(plan.name, plan.args)
        // A tool that ran but achieved nothing (open_app with no URL scheme) is
        // NOT a success — escalate rather than claiming it happened.
        guard outcome.error == nil, !localToolMissed(plan.name, outcome) else { return .escalate }

        let say = plan.confirmation.flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.spokenConfirmation(plan.name, outcome.result)
        emit(say)
        return .answered(inputTokens: Self.estimateTokens(text),
                         outputTokens: Self.estimateTokens(say))
    }

    private func streamAnswer(_ text: String, emit: (String) -> Void) async -> OnDeviceReply {
        var produced = ""
        do {
            for try await chunk in stream(text) {
                produced += chunk
                emit(chunk)
            }
        } catch {
            // A mid-stream failure with nothing to show is a miss — let the
            // server answer it properly. Partial text is kept and counted.
            if produced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .escalate
            }
        }
        guard !produced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .escalate
        }
        return .answered(inputTokens: Self.estimateTokens(text),
                         outputTokens: Self.estimateTokens(produced))
    }

    // MARK: - Helpers

    /// What to say after a tool ran without its own confirmation line.
    static func spokenConfirmation(_ name: String, _ result: [String: Any]?) -> String {
        if let note = (result?["note"] ?? result?["message"]) as? String,
           !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return note
        }
        return "Done — \(name.replacingOccurrences(of: "_", with: " "))."
    }

    /// Apple's Foundation Models report no usage, so the counts `ChatStore` shows
    /// are estimates (~4 characters per token) rather than nothing at all.
    static func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}
