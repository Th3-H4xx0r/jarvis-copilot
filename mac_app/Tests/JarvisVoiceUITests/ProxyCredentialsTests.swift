import XCTest
@testable import JarvisVoiceUI

/// `ProxyCredentials` is read from whatever thread a request is built on.
///
/// `APICredentials` is a plain `Sendable` protocol with no isolation, and
/// `JarvisAPI.request` — which reads both properties — is nonisolated, so on a
/// voice turn it runs on the cooperative pool, not the main actor. The first
/// version of this type stored its fields on `@MainActor` and read them through
/// `MainActor.assumeIsolated`, which does not "check and adapt": it TRAPS. Every
/// turn died at `SIGTRAP` the moment it asked for the base URL.
final class ProxyCredentialsTests: XCTestCase {

    func testCredentialsAreReadableOffTheMainActor() async throws {
        let url = URL(string: "http://127.0.0.1:54321")!
        ProxyCredentials.configure(baseURL: url, headers: ["X-Test": "1"])

        // `.detached` so this really is another executor — the same place
        // `JarvisAPI.request` reads them from during a turn.
        let (base, headers) = await Task.detached { () -> (URL?, [String: String]) in
            let creds = ProxyCredentials()
            return (creds.baseURL, creds.headers)
        }.value

        XCTAssertEqual(base, url)
        XCTAssertEqual(headers["X-Test"], "1")
    }

    func testTheSharedAPIPicksUpTheConfiguredProxyOffTheMainActor() async throws {
        // The real path: `JarvisAPI` holds the credentials behind the protocol
        // and reads them while building a request, off the main actor.
        let url = URL(string: "http://127.0.0.1:65000")!
        ProxyCredentials.configure(baseURL: url)
        let api = JarvisAPI(credentials: ProxyCredentials())

        let paired = await Task.detached { api.isPaired || api.credentials.baseURL != nil }.value
        XCTAssertTrue(paired)
    }

    func testConfigureReplacesEarlierCredentials() {
        // The proxy port changes across a re-pair, so this is not write-once.
        ProxyCredentials.configure(baseURL: URL(string: "http://127.0.0.1:1")!,
                                   headers: ["A": "1"])
        ProxyCredentials.configure(baseURL: URL(string: "http://127.0.0.1:2")!)
        let creds = ProxyCredentials()
        XCTAssertEqual(creds.baseURL?.port, 2)
        XCTAssertTrue(creds.headers.isEmpty, "headers should not survive a reconfigure")
    }
}

/// The crash site itself, against a live server.
///
/// Opt-in: set `JC_PROXY_ORIGIN=http://127.0.0.1:<port>` to a running
/// `PinnedProxy` (see `mac_app/scripts/live-proxy-test.py`, which starts one and
/// runs this). `/api/devices` is the very request `maybeRefreshDevices` makes
/// mid-turn, and it is issued from a detached task here for the same reason it
/// was in the crash: `JarvisAPI.request` reads the credentials wherever it runs.
final class ProxyCredentialsLiveTests: XCTestCase {

    func testARealRequestReadsCredentialsOffTheMainActor() async throws {
        let env = ProcessInfo.processInfo.environment["JC_PROXY_ORIGIN"] ?? ""
        try XCTSkipIf(env.isEmpty, "set JC_PROXY_ORIGIN to a running PinnedProxy")
        let origin = try XCTUnwrap(URL(string: env))

        ProxyCredentials.configure(baseURL: origin)
        let api = JarvisAPI(credentials: ProxyCredentials())

        let devices = try await Task.detached {
            try await api.get("/api/devices").array(key: "devices")
        }.value
        // The point is that the request was BUILT and answered at all — an empty
        // roster is a fine answer, a SIGTRAP is not.
        XCTAssertNotNil(devices)
    }
}

/// The two pickers' content, against a live server.
///
/// The menus themselves are a thin shell over these two calls; what can
/// actually be wrong is that the Mac target builds the stores but the requests
/// come back empty, and an empty menu looks exactly like a menu that has not
/// loaded yet. Opt-in like the test above — see `scripts/live-proxy-test.py`.
@MainActor
final class VoicePickerLiveTests: XCTestCase {

    private func liveOrigin() throws -> URL {
        let env = ProcessInfo.processInfo.environment["JC_PROXY_ORIGIN"] ?? ""
        try XCTSkipIf(env.isEmpty, "set JC_PROXY_ORIGIN to a running PinnedProxy")
        let url = try XCTUnwrap(URL(string: env))
        ProxyCredentials.configure(baseURL: url)
        return url
    }

    func testTheModelMenuHasAModelCatalogueToShow() async throws {
        _ = try liveOrigin()
        let catalog = try await ModelsAPI(api: JarvisAPI(credentials: ProxyCredentials())).list()
        XCTAssertFalse(catalog.models.isEmpty, "the model menu would be empty")
        XCTAssertFalse(catalog.providers.isEmpty, "the menu groups by provider")
        // Every model must land in a section, or it is unreachable in the menu.
        let grouped = catalog.providers.flatMap { catalog.models(for: $0) }
        XCTAssertEqual(grouped.count, catalog.models.count)
    }

    func testTheSessionMenuHasChatsToShow() async throws {
        _ = try liveOrigin()
        let sessions = try await SessionsAPI(api: JarvisAPI(credentials: ProxyCredentials())).list()
        // An account with no chats is legitimate — the menu still offers Voice
        // and New session — so this asserts the call works, not that it is full.
        XCTAssertNotNil(sessions)
        for s in sessions.prefix(5) {
            XCTAssertFalse(s.id.isEmpty, "a session with no id cannot be selected")
            XCTAssertFalse(s.displayTitle.isEmpty, "a blank row in the menu")
        }
    }
}
