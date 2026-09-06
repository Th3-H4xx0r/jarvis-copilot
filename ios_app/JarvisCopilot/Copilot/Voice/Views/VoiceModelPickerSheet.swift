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
                VStack(alignment: .leading, spacing: 20) {
                    modelSection
                    VoiceEngineSections(store: store)
                    modeSection
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
            GlassSectionLabel("Model")
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
                    GlassSectionLabel(provider.isEmpty ? "Models" : provider)
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

    // MARK: - Mode
    //
    // Flutter hard-codes realtime and has no toggle; ours keeps one because the
    // quality (push-to-talk) lane is still reachable here and the screen itself
    // must stay as clean as the reference.

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassSectionLabel("Turn mode")
            VoiceModeToggle(mode: store.mode, enabled: !store.isActive) { mode in
                Task { await store.setMode(mode) }
            }
            .frame(maxWidth: .infinity)
            Text(store.mode == .realtime
                 ? "Continuous streaming conversation."
                 : "One question per tap, over the quality lane.")
                .font(.system(size: 12))
                .foregroundStyle(JcTheme.muted)
                .padding(.top, 10)
                .padding(.leading, 4)
        }
    }
}

/// The toolbar capsule: the current voice model's name, tappable to change it.
/// Port of `ModelChip(compact: true)` — sparkles, label, chevron, glass pill.
struct VoiceModelChip: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(JcTheme.muted)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 104, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(JcTheme.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(JcTheme.glassFill, in: Capsule())
            .overlay(Capsule().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice model: \(label)")
    }
}

/// The rolling voice debug log, behind a long-press on the status line. Empty
/// until the store adopts ``VoiceDiagnosticsProviding`` — the screen must not
/// depend on a debug hook existing.
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
