import SwiftUI

/// Glasses → Notes & translation → Live captions.
struct LiveCaptionsSettingsView: View {
    private let bridge = LiveLensBridge.shared
    @State private var probing = false

    var body: some View {
        List {
            Section {
                Toggle("Show on glasses", isOn: Binding(get: { bridge.enabled }, set: { bridge.enabled = $0 }))
                Picker("Lens style", selection: Binding(get: { bridge.style }, set: { bridge.style = $0 })) {
                    ForEach(LensCaptionStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(Self.describe(bridge.status)).font(.caption).foregroundStyle(JcTheme.muted)
                if let notice = bridge.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
            } footer: {
                Text("While Live Jarvis records, the lens shows who is speaking and what they say, with Live's translation when there is one. Opening Subtitles on the glasses turns this on; closing it turns it off. It steps aside for AI notes and translation.")
            }
            Section {
                HStack {
                    Text("Fact-check gesture")
                    Spacer()
                    Text(bridge.factCheckGesture == nil ? "Not set" : "Set").foregroundStyle(JcTheme.muted)
                }
                Button(bridge.learningGesture ? "Do the gesture on the glasses…" : "Learn gesture", jcIcon: "hand.tap") {
                    bridge.learnGesture()
                }
                .disabled(bridge.learningGesture)
                if bridge.factCheckGesture != nil {
                    Button("Forget gesture", jcIcon: "trash", role: .destructive) { bridge.forgetGesture() }
                }
                if let notice = bridge.gestureNotice { Text(notice).font(.caption).foregroundStyle(JcTheme.muted) }
            } header: { Text("Glasses gesture") } footer: {
                Text("While captions are on the lens, this gesture on the glasses fact-checks the conversation; the verdict shows on the lens.")
            }
            Section {
                Button(probing ? "Sending test captions…" : "Send test captions", jcIcon: "text.bubble") {
                    probing = true
                    Task { await bridge.sendTestCaptions(); probing = false }
                }
                .disabled(probing)
            } header: { Text("Research") } footer: {
                Text("Three test lines on the chosen lens style for about 20 seconds, to check how they look.")
            }
        }
        .navigationTitle("Live captions")
    }

    static func describe(_ status: LiveLensBridge.Status) -> String {
        switch status {
        case .off: return "Off"
        case .notRecording: return "Waiting for Live to record"
        case .glassesOff: return "Glasses not connected"
        case .pausedForLens: return "Paused while another glasses app is open"
        case .showing: return "Showing on the lens"
        }
    }
}
