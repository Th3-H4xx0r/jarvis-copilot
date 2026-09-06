import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The platform and policy seams ``ChatStore`` depends on. Each is a small
/// protocol with a production implementation here and a fake in the tests, so the
/// store never touches UIKit or an on-device model directly.

/// Where per-message "copy" puts text.
protocol ChatClipboard: Sendable {
    func copy(_ text: String)
}

struct SystemChatClipboard: ChatClipboard {
    func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

/// What the on-device layer decided about a turn.
enum OnDeviceReply: Equatable, Sendable {
    /// Handled locally — the answer was streamed through `emit`. Apple's
    /// Foundation Models report no usage, so the counts may be estimates.
    case answered(inputTokens: Int?, outputTokens: Int?)
    /// A miss, an error, or a turn that needs the agent's tools: run it on the server.
    case escalate
}

/// The on-device answer path (`services/local_router.dart` + `on_device_ai.dart`
/// in the Flutter app). Nothing is wired to it yet, so every turn goes to the
/// server — but the hook, the "on-device" badge, the local-turn persistence and
/// the "Try on server" retry are all in place for when it lands.
///
/// `Copilot/Skills`' `LocalRouter.handle(_:surface:)` is the intended
/// implementation: its `.directAnswer` becomes ``OnDeviceReply/answered``, and
/// `.escalate` (plus any `.toolCall` needing confirmation) becomes
/// ``OnDeviceReply/escalate``.
@MainActor
protocol OnDeviceChatHandler {
    /// Stream tokens through `emit`; return `.escalate` to fall through to the server.
    func answer(_ text: String, emit: (String) -> Void) async -> OnDeviceReply
}
