import LinkPresentation
import SwiftUI
import WebKit

// The main chat's embeds (see `MarkdownBlocks.withEmbeds`): a page the agent
// saved, shown live inside the reply, and an iMessage-style card for a link on
// a line of its own. The web UI does the same in `static/ui.js`.

// MARK: - HTML page

/// A page the agent saved on the server — the costumes table, a chart — live
/// inside the reply, with a button that opens it full screen.
///
/// Fetched through `JarvisAPI` (`/api/media` is cookie-gated) and deliberately
/// not through ``ChatImageCache``: the agent often rewrites the same file ("make
/// the table blue"), and a cached copy would keep showing the old page.
struct ChatHTMLCard: View {
    let path: String

    /// Kept with its path: the transcript's `ForEach` is keyed by offset, so
    /// this view can be handed a different page and must not show the old one.
    @State private var page: (path: String, html: String)?
    @State private var failedPath: String?
    @State private var fullscreen = false

    static let height: CGFloat = 420
    /// Same order as the web's preview cap, with room for inlined images.
    static let maxBytes = 2 * 1024 * 1024

    private var name: String { (path as NSString).lastPathComponent }
    private var html: String? { page?.path == path ? page?.html : nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(JcTheme.border).frame(height: 1)
            content.frame(height: Self.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(JcTheme.border, lineWidth: 1))
        .task(id: path) { await load() }
        .fullScreenCover(isPresented: $fullscreen) {
            ChatHTMLFullScreen(name: name, html: html ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            JcIcon("globe", size: 13)
                .foregroundStyle(JcTheme.cyan)
            Text(name)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button { fullscreen = true } label: {
                JcIcon("arrow.up.left.and.arrow.down.right", size: 12)
            }
            .buttonStyle(.jcGlass(tint: JcTheme.cyan, compact: true))
            .disabled(html == nil)
            .accessibilityLabel("Open page full screen")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(JcTheme.surfaceAlt.opacity(0.55))
    }

    @ViewBuilder private var content: some View {
        if let html {
            ChatHTMLWebView(html: html)
        } else if failedPath == path {
            Text("Couldn't load this page")
                .font(.footnote)
                .foregroundStyle(JcTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        guard html == nil else { return }
        let api = JarvisAPI.shared
        var base = ChatMedia.apiBase(api)
        if base.hasSuffix("/") { base.removeLast() }
        guard let data = try? await api.bytes(base + ChatMedia.mediaSource(path), absolute: true),
              data.count <= Self.maxBytes else {
            failedPath = path
            return
        }
        page = (path, String(decoding: data, as: UTF8.self))
    }
}

/// The page full screen, the way ``ImageViewerPage`` shows a picture.
private struct ChatHTMLFullScreen: View {
    let name: String
    let html: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChatHTMLWebView(html: html)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// The live page: its scripts run, but it is walled off from the app — a
/// throwaway cookie-less data store and no base URL, so it can't reach the
/// Jarvis login — and a link it opens goes to Safari instead of replacing the
/// page. Only http/https/mailto leave the app (``ChatLinkPolicy``); anything
/// else a page tries to open is dropped.
struct ChatHTMLWebView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.loaded = html
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// Not `@MainActor`, like `ServerWebView.Coordinator`: WebKit calls back on
    /// the main thread already.
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loaded = ""

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let frame = action.targetFrame else {
                // A new window (target=_blank, window.open): createWebViewWith opens it.
                return decisionHandler(.allow)
            }
            let scheme = (url.scheme ?? "").lowercased()
            if ["about", "data", "blob"].contains(scheme) { return decisionHandler(.allow) }
            if !frame.isMainFrame, ["http", "https"].contains(scheme) {
                return decisionHandler(.allow)   // an embedded video or map
            }
            Self.openOutside(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url { Self.openOutside(url) }
            return nil
        }

        private static func openOutside(_ url: URL) {
            guard ChatLinkPolicy.isAllowed(url) else { return }
            MainActor.assumeIsolated { UIApplication.shared.open(url) }
        }
    }
}

// MARK: - Link preview

/// A link on a line of its own, drawn the way Messages draws one: Apple's own
/// `LPLinkView`, fed metadata the phone fetches itself. Tapping it opens the
/// link, as in Messages.
struct ChatLinkPreview: View {
    let url: URL
    @State private var metadata: LPLinkMetadata?

    var body: some View {
        LinkCard(metadata: metadata ?? Self.placeholder(url))
            .frame(maxWidth: 360, alignment: .leading)
            .task(id: url) {
                if let hit = ChatLinkMetadataCache.shared.cached(url) {
                    metadata = hit
                    return
                }
                // Held in state so a streaming re-render doesn't hand the view a
                // fresh placeholder (and a relayout) every token.
                metadata = Self.placeholder(url)
                // A link still streaming in changes every token; only fetch the
                // one that has stopped changing.
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled,
                      let fetched = await ChatLinkMetadataCache.shared.metadata(for: url) else { return }
                metadata = fetched
            }
    }

    /// What `LPLinkView` draws before (or without) the real metadata: the host.
    private static func placeholder(_ url: URL) -> LPLinkMetadata {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        return metadata
    }

    private struct LinkCard: UIViewRepresentable {
        let metadata: LPLinkMetadata

        func makeUIView(context: Context) -> LPLinkView { LPLinkView(metadata: metadata) }

        func updateUIView(_ view: LPLinkView, context: Context) {
            if view.metadata !== metadata { view.metadata = metadata }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: LPLinkView, context: Context) -> CGSize? {
            let width = min(proposal.width ?? 360, 360)
            let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            return CGSize(width: width, height: fitted.height)
        }
    }
}

/// Fetched link metadata, so a preview scrolled away and back (or the same link
/// in two replies) is fetched once. `NSCache` evicts under memory pressure.
@MainActor
final class ChatLinkMetadataCache {
    static let shared = ChatLinkMetadataCache()

    private let cache: NSCache<NSURL, LPLinkMetadata> = {
        let cache = NSCache<NSURL, LPLinkMetadata>()
        cache.countLimit = 128
        return cache
    }()
    private var inFlight: [URL: Task<LPLinkMetadata?, Never>] = [:]

    func cached(_ url: URL) -> LPLinkMetadata? { cache.object(forKey: url as NSURL) }

    func metadata(for url: URL) async -> LPLinkMetadata? {
        if let hit = cached(url) { return hit }
        if let running = inFlight[url] { return await running.value }
        let task = Task<LPLinkMetadata?, Never> {
            let provider = LPMetadataProvider()
            provider.timeout = 10
            return try? await provider.startFetchingMetadata(for: url)
        }
        inFlight[url] = task
        let metadata = await task.value
        inFlight[url] = nil
        if let metadata { cache.setObject(metadata, forKey: url as NSURL) }
        return metadata
    }
}
