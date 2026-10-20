import Foundation
import ObjectiveC
import SpotifyiOS
import UIKit

/// The Spotify app as App Remote sees it: Spotify's SDK in the app, a fake in tests.
@MainActor
protocol SpotifyAppConnection: AnyObject {
    var isConnected: Bool { get }
    func connect(token: String, timeout: Duration) async throws
    func play(_ uri: String) async throws
    /// The link Spotify's SDK opens to wake the Spotify app straight onto `uri`
    /// (`authorizeAndPlayURI`), or nil when it won't.
    func wakeLink(playing uri: String) async -> URL?
    func disconnect()
}

/// Plays a song in the Spotify app on this iPhone through Spotify's iOS SDK (App Remote).
///
/// In the car, plays sent through Spotify's Web API are taken (HTTP 204) and never start —
/// Spotify reports "nothing playing anywhere" (2026-10-18 16:56, 17:03, 17:44). So once the
/// server has opened Spotify on the car's screen, it hands the phone the song and its own
/// Spotify token (which carries `app-remote-control`), and the phone tells the Spotify app
/// itself. The Spotify app takes that connection only while it plays music (2026-10-20 23:18:
/// six "Connection attempt failed" with Spotify open on the car): then its SDK's wake link —
/// opened on the car's screen — starts the song. Server use only: the `spotify_remote_play`
/// skill is never a model tool.
@MainActor
final class SpotifyRemote {
    static let shared = SpotifyRemote()
    static let skillName = "spotify_remote_play"
    /// Registered for Jarvis's Spotify app (iOS bundle id + this redirect) on developer.spotify.com.
    static let redirectURL = URL(string: "jarviscopilot://spotify-callback")!

    enum Outcome: String {
        case played  // the connected Spotify app was told to play it
        case woke    // the Spotify app was woken straight onto it
    }

    enum Failure: LocalizedError {
        case connect(String)
        case timedOut
        case play(String)
        case wake

        var errorDescription: String? {
            switch self {
            case .connect(let why): return "couldn't reach the Spotify app: \(why)"
            case .timedOut: return "the Spotify app didn't answer"
            case .play(let why): return "Spotify wouldn't play it: \(why)"
            case .wake: return "couldn't open Spotify's wake link"
            }
        }
    }

    private let makeConnection: @MainActor (String) -> SpotifyAppConnection
    private let openWakeLink: @MainActor (URL) async -> Bool
    private var connection: SpotifyAppConnection?
    private var connectionClientID: String?

    init(makeConnection: @escaping @MainActor (String) -> SpotifyAppConnection = { SDKSpotifyConnection(clientID: $0) },
         openWakeLink: @escaping @MainActor (URL) async -> Bool = { await SpotifyWakeLink.open($0) }) {
        self.makeConnection = makeConnection
        self.openWakeLink = openWakeLink
    }

    /// Connects (if needed) and plays `uri` — or, when the Spotify app won't take a connection,
    /// wakes it straight onto `uri`. Every step goes in voice.log: 2026-10-20 23:34 the server
    /// heard nothing back for 15 s, twice, and nothing said where it stopped.
    func play(uri: String, token: String, clientID: String, timeout: Duration = .seconds(4)) async throws -> Outcome {
        let started = Date()
        func note(_ step: String) {
            VoiceLogFile.shared.append("[spotify] +\(Int(Date().timeIntervalSince(started) * 1000))ms \(step)")
        }
        note("play \(uri)")
        let app = connection(clientID: clientID)
        if !app.isConnected {
            do {
                try await app.connect(token: token, timeout: timeout)
                note("connected")
            } catch {
                note("connect failed: \(error.localizedDescription)")
                guard let link = await app.wakeLink(playing: uri) else {
                    note("no wake link")
                    throw error
                }
                note("wake link \(link.scheme ?? "?")://\(link.host ?? "?")")
                let opened = await openWakeLink(link)
                note(opened ? "wake link opened" : "wake link didn't open")
                guard opened else { throw Failure.wake }
                return .woke
            }
        }
        do {
            try await app.play(uri)
        } catch {
            note("play failed: \(error.localizedDescription)")
            throw error
        }
        note("playing")
        return .played
    }

    private func connection(clientID: String) -> SpotifyAppConnection {
        if let connection, connectionClientID == clientID { return connection }
        connection?.disconnect()
        let made = makeConnection(clientID)
        connection = made
        connectionClientID = clientID
        return made
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
            let outcome = try await SpotifyRemote.shared.play(uri: uri, token: token, clientID: clientID)
            return [outcome.rawValue: uri]
        }
    }
}

/// App Remote through Spotify's SDK.
@MainActor
final class SDKSpotifyConnection: NSObject, SpotifyAppConnection {
    private let remote: SPTAppRemote
    private var connecting: CheckedContinuation<Void, Error>?

    init(clientID: String) {
        remote = SPTAppRemote(configuration: SPTConfiguration(clientID: clientID, redirectURL: SpotifyRemote.redirectURL),
                              logLevel: .error)
        super.init()
        remote.delegate = self
    }

    var isConnected: Bool { remote.isConnected }

    func connect(token: String, timeout: Duration) async throws {
        remote.connectionParameters.accessToken = token
        try await withCheckedThrowingContinuation { (connected: CheckedContinuation<Void, Error>) in
            connecting?.resume(throwing: SpotifyRemote.Failure.connect("superseded"))
            connecting = connected
            remote.connect()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishConnecting(SpotifyRemote.Failure.timedOut)
            }
        }
    }

    func play(_ uri: String) async throws {
        guard let player = remote.playerAPI else { throw SpotifyRemote.Failure.connect("no player") }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            player.play(uri) { _, error in
                if let error {
                    done.resume(throwing: SpotifyRemote.Failure.play(error.localizedDescription))
                } else {
                    done.resume()
                }
            }
        }
    }

    func wakeLink(playing uri: String) async -> URL? {
        await SpotifyWakeLink.capture { [remote] done in remote.authorizeAndPlayURI(uri, completionHandler: done) }
    }

    func disconnect() { remote.disconnect() }

    private func finishConnecting(_ error: Error?) {
        guard let waiting = connecting else { return }
        connecting = nil
        if let error { waiting.resume(throwing: error) } else { waiting.resume() }
    }
}

extension SDKSpotifyConnection: SPTAppRemoteDelegate {
    nonisolated func appRemoteDidEstablishConnection(_ appRemote: SPTAppRemote) {
        Task { @MainActor in self.finishConnecting(nil) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didFailConnectionAttemptWithError error: Error?) {
        let why = error?.localizedDescription ?? "unknown"
        Task { @MainActor in self.finishConnecting(SpotifyRemote.Failure.connect(why)) }
    }

    nonisolated func appRemote(_ appRemote: SPTAppRemote, didDisconnectWithError error: Error?) {
        let why = error?.localizedDescription ?? "disconnected"
        Task { @MainActor in self.finishConnecting(SpotifyRemote.Failure.connect(why)) }
    }
}

/// Spotify's SDK wakes the Spotify app by opening a `spotify-action:` link (authorize and play)
/// through UIApplication, which can't open anything with the phone locked in the car. While
/// `capture` runs, that link is handed back instead of opened, so it can open on the car's screen.
@MainActor
enum SpotifyWakeLink {
    fileprivate static var capturing: ((URL) -> Void)?
    private static var installed = false

    /// Runs `ask` (which makes the SDK open its link, then calls back whether it could) and
    /// returns the link, or nil when the SDK opened none within a second.
    static func capture(_ ask: (@escaping (Bool) -> Void) -> Void) async -> URL? {
        install()
        let link: URL? = await withCheckedContinuation { (done: CheckedContinuation<URL?, Never>) in
            let once = Once(done)
            capturing = { once.finish($0) }
            ask { opened in
                guard !opened else { return }
                Task { @MainActor in once.finish(nil) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                once.finish(nil)
            }
        }
        capturing = nil
        return link
    }

    /// On the car's screen when CarPlay is up, else as UIApplication opens it. The car's screen
    /// may never call back, so its answer is awaited for `limit` at most (then: asked).
    static func open(_ url: URL, within limit: Duration = .seconds(3)) async -> Bool {
        if CarScreen.isConnected {
            return await answer(within: limit) { done in CarScreen.open(url, done: done) } ?? true
        }
        return await UIApplication.shared.open(url)
    }

    /// `ask`'s answer, or nil when it hasn't answered within `limit`.
    static func answer(within limit: Duration, _ ask: (@escaping (Bool) -> Void) -> Void) async -> Bool? {
        await withCheckedContinuation { (done: CheckedContinuation<Bool?, Never>) in
            let once = OnceAnswer(done)
            ask { ok in Task { @MainActor in once.finish(ok) } }
            Task { @MainActor in
                try? await Task.sleep(for: limit)
                once.finish(nil)
            }
        }
    }

    @MainActor
    private final class OnceAnswer {
        private var done: CheckedContinuation<Bool?, Never>?
        init(_ done: CheckedContinuation<Bool?, Never>) { self.done = done }
        func finish(_ ok: Bool?) {
            done?.resume(returning: ok)
            done = nil
        }
    }

    private static func install() {
        guard !installed,
              let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.open(_:options:completionHandler:))),
              let handing = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.jc_openHandingBackSpotifyWake(_:options:completionHandler:)))
        else { return }
        method_exchangeImplementations(original, handing)
        installed = true
    }

    @MainActor
    private final class Once {
        private var done: CheckedContinuation<URL?, Never>?
        init(_ done: CheckedContinuation<URL?, Never>) { self.done = done }
        func finish(_ link: URL?) {
            done?.resume(returning: link)
            done = nil
        }
    }
}

extension UIApplication {
    /// Swapped in for `open(_:options:completionHandler:)` by `SpotifyWakeLink`: the SDK's wake
    /// link goes back to it while it's capturing; everything else opens as before.
    @objc fileprivate func jc_openHandingBackSpotifyWake(_ url: URL, options: [UIApplication.OpenExternalURLOptionsKey: Any],
                                                         completionHandler: ((Bool) -> Void)?) {
        if url.scheme == "spotify-action", let capturing = SpotifyWakeLink.capturing {
            capturing(url)
            completionHandler?(true)
            return
        }
        jc_openHandingBackSpotifyWake(url, options: options, completionHandler: completionHandler)  // the original
    }
}
