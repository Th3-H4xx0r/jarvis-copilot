import Foundation

/// Phone-owned sequence; never retry the final tap because it toggles playback.
@MainActor
final class InmoMusicResume {
    private(set) var isRunning = false
    func run(dismissChat: () async throws -> Void,
             send: (Data) async throws -> Void,
             sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
             now: () -> Date = Date.init) async throws -> Bool {
        guard !isRunning else { throw InmoProtocolError.unavailable("Music resume is already running") }
        isRunning = true
        defer { isRunning = false }
        try Task.checkCancellation()
        try await dismissChat()
        try await sleep(0.3) // Let the module close before GO is interpreted.

        func gesture(_ events: [(bytes: Data, offsetMillis: UInt64)]) async throws {
            let start = now()
            do {
                for event in events {
                    try Task.checkCancellation()
                    let wait = Double(event.offsetMillis) / 1000 - now().timeIntervalSince(start)
                    if wait > 0 { try await sleep(wait) }
                    try Task.checkCancellation()
                    try await send(event.bytes)
                }
            } catch {
                // Release a possibly held key, without retrying a toggle gesture.
                if let release = events.last { try? await send(release.bytes) }
                throw error
            }
        }
        let goStart = UInt64((now().timeIntervalSince1970 * 1000).rounded())
        try await gesture(InmoCommand.goDoublePress(startMillis: goStart))
        try await sleep(0.5) // Double-click recognition and screen-off transition.
        try Task.checkCancellation()
        // Always send the requested tap. isOtherAudioPlaying can remain true
        // while Spotify is paused; it is not a reliable reason to skip this step.
        let tapStart = UInt64((now().timeIntervalSince1970 * 1000).rounded())
        try await gesture([(InmoCommand.sidePadKey(pressed: true, atMillis: tapStart), 0),
                           (InmoCommand.sidePadKey(pressed: false, atMillis: tapStart + 30), 30)])
        return true
    }
}
