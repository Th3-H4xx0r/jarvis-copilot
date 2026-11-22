import Foundation

/// The on-glasses "Hey Jarvis" wake channel (plan §6.3 — the top priority).
///
/// Thin installer, modelled on `Glasses/Features/InmoAIChannel.swift`. The turn lifecycle itself
/// lives in `MetaGlassesSession` (wake → `VoiceStore` external turn → reply → close); this type
/// just brings the session up and arms the wake word. RUNTIME-INERT: `install(on:)` is never
/// called in production, so no session starts and no audio is claimed. Music stays on A2DP — the
/// voice audio rides L2CAP, never HFP (plan §6.3).
@MainActor
final class MetaWakeChannel {
    static let shared = MetaWakeChannel()
    private(set) var enabled = false

    private init() {}

    /// Bring the glasses session up and arm "Hey Jarvis". Never called during scaffolding.
    /// TODO(plan §6.3): enrol the custom wake word (3× 16 kHz samples) on the owned L2CAP session;
    /// the firmware builds the model and fires `GlassesInboundEvent.wake`, which
    /// `MetaGlassesSession` turns into a realtime `VoiceStore` turn with a glasses-only input.
    func install(on device: MetaGlassesDevice) async throws {
        try await device.session.start()
        enabled = true
    }

    /// Stop the session and disarm. Never called during scaffolding.
    func uninstall(from device: MetaGlassesDevice) async {
        await device.session.stop()
        enabled = false
    }
}
