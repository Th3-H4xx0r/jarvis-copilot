import Foundation
import SpotifyiOS

/// Plays a song in the Spotify app on this iPhone through Spotify's iOS SDK (App Remote).
///
/// In the car, plays sent through Spotify's Web API are taken (HTTP 204) and never start —
/// Spotify reports "nothing playing anywhere" (2026-10-18 16:56, 17:03, 17:44). So once the
/// server has opened Spotify on the car's screen, it hands the phone the song and its own
/// Spotify token (which carries `app-remote-control`), and the phone tells the Spotify app
/// itself. Server use only: the `spotify_remote_play` skill is never a model tool.
@MainActor
final class SpotifyRemote: NSObject {
    static let shared = SpotifyRemote()
    static let skillName = "spotify_remote_play"
    /// Registered for Jarvis's Spotify app (iOS bundle id + this redirect) on developer.spotify.com.
    static let redirectURL = URL(string: "jarviscopilot://spotify-callback")!

    enum Failure: LocalizedError {
        case connect(String)
        case timedOut
        case play(String)

        var errorDescription: String? {
            switch self {
            case .connect(let why): return "couldn't reach the Spotify app: \(why)"
            case .timedOut: return "the Spotify app didn't answer"
            case .play(let why): return "Spotify wouldn't play it: \(why)"
            }
        }
    }

    private var remote: SPTAppRemote?
    private var remoteClientID: String?
    private var connecting: CheckedContinuation<Void, Error>?

    /// Connects (if needed) and plays `uri`.
    func play(uri: String, token: String, clientID: String, timeout: Duration = .seconds(8)) async throws {
        let remote = self.remote(clientID: clientID)
        remote.connectionParameters.accessToken = token
        if !remote.isConnected {
            try await connect(remote, timeout: timeout)
        }
        guard let player = remote.playerAPI else { throw Failure.connect("no player") }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            player.play(uri) { _, error in
                if let error { done.resume(throwing: Failure.play(error.localizedDescription)) } else { done.resume() }
            }
        }
    }

    private func remote(clientID: String) -> SPTAppRemote {
        if let remote, remoteClientID == clientID { return remote }
        remote?.disconnect()
        let made = SPTAppRemote(configuration: SPTConfiguration(clientID: clientID, redirectURL: Self.redirectURL),
                                logLevel: .error)
        made.delegate = self
        remote = made
        remoteClientID = clientID
        return made
    }

    private func connect(_ remote: SPTAppRemote, timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { (connected: CheckedContinuation<Void, Error>) in
            connecting?.resume(throwing: Failure.connect("superseded"))
            connecting = connected
            remote.connect()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishConnecting(Failure.timedOut)
            }
        }
    }

    private func finishConnecting(_ error: Error?) {
        guard let waiting = connecting else { return }
        connecting = nil
        if let error { waiting.resume(throwing: error) } else { waiting.resume() }
    }

    // MARK: The skill

    static func skill() -> AnySkill {
        AnySkill(
            name: skillName,
            description: "Play a Spotify URI in the Spotify app on this phone. Server use only.",
            inputSchema: SkillSchema.object([
                "uri": SkillSchema.string(),
                "token": SkillSchema.string(),
                "client_id": SkillSchema.string(),
            ], required: ["uri", "token", "client_id"])
        ) { args in
            let uri = SkillArgs.string(args, "uri")
            let token = SkillArgs.string(args, "token")
            let clientID = SkillArgs.string(args, "client_id")
            guard uri.hasPrefix("spotify:"), !token.isEmpty, !clientID.isEmpty else {
                throw SkillError.badArgument("uri (spotify:…), token and client_id required")
            }
            try await SpotifyRemote.shared.play(uri: uri, token: token, clientID: clientID)
            return ["played": uri]
        }
    }
}

extension SpotifyRemote: SPTAppRemoteDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in self.finishConnecting(nil) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        let why = error?.localizedDescription ?? "unknown"
        Task { @MainActor in self.finishConnecting(Failure.connect(why)) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        let why = error?.localizedDescription ?? "disconnected"
        Task { @MainActor in self.finishConnecting(Failure.connect(why)) }
    }
}
