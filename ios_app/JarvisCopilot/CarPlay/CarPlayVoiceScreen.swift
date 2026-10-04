import AVFAudio
import CarPlay
import Observation
import UIKit

/// What the car's voice screen shows for each `VoiceState`. CarPlay takes at
/// most five states and opens on the first; idle is not one of them — a
/// finished conversation closes the screen.
@MainActor
enum CarPlayVoiceState {
    static let shown: [VoiceState] = [.connecting, .listening, .thinking, .speaking, .error]

    static func id(for state: VoiceState) -> String? { shown.contains(state) ? state.rawValue : nil }

    /// Longest first: CarPlay picks the first variant that fits the car's screen.
    static func titles(for state: VoiceState, micAllowed: Bool) -> [String] {
        switch state {
        case .connecting: return ["Connecting to Jarvis…", "Connecting…"]
        case .listening: return ["Listening…"]
        case .thinking: return ["Thinking…"]
        case .speaking: return ["Jarvis"]
        case .error:
            // The car can't show the permission prompt, so say where to fix it.
            return micAllowed ? ["Lost the connection — tap Stop", "Lost the connection", "Error"]
                              : ["Allow the microphone on your iPhone", "Allow the mic on your iPhone", "Mic is off"]
        case .idle: return ["Ready"]
        }
    }
}

/// The voice screen on the car: the orb, what Jarvis is doing, Mute and Stop.
/// Recording only ever runs while this template is showing (CarPlay's rule for
/// voice-based conversational apps); Done, Stop or the end of the conversation
/// stops the session and releases the audio session.
@available(iOS 26.4, *)
@MainActor
final class CarPlayVoiceScreen {
    private let ui: CPInterfaceController
    private var template: CPVoiceControlTemplate?
    private var sawActive = false
    private(set) var isShowing = false

    private var store: VoiceStore { .shared }

    init(ui: CPInterfaceController) { self.ui = ui }

    /// Open the screen and start listening (or just start, when it's already open).
    func start() {
        if isShowing {
            begin()
            return
        }
        let micAllowed = AVAudioApplication.shared.recordPermission != .denied
        let template = CPVoiceControlTemplate(voiceControlStates: CarPlayVoiceState.shown.compactMap { state in
            guard let id = CarPlayVoiceState.id(for: state) else { return nil }
            return CPVoiceControlState(identifier: id, titleVariants: CarPlayVoiceState.titles(for: state, micAllowed: micAllowed),
                                       image: OrbFrames.animated(for: state), repeats: true)
        })
        template.leadingNavigationBarButtons = [CPBarButton(title: "Done") { [weak self] _ in self?.close() }]
        self.template = template
        isShowing = true
        sawActive = false
        updateButtons()
        ui.presentTemplate(template, animated: true) { [weak self] _, _ in
            guard let self, self.isShowing else { return }
            if micAllowed { self.begin() } else { template.activateVoiceControlState(withIdentifier: VoiceState.error.rawValue) }
            self.observe()
        }
    }

    func stop() { close() }

    private func begin() {
        Task {
            if !store.isActive { await store.primaryAction() }
            follow()
        }
    }

    private func observe() {
        guard isShowing else { return }
        withObservationTracking {
            _ = store.state; _ = store.muted; _ = store.error
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.follow()
                self?.observe()
            }
        }
    }

    /// Mirror the store onto the template.
    private func follow() {
        guard isShowing, let template else { return }
        if store.state.isActive { sawActive = true }
        if let id = CarPlayVoiceState.id(for: store.state) {
            template.activateVoiceControlState(withIdentifier: id)
        } else if store.error != nil {
            template.activateVoiceControlState(withIdentifier: VoiceState.error.rawValue)   // idle with a reason
        } else if sawActive {
            close(stopVoice: false)                                                         // it ended on its own
            return
        }
        updateButtons()
    }

    /// Realtime: Mute / Unmute. Push-to-talk: Send ends the turn. Stop always.
    /// CarPlay keeps the buttons on each state, so every state gets the same pair.
    private func updateButtons() {
        guard let template else { return }
        let primary: CPButton
        if store.mode == .quality {
            primary = CPButton(image: UIImage(systemName: "arrow.up.circle.fill") ?? UIImage()) { [weak self] _ in
                self?.store.finishSpeaking()
            }
            primary.title = "Send"
        } else {
            primary = CPButton(image: UIImage(systemName: store.muted ? "mic.fill" : "mic.slash.fill") ?? UIImage()) { [weak self] _ in
                self?.store.toggleMute()
                self?.updateButtons()
            }
            primary.title = store.muted ? "Unmute" : "Mute"
        }
        let stop = CPButton(image: UIImage(systemName: "stop.fill") ?? UIImage()) { [weak self] _ in self?.close() }
        stop.title = "Stop"
        for state in template.voiceControlStates { state.actionButtons = [primary, stop] }
        if let active = template.activeStateIdentifier { template.activateVoiceControlState(withIdentifier: active) }
    }

    private func close(stopVoice: Bool = true) {
        guard isShowing else { return }
        isShowing = false
        template = nil
        if stopVoice { Task { await store.stopAll() } }
        ui.dismissTemplate(animated: true, completion: nil)
    }
}
