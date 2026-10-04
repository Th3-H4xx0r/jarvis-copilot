import AVFAudio

/// The car's voice is the Voice tab itself (no pop-up voice screen): its header shows
/// the orb, what Jarvis is doing and the conversation, with Talk / Mute / Stop.
@MainActor
enum CarPlayVoiceState {
    /// The car can't answer a permission prompt, so only a mic already granted counts.
    static func micAllowed(_ permission: AVAudioApplication.recordPermission) -> Bool { permission == .granted }
}
