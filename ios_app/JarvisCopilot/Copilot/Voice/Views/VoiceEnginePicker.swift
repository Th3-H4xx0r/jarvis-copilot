import SwiftUI

/// Which TTS engine (and voice within it) speaks the replies. Port of the engine
/// half of `widgets/model_picker_sheet.dart`.
///
/// Only `engines.usable` is offered: an engine the server can't run (missing API
/// key) would 500 the moment it tried to synthesize, and the user has no way to
/// fix that from the phone.
///
/// The sections are a standalone view so ``VoiceModelPickerSheet`` can show the
/// LLM model and the speaking voice in ONE sheet — the Flutter app splits them
/// across two entry points, but the user only ever has one "voice settings"
/// button to reach for.
struct VoiceEngineSections: View {
    let store: VoiceStore

    /// The engine whose voices are listed. Starts at the current selection.
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if store.engines.usable.isEmpty {
                CenteredMessage(text: "No usable voice engine — the server has none configured.")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                engineList
                voiceList
            }
        }
        .task {
            expanded = store.selectedEngine
            await store.loadEngines()
            if expanded == nil { expanded = store.engines.active }
        }
    }

    private var engineList: some View {
        VStack(alignment: .leading, spacing: 0) {
            GlassSectionLabel("Speaking voice")
            GlassGroup {
                // "Server default" — clears the override so the server picks.
                GlassRow(symbol: "wand.and.stars", title: "Server default",
                         subtitle: store.engines.active.isEmpty ? nil : store.engines.active,
                         action: {
                             store.selectEngine(nil)
                             expanded = nil
                         }) {
                    VoicePickerCheck(on: store.selectedEngine == nil)
                }
                let usable = store.engines.usable
                ForEach(Array(usable.enumerated()), id: \.element.id) { index, engine in
                    GlassRow(symbol: "waveform.circle",
                             title: engine.name,
                             subtitle: engine.active ? "Server's current engine" : nil,
                             last: index == usable.count - 1,
                             action: {
                                 store.selectEngine(engine.id)
                                 expanded = engine.id
                             }) {
                        VoicePickerCheck(on: store.selectedEngine == engine.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var voiceList: some View {
        if let id = expanded,
           let engine = store.engines.usable.first(where: { $0.id == id }),
           !engine.voices.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                GlassSectionLabel("Voice")
                GlassGroup {
                    GlassRow(symbol: "person.wave.2", title: "Engine default",
                             action: { store.selectEngine(engine.id, voice: nil) }) {
                        VoicePickerCheck(on: store.selectedVoice == nil)
                    }
                    ForEach(Array(engine.voices.enumerated()), id: \.element) { index, voice in
                        GlassRow(symbol: "person.wave.2", title: voice,
                                 last: index == engine.voices.count - 1,
                                 action: { store.selectEngine(engine.id, voice: voice) }) {
                            VoicePickerCheck(on: store.selectedVoice == voice)
                        }
                    }
                }
            }
        }
    }
}

/// The engine sections on their own, for anywhere that wants just the TTS pick.
struct VoiceEnginePicker: View {
    let store: VoiceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VoiceEngineSections(store: store)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .jcScreen("Voice engine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The blue tick every picker row uses when it is the current choice — Flutter's
/// `Icon(Icons.check_rounded, color: JcTheme.primaryBlueHi)`.
struct VoicePickerCheck: View {
    let on: Bool

    var body: some View {
        if on {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(JcTheme.primaryBlueHi)
        }
    }
}
