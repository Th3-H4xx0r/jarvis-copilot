import SwiftUI
#if os(iOS)
import WebKit
#endif

/// Embeds a server tab, ported from `pages/webview_page.dart`.
///
/// Two things make the page boot authenticated:
///  * the `hermes_session` cookie is written into the webview's cookie store
///    *before* the first load — a `Cookie:` header on the top-level request is
///    not inherited by the page's own fetches, so the webui would boot logged
///    out and redirect;
///  * the Cloudflare Access service token rides on the top-level request as
///    headers, which is what lets Cloudflare validate it and set the
///    `CF_Authorization` cookie every subresource then carries.
///
/// Cert pinning is deliberately absent: `WKWebView` never surfaces the leaf
/// certificate, so the Flutter client can't pin on iOS either (see the long note
/// in `webview_page.dart`). The bridge's own HTTP/WS traffic is unaffected.
struct WebViewPage: View {
    let title: String
    /// Path (and query) inside the paired server, e.g. `/?panel=settings`.
    let path: String

    init(title: String, path: String) {
        self.title = title
        self.path = path
    }

    @State private var progress: Double = 0
    @State private var isLoading = true

    private var url: URL? {
        guard let base = BridgeClient.shared.apiBaseURL() else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    var body: some View {
        Group {
            #if os(iOS)
            if let url {
                VStack(spacing: 0) {
                    if isLoading {
                        ProgressView(value: max(progress, 0.02))
                            .progressViewStyle(.linear)
                            .tint(JcTheme.primaryBlue)
                    }
                    ServerWebView(url: url,
                                  headers: BridgeClient.shared.apiAuthHeaders(),
                                  progress: $progress,
                                  isLoading: $isLoading)
                }
            } else {
                CenteredMessage(text: "No server paired.")
            }
            #else
            CenteredMessage(text: "Web views are not available on this platform.")
            #endif
        }
        .jcScreen(title)
    }
}

#if os(iOS)

/// The `WKWebView` itself. Seeds cookies, then loads once — `updateUIView`
/// deliberately does nothing, because re-issuing the load on every SwiftUI
/// re-render is what made the Flutter version thrash before its future was cached.
struct ServerWebView: UIViewRepresentable {
    let url: URL
    let headers: [String: String]
    @Binding var progress: Double
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Non-persistent: the session cookie we seed below is the paired
        // server's login. A `.default()` store writes it to disk, where it
        // outlives an unpair (and a reinstall of the *webui*, not the app), so
        // the embedded tabs would stay authenticated for whoever holds the
        // phone next. Everything the webui needs is re-seeded on each load.
        configuration.websiteDataStore = .nonPersistent()
        // The webui's voice panel needs the mic without a second gesture; the app
        // already holds the OS-level permission.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // `window.JarvisCopilotMobile.popView()` lets an embedded panel hand
        // control back to the native shell, as the Flutter bridge does. Injected
        // at document end so the webui's own `_jcMobileDetect` sees it.
        let bridge = WKUserScript(source: """
            if (!window.JarvisCopilotMobile) {
              window.JarvisCopilotMobile = {
                popView: function () { window.webkit.messageHandlers.popView.postMessage(null); }
              };
            }
            if (document.body) { document.body.classList.add('in-mobile-app'); }
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(bridge)
        configuration.userContentController.add(context.coordinator, name: "popView")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observe(webView)

        // Cookies have to be in the store before the load starts, otherwise the
        // first request goes out unauthenticated and the webui bounces us.
        let cookies = WebViewCookies.cookies(in: headers).compactMap { cookie in
            HTTPCookie(properties: [
                .name: cookie.name,
                .value: cookie.value,
                .domain: url.host ?? "",
                .path: "/",
                .secure: url.scheme == "https" ? "TRUE" : "FALSE",
            ])
        }
        var request = URLRequest(url: url)
        for (key, value) in WebViewCookies.requestHeaders(in: headers) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let store = configuration.websiteDataStore.httpCookieStore
        Task { @MainActor in
            for cookie in cookies { await store.setCookie(cookie) }
            webView.load(request)
        }
        return webView
    }

    /// The load is deliberately NOT re-issued (that is what made the Flutter
    /// version thrash), but the coordinator's copy of this struct must be
    /// refreshed: SwiftUI rebuilds `ServerWebView` on every re-render and the
    /// bindings inside the copy made at `makeCoordinator` time write into a
    /// `@State` box that is no longer the one on screen.
    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "popView")
        coordinator.stopObserving()
    }

    /// Not `@MainActor`: `WKNavigationDelegate` and KVO both call back on the main
    /// thread already, and annotating the class makes the delegate conformances
    /// fight the SDK's own (un)annotated requirements.
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        /// Refreshed by `updateUIView` — see the note there.
        var parent: ServerWebView
        private var progressObservation: NSKeyValueObservation?

        init(_ parent: ServerWebView) { self.parent = parent }

        func observe(_ webView: WKWebView) {
            // `[weak self]` (not `[parent]`): capturing the struct would pin the
            // bindings from whichever render installed the observer.
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue else { return }
                // WebKit fires KVO on the main thread but the callback is not
                // typed as isolated, and a `@Binding` write is main-actor work.
                MainActor.assumeIsolated { self?.parent.progress = value }
            }
        }

        func stopObserving() {
            progressObservation?.invalidate()
            progressObservation = nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            parent.isLoading = false
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            // `popView` — the navigation stack's own back gesture handles the pop;
            // the receiver exists so the injected bridge doesn't throw.
        }
    }
}

#endif
