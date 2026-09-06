import Foundation

/// How the Chat screen is reached from OUTSIDE itself: Siri's "Ask JARVIS", a
/// `jarviscopilot://chat?session=` link, and the on-device lane it has to be
/// built with.
///
/// These live on the store rather than inside `ChatPage`'s `.task` so they can be
/// asserted without rendering — a SwiftUI `.task` does not run under a test's
/// layout pass, and this is exactly the wiring that silently rots.
extension ChatStore {

    /// The store the app ships.
    ///
    /// `onDevice:` is the whole local-first lane: without it every turn goes to
    /// the server regardless of what the on-device AI settings say.
    static func production(api: JarvisAPI = .shared) -> ChatStore {
        ChatStore(api: api, onDevice: OnDeviceAI.shared.chatHandler)
    }

    /// Whether a local-first handler is attached at all.
    var usesOnDeviceLane: Bool { onDevice != nil }

    /// Take over "Ask JARVIS" for this thread.
    ///
    /// `AppServices` installs a fallback sender at launch that posts through a
    /// private `ChatStore`, so the turn is persisted server-side but appears
    /// nowhere the user can see it. Once the screen exists it owns the bus, and
    /// drains anything the bus latched before that (a cold launch runs the intent
    /// before any page is mounted).
    func adoptChatLaunch(_ bus: ChatLaunchBus) async {
        bus.send = { [weak self] prompt in await self?.send(prompt) }
        if let pending = bus.consume() { await send(pending) }
    }

    /// Open whatever `jarviscopilot://chat?session=<id>` asked for. A latch, so
    /// it is taken exactly once; nothing pending is the common case and a no-op.
    func openDeepLinkTarget(_ targets: DeepLinkTargets) async {
        guard let id = targets.consumeChat() else { return }
        guard id != sessionID else { return }   // already looking at it
        await openSession(id)
    }
}
