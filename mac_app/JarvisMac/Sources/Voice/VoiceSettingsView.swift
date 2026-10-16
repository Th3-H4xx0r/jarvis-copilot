import AVFoundation
import Speech
import SwiftUI

/// Settings → Voice: push to talk and the "Hey Jarvis" wake word.
struct VoiceSettings: View {
    var body: some View {
        Form {
            TalkSection()
            WakeWordSection()
        }
        .formStyle(.grouped)
    }
}

/// Talk to Jarvis: hold one key (Right ⌥…) to talk — it listens while the key
/// is down, and the answer comes in a small island under the notch — or a key
/// combination (Press opens Voice, Hold talks the same way).
struct TalkSection: View {
    @State private var key: FlowKey? = Prefs.talkKey
    private var watcher: TalkKeyWatcher { TalkKeyWatcher.shared }
    private var flow: FlowDictation { FlowDictation.shared }

    var body: some View {
        Section {
            Picker("Hold to talk", selection: $key) {
                Text("Off").tag(FlowKey?.none)
                ForEach(FlowKey.allCases) { k in Text(k.label).tag(FlowKey?.some(k)) }
            }
            .onChange(of: key) { _, k in
                Prefs.talkKey = k
                watcher.sync()
            }
            if let key, TalkKeyChoice.clashes(talk: key, flow: flow.key, flowOn: flow.enabled) {
                let other = TalkKeyChoice.otherKey(than: key)
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Flow dictation is held on \(key.label) too, so it stays Flow's.")
                    Spacer()
                    Button("Move Flow to \(other.label)") {
                        flow.key = other
                        watcher.sync()
                    }
                }
            } else if key != nil && !watcher.trusted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Accessibility is off — Jarvis can't see the key")
                    Spacer()
                    Button("Open System Settings") {
                        flow.askForAccessibility()
                        flow.openAccessibilitySettings()
                    }
                }
            }
            Text("Hold it, say what you need, let go: Jarvis answers in a small island under the notch, which folds when it's done. Click it for the full voice view. Held with another key (⌥E) it types as usual.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text("Shortcut")
                Spacer()
                ShortcutField(action: .talk)
            }
            Text("A key combination instead: Press opens Voice, Hold talks like the key above.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Talk to Jarvis")
        }
    }
}

struct WakeWordSection: View {
    private var wake: WakeWord { WakeWord.shared }

    var body: some View {
        Section {
            Toggle("Listen for “Hey Jarvis”", isOn: Binding(get: { wake.conditions.enabled },
                                                          set: { wake.setEnabled($0) }))
            WakeStatusRow(status: wake.status, problem: wake.problem)
            Text("Say “Hey Jarvis” or “OK Jarvis” and the Jarvis voice panel opens. Speech is recognised on this Mac only, and only while a voice is heard. It pauses while the screen is locked or asleep, in Low Power Mode, while you dictate or record a call, and it waits while an approval or a question needs you.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Wake word")
        }
    }
}

private struct WakeStatusRow: View {
    let status: WakeStatus
    let problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label)
                Spacer()
                if let url = settingsURL {
                    Button("Open System Settings") { SpeechPermissions.open(url) }
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var label: String {
        switch status {
        case .off: return String(localized: "Off")
        case .listening: return String(localized: "Listening for “Hey Jarvis”")
        case .paused(let why): return String(localized: "Paused: \(why)")
        case .unavailable: return String(localized: "No on-device speech recognizer for English on this Mac — turn on Dictation in System Settings → Keyboard")
        case .needsPermission(.microphone): return String(localized: "Microphone access is off")
        case .needsPermission(.speech): return String(localized: "Speech recognition access is off")
        }
    }

    private var color: Color {
        switch status {
        case .listening: return JcAccent.color
        case .paused: return .orange
        case .off: return .secondary
        case .unavailable, .needsPermission: return .red
        }
    }

    private var settingsURL: URL? {
        switch status {
        case .needsPermission(.microphone): return DictationFailure.micDenied.settingsURL
        case .needsPermission(.speech): return DictationFailure.speechDenied.settingsURL
        case .unavailable: return DictationFailure.unavailable("").settingsURL
        default: return nil
        }
    }
}
