import AppKit
import AVFoundation
import SwiftUI

/// Settings → Flow, and the Flow window's Settings page: the same sections.
struct FlowSettings: View {
    var body: some View {
        Form {
            FlowDictationSection()
            FlowEngineSection()
            FlowHistorySection()
            NotesSettingsSection()
            Section {
                Button("Open the Flow window") { FlowWindow.show() }
            }
        }
        .formStyle(.grouped)
    }
}

struct FlowDictationSection: View {
    private var flow: FlowDictation { FlowDictation.shared }
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        Section {
            Toggle("Hold a key to dictate anywhere", isOn: Binding(get: { flow.enabled }, set: { flow.setEnabled($0) }))
            Picker("Key", selection: Binding(get: { flow.key }, set: { flow.key = $0 })) {
                ForEach(FlowKey.allCases) { Text($0.label).tag($0) }
            }
            if flow.enabled {
                permissionRow(ok: flow.trusted, okText: String(localized: "Accessibility: allowed"),
                              offText: String(localized: "Accessibility is off — Jarvis can't see the key or paste")) {
                    flow.askForAccessibility()
                    flow.openAccessibilitySettings()
                }
                permissionRow(ok: mic == .authorized || mic == .notDetermined,
                              okText: mic == .authorized ? String(localized: "Microphone: allowed")
                                                         : String(localized: "Microphone: asked the first time you dictate"),
                              offText: String(localized: "Microphone access is off")) {
                    SpeechPermissions.open(DictationFailure.micDenied.settingsURL)
                }
                if let failure = flow.lastFailure {
                    HStack {
                        Text(failure.message).font(.caption).foregroundStyle(.red)
                        Spacer()
                        if let url = failure.settingsURL { Button("Open System Settings") { SpeechPermissions.open(url) } }
                    }
                }
            }
            Text("Hold \(flow.key.label), speak, let go: the words are pasted where you type. Tap it twice for hands-free, until the next tap. Esc cancels. ⌃⌘V pastes the last dictation again.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Flow dictation")
        }
        .onAppear { mic = AVCaptureDevice.authorizationStatus(for: .audio) }
    }

    private func permissionRow(ok: Bool, okText: String, offText: String, fix: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? JcAccent.color : .orange)
            Text(ok ? okText : offText)
            Spacer()
            if !ok { Button("Open System Settings", action: fix) }
        }
    }
}

struct FlowEngineSection: View {
    @State private var engine = Prefs.flowEngine
    @State private var cleanup = Prefs.flowCleanup
    @State private var style = Prefs.flowDefaultStyle
    @State private var detail = ""
    @State private var pick = FlowModelPick(model: Prefs.flowCleanupModel, provider: Prefs.flowCleanupProvider)
    private var catalog: FlowModelCatalog { FlowModelCatalog.shared }

    var body: some View {
        Section {
            Picker("Speech engine", selection: $engine) {
                ForEach(FlowEngine.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: engine) { _, v in
                Prefs.flowEngine = v
                Task { detail = await DictationEngines.describe(v) }
            }
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            Toggle("Clean up the words with a Jarvis model", isOn: $cleanup)
                .onChange(of: cleanup) { _, v in Prefs.flowCleanup = v }
            Text("Removes the “uh”s, repeats and corrections said on the way, fixes punctuation and writes in each app's style. The words then go to your Jarvis server; if it's slow or away they're pasted as heard.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Clean-up model", selection: $pick) {
                Text("Auto — Jarvis picks").tag(FlowModelPick())
                if let model = pick.model, !catalog.groups.contains(where: { g in g.models.contains { $0.id == model } }) {
                    // The saved pick, while the list loads (or if it's gone from it).
                    Text(model).tag(pick)
                }
                ForEach(catalog.groups) { group in
                    Section(group.provider) {
                        ForEach(group.models) { m in
                            Text(m.label).tag(FlowModelPick(model: m.id, provider: group.providerID))
                        }
                    }
                }
            }
            .disabled(!cleanup)
            .onChange(of: pick) { _, v in
                Prefs.flowCleanupModel = v.model
                Prefs.flowCleanupProvider = v.provider
            }
            if let error = catalog.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else {
                Text("A small, fast model keeps you from waiting to paste.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Style for other apps", selection: $style) {
                ForEach(FlowStyle.allCases) { Text($0.label).tag($0) }
            }
            .onChange(of: style) { _, v in Prefs.flowDefaultStyle = v }
            HStack {
                Text("Code and AI apps (VS Code, Terminal, Claude…) get a light clean-up. Set any app's style — or “As said” to skip Jarvis there — in the Flow window.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Styles per app…") { FlowWindow.show(.styles) }
            }
        } header: {
            Text("Words")
        }
        .task {
            detail = await DictationEngines.describe(engine)
            await catalog.load()
        }
    }
}

/// The clean-up model picked in Flow settings: an `/api/models` id and its
/// provider; both nil is Auto.
struct FlowModelPick: Hashable {
    var model: String?
    var provider: String?
}

struct FlowHistorySection: View {
    private var store: FlowStore { FlowStore.shared }
    @State private var confirmClear = false

    var body: some View {
        Section {
            Picker("Keep the history", selection: Binding(get: { store.keepDays }, set: { store.keepDays = $0 })) {
                Text("Not at all").tag(0)
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
                Text("Forever").tag(-1)
            }
            HStack {
                Button("Clear the history") { store.clearHistory() }
                Button("Clear history and stats", role: .destructive) { confirmClear = true }
            }
            .confirmationDialog("Clear the history and every number?", isPresented: $confirmClear) {
                Button("Clear everything", role: .destructive) { store.clearEverything() }
            }
            Text("Dictations stay on this Mac.").font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("History")
        }
    }
}

struct NotesSettingsSection: View {
    @State private var upload = Prefs.notesUpload
    @State private var summarize = Prefs.notesSummarize

    var body: some View {
        Section {
            Toggle("Send finished notes to Jarvis (the phone sees them)", isOn: $upload)
                .onChange(of: upload) { _, v in Prefs.notesUpload = v }
            Toggle("Write a summary and to-dos with a Jarvis model", isOn: $summarize)
                .onChange(of: summarize) { _, v in Prefs.notesSummarize = v }
                .disabled(!upload)
            Text("A call is recorded only when you press Record. Your microphone is “You”, what the Mac plays is “Them”. Audio stays in memory just long enough to be transcribed on this Mac and is never saved; only the text is kept and sent.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Notes")
        }
    }
}
