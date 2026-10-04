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

    /// The car can't answer a permission prompt, so only a mic already granted counts.
    static func micAllowed(_ permission: AVAudioApplication.recordPermission) -> Bool { permission == .granted }

    /// CarPlay rate-limits state changes; re-sending the shown state could swallow the next real one.
    static func needsActivation(active: String?, next: String) -> Bool { active != next }

    /// Longest first: CarPlay picks the first variant that fits the car's screen.
    static func titles(for state: VoiceState, micAllowed: Bool) -> [String] {
        switch state {
        case .connecting: return ["Connecting to Jarvis…", "Connecting…"]
        case .listening: return ["Listening…"]
        case .thinking: return ["Thinking…"]
        case .speaking: return ["Speaking"]
        case .error:
            // The car can't show the permission prompt, so say where to fix it.
            return micAllowed ? ["Lost the connection — tap End", "Lost the connection", "Error"]
                              : ["Allow the microphone on your iPhone", "Allow the mic on your iPhone", "Mic is off"]
        case .idle: return ["Ready"]
        }
    }
}

/// How the car's voice screen follows the voice session. CarPlay lets a voice app
/// record only while its voice screen shows, so an active session always gets the
/// screen — however it started (Talk, the widget, a restart between turns).
@MainActor
enum CarPlayVoiceMirror {
    enum Step: Equatable { case none, show, activate(String), hideSoon }

    static func step(state: VoiceState, hasError: Bool, showing: Bool, stopping: Bool) -> Step {
        guard showing else { return state.isActive && !stopping ? .show : .none }
        if let id = CarPlayVoiceState.id(for: state) { return .activate(id) }
        return hasError ? .activate(VoiceState.error.rawValue) : .hideSoon
    }
}

/// The voice card on the car: Apple's voice template as an iOS 27 overlay at the bottom
/// of the Voice tab — the phone's orb animating per state (it only renders in the overlay,
/// never in the full-screen presentation), the status, Mute and End — with the
/// conversation text readable above it. End (or Done) stops the session and releases the
/// audio session; a session that goes quiet for a moment closes it.
@available(iOS 26.4, *)
@MainActor
final class CarPlayVoiceScreen {
    private let ui: CPInterfaceController
    private var template: CPVoiceControlTemplate?
    private(set) var isShowing = false
    private var isOverlay = false
    private var watching = false
    /// The driver stopped it: the session winding down mustn't bring the screen back.
    private var stopping = false
    /// Showing the microphone message: it stays until Stop, not a timed hide.
    private var pinned = false
    private var hideTask: Task<Void, Never>?

    private var store: VoiceStore { .shared }

    init(ui: CPInterfaceController) { self.ui = ui }

    /// Follow the voice session from now on (the car connected).
    func attach() {
        guard !watching else { return }
        watching = true
        observe()
        follow()
    }

    /// The car disconnected or Jarvis left the screen: stop following, end any session.
    func stop() {
        watching = false
        close()
    }

    /// Talk: open the screen and start listening (or just start, when it's already open).
    func start() {
        stopping = false
        if isShowing { begin() } else { show(talk: true) }
    }

    /// Whether `template` is this screen's (the coordinator asks when a template disappears).
    func owns(_ other: CPTemplate) -> Bool { template === other }

    /// The system took the screen away: recording can't go on without it.
    func templateGone() {
        guard isShowing else { return }
        isShowing = false
        template = nil
        stopping = true
        Task { await store.stopAll() }
    }

    private func show(talk: Bool) {
        let micAllowed = CarPlayVoiceState.micAllowed(AVAudioApplication.shared.recordPermission)
        let template = CPVoiceControlTemplate(voiceControlStates: CarPlayVoiceState.shown.compactMap { state in
            guard let id = CarPlayVoiceState.id(for: state) else { return nil }
            return CPVoiceControlState(identifier: id, titleVariants: CarPlayVoiceState.titles(for: state, micAllowed: micAllowed),
                                       image: OrbFrames.animated(for: state), repeats: true)
        })
        template.leadingNavigationBarButtons = [CPBarButton(title: "Done") { [weak self] _ in self?.close() }]
        self.template = template
        isShowing = true
        pinned = !micAllowed
        buttonsKey = nil
        updateButtons()
        let shown: (Bool) -> Void = { [weak self] presented in
            guard let self, self.template === template else { return }
            guard presented else {                       // CarPlay refused it: nothing shows, so nothing may record
                self.isShowing = false
                self.template = nil
                if self.store.isActive { self.stopping = true; Task { await self.store.stopAll() } }
                return
            }
            if !micAllowed {
                self.activate(VoiceState.error.rawValue)
            } else if talk {
                self.begin()
            }
            self.follow()
        }
        if #available(iOS 27.0, *) {
            isOverlay = true
            ui.showOverlayTemplate(template, animated: true) { presented, _ in shown(presented) }
            return
        }
        isOverlay = false
        let present = { [weak self] in
            self?.ui.presentTemplate(template, animated: true) { presented, _ in shown(presented) }
        }
        // An alert or choice sheet is already up (a widget tap mid-alert): it goes first.
        if ui.presentedTemplate != nil {
            ui.dismissTemplate(animated: false) { _, _ in present() }
        } else {
            present()
        }
    }

    private func begin() {
        Task {
            if !store.isActive { await store.primaryAction() }
            follow()
        }
    }

    private func observe() {
        guard watching else { return }
        withObservationTracking {
            _ = store.state; _ = store.muted; _ = store.error
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.follow()
                self?.observe()
            }
        }
    }

    /// Mirror the session onto the screen.
    private func follow() {
        guard watching else { return }
        switch CarPlayVoiceMirror.step(state: store.state, hasError: store.error != nil, showing: isShowing, stopping: stopping) {
        case .none: break
        case .show: show(talk: false)
        case .activate(let id):
            hideTask?.cancel()
            hideTask = nil
            activate(id)
            updateButtons()
        case .hideSoon:
            guard !pinned, hideTask == nil else { break }
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled, !self.store.isActive, self.store.error == nil else { return }
                self.hideTask = nil
                self.close(stopVoice: false)
            }
        }
        if !store.state.isActive { stopping = false }
    }

    private func activate(_ id: String) {
        guard let template, CarPlayVoiceState.needsActivation(active: template.activeStateIdentifier, next: id) else { return }
        template.activateVoiceControlState(withIdentifier: id)
    }

    /// Realtime: Mute / Unmute. Push-to-talk: Send ends the turn. End always.
    /// CarPlay keeps the buttons on each state, so every state gets the same pair;
    /// they are only rebuilt when what they say changes.
    private var buttonsKey: String?

    private func updateButtons() {
        guard let template else { return }
        let key = "\(store.mode.rawValue)-\(store.muted)"
        guard key != buttonsKey else { return }
        buttonsKey = key
        let primary: CPButton
        if store.mode == .quality {
            primary = CPButton(image: UIImage(systemName: "arrow.up.circle.fill") ?? UIImage()) { [weak self] _ in
                self?.store.finishSpeaking()
            }
            primary.title = "Send"
        } else {
            primary = CPButton(image: UIImage(systemName: store.muted ? "mic.slash" : "mic") ?? UIImage()) { [weak self] _ in
                self?.store.toggleMute()
                self?.updateButtons()
            }
            primary.title = store.muted ? "Unmute" : "Mute"
        }
        let stop = CPButton(image: UIImage(systemName: "xmark") ?? UIImage()) { [weak self] _ in self?.close() }
        stop.title = "End"
        for state in template.voiceControlStates { state.actionButtons = [primary, stop] }
    }

    private func close(stopVoice: Bool = true) {
        hideTask?.cancel()
        hideTask = nil
        pinned = false
        if stopVoice, store.isActive {
            stopping = true
            Task { await store.stopAll() }
        }
        guard isShowing else { return }
        isShowing = false
        template = nil
        if #available(iOS 27.0, *), isOverlay {
            ui.hideOverlayTemplate(animated: true, completion: nil)
        } else {
            ui.dismissTemplate(animated: true, completion: nil)
        }
    }
}
