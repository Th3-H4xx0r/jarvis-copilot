import SwiftUI

/// Glasses → Notes & translation → Live captions.
struct LiveCaptionsSettingsView: View {
    private let bridge = LiveLensBridge.shared
    @State private var probing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                CardGroup(footer: "While Live Jarvis records, the lens shows who is speaking and what they say, with Live's translation when there is one. Opening Subtitles on the glasses turns this on; closing it turns it off. It steps aside for AI notes and translation.") {
                    Row { Toggle("Show on glasses", isOn: Binding(get: { bridge.enabled }, set: { bridge.enabled = $0 })) }
                    RowDivider()
                    Row {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Lens style").foregroundStyle(JcTheme.text)
                            JcSegmented(items: LensCaptionStyle.allCases,
                                        selection: Binding(get: { bridge.style }, set: { bridge.style = $0 }),
                                        label: { $0.label })
                        }
                    }
                    RowDivider()
                    Row {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Self.describe(bridge.status)).font(JcText.small).foregroundStyle(JcTheme.muted)
                            if let notice = bridge.notice { Text(notice).font(JcText.small).foregroundStyle(JcTheme.amber) }
                        }
                    }
                }
                CardGroup("Glasses gesture", footer: "While captions are on the lens, this gesture fact-checks the conversation and the verdict shows on the lens. The glasses keep taps and swipes to themselves — only gestures that open or leave a glasses app reach the phone. Good choices: the back/exit gesture while captions show (captions come straight back), or a long-press of the GO button.") {
                    Row {
                        HStack {
                            Text("Fact-check gesture").foregroundStyle(JcTheme.text)
                            Spacer()
                            Text(bridge.factCheckGesture == nil ? "Not set" : "Set").foregroundStyle(JcTheme.muted)
                        }
                    }
                    RowDivider()
                    Row {
                        HStack(spacing: 10) {
                            Button(bridge.learningGesture ? "Do the gesture on the glasses…" : "Learn gesture", jcIcon: "hand.tap") {
                                bridge.learnGesture()
                            }
                            .buttonStyle(.jcGlass(compact: true))
                            .disabled(bridge.learningGesture)
                            if bridge.factCheckGesture != nil {
                                Button("Forget", jcIcon: "trash") { bridge.forgetGesture() }
                                    .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
                            }
                        }
                    }
                    if let notice = bridge.gestureNotice {
                        RowDivider()
                        Row { Text(notice).font(JcText.small).foregroundStyle(JcTheme.muted) }
                    }
                }
                CardGroup("Research", footer: "Three test lines on the chosen lens style for about 20 seconds, to check how they look.") {
                    Row {
                        Button(probing ? "Sending test captions…" : "Send test captions", jcIcon: "text.bubble") {
                            probing = true
                            Task { await bridge.sendTestCaptions(); probing = false }
                        }
                        .buttonStyle(.jcGlass(compact: true))
                        .disabled(probing)
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .tint(JcTheme.accent)
        .jcPageChrome("Live captions")
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
