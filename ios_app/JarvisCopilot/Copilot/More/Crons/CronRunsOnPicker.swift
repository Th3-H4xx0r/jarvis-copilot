import SwiftUI
import Observation

/// What the "Runs on" picker offers: the server's model catalogue (the chat
/// model picker's) and the harness list (the Pod harness picker's).
@Observable
@MainActor
final class CronRunsOnChoices {
    private(set) var catalog: ModelCatalog?
    private(set) var harnesses: [AgentHarness] = []
    private(set) var loaded = false

    func load() async {
        async let models: Void = loadCatalog()
        if let snapshot = try? await HarnessAPI().snapshot() { harnesses = snapshot.harnesses }
        await models
        loaded = true
    }

    func loadCatalog() async {
        if let fresh = try? await ModelsAPI().list() { catalog = fresh }
    }

    /// `@provider:model` for a catalogue entry (the harness editor's form).
    static func ref(for model: ChatModel) -> String {
        model.id.hasPrefix("@") || model.providerID.isEmpty ? model.id : "@\(model.providerID):\(model.id)"
    }

    func model(for ref: String) -> ChatModel? {
        catalog?.models.first { Self.ref(for: $0) == ref }
    }

    /// How a choice reads, from what has loaded; `fallback` (the job's own
    /// server label) covers a harness or model the lists don't have.
    func label(for choice: CronRunsOn, fallback: String = "") -> String {
        switch choice {
        case .default:
            return "Default"
        case .model(let ref):
            if let m = model(for: ref) { return m.provider.isEmpty ? m.label : "\(m.label) · \(m.provider)" }
            return fallback.isEmpty ? HarnessFormat.shortModel(ref) : fallback
        case .harness(let id):
            if let h = harnesses.first(where: { $0.id == id }) { return h.title }
            return fallback.isEmpty ? id : fallback
        }
    }

    var defaultNote: String {
        let model = catalog?.activeModel ?? catalog?.defaultModel ?? ""
        return model.isEmpty ? "The server's default model" : "Server default — \(model)"
    }
}

/// The form row: what the schedule runs on, opening ``CronRunsOnSheet``.
struct CronRunsOnField: View {
    @Binding var selection: CronRunsOn
    let choices: CronRunsOnChoices
    /// The job's own label from the server (covers a harness that is gone).
    var fallbackLabel: String = ""

    @State private var picking = false

    private var symbol: String {
        switch selection {
        case .default: return "sparkles"
        case .model: return "memorychip"
        case .harness: return "point.3.connected.trianglepath.dotted"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            FormFieldLabel("Runs on")
            Button { picking = true } label: {
                GradientBorder(radius: JcTheme.fieldRadius) {
                    HStack(spacing: 10) {
                        JcIcon(symbol).font(.system(size: 16)).foregroundStyle(JcTheme.cyan)
                        Text(choices.label(for: selection, fallback: fallbackLabel))
                            .font(JcText.body.weight(.semibold))
                            .foregroundStyle(JcTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        JcIcon("chevron.down", size: 13, weight: .semibold)
                            .foregroundStyle(JcTheme.muted)
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
                    .padding(.vertical, 13)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Runs on")
            .accessibilityValue(choices.label(for: selection, fallback: fallbackLabel))
        }
        .padding(.bottom, 16)
        .sheet(isPresented: $picking) {
            CronRunsOnSheet(current: selection, choices: choices, fallbackLabel: fallbackLabel) {
                selection = $0
            }
        }
        .task { if !choices.loaded { await choices.load() } }
    }
}

/// Default, a model (the shared catalogue picker), or a harness.
struct CronRunsOnSheet: View {
    let current: CronRunsOn
    let choices: CronRunsOnChoices
    var fallbackLabel: String = ""
    let select: (CronRunsOn) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pickingModel = false
    @State private var pickedModel = false

    private var currentModelRef: String? {
        if case .model(let ref) = current { return ref }
        return nil
    }

    private var isHarness: Bool {
        if case .harness = current { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    GlassGroup {
                        GlassRow(symbol: "sparkles", title: "Default", subtitle: choices.defaultNote,
                                 action: { choose(.default) }) {
                            VoicePickerCheck(on: current == .default)
                        }
                        GlassRow(symbol: "memorychip", title: "A model",
                                 subtitle: currentModelRef.map { choices.label(for: .model($0), fallback: fallbackLabel) }
                                     ?? "Pick one model for every run",
                                 last: true,
                                 action: { pickingModel = true }) {
                            VoicePickerCheck(on: currentModelRef != nil)
                        }
                    }
                    GlassQuietLabel("Harnesses").padding(.top, 16)
                    if choices.loaded && choices.harnesses.isEmpty {
                        Text("No harnesses yet.").font(.footnote).foregroundStyle(JcTheme.muted)
                    } else if choices.harnesses.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        GlassGroup {
                            ForEach(Array(choices.harnesses.enumerated()), id: \.element.id) { index, harness in
                                GlassRow(symbol: "point.3.connected.trianglepath.dotted", title: harness.title,
                                         subtitle: harness.id == "single" ? "Answers with the default model" : nil,
                                         last: index == choices.harnesses.count - 1,
                                         action: { choose(.harness(harness.id)) }) {
                                    VoicePickerCheck(on: current == .harness(harness.id))
                                }
                            }
                        }
                    }
                    if isHarness, case .harness(let id) = current,
                       !choices.harnesses.contains(where: { $0.id == id }), choices.loaded {
                        Text("\(fallbackLabel.isEmpty ? id : fallbackLabel) is no longer available; runs use Default.")
                            .font(.footnote).foregroundStyle(JcTheme.danger).padding(.top, 10)
                    }
                    Text("A harness picks a node for each run and can follow up with review or background steps.")
                        .font(.footnote).foregroundStyle(JcTheme.muted).padding(.top, 14)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .jcScreen("Runs on")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .task { if !choices.loaded { await choices.load() } }
        .sheet(isPresented: $pickingModel, onDismiss: { if pickedModel { dismiss() } }) {
            CatalogModelPickerSheet(title: "Model",
                                    catalog: choices.catalog,
                                    selectedID: currentModelRef.flatMap { choices.model(for: $0)?.id },
                                    showsAuto: false,
                                    load: { await choices.loadCatalog() },
                                    select: { picked in
                                        guard let picked else { return }
                                        pickedModel = true
                                        select(.model(CronRunsOnChoices.ref(for: picked)))
                                    })
        }
    }

    private func choose(_ choice: CronRunsOn) {
        select(choice)
        dismiss()
    }
}
