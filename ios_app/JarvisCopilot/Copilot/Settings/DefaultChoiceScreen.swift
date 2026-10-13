import SwiftUI

// MARK: - Default

/// Settings → Default: the one default — a harness, or a single model (the
/// Single harness answering with `model.default`). Chats, voice, the Mac, the
/// Pod, Telegram/iMessage and schedules follow it unless they have their own
/// pick. Nothing here is stored on the phone.
@MainActor
@Observable
final class DefaultChoiceStore {
    let harnesses: HarnessStore
    private(set) var catalog: ModelCatalog?
    /// `model.default` as the server reports it (a bare id or `@provider:model`).
    private(set) var defaultModel = ""

    @ObservationIgnored private let models: ModelsAPI

    init(harnesses: HarnessStore? = nil, api: JarvisAPI = .shared) {
        self.harnesses = harnesses ?? .shared
        self.models = ModelsAPI(api: api)
    }

    func load() async {
        await harnesses.refresh()
        await loadCatalog()
    }

    func loadCatalog() async {
        guard let fresh = try? await models.list() else { return }
        catalog = fresh
        defaultModel = fresh.defaultModel
    }

    /// Harnesses the default can be: those without problems (one with problems
    /// would quietly run as Single). Single itself is the model row.
    var harnessChoices: [AgentHarness] {
        harnesses.harnesses.filter { $0.id != "single" && ($0.problems ?? []).isEmpty }
    }

    var isHarnessDefault: Bool { harnesses.effective("default") != "single" }

    /// The model Single answers with, by its catalogue name.
    var modelLabel: String {
        guard !defaultModel.isEmpty else { return "Server default" }
        if let m = catalog?.models.first(where: { $0.id == defaultModel || WebBrowserStore.ref(for: $0) == defaultModel }) {
            return m.label
        }
        return HarnessFormat.shortModel(defaultModel)
    }

    /// The catalogue row behind `model.default`, for the picker's tick.
    var defaultModelID: String? {
        catalog?.models.first { $0.id == defaultModel || WebBrowserStore.ref(for: $0) == defaultModel }?.id
    }

    var currentLabel: String {
        isHarnessDefault ? harnesses.title(for: harnesses.effective("default")) : modelLabel
    }

    func chooseHarness(_ id: String) async {
        await harnesses.assign(id, to: "default")
    }

    /// A model as the default: the model, then Single (only if the model took).
    func chooseModel(_ model: ChatModel) async {
        let ref = WebBrowserStore.ref(for: model)
        if await harnesses.setDefaultModel(ref) { defaultModel = ref }
    }

    /// "Model for Single and fallbacks": the model only; the harness stays the default.
    func chooseSingleModel(_ model: ChatModel) async {
        let ref = WebBrowserStore.ref(for: model)
        if await harnesses.setSingleModel(ref) { defaultModel = ref }
    }
}

/// Which picker sheet is up: the model as the default, or Single's model only.
private enum DefaultModelPick: String, Identifiable {
    case asDefault, forSingle
    var id: String { rawValue }
}

struct DefaultChoiceScreen: View {
    @State private var store = DefaultChoiceStore()
    @State private var picking: DefaultModelPick?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                harnessSection
                modelSection
                if let message = store.harnesses.errorMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.danger)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .jcScreen("Default")
        .task { await store.load() }
        .refreshable { await store.load() }
        .sheet(item: $picking) { pick in
            CatalogModelPickerSheet(
                title: pick == .asDefault ? "Default model" : "Model for Single",
                catalog: store.catalog,
                selectedID: store.defaultModelID,
                showsAuto: false,
                load: { await store.loadCatalog() },
                select: { picked in
                    guard let picked else { return }
                    Task {
                        if pick == .asDefault { await store.chooseModel(picked) }
                        else { await store.chooseSingleModel(picked) }
                    }
                })
        }
    }

    private var harnessSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Harnesses")
            if store.harnessChoices.isEmpty {
                GlassGroup {
                    GlassRow(symbol: "flowchart", title: store.harnesses.isLoading ? "Loading…" : "No harnesses yet",
                             subtitle: "Build one in More → Harnesses", last: true) { EmptyView() }
                }
            } else {
                GlassGroup {
                    ForEach(Array(store.harnessChoices.enumerated()), id: \.element.id) { index, harness in
                        GlassRow(symbol: "point.3.connected.trianglepath.dotted", title: harness.title,
                                 last: index == store.harnessChoices.count - 1,
                                 action: { Task { await store.chooseHarness(harness.id) } }) {
                            VoicePickerCheck(on: store.harnesses.effective("default") == harness.id)
                        }
                        .accessibilityAddTraits(store.harnesses.effective("default") == harness.id ? .isSelected : [])
                    }
                }
            }
            LiveSettingsNote("Chats, voice, your Mac and Pod, Telegram/iMessage and schedules run this unless "
                           + "they have their own pick (More → Harnesses for Voice and Chat).")
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Single model")
            GlassGroup {
                GlassRow(symbol: "sparkles", title: "Single model…",
                         subtitle: store.isHarnessDefault ? "One model answers everything" : store.modelLabel,
                         last: !store.isHarnessDefault,
                         action: { picking = .asDefault }) {
                    VoicePickerCheck(on: !store.isHarnessDefault)
                }
                .accessibilityAddTraits(store.isHarnessDefault ? [] : .isSelected)
                if store.isHarnessDefault {
                    GlassRow(symbol: "arrow.uturn.backward", title: "Model for Single and fallbacks",
                             subtitle: store.modelLabel, last: true,
                             action: { picking = .forSingle }) {
                        JcIcon("chevron.up.chevron.down", size: 12, weight: .semibold)
                            .foregroundStyle(JcTheme.muted)
                    }
                }
            }
            if store.isHarnessDefault {
                LiveSettingsNote("Single answers with this model, and a turn whose harness can't run falls back to it.")
            }
        }
    }
}
