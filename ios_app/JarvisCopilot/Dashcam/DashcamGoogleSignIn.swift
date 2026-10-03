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
        // The browser sheet ends either way: the listener gets the code (we close the sheet) or the user cancels.
        let browser = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: "jarviscopilot-oauth") { _, _ in }
        browser.presentationContextProvider = self
        browser.prefersEphemeralWebBrowserSession = false
        session = browser
        browser.start()
        let code: String
        do { code = try await codeTask.value } catch { browser.cancel(); throw error }
        browser.cancel()
        return try await exchange(code: code, verifier: verifier, clientID: clientID, clientSecret: clientSecret, redirect: redirect)
    }

    /// A one-request HTTP server on a free loopback port; its task finishes with Google's `code`.
    private func listen(state: String) async throws -> (UInt16, Task<String, Error>) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        listener = l
        let codeStream = AsyncThrowingStream<String, Error> { cont in
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
            l.start(queue: .main)
        }
        // Wait for the port.
        for _ in 0..<50 where l.port == nil { try await Task.sleep(for: .milliseconds(20)) }
        guard let port = l.port?.rawValue else { throw Failure.noCode("couldn't open a local port") }
        let task = Task<String, Error> {
            for try await code in codeStream { return code }
            throw Failure.cancelled
        }
        return (port, task)
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
