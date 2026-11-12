import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Ad and tracker blocking

/// The browser's block lists (VaultBlocklist.generated.swift, from EasyList + EasyPrivacy) as
/// WebKit content rule lists. Compiled once per list version, then loaded from WebKit's cache;
/// a broken part is skipped rather than taking the whole blocker down.
@MainActor
enum VaultBlocker {
    /// The ad/tracker servers (in parts) and the "hide empty ad spaces" CSS, kept apart so each
    /// can be switched on its own.
    struct Lists {
        var hosts: [WKContentRuleList] = []
        var css: WKContentRuleList?
        var count: Int { hosts.count + (css == nil ? 0 : 1) }
    }

    private static var lists: Lists?
    private static var building: Task<Lists, Never>?
    nonisolated static let parts = 4
    private static let prefix = "jc-vault-block-"

    /// Start compiling early (on unlock) so the first page doesn't wait.
    static func prepare() {
        Task { _ = await ruleLists() }
    }

    static func ruleLists() async -> Lists {
        if let lists { return lists }
        if let building { return await building.value }
        let task = Task { await load() }
        building = task
        let out = await task.value
        lists = out
        building = nil
        return out
    }

    private static func load() async -> Lists {
        guard let store = WKContentRuleListStore.default() else { return Lists() }
        let version = VaultBlocklist.version
        let ids = (0..<parts).map { "\(prefix)\(version)-hosts-\($0)" } + ["\(prefix)\(version)-css"]
        // Drop lists from older versions.
        for id in await store.availableIdentifiers() where id.hasPrefix(prefix) && !ids.contains(id) {
            try? await store.removeContentRuleList(forIdentifier: id)
        }
        var out = Lists()
        for (i, id) in ids.enumerated() {
            let put: (WKContentRuleList) -> Void = { list in
                if i < VaultBlocker.parts { out.hosts.append(list) } else { out.css = list }
            }
            if let cached = try? await store.contentRuleList(forIdentifier: id) {
                put(cached)
                continue
            }
            let json = await Task.detached(priority: .utility) {
                i < VaultBlocker.parts ? VaultBlocker.hostRules(part: i, of: VaultBlocker.parts)
                                       : VaultBlocker.selectorRules()
            }.value
            guard let json else { continue }
            if let list = try? await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) {
                put(list)
            }
        }
        return out
    }

    /// Block rules for every `part`-th host. "3 host" = only when another site loads it.
    nonisolated static func hostRules(part: Int, of parts: Int) -> String? {
        var rules: [[String: Any]] = []
        for (i, line) in VaultBlocklist.hosts.split(separator: "\n").enumerated() where i % parts == part {
            let thirdParty = line.hasPrefix("3 ")
            let host = thirdParty ? line.dropFirst(2) : line[...]
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            var trigger: [String: Any] = ["url-filter": "^[^:]+://+([^:/]+\\.)?\(escaped)[:/]"]
            if thirdParty { trigger["load-type"] = ["third-party"] }
            rules.append(["trigger": trigger, "action": ["type": "block"]])
        }
        return encode(rules)
    }

    /// Generic element hiding, a few hundred selectors per rule.
    nonisolated static func selectorRules() -> String? {
        let selectors = VaultBlocklist.selectors.split(separator: "\n").map(String.init)
        var rules: [[String: Any]] = []
        var i = 0
        while i < selectors.count {
            let chunk = selectors[i..<min(i + 300, selectors.count)].joined(separator: ", ")
            rules.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": chunk]])
            i += 300
        }
        return encode(rules)
    }

    nonisolated private static func encode(_ rules: [[String: Any]]) -> String? {
        guard !rules.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension WKContentRuleListStore {
    func availableIdentifiers() async -> [String] {
        await withCheckedContinuation { cont in
            getAvailableContentRuleListIdentifiers { cont.resume(returning: $0 ?? []) }
        }
    }
}

// MARK: - The browser

/// One private browsing session: nothing persists (a fresh in-memory website data store each
/// time), other apps and downloads are refused, and Jarvis Shields (VaultShields.swift) decide
/// the rest per site: ad/tracker blocking, ad-space hiding, pop-ups, stealth, GPC, JavaScript.
@MainActor
final class VaultBrowserModel: NSObject, ObservableObject {
    let webView: WKWebView
    @Published var title = ""
    @Published var url: URL?
    @Published var progress = 0.0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var ready = false
    @Published var blockedPopups = 0
    /// A pop-up the page tried to open without a tap: one tap opens it here.
    @Published var pendingPopup: URL?
    @Published var notice: String?
    /// Shields up for the page on screen (the shield icon).
    @Published private(set) var shieldsHere = true
    @Published var desktopSite = false

    private var observations: [NSKeyValueObservation] = []
    private let start: URL
    private let shields: VaultShields
    private var lists = VaultBlocker.Lists()
    /// What the page's rules were last set up for: (site, settings).
    private var appliedFor: (String, VaultShieldSettings)?
    var onActivity: (() -> Void)?

    init(start: URL, shields: VaultShields = .shared) {
        self.start = start
        self.shields = shields
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()                     // private: gone when it closes
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = shields.settings.blockAutoplay ? .all : []
        config.dataDetectorTypes = []
        config.upgradeKnownHostsToHTTPS = true
        // Look like Safari itself: an in-app web view's user agent is what "update your browser"
        // and "in-app browser" walls key on.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        config.applicationNameForUserAgent = "Version/\(os.majorVersion).\(os.minorVersion) Mobile/15E148 Safari/604.1"
        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = false
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title) { [weak self] wv, _ in
                let v = wv.title ?? ""
                Task { @MainActor in self?.title = v }
            },
            webView.observe(\.url) { [weak self] wv, _ in
                let v = wv.url
                Task { @MainActor in if let v { self?.url = v } }
            },
            webView.observe(\.estimatedProgress) { [weak self] wv, _ in
                let v = wv.estimatedProgress
                Task { @MainActor in self?.progress = v }
            },
            webView.observe(\.isLoading) { [weak self] wv, _ in
                let v = wv.isLoading
                Task { @MainActor in self?.isLoading = v }
            },
            webView.observe(\.canGoBack) { [weak self] wv, _ in
                let v = wv.canGoBack
                Task { @MainActor in self?.canGoBack = v }
            },
            webView.observe(\.canGoForward) { [weak self] wv, _ in
                let v = wv.canGoForward
                Task { @MainActor in self?.canGoForward = v }
            },
        ]
        url = start
    }

    /// Blocking first, then the page — never a page load without the blocker.
    func begin() async {
        guard !ready else { return }
        lists = await VaultBlocker.ruleLists()
        apply(for: start)
        ready = true
        webView.load(URLRequest(url: start))
    }

    /// Set the page's rules and scripts for `url`'s site under the current settings. Called before
    /// each main-frame navigation (and after the settings change), so a site with Shields down
    /// loads clean and the next one gets them back.
    func apply(for url: URL?, force: Bool = false) {
        let site = VaultShields.site(url)
        let s = shields.settings
        if !force, let applied = appliedFor, applied.0 == site, applied.1 == s { return }
        appliedFor = (site, s)
        let on = shields.isOn(for: url)
        shieldsHere = on
        let ucc = webView.configuration.userContentController
        ucc.removeAllContentRuleLists()
        ucc.removeAllUserScripts()
        if on && s.blockAds { lists.hosts.forEach { ucc.add($0) } }
        if on && s.hideAdSpaces, let css = lists.css { ucc.add(css) }
        if s.globalPrivacyControl { ucc.addUserScript(VaultShieldScripts.globalPrivacyControl()) }
        if on && s.blockAds && s.stealth { ucc.addUserScript(VaultShieldScripts.stealth()) }
    }

    /// After the Shields sheet: re-apply and reload so the page shows the new settings.
    func settingsChanged() {
        apply(for: webView.url ?? start, force: true)
        if webView.url != nil { webView.reload() }
    }

    /// The address bar: a URL as typed, or a search with his chosen engine.
    func go(_ text: String) {
        if let target = Self.target(for: text, search: shields.settings.search) { webView.load(URLRequest(url: target)) }
    }

    nonisolated static func target(for text: String, search: VaultSearchEngine = .duckDuckGo) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let u = URL(string: t), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme), u.host != nil {
            return u
        }
        if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t), u.host != nil {
            return u
        }
        return search.url(for: t)
    }

    func openPendingPopup() {
        guard let u = pendingPopup else { return }
        pendingPopup = nil
        webView.load(URLRequest(url: u))
    }

    /// Stop everything; the in-memory store goes with the web view.
    func tearDown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        observations.removeAll()
        webView.loadHTMLString("", baseURL: nil)
    }

    nonisolated static func site(_ url: URL?) -> String { VaultShields.site(url) }
}

extension VaultBrowserModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        onActivity?()
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "blob", "data"].contains(scheme) {
            if navigationAction.targetFrame?.isMainFrame ?? true, ["http", "https"].contains(scheme) {
                apply(for: url)          // this site's Shields, before its first byte
            }
            preferences.allowsContentJavaScript = shields.settings.javascript
            preferences.preferredContentMode = desktopSite ? .desktop : .mobile
            decisionHandler(.allow, preferences)
            return
        }
        // tel:, itms-apps:, other apps' links: the private browser never hands off by itself.
        decisionHandler(.cancel, preferences)
        if navigationAction.targetFrame?.isMainFrame ?? true {
            notice = "Blocked a link that would open another app"
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType {
            decisionHandler(.cancel)
            notice = "Downloads are off in the private browser"
            return
        }
        decisionHandler(.allow)
    }

    /// New windows never open. A link meant for a new tab loads here; a pop-up to another site
    /// that wasn't a plain link tap is held back with a one-tap "Open".
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let target = navigationAction.request.url else { return nil }
        let blocking = shields.isOn(for: webView.url) && shields.settings.blockPopups
        if !blocking || navigationAction.navigationType == .linkActivated || Self.site(target) == Self.site(webView.url) {
            webView.load(navigationAction.request)
        } else {
            blockedPopups += 1
            pendingPopup = target
        }
        return nil
    }

    // Pages don't get to put up dialogs.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        completionHandler(nil)
    }

    // Camera, microphone and motion: always no.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onActivity?() }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled, ns.code != 102 else { return }     // 102: a cancel of ours
        notice = ns.localizedDescription
    }
}

/// The browser screen: address on top, back / forward / blocker / more at the bottom.
struct VaultBrowserView: View {
    @StateObject private var model: VaultBrowserModel
    @ObservedObject private var session = VaultSession.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var editing = false
    @State private var address = ""
    @State private var toast: String?
    @State private var showShields = false
    @ObservedObject private var shields = VaultShields.shared
    @FocusState private var addressFocused: Bool

    init(url: URL) {
        _model = StateObject(wrappedValue: VaultBrowserModel(start: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack(alignment: .top) {
                VaultWebView(webView: model.webView)
                    .opacity(model.ready ? 1 : 0)
                if !model.ready {
                    VStack(spacing: 12) {
                        ProgressView().tint(JcTheme.muted)
                        Text("Turning on the ad and tracker blocker…")
                            .font(.system(size: 13)).foregroundStyle(JcTheme.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.isLoading {
                    ProgressView(value: max(model.progress, 0.05))
                        .progressViewStyle(.linear)
                        .tint(JcTheme.text)
                        .frame(height: 2)
                }
            }
            .overlay(alignment: .bottom) {
                if let popup = model.pendingPopup { popupBar(popup) }
            }
            .animation(.easeOut(duration: 0.2), value: model.pendingPopup)
            bottomBar
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .moreToast($toast)
        .task {
            model.onActivity = { VaultSession.shared.touch() }
            await model.begin()
        }
        .task { await keepVaultAwake() }
        .onChange(of: model.notice) { _, n in
            if let n { toast = n; model.notice = nil }
        }
        // Locking the vault (background, the lock button, the hard limit) closes the browser.
        .onChange(of: session.isUnlocked) { _, open in if !open { close() } }
        .sheet(isPresented: $showShields, onDismiss: { model.settingsChanged() }) {
            VaultShieldsSheet(shields: shields, url: model.url, blockedPopups: model.blockedPopups)
                .presentationDetents([.large])
        }
        .onAppear { session.screenAppeared() }
        .onDisappear {
            session.screenDisappeared()
            model.tearDown()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 8) {
            iconButton(editing ? "xmark.circle.fill" : "xmark", editing ? "Cancel" : "Close") {
                if editing { editing = false } else { close() }
            }
            HStack(spacing: 6) {
                JcIcon(model.url?.scheme == "https" ? "lock.fill" : "exclamationmark.triangle", size: 11)
                    .foregroundStyle(JcTheme.muted)
                if editing {
                    TextField("Search or enter address", text: $address)
                        .font(.system(size: 15))
                        .foregroundStyle(JcTheme.text)
                        .textFieldStyle(.plain)
                        .keyboardType(.webSearch)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit {
                            model.go(address)
                            editing = false
                        }
                } else {
                    Text(displayHost)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(JcButton.fill, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                guard !editing else { return }
                address = model.url?.absoluteString ?? ""
                editing = true
                addressFocused = true
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Address, \(displayHost)")
            iconButton(model.isLoading ? "xmark" : "arrow.clockwise", model.isLoading ? "Stop" : "Reload") {
                if model.isLoading { model.webView.stopLoading() } else { model.webView.reload() }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            JcIcon(symbol, size: 15, weight: .semibold)
                .foregroundStyle(JcTheme.text)
                .frame(width: 40, height: 40)
                .background(JcButton.fill, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            barButton("chevron.left", "Back", enabled: model.canGoBack) { model.webView.goBack() }
            barButton("chevron.right", "Forward", enabled: model.canGoForward) { model.webView.goForward() }
            Button { showShields = true } label: {
                barIcon(model.shieldsHere ? "shield.fill" : "shield.slash")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.shieldsHere ? "Shields up" : "Shields down")
            Menu {
                Button(model.desktopSite ? "Request mobile site" : "Request desktop site",
                       jcIcon: model.desktopSite ? "iphone" : "desktopcomputer") {
                    model.desktopSite.toggle()
                    model.webView.reload()
                }
                Button("Open in default browser", jcIcon: "safari") {
                    if let u = model.url { openURL(u) }
                }
                Button("Copy link", jcIcon: "doc.on.doc") {
                    UIPasteboard.general.setItems([[UTType.plainText.identifier: model.url?.absoluteString ?? ""]],
                                                  options: [.localOnly: true,
                                                            .expirationDate: Date().addingTimeInterval(120)])
                    toast = "Link copied"
                }
            } label: {
                barIcon("ellipsis")
            }
            .accessibilityLabel("More")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func barIcon(_ symbol: String) -> some View {
        JcIcon(symbol, size: 18, weight: .medium)
            .foregroundStyle(JcTheme.text)
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(Rectangle())
    }

    private func barButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { barIcon(symbol) }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : JcButton.disabledOpacity)
            .accessibilityLabel(label)
    }

    private func popupBar(_ url: URL) -> some View {
        HStack(spacing: 10) {
            JcIcon("rectangle.on.rectangle.slash", size: 15).foregroundStyle(JcTheme.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pop-up blocked").font(.system(size: 14, weight: .semibold)).foregroundStyle(JcTheme.text)
                Text(url.host ?? url.absoluteString).font(.system(size: 12)).foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Open") { model.openPendingPopup() }
                .buttonStyle(.jcGlass(tint: JcTheme.text))
            Button { model.pendingPopup = nil } label: {
                JcIcon("xmark", size: 13, weight: .semibold).foregroundStyle(JcTheme.muted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .jcLiquidGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var displayHost: String {
        guard let host = model.url?.host else { return model.title.isEmpty ? "Private browser" : model.title }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func close() {
        model.tearDown()
        dismiss()
    }

    /// While a page is open the vault stays unlocked (up to its hard limit): a quiet vault call
    /// every two minutes keeps the server's idle timer from running out mid-read.
    private func keepVaultAwake() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, session.isUnlocked else { return }
            _ = try? await session.call { try await session.api.tree(token: $0) }
        }
    }
}

/// A link to open in the private browser (`.fullScreenCover(item:)`).
struct VaultBrowserTarget: Identifiable {
    let id = UUID()
    let url: URL
}

/// Hosts the model's web view.
private struct VaultWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView {
        webView.isOpaque = false
        webView.backgroundColor = .black
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
