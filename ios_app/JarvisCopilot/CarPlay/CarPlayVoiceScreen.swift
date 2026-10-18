import AVFAudio
import CarPlay
import Combine
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
    /// The next start is the Talk widget's: one answer, then the mic goes off.
    private var wantsOneAnswer = false
    private(set) var isShowing = false {
        didSet { if isShowing != oldValue { cpDiag("card isShowing=\(isShowing)"); onShowingChange?() } }
    }
    /// The card opened or closed (the Voice tab moves its header out of the way).
    var onShowingChange: (() -> Void)?
    private var isOverlay = false
    private var watching = false
    /// The driver stopped it: the session winding down mustn't bring the screen back.
    private var stopping = false
    /// Showing the microphone message: it stays until Stop, not a timed hide.
    private var pinned = false
    private var hideTask: Task<Void, Never>?
    /// The call or text waiting for his answer (SendConfirmations): while it waits the card
    /// shows the person — photo, "Text Shabd: “hello”" — with Send and Cancel, and keeps
    /// listening for a spoken yes or no. Never a screen of its own: pushing one hides this
    /// card, and with it the microphone (2026-10-18 11:38).
    private var confirm: SendConfirmations.Card?
    private var confirmFeed: AnyCancellable?

    private var store: VoiceStore { .shared }

    init(ui: CPInterfaceController) { self.ui = ui }

    /// Follow the voice session from now on (the car connected).
    func attach() {
        guard !watching else { return }
        watching = true
        observe()
        let center = SendConfirmations.shared
        // @Published sends the new values before the store changes: use them.
        confirmFeed = center.$card.combineLatest(center.$outcome)
            .sink { [weak self] card, outcome in
                Task { @MainActor in self?.confirmChanged(outcome == nil ? card : nil) }
            }
        follow()
    }

    /// The car disconnected or Jarvis left the screen: stop following, end any session.
    func stop() {
        watching = false
        confirmFeed = nil
        close()
    }

    /// Talk: open the screen and start listening (or just start, when it's already open).
    /// `oneShot`: one answer, then the mic goes off (the Talk widget's orb).
    func start(oneShot: Bool = false) {
        stopping = false
        if oneShot { wantsOneAnswer = true }
        if isShowing { begin() } else { show(talk: true) }
    }

    /// Whether `template` is this screen's (the coordinator asks when a template disappears).
    func owns(_ other: CPTemplate) -> Bool { template === other }

    /// A voice card appeared that isn't the live one: CarPlay brings back a card it only hid
    /// (a screen pushed over it, then Back) after the session already ended with it. Its
    /// Stop has nothing to stop and it would sit there saying "Speaking" — take it away.
    func templateAppeared(_ other: CPTemplate) {
        guard other is CPVoiceControlTemplate, other !== template, !isShowing else { return }
        cpDiag("stray voice card; hiding it")
        if #available(iOS 27.0, *) { ui.hideOverlayTemplate(animated: true, completion: nil) }
    }

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
        let template = makeTemplate(micAllowed: micAllowed)
        self.template = template
        isShowing = true
        pinned = !micAllowed
        buttonsKey = nil
        updateButtons()
        // Voice starts now, beside the card's animation: waiting for the card to
        // finish presenting put ~0.6 s between the tap and the mic. If CarPlay
        // refuses the card, the completion below stops it again.
        if micAllowed, talk { begin() } else { wantsOneAnswer = false }
        let shown: (Bool) -> Void = { [weak self] presented in
            cpDiag("overlay presented=\(presented)")
            guard let self, self.template === template else { return }
            guard presented else {                       // CarPlay refused it: nothing shows, so nothing may record
                self.isShowing = false
                self.template = nil
                if self.store.isActive { self.stopping = true; Task { await self.store.stopAll() } }
                return
            }
            if !micAllowed { self.activate(VoiceState.error.rawValue) }
            // The state may have changed while the card was animating in: say it again
            // now that it is on screen.
            if let id = template.activeStateIdentifier { template.activateVoiceControlState(withIdentifier: id) }
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
        let once = wantsOneAnswer
        wantsOneAnswer = false
        Task {
            if once {
                // The car's own start may already be running: it becomes the one answer,
                // or — mid-reply, or holding to talk — it starts over as one.
                let started = store.isActive ? false : await store.startOneShotTurn()
                if !started, store.isActive, !store.answerOnce() {
                    await store.stopAll()
                    _ = await store.startOneShotTurn()
                }
            } else if !store.isActive {
                await store.primaryAction()
            }
            follow()
        }
    }

    private func observe() {
        guard watching else { return }
        withObservationTracking {
            _ = store.shownState; _ = store.muted; _ = store.error
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
        switch CarPlayVoiceMirror.step(state: store.shownState, hasError: store.error != nil, showing: isShowing, stopping: stopping) {
        case .none: break
        case .show: show(talk: false)
        case .activate(let id):
            hideTask?.cancel()
            hideTask = nil
            activate(confirm.map(CarPlayConfirmText.stateID) ?? id)
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
        guard let template else { return }
        // A card made while a call/text waited has no "connecting" (five states at most).
        let ids = template.voiceControlStates.map(\.identifier)
        guard let next = ids.contains(id) ? id : (ids.contains(VoiceState.listening.rawValue) ? VoiceState.listening.rawValue : nil),
              CarPlayVoiceState.needsActivation(active: template.activeStateIdentifier, next: next) else { return }
        template.activateVoiceControlState(withIdentifier: next)
    }

    /// The card's states: the voice states with the orb — and, while a call or text waits, that
    /// first (CarPlay opens on the first), in place of "connecting" (five at most).
    private func makeTemplate(micAllowed: Bool) -> CPVoiceControlTemplate {
        var states: [CPVoiceControlState] = []
        if let confirm {
            states.append(CPVoiceControlState(identifier: CarPlayConfirmText.stateID(confirm),
                                              titleVariants: CarPlayConfirmText.titles(confirm),
                                              image: CarPlayConfirmText.avatar(confirm), repeats: false))
        }
        for state in CarPlayVoiceState.shown where !(confirm != nil && state == .connecting) {
            guard let id = CarPlayVoiceState.id(for: state) else { continue }
            states.append(CPVoiceControlState(identifier: id, titleVariants: CarPlayVoiceState.titles(for: state, micAllowed: micAllowed),
                                              image: OrbFrames.animated(for: state), repeats: true))
        }
        return CPVoiceControlTemplate(voiceControlStates: states)
    }

    /// A call or text started or stopped waiting for his answer.
    private func confirmChanged(_ card: SendConfirmations.Card?) {
        guard card?.id != confirm?.id || (card == nil) != (confirm == nil) else { return }
        confirm = card
        guard isShowing, let template else { return }   // a card opened later is made with it
        if let card, !template.voiceControlStates.contains(where: { $0.identifier == CarPlayConfirmText.stateID(card) }) {
            swapTemplate()
        } else {
            buttonsKey = nil
            follow()
        }
    }

    /// The same card with this call/text's state: put up in place of the old one. Its
    /// disappearance isn't him closing it — the session goes on.
    private func swapTemplate() {
        let micAllowed = CarPlayVoiceState.micAllowed(AVAudioApplication.shared.recordPermission)
        let new = makeTemplate(micAllowed: micAllowed)
        template = new
        buttonsKey = nil
        updateButtons()
        let present: () -> Void = { [weak self] in
            guard let self, self.template === new else { return }
            let shown: (Bool) -> Void = { [weak self] presented in
                cpDiag("card swapped for a confirmation presented=\(presented)")
                guard let self, self.template === new else { return }
                guard presented else {
                    self.isShowing = false
                    self.template = nil
                    if self.store.isActive { self.stopping = true; Task { await self.store.stopAll() } }
                    return
                }
                self.follow()
            }
            if #available(iOS 27.0, *), self.isOverlay {
                self.ui.showOverlayTemplate(new, animated: false) { presented, _ in shown(presented) }
            } else {
                self.ui.presentTemplate(new, animated: false) { presented, _ in shown(presented) }
            }
        }
        if #available(iOS 27.0, *), isOverlay {
            ui.hideOverlayTemplate(animated: false) { _, _ in present() }
        } else {
            ui.dismissTemplate(animated: false) { _, _ in present() }
        }
    }

    /// Realtime: Mute / Unmute. Push-to-talk: Send ends the turn. Stop always — the
    /// card's one way out (no separate Done button doing the same thing).
    /// CarPlay keeps the buttons on each state, so every state gets the same pair;
    /// they are only rebuilt when what they say changes.
    private var buttonsKey: String?

    private func updateButtons() {
        guard let template else { return }
        let key = "\(store.mode.rawValue)-\(store.muted)-\(confirm?.id ?? "")"
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
        let stop = CPButton(image: UIImage(systemName: "stop.fill") ?? UIImage()) { [weak self] _ in self?.close() }
        stop.title = "Stop"
        let confirmButtons = confirm.map { card in
            CarPlayConfirmText.buttons(card).map { spec -> CPButton in
                let button = CPButton(image: UIImage(systemName: spec.symbol) ?? UIImage()) { _ in
                    Task { await SendConfirmations.shared.tap(yes: spec.yes) }
                }
                button.title = spec.title
                return button
            }
        }
        for state in template.voiceControlStates {
            if let confirm, state.identifier == CarPlayConfirmText.stateID(confirm), let confirmButtons {
                state.actionButtons = confirmButtons
            } else {
                state.actionButtons = [primary, stop]
            }
        }
    }

    private func close(stopVoice: Bool = true) {
        wantsOneAnswer = false
        hideTask?.cancel()
        hideTask = nil
        pinned = false
        // Stop always stops: an errored session too (its mic may be retrying).
        if stopVoice, store.state != .idle {
            stopping = true
            Task { await store.stopAll() }
        }
        guard isShowing else {
            // A card the session no longer owns (it came back after a push) still goes.
            if #available(iOS 27.0, *) { ui.hideOverlayTemplate(animated: true, completion: nil) }
            return
        }
        isShowing = false
        template = nil
        if #available(iOS 27.0, *), isOverlay {
            ui.hideOverlayTemplate(animated: true, completion: nil)
        } else {
            ui.dismissTemplate(animated: true, completion: nil)
        }
    }
}
