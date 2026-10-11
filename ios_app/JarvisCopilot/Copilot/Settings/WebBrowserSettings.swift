import SwiftUI

// MARK: - Web & browser

/// The server's web settings (`/api/web/config`) — the same keys the web's
/// Settings → Web & browser block edits. Nothing here is stored on the phone.
struct WebBrowserSettings: Equatable, Sendable {
    /// `@provider:model`, `harness:<id>` (its Route picks per page) or "" (default).
    var extractModel = ""
    /// "lightpanda" (fast; Chrome when a site needs it) or "chrome".
    var engine = "chrome"
    var stealthFallback = true
    var lightpandaInstalled = false

    static func from(_ d: [String: Any]) -> WebBrowserSettings {
        var out = WebBrowserSettings()
        out.apply(d)
        return out
    }

    /// A GET, or a PUT's reply.
    mutating func apply(_ d: [String: Any]) {
        let c = d.dict("config") ?? [:]
        if let v = c.string("extract_model") { extractModel = v }
        if let v = c.string("engine") { engine = v == "lightpanda" ? "lightpanda" : "chrome" }
        if let v = c.bool("stealth_fallback") { stealthFallback = v }
        if let v = d.bool("lightpanda_installed") { lightpandaInstalled = v }
    }
}

struct WebBrowserAPI: Sendable {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) {
        self.api = api
    }

    func load() async throws -> [String: Any] {
        try await api.get("/api/web/config").object()
    }

    func catalog() async throws -> ModelCatalog {
        try await ModelsAPI(api: api).list()
    }

    func harnesses() async throws -> [String: Any] {
        try await api.get("/api/harnesses").object()
    }

    /// PUT a patch (just the key that changed); the reply is the server's view.
    func save(_ patch: [String: Any]) async throws -> [String: Any] {
        try await api.put("/api/web/config", json: patch).object()
    }
}

struct ExtractChoice: Hashable, Sendable {
    let value: String
    let label: String
}

/// Settings → Web & browser on screen. Each change shows at once and is PUT at
/// once; a refusal puts back what the server holds and says why.
@MainActor
@Observable
final class WebBrowserStore {
    static let shared = WebBrowserStore()

    private(set) var settings = WebBrowserSettings()
    private(set) var catalog: ModelCatalog?
    private(set) var harnesses: [ExtractChoice] = []
    private(set) var loaded = false
    private(set) var error = ""

    private let api: WebBrowserAPI

    init(api: WebBrowserAPI = WebBrowserAPI()) {
        self.api = api
    }

    /// Harnesses the extraction can use: those without problems (a harness with
    /// problems would quietly run as the default).
    static func harnessChoices(_ snapshot: [String: Any]) -> [ExtractChoice] {
        snapshot.list("harnesses").compactMap { h in
            guard let id = h.string("id"), !id.isEmpty,
                  ((h["problems"] as? [Any]) ?? []).isEmpty else { return nil }
            return ExtractChoice(value: "harness:\(id)", label: h.string("name") ?? id)
        }
    }

    /// `@provider:model` for a picked model (the harness editor's form); "" = default.
    static func ref(for model: ChatModel?) -> String {
        guard let m = model else { return "" }
        return m.id.hasPrefix("@") || m.providerID.isEmpty ? m.id : "@\(m.providerID):\(m.id)"
    }

    /// What the current choice reads as: "Claude Haiku 5.5 · Anthropic API", a
    /// harness's name, or the default.
    var currentLabel: String {
        let value = settings.extractModel
        if value.isEmpty { return defaultLabel }
        if let h = harnesses.first(where: { $0.value == value }) { return "\(h.label) (harness)" }
        if let m = catalog?.models.first(where: { Self.ref(for: $0) == value }) {
            return m.provider.isEmpty ? m.label : "\(m.label) · \(m.provider)"
        }
        return value.hasPrefix("harness:") ? String(value.dropFirst(8)) : HarnessFormat.shortModel(value)
    }

    let defaultLabel = "Default"
    let defaultNote = "Claude Haiku 5.5 when the Anthropic API key is set, otherwise the helper model."

    func load() async {
        do {
            settings = WebBrowserSettings.from(try await api.load())
            loaded = true
            error = ""
        } catch {
            self.error = apiErrorLine(error)
            return
        }
        harnesses = Self.harnessChoices((try? await api.harnesses()) ?? [:])
        if catalog == nil { await loadCatalog() }
    }

    func loadCatalog() async {
        catalog = (try? await api.catalog()) ?? catalog
    }

    func setExtractModel(_ ref: String) async {
        guard loaded, ref != settings.extractModel else { return }
        let old = settings.extractModel
        settings.extractModel = ref
        await commit(["extract_model": ref]) { $0.extractModel = old }
    }

    func setEngine(_ engine: String) async {
        guard loaded, engine != settings.engine else { return }
        let old = settings.engine
        settings.engine = engine
        await commit(["engine": engine]) { $0.engine = old }
    }

    func setStealthFallback(_ on: Bool) async {
        guard loaded, on != settings.stealthFallback else { return }
        let old = settings.stealthFallback
        settings.stealthFallback = on
        await commit(["stealth_fallback": on]) { $0.stealthFallback = old }
    }

    private func commit(_ patch: [String: Any], revert: (inout WebBrowserSettings) -> Void) async {
        do {
            settings.apply(try await api.save(patch))
            error = ""
        } catch {
            revert(&settings)
            self.error = apiErrorLine(error)
        }
    }
}

/// Settings → Web & browser: which model turns pages into structured data (a
/// model or a harness), the browser engine, and the stealth fallback for page reads.
struct WebBrowserSettingsScreen: View {
    @State private var store = WebBrowserStore.shared
    @State private var picking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                extraction
                engine
                stealth
                if !store.error.isEmpty {
                    Text(store.error)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.danger)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 36)
            .disabled(!store.loaded)
            .opacity(store.loaded ? 1 : 0.5)
        }
        .jcScreen("Web & browser")
        .task { await store.load() }
        .refreshable { await store.load() }
        .sheet(isPresented: $picking) {
            let current = store.settings.extractModel
            CatalogModelPickerSheet(
                title: "Extraction model",
                catalog: store.catalog,
                selectedID: store.catalog?.models.first { WebBrowserStore.ref(for: $0) == current }?.id,
                autoSubtitle: store.defaultNote,
                load: { await store.loadCatalog() },
                select: { picked in Task { await store.setExtractModel(WebBrowserStore.ref(for: picked)) } })
        }
    }

    private var extraction: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Extraction model")
            GlassGroup {
                VStack(spacing: 0) {
                    Button { picking = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.currentLabel)
                                    .font(JcText.body)
                                    .foregroundStyle(JcTheme.text)
                                    .lineLimit(1)
                                if store.settings.extractModel.isEmpty {
                                    Text(store.defaultNote)
                                        .font(.system(size: 12))
                                        .foregroundStyle(JcTheme.muted)
                                }
                            }
                            Spacer()
                            JcIcon("chevron.up.chevron.down", size: 12, weight: .semibold)
                                .foregroundStyle(JcTheme.muted)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Extraction model")
                    .accessibilityValue(store.currentLabel)
                    ForEach(store.harnesses, id: \.self) { h in
                        Divider().overlay(JcTheme.border)
                        Button {
                            Task { await store.setExtractModel(h.value) }
                        } label: {
                            HStack {
                                Text("\(h.label) (harness)")
                                    .font(JcText.body)
                                    .foregroundStyle(JcTheme.text)
                                Spacer()
                                if store.settings.extractModel == h.value {
                                    JcIcon("checkmark", size: 13, weight: .semibold)
                                        .foregroundStyle(JcTheme.accent)
                                }
                            }
                            .padding(14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(store.settings.extractModel == h.value ? .isSelected : [])
                    }
                }
            }
            LiveSettingsNote("Turns a web page into structured data (prices, listings, tables) in one step. "
                           + "Pick a harness to let its Route choose the model for each page.")
        }
    }

    private var engine: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Browser engine")
            GlassGroup {
                Picker("Engine", selection: Binding(
                    get: { store.settings.engine },
                    set: { value in Task { await store.setEngine(value) } })) {
                    Text("Lightpanda first").tag("lightpanda")
                    Text("Chrome only").tag("chrome")
                }
                .pickerStyle(.segmented)
                .padding(14)
            }
            if store.loaded {
                LiveSettingsNote(store.settings.lightpandaInstalled
                    ? "Lightpanda is a fast headless browser; pages it can't render move to Chrome, and the site "
                        + "is remembered. Everything runs on the server — your Mac's browser only when you ask."
                    : "Lightpanda isn't installed on the server, so Chrome runs.")
            }
        }
    }

    private var stealth: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Blocked pages")
            GlassGroup {
                SwitchRow(symbol: "eye.slash", title: "Stealth fallback",
                          subtitle: "Page reads retry sites that block bots in a stealth browser",
                          isOn: store.settings.stealthFallback, last: true) { on in
                    Task { await store.setStealthFallback(on) }
                }
            }
        }
    }
}
