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

    func models() async throws -> [String: Any] {
        try await api.get("/api/models").object()
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
    private(set) var choices: [ExtractChoice] = WebBrowserStore.choices(models: [:], harnesses: [:])
    private(set) var loaded = false
    private(set) var error = ""

    private let api: WebBrowserAPI

    init(api: WebBrowserAPI = WebBrowserAPI()) {
        self.api = api
    }

    /// Default, then every model (`@provider:model`), then every harness.
    static func choices(models: [String: Any], harnesses: [String: Any]) -> [ExtractChoice] {
        var out = [ExtractChoice(value: "", label: "Default — Claude Haiku 5.5")]
        for g in models.list("groups") {
            let provider = g.string("provider_id") ?? g.string("provider") ?? ""
            for m in g.list("models") {
                guard let id = m.string("id"), !id.isEmpty else { continue }
                let ref = id.hasPrefix("@") ? id : "@\(provider):\(id)"
                out.append(ExtractChoice(value: ref, label: m.string("label") ?? id))
            }
        }
        for h in harnesses.list("harnesses") {
            guard let id = h.string("id"), !id.isEmpty else { continue }
            out.append(ExtractChoice(value: "harness:\(id)", label: "\(h.string("name") ?? id) (harness)"))
        }
        return out
    }

    func load() async {
        do {
            settings = WebBrowserSettings.from(try await api.load())
            loaded = true
            error = ""
        } catch {
            self.error = apiErrorLine(error)
            return
        }
        let models = (try? await api.models()) ?? [:]
        let harnesses = (try? await api.harnesses()) ?? [:]
        choices = Self.choices(models: models, harnesses: harnesses)
    }

    func setExtractModel(_ ref: String) async {
        guard ref != settings.extractModel else { return }
        let old = settings.extractModel
        settings.extractModel = ref
        await commit(["extract_model": ref]) { $0.extractModel = old }
    }

    func setEngine(_ engine: String) async {
        guard engine != settings.engine else { return }
        let old = settings.engine
        settings.engine = engine
        await commit(["engine": engine]) { $0.engine = old }
    }

    func setStealthFallback(_ on: Bool) async {
        guard on != settings.stealthFallback else { return }
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
/// model or a harness), the browser engine, and the stealth fallback.
struct WebBrowserSettingsScreen: View {
    @State private var store = WebBrowserStore.shared

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
        }
        .jcScreen("Web & browser")
        .task { await store.load() }
        .refreshable { await store.load() }
    }

    private var currentLabel: String {
        store.choices.first { $0.value == store.settings.extractModel }?.label
            ?? (store.settings.extractModel.isEmpty ? "Default" : store.settings.extractModel)
    }

    private var extraction: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Extraction model")
            GlassGroup {
                Menu {
                    ForEach(store.choices, id: \.self) { choice in
                        Button {
                            Task { await store.setExtractModel(choice.value) }
                        } label: {
                            if choice.value == store.settings.extractModel {
                                Label(choice.label, systemImage: "checkmark")
                            } else {
                                Text(choice.label)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(currentLabel)
                            .font(JcText.body)
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        Spacer()
                        JcIcon("chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(JcTheme.muted)
                    }
                    .padding(14)
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
            LiveSettingsNote(store.settings.lightpandaInstalled
                ? "Lightpanda is a fast headless browser; pages it can't render move to Chrome, and the site "
                    + "is remembered. Everything runs on the server — your Mac's browser only when you ask."
                : "Lightpanda isn't installed on the server, so Chrome runs.")
        }
    }

    private var stealth: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Blocked pages")
            GlassGroup {
                SwitchRow(symbol: "eye.slash", title: "Stealth fallback",
                          subtitle: "Retry pages that block bots in a stealth browser",
                          isOn: store.settings.stealthFallback, last: true) { on in
                    Task { await store.setStealthFallback(on) }
                }
            }
        }
    }
}
