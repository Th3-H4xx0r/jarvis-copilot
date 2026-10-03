import AuthenticationServices
import CryptoKit
import Foundation
import Network
import UIKit

/// Signs in to Google on the phone with the user's own OAuth client (a "Desktop app" client) and returns
/// the token JSON a Drive destination takes — what `rclone authorize drive <id> <secret>` prints on a Mac.
/// Same method as rclone: PKCE + a loopback redirect to a tiny listener on 127.0.0.1 inside the app.
@MainActor
final class DashcamGoogleSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: LocalizedError {
        case cancelled, noCode(String), exchange(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign-in was cancelled"
            case .noCode(let why): return "Google didn't sign in: \(why)"
            case .exchange(let why): return "Google didn't hand over the token: \(why)"
            }
        }
    }

    private var session: ASWebAuthenticationSession?
    private var listener: NWListener?
    /// Ends the wait for Google's reply — the sheet was closed (failed page, swiped away, Cancel).
    private final class Abort: @unchecked Sendable { var finish: ((Error) -> Void)? }
    private let abort = Abort()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }

    func signIn(clientID: String, clientSecret: String) async throws -> String {
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(24)
        let (port, codeTask) = try await listen(state: state)
        defer { listener?.cancel(); listener = nil }
        let redirect = "http://127.0.0.1:\(port)"
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: "https://www.googleapis.com/auth/drive"),
            .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        // The browser sheet ends either way: the listener gets the code (we close the sheet) or the user closes it,
        // which must end the wait too, or the button spins forever.
        let abort = self.abort
        let browser = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "jarviscopilot-oauth") { _, error in
            if error != nil { abort.finish?(Failure.cancelled) }
        }
        browser.presentationContextProvider = self
        browser.prefersEphemeralWebBrowserSession = false
        session = browser
        browser.start()
        let code: String
        do { code = try await codeTask.value } catch { browser.cancel(); throw error }
        browser.cancel()
        return try await exchange(code: code, verifier: verifier, clientID: clientID, clientSecret: clientSecret, redirect: redirect)
    }

    /// A one-request HTTP server on a loopback port; its task finishes with Google's `code`. The port is
    /// read only once the listener is READY: before that it reads 0, and Safari refuses port 0 as a
    /// "restricted network port". rclone's own port (53682) first, any free one if that's taken.
    private func listen(state: String) async throws -> (UInt16, Task<String, Error>) {
        var (l, codeStream) = try makeListener(port: 53682, state: state)
        var port = await ready(l)
        if port == nil {
            l.cancel()
            (l, codeStream) = try makeListener(port: nil, state: state)
            port = await ready(l)
        }
        listener = l
        guard let port, port != 0 else { throw Failure.noCode("couldn't open a local port") }
        let stream = codeStream
        let task = Task<String, Error> {
            for try await code in stream { return code }
            throw Failure.cancelled
        }
        return (port, task)
    }

    private func makeListener(port: UInt16?, state: String) throws -> (NWListener, AsyncThrowingStream<String, Error>) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any)
        let l = try NWListener(using: params)
        let abort = self.abort
        let codeStream = AsyncThrowingStream<String, Error> { cont in
            abort.finish = { cont.finish(throwing: $0) }
            l.newConnectionHandler = { conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    let text = String(decoding: data ?? Data(), as: UTF8.self)
                    let target = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                    let items = URLComponents(string: "http://x" + target)?.queryItems ?? []
                    func value(_ k: String) -> String? { items.first { $0.name == k }?.value }
                    let ok = value("state") == state && value("code") != nil
                    let page = ok ? "Signed in. You can go back to Jarvis." : "Sign-in failed: \(value("error") ?? "no code")"
                    let body = "<html><body style='font:20px -apple-system;padding:40px'>\(page)</body></html>"
                    let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    if let code = value("code"), ok { cont.yield(code); cont.finish() }
                    else if text.hasPrefix("GET") && !target.hasPrefix("/favicon") { cont.finish(throwing: Failure.noCode(value("error") ?? "no code")) }
                }
            }
        }
        return (l, codeStream)
    }

    /// Starts the listener and waits (up to 3 s) until it is listening; nil when it couldn't.
    private func ready(_ l: NWListener) async -> UInt16? {
        await withCheckedContinuation { (cont: CheckedContinuation<UInt16?, Never>) in
            var done = false
            func finish(_ v: UInt16?) { if !done { done = true; cont.resume(returning: v) } }
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(l.port?.rawValue)
                case .failed, .cancelled: finish(nil)
                default: break
                }
            }
            l.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }

    private func exchange(code: String, verifier: String, clientID: String, clientSecret: String, redirect: String) async throws -> String {
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [.init(name: "code", value: code), .init(name: "client_id", value: clientID),
                           .init(name: "client_secret", value: clientSecret), .init(name: "redirect_uri", value: redirect),
                           .init(name: "grant_type", value: "authorization_code"), .init(name: "code_verifier", value: verifier)]
        r.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let access = o["access_token"] as? String else {
            throw Failure.exchange((o["error_description"] as? String) ?? (o["error"] as? String) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let refresh = o["refresh_token"] as? String else { throw Failure.exchange("no refresh token — remove the app's access in your Google account and try again") }
        let expires = Date().addingTimeInterval((o["expires_in"] as? NSNumber)?.doubleValue ?? 3600)
        let f = ISO8601DateFormatter()
        // The shape rclone writes (and the server's drive_token accepts).
        let token: [String: Any] = ["access_token": access, "token_type": "Bearer", "refresh_token": refresh,
                                    "expiry": f.string(from: expires)]
        return String(decoding: try JSONSerialization.data(withJSONObject: token, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars.randomElement()! })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
