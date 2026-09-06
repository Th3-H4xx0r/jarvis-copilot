import Foundation
#if canImport(WebKit)
import WebKit
#endif

/// One name/value pair from a `Cookie:` header.
struct WebCookie: Equatable, Hashable {
    let name: String
    let value: String
}

/// Splits `BridgeClient.apiAuthHeaders()` into what a `WKWebView` needs.
///
/// The bridge hands us credentials as request headers, but a webview only boots
/// authenticated if `hermes_session` is in its *cookie store* — a `Cookie:`
/// header on the top-level request is not inherited by the page's subresource
/// requests. The Cloudflare service token is the opposite case: it has to ride on
/// the request as headers so Cloudflare can validate it and set its own
/// `CF_Authorization` cookie for everything that follows.
enum WebViewCookies {

    /// Parses a `Cookie:` header value into its pairs.
    ///
    /// Splits each pair at the FIRST `=` only: session tokens are base64 and
    /// routinely carry `=` padding, which splitting on every `=` would truncate.
    static func parse(header: String) -> [WebCookie] {
        header.split(separator: ";").compactMap { piece in
            let pair = piece.trimmingCharacters(in: .whitespaces)
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else { return nil }
            let name = pair[pair.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return WebCookie(name: name, value: value)
        }
    }

    /// The cookies to seed into the webview's store.
    static func cookies(in headers: [String: String]) -> [WebCookie] {
        guard let header = headers["Cookie"] else { return [] }
        return parse(header: header)
    }

    /// The headers to keep on the request — everything except the cookie, which
    /// travels in the cookie store instead (sending both would present the
    /// session twice).
    static func requestHeaders(in headers: [String: String]) -> [String: String] {
        headers.filter { $0.key.caseInsensitiveCompare("Cookie") != .orderedSame }
    }

    /// Every website data type WebKit can hold — cookies, local/session storage,
    /// IndexedDB, the disk and memory caches, service workers.
    static var allDataTypes: Set<String> {
        #if canImport(WebKit)
        return WKWebsiteDataStore.allWebsiteDataTypes()
        #else
        return []
        #endif
    }

    /// Wipe everything the embedded server tabs persisted.
    ///
    /// The live webviews use a `.nonPersistent()` store (nothing survives the
    /// view), but earlier builds wrote `hermes_session` into the shared
    /// on-disk default store, and Cloudflare's `CF_Authorization` cookie can
    /// land there via any redirect. Unpair has to clear it: the Keychain wipe
    /// alone would leave the next person to pair this phone holding a
    /// logged-in webui.
    @MainActor
    static func clearAll() {
        #if canImport(WebKit)
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: allDataTypes,
                         modifiedSince: Date(timeIntervalSince1970: 0)) {}
        #endif
    }
}
