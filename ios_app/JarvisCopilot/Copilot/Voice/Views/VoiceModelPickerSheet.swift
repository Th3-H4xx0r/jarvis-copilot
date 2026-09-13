import SwiftUI

/// The Voice screen's one settings sheet: which SERVER MODEL answers, which TTS
/// engine/voice speaks, and (ours, not Flutter's) which turn mode runs.
///
/// Port of `widgets/model_picker_sheet.dart` for `VoiceSurface.voice` — "Auto"
/// on top clearing the override, then the catalogue grouped by provider with the
/// current pick ticked. Flutter reaches the TTS engine from a different entry
/// point; here both live in the sheet the sparkles chip opens, because the phone
/// only has room for one settings button in the bar.
struct VoiceModelPickerSheet: View {
    let store: VoiceStore
    let models: VoiceModelStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // How the conversation works comes first: these change how
                    // every turn behaves, and were buried under the whole model
                    // catalogue.
                    conversationSection
                    modelSection
                    VoiceEngineSections(store: store)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .jcScreen("Voice model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await models.load() }
    }

    // MARK: - Model

    @ViewBuilder
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Model")
            Text("Choose the server model for voice turns.")
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
                .padding(.leading, 4)
                .padding(.bottom, 12)

            GlassGroup {
                GlassRow(symbol: "wand.and.stars",
                         title: "Auto",
                         subtitle: "Server fast lane — fastest replies. Pick a model below to override.",
                         subtitleLineLimit: 2,
                         last: true,
                         action: { models.select(nil); dismiss() }) {
                    VoicePickerCheck(on: models.selectedModelID == nil)
                }
            }

            if models.loading && models.catalog == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if let failure = models.loadError, models.catalog == nil {
                loadFailure(failure)
            } else {
                catalogueGroups
            }
        }
    }

    @ViewBuilder
    private var catalogueGroups: some View {
        // With nothing explicitly chosen, tick where the server actually is, so
        // the sheet still shows "where you are". Same fallback as Flutter's
        // `effectiveSelected`.
        let effective = models.selectedModelID
            ?? models.catalog?.activeModel
            ?? models.catalog?.defaultModel
        let providers = models.catalog?.providers ?? []

        if providers.isEmpty {
            Text("No models available.")
                .font(.system(size: 13))
                .foregroundStyle(JcTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        } else {
            ForEach(providers, id: \.self) { provider in
                let group = models.catalog?.models(for: provider) ?? []
                VStack(alignment: .leading, spacing: 0) {
                    GlassQuietLabel(provider.isEmpty ? "Models" : provider)
                        .padding(.top, 16)
                    GlassGroup {
                        ForEach(Array(group.enumerated()), id: \.element.id) { index, model in
                            GlassRow(symbol: "cpu",
                                     title: model.label,
                                     subtitle: model.label == model.id ? nil : model.id,
                                     last: index == group.count - 1,
                                     action: { models.select(model); dismiss() }) {
                                VoicePickerCheck(on: model.id == effective)
                            }
                        }
                    }
                }
            }
        }
    }

    private func loadFailure(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "icloud.slash")
                .font(.system(size: 26))
                .foregroundStyle(JcTheme.muted)
            Text("Couldn't load models")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(JcTheme.text)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button("Retry") { Task { await models.load(force: true) } }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(JcTheme.accent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Conversation

    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassQuietLabel("Conversation")
            if store.isActive {
                Text("End the conversation to change these.")
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .padding(.leading, 4)
                    .padding(.bottom, 10)
            }

            VoiceOptionHeading("Turn mode")
            VoiceOptionCards(options: VoiceOptionCards.modes, selection: store.mode,
                             enabled: !store.isActive) { mode in
                Task { await store.setMode(mode) }
            }

            VoiceOptionHeading("Transcription")
                .padding(.top, 16)
            VoiceOptionCards(options: VoiceOptionCards.transcriptions, selection: store.transcription,
                             enabled: !store.isActive) { value in
                Task { await store.setTranscription(value) }
            }
            transcriptionStatus
                .padding(.top, 8)
                .padding(.leading, 4)
        }
    }

    /// Only while something is happening: the model downloading, or on-device
    /// transcription unable to run. The cards already say what each choice does.
    @ViewBuilder
    private var transcriptionStatus: some View {
        switch store.transcriptionStatus {
        case .preparing(let fraction):
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini).tint(JcTheme.muted)
                Text(fraction.map { "Downloading speech model… \(Int($0 * 100))%" }
                     ?? "Getting on-device transcription ready…")
            }
            .font(.system(size: 12))
            .foregroundStyle(JcTheme.muted)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.danger)
        case .ready, .idle:
            EmptyView()
        }
    }
}

/// The rolling voice debug log (`VoiceStore.diagnostics`).
struct VoiceDiagnosticsSheet: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if lines.isEmpty {
                    CenteredMessage(text: "No diagnostics yet — start a turn and come back.")
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(JcTheme.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .jcScreen("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
