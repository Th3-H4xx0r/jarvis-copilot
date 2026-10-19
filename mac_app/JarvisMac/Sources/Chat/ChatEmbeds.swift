import AppKit
import LinkPresentation
import SwiftUI
import WebKit

// The chat's embeds (ChatMarkdown.withEmbeds), ported from the phone's
// ChatEmbeds: a page the agent saved, live inside the reply, and a preview
// card for a link on a line of its own.

// MARK: - HTML page

/// A page the agent saved on the server — a table, a chart — live inside the
/// reply, with a button that opens it in its own window.
///
/// Fetched through the island's API origin (it carries the session, like the
/// chat's pictures) and never cached: the agent often rewrites the same file
/// ("make the table blue"), and a cached copy would keep showing the old page.
struct ChatHTMLCard: View {
    let path: String

    /// Kept with its path: the reply's blocks are keyed by offset, so this view
    /// can be handed a different page and must not show the old one.
    @State private var page: (path: String, html: String)?
    @State private var failedPath: String?

    static let height: CGFloat = 300
    /// The web's preview cap, with room for inlined images.
    static let maxBytes = 2 * 1024 * 1024

    private var name: String { (path as NSString).lastPathComponent }
    private var html: String? { page?.path == path ? page?.html : nil }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5)
            // A page that didn't load is one quiet row, not an empty box.
            content.frame(height: failedPath == path ? 40 : Self.height)
        }
        .background(Color.white.opacity(0.03))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        .task(id: path) { await load() }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "globe").font(.system(size: 11, weight: .medium)).foregroundStyle(JcAccent.color)
            Text(name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ChatStyle.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                if let html { ChatPageWindow.show(name: name, html: html) }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(html == nil ? ChatStyle.faint : JcAccent.color)
                    .frame(width: 24, height: 22)
                    .chatGlass(in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(html == nil)
            .help("Open in a window")
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 5)
    }

    @ViewBuilder private var content: some View {
        if let html {
            ChatHTMLWebView(html: html)
        } else if failedPath == path {
            Label("Couldn't load this page", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11.5)).foregroundStyle(ChatStyle.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() async {
        guard html == nil else { return }
        // Only a card that stays on screen fetches and makes its web view, and
        // never in the frames the island springs open in; a path still
        // streaming in settles first.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        guard let url = ChatMedia.url(for: ChatMedia.mediaSource(path), origin: AppModel.shared.apiOrigin),
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30)),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty, data.count <= Self.maxBytes
        else {
            if !Task.isCancelled { failedPath = path }
            return
        }
        page = (path, String(decoding: data, as: UTF8.self))
    }
}

/// The live page: its scripts run, but it is walled off from the app — a
/// throwaway cookie-less data store and no base URL, so it can't reach the
/// Jarvis session — and a link it opens goes to the default browser instead of
/// replacing the page.
struct ChatHTMLWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> ChatWebPolicy { ChatWebPolicy() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = ChatWebPolicy.webView(delegate: context.coordinator)
        context.coordinator.loaded = html
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: ChatWebPolicy) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }
}

/// Where a page's links go. A page loads in place (about/data/blob, and
/// http(s) in a subframe — an embedded video or map); a link it follows in the
/// main frame, opens in a new window (target=_blank) or with `window.open`
/// goes to the default browser — http, https and mailto only; anything else is
/// dropped.
final class ChatWebPolicy: NSObject, WKNavigationDelegate, WKUIDelegate {
    var loaded = ""

    static let outsideSchemes: Set<String> = ["http", "https", "mailto"]

    /// A fresh, walled-off web view.
    @MainActor
    static func webView(delegate: ChatWebPolicy) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        return webView
    }

    /// What happens to a navigation: in place, or out to the browser (true = out).
    static func opensOutside(_ url: URL, mainFrame: Bool) -> Bool? {
        let scheme = (url.scheme ?? "").lowercased()
        if ["about", "data", "blob"].contains(scheme) { return false }
        if !mainFrame, ["http", "https"].contains(scheme) { return false }
        return outsideSchemes.contains(scheme) ? true : nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let frame = action.targetFrame else {
            // A new window (target=_blank, window.open): createWebViewWith sends it out.
            return decisionHandler(.allow)
        }
        // The page itself (loadHTMLString's about:blank) loads in place.
        if Self.opensOutside(url, mainFrame: frame.isMainFrame) == false { return decisionHandler(.allow) }
        Self.openOutside(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { Self.openOutside(url) }
        return nil
    }

    private static func openOutside(_ url: URL) {
        guard outsideSchemes.contains((url.scheme ?? "").lowercased()) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A page from a reply in its own window: resizable, centred, over the island
/// (the chat's file picker's level), with a fresh web view.
@MainActor
enum ChatPageWindow {
    static let size = NSSize(width: 1000, height: 750)
    /// The open windows, each with its page's link policy (a web view holds its
    /// delegates weakly), until it closes.
    private static var open: Set<Holder> = []

    @discardableResult
    static func show(name: String, html: String) -> NSWindow {
        let policy = ChatWebPolicy()
        let webView = ChatWebPolicy.webView(delegate: policy)
        policy.loaded = html
        webView.loadHTMLString(html, baseURL: nil)
        let window = PageWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
        window.title = name
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.level = ChatAttachPanel.level
        window.minSize = NSSize(width: 420, height: 300)
        window.center()
        let holder = Holder(window: window, policy: policy)
        window.delegate = holder
        open.insert(holder)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    static var openCount: Int { open.count }

    private final class Holder: NSObject, NSWindowDelegate {
        let window: NSWindow
        let policy: ChatWebPolicy

        init(window: NSWindow, policy: ChatWebPolicy) {
            self.window = window
            self.policy = policy
        }

        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                (window.contentView as? WKWebView)?.stopLoading()
                window.delegate = nil
                ChatPageWindow.open.remove(self)
            }
        }
    }

    /// ⌘W closes it (the app has no menu bar of its own to do that).
    private final class PageWindow: NSWindow {
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "w" {
                performClose(nil)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}

// MARK: - Link preview

/// A link on a line of its own, drawn the way Messages draws one: Apple's own
/// `LPLinkView`, fed metadata fetched here. A click opens the link in the
/// default browser.
struct ChatLinkPreview: View {
    let url: URL
    @State private var metadata: LPLinkMetadata?

    static let maxWidth: CGFloat = 360

    var body: some View {
        LinkCard(metadata: metadata ?? ChatLinkMetadataCache.shared.cached(url) ?? Self.placeholder(url))
            .frame(maxWidth: Self.maxWidth, alignment: .leading)
            // The card's own clicks (and media playback) are swapped for one
            // that opens the page.
            .overlay {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .pointerStyle(.link)
            }
            .help(url.absoluteString)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: url) {
                if let hit = ChatLinkMetadataCache.shared.cached(url) {
                    metadata = hit
                    return
                }
                // Held in state so a streaming re-render doesn't hand the card a
                // fresh placeholder (and a relayout) every token.
                metadata = Self.placeholder(url)
                // A link still streaming in changes every token; only the one
                // that has stopped changing is fetched.
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let fetched = await ChatLinkMetadataCache.shared.metadata(for: url) else { return }
                metadata = fetched
            }
    }

    /// What the card draws before (or without) the real metadata: the host.
    static func placeholder(_ url: URL) -> LPLinkMetadata {
        let metadata = LPLinkMetadata()
        metadata.originalURL = url
        metadata.url = url
        return metadata
    }

    private struct LinkCard: NSViewRepresentable {
        let metadata: LPLinkMetadata

        func makeNSView(context: Context) -> LPLinkView {
            let view = LPLinkView(metadata: metadata)
            view.appearance = NSAppearance(named: .darkAqua)  // on the island's black
            return view
        }

        func updateNSView(_ view: LPLinkView, context: Context) {
            if view.metadata !== metadata { view.metadata = metadata }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: LPLinkView, context: Context) -> CGSize? {
            let natural = nsView.intrinsicContentSize
            let width = min(proposal.width ?? ChatLinkPreview.maxWidth, ChatLinkPreview.maxWidth, max(natural.width, 1))
            return CGSize(width: width, height: max(natural.height, 1))
        }
    }
}

/// Fetched link metadata, so a preview scrolled away and back (or the same
/// link in two replies, or the island opened again) is fetched once.
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
