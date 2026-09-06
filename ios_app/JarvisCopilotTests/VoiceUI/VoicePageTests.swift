import SwiftUI
import XCTest
@testable import JarvisCopilot

/// Presentation helpers + a hosting smoke test for the Voice screen.
///
/// The smoke test really does lay the screen out in a `UIHostingController`, so a
/// crash in the `Canvas` orb, the karaoke `AttributedString` or a nil-unwrap in a
/// toolbar fails here rather than on someone's phone. It is deliberately a
/// LAYOUT check, not a snapshot: pixel comparisons in CI rot instantly.
@MainActor
final class VoicePageTests: XCTestCase {

    // MARK: - Presentation helpers

    func testEveryStateHasACaption() {
        for state in VoiceState.allCases {
            XCTAssertFalse(voiceCaption(for: state).isEmpty, "\(state)")
        }
        XCTAssertEqual(voiceCaption(for: .idle), "Tap the mic to start talking")
        XCTAssertEqual(voiceCaption(for: .listening), "Go ahead, I'm listening…")
    }

    func testStateColoursMatchTheFlutterScreen() {
        XCTAssertEqual(voiceStateColor(.listening), JcTheme.cyan)
        XCTAssertEqual(voiceStateColor(.thinking), JcTheme.accent)
        XCTAssertEqual(voiceStateColor(.connecting), JcTheme.accent)
        XCTAssertEqual(voiceStateColor(.speaking), JcTheme.accentAlt)
        XCTAssertEqual(voiceStateColor(.error), JcTheme.danger)
        XCTAssertEqual(voiceStateColor(.idle), JcTheme.muted)
    }

    func testDeviceSymbolsCoverEveryIconKind() {
        XCTAssertEqual(voiceDeviceSymbol("watch"), "applewatch")
        XCTAssertEqual(voiceDeviceSymbol("tablet"), "ipad")
        XCTAssertEqual(voiceDeviceSymbol("phone"), "iphone")
        XCTAssertEqual(voiceDeviceSymbol("laptop"), "laptopcomputer")
        XCTAssertEqual(voiceDeviceSymbol("desktop"), "desktopcomputer")
        XCTAssertEqual(voiceDeviceSymbol("web"), "globe")
        // Unknown kinds fall back the same way `deviceIconKind` does.
        XCTAssertEqual(voiceDeviceSymbol("toaster"), "desktopcomputer")
    }

    /// The reply auto-scroll follows this: it must point at the segment being
    /// voiced, not the one after it.
    func testActiveSegmentTracksTheSpokenWordCount() {
        var reply = VoiceReply()
        reply.append("One two three.")   // words 0..2
        reply.append("Four five.")       // words 3..4
        reply.append("Six.")             // word 5
        let segments = reply.segments

        XCTAssertEqual(voiceActiveSegment(segments, spokenWords: 0), 0)
        XCTAssertEqual(voiceActiveSegment(segments, spokenWords: 2), 0)
        XCTAssertEqual(voiceActiveSegment(segments, spokenWords: 4), 1)
        XCTAssertEqual(voiceActiveSegment(segments, spokenWords: 6), 2)
        XCTAssertEqual(voiceActiveSegment([], spokenWords: 3), -1)
    }

    func testVoiceTabIndexMatchesTheShell() {
        XCTAssertEqual(voiceTabIndex, AppTab.allCases.firstIndex(of: .voice))
        XCTAssertTrue(orbTickerEnabled(activeTab: voiceTabIndex, ownerTab: voiceTabIndex))
        XCTAssertFalse(orbTickerEnabled(activeTab: voiceTabIndex + 1, ownerTab: voiceTabIndex))
    }

    // MARK: - Hosting smoke test

    func testLaysOutIdleListeningAndSpeaking() {
        let store = mockedStore()

        // Idle — the empty state: caption, orb, state label.
        assertLaysOut(store, name: "idle")

        // Listening — a user transcript and a live mic level.
        _ = store.machine.apply(.startRequested)
        _ = store.machine.apply(.connected)
        store.userTranscript = "What's the weather like?"
        store.amplitude = 0.6
        store.deviceKinds = ["phone", "laptop", "watch"]
        XCTAssertEqual(store.state, .listening)
        assertLaysOut(store, name: "listening")

        // Speaking — a multi-segment reply mid-karaoke, plus a tool pill.
        _ = store.machine.apply(.endOfSpeech)
        store.reply.append("Clear skies today.")
        store.reply.append("Twenty two degrees.")
        store.toolStatus = "Running search_web"
        _ = store.machine.apply(.playbackStarted)
        store.reply.clipStarted(tag: 0, durationMs: 1000)
        store.reply.clipPosition(tag: 0, positionMs: 500)
        XCTAssertEqual(store.state, .speaking)
        XCTAssertGreaterThan(store.spokenWords, 0)
        XCTAssertLessThan(store.spokenWords, store.reply.totalWords)
        assertLaysOut(store, name: "speaking")

        // Error — the banner replaces nothing, it sits under the reply.
        _ = store.machine.apply(.failed("Could not start voice"))
        store.error = "Could not start voice"
        assertLaysOut(store, name: "error")
    }

    func testControlsAndPickerLayOut() {
        let store = mockedStore()
        assertLaysOut(VoiceControls(state: .listening, isActive: true, muted: true,
                                    onPrimary: {}, onMute: {}, onFinish: {}, onInterrupt: {}),
                      name: "controls")
        assertLaysOut(VoiceModeToggle(mode: .realtime, enabled: true) { _ in }, name: "mode")
        assertLaysOut(VoiceStatusPill(state: .thinking, toolStatus: "Running search_web"),
                      name: "pill")
        assertLaysOut(VoiceDeviceRow(kinds: ["phone", "web"]), name: "devices")
        assertLaysOut(VoiceEnginePicker(store: store), name: "picker")
    }

    /// The screen's own furniture after the Flutter-parity pass: the unboxed
    /// status line, the error-as-reply slot, the "Try on server" chip, and the
    /// model chip + combined picker that made the LLM changeable at all.
    func testTheParityComponentsLayOut() {
        let store = mockedStore()
        let models = mockedModels()
        assertLaysOut(VoiceStatusLabel(state: .idle, toolStatus: nil), name: "status-label")
        assertLaysOut(VoiceStatusLabel(state: .thinking, toolStatus: "Running search_web"),
                      name: "status-tool")
        assertLaysOut(VoicePlainReply(text: "Lost the voice connection — tap to try again.",
                                      tint: JcTheme.danger), name: "plain-reply")
        assertLaysOut(VoiceTryServerChip {}, name: "try-server")
        assertLaysOut(VoiceModelChip(label: "Claude Opus 4.7") {}, name: "model-chip")
        assertLaysOut(VoiceModelPickerSheet(store: store, models: models), name: "model-picker")
        assertLaysOut(VoiceDiagnosticsSheet(lines: ["ws open", "hello sent"]), name: "diagnostics")
        assertLaysOut(VoiceDiagnosticsSheet(lines: []), name: "diagnostics-empty")
    }

    /// The chip is the only place the current model is visible, so it must never
    /// render blank — "Auto" is the floor.
    func testTheModelChipAlwaysHasALabel() {
        XCTAssertEqual(mockedModels().chipLabel, "Auto")
    }

    func testOrbAndWaveformLayOutInEveryState() {
        for state in VoiceState.allCases {
            assertLaysOut(VoiceOrb(state: state, amplitude: 0.5, size: 200, animating: false),
                          name: "orb-\(state.rawValue)")
            assertLaysOut(VoiceWaveformView(state: state, amplitude: 0.5, animating: false),
                          name: "wave-\(state.rawValue)")
        }
    }

    // MARK: - Helpers

    /// A store with every platform boundary mocked and no launch latch, so
    /// building the page can't start a turn or touch the mic.
    private func mockedStore() -> VoiceStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/voice/engines", json: ["engines": [], "active": ""])
        transport.route("/api/devices", json: [])
        return VoiceStore(api: api,
                          input: MockAudioInput(),
                          output: MockAudioOutput(),
                          recognizer: MockSpeechRecognizing(),
                          synthesizer: MockVoiceSynthesizing(),
                          audioSession: MockAudioSessionControlling(),
                          connector: MockVoiceSocketConnector(),
                          clock: TestVoiceClock(),
                          keyValueStore: MemoryKeyValueStore(),
                          launch: nil,
                          local: nil)
    }

    /// A model store backed by a mocked catalogue and an in-memory preference
    /// store, so opening the picker can't reach the network or the real defaults.
    private func mockedModels() -> VoiceModelStore {
        let (api, transport) = JarvisAPI.mocked()
        transport.route("/api/models", json: ["groups": [
            ["provider": "Anthropic", "models": [
                ["id": "anthropic/claude-opus-4.7", "label": "Claude Opus 4.7"],
            ]],
        ]])
        return VoiceModelStore(api: api, selection: ModelSelection(store: MemoryKeyValueStore()))
    }

    private func assertLaysOut(_ store: VoiceStore, name: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        assertLaysOut(VoicePage(store: store, models: mockedModels()).environment(AppRouter()),
                      name: name, file: file, line: line)
    }

    private func assertLaysOut(_ view: some View, name: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874) // iPhone 17 Pro Max points
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // `subviews` is not a signal — SwiftUI happily renders a whole screen into
        // one layer. What we can assert is that the layout pass ran and the view
        // asked for real space against the screen-sized proposal (an UNBOUNDED
        // proposal legitimately measures 0 for a `maxHeight: .infinity` screen).
        let fitted = host.sizeThatFits(in: CGSize(width: 402, height: 874))
        XCTAssertGreaterThan(fitted.width, 0, "\(name) has no width", file: file, line: line)
        XCTAssertGreaterThan(fitted.height, 0, "\(name) has no height", file: file, line: line)
        XCTAssertEqual(host.view.bounds.width, 402, accuracy: 0.5, "\(name) did not lay out",
                       file: file, line: line)
    }
}
