import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation

/// Flow dictation: hold a key anywhere on the Mac (right ⌥ by default), speak,
/// let go, and the words are pasted where you type. Two quick taps keep it
/// listening hands-free until the next tap; Esc cancels; ⌃⌘V pastes the last one
/// again. Speech is recognised on this Mac (SpeechEngines.swift); the words go
/// through the dictionary, snippets and (when turned on) a Jarvis model's
/// clean-up, then the clipboard + ⌘V, and the clipboard gets back what it held.
///
/// Watching the key and pasting both need the Accessibility permission. Off by
/// default; nothing listens until you hold the key.
/// After coucou's FlowDictation (github.com/Louis-CFM/coucou, MIT).
@MainActor
@Observable
final class FlowDictation {
    static let shared = FlowDictation()

    /// How long the microphone stays open after the key comes up (the last word
    /// is often still being said).
    static let tail: Duration = .milliseconds(450)

    private(set) var enabled = Prefs.flowEnabled
    /// macOS lets Jarvis watch the key and paste (Privacy & Security → Accessibility).
    private(set) var trusted = AXIsProcessTrusted()
    /// Why the last dictation couldn't start (Settings and the pill say so).
    private(set) var lastFailure: DictationFailure?
    private(set) var listening = false

    var key: FlowKey = Prefs.flowKey {
        didSet {
            Prefs.flowKey = key
            pill.model.keyLabel = key.label
            cancelAll()
        }
    }

    @ObservationIgnored let pill: FlowPillController
    @ObservationIgnored private let bands = FlowAudioBands()
    @ObservationIgnored private var logic = FlowKeyLogic()
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var current: Listen?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var trustTask: Task<Void, Never>?
    @ObservationIgnored private var promptedThisRun = false

    /// One listen, from the key press to the paste. Cancelling it drops its words.
    @MainActor
    private final class Listen {
        var session: DictationSession?
        var opening: Task<Void, Never>?
        var cancelled = false
        var ended = false
        /// The app the words go to, seen when the key went down.
        let app = NSWorkspace.shared.frontmostApplication
        let startedAt = Date()
        var stoppedAt: Date?
    }

    private init() {
        pill = FlowPillController(bands: bands)
        pill.model.keyLabel = Prefs.flowKey.label
    }

    // MARK: control

    /// At launch: listens for the key if Flow was left on.
    func start() { refresh() }

    func setEnabled(_ on: Bool) {
        Prefs.flowEnabled = on
        enabled = on
        if on && !AXIsProcessTrusted() { askForAccessibility() }
        refresh()
    }

    private func refresh() {
        removeMonitors()
        trusted = AXIsProcessTrusted()
        guard enabled else {
            cancelAll()
            trustTask?.cancel()
            trustTask = nil
            return
        }
        installMonitors()
        if !trusted { waitForTrust() }
    }

    func askForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        SpeechPermissions.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))
    }

    /// The Flow window's microphone: hands-free straight away, until the key or Done.
    func startHandsFree() {
        guard logic.phase == .idle, current == nil else { return }
        logic.lock()
        begin()
        pill.setPhase(.locked)
    }

    /// Done (the Flow window), or the key while hands-free.
    func finishHandsFree() {
        guard logic.phase == .locked else { return }
        logic.reset()
        finish()
    }

    func cancelAll() {
        logic.reset()
        abort()
    }

    /// ⌃⌘V or the history's button: the last dictation pasted again.
    func pasteAgain(_ text: String? = nil) {
        guard let text = text ?? FlowStore.shared.lastText, !text.isEmpty else { return }
        switch FlowPaste.insert(text) {
        case .pasted: pill.flash(.pastedAgain)
        case .noAccess: announceNoAccess()
        case .noField: announceNoField()
        }
    }

    // MARK: the key

    private func installMonitors() {
        // A global monitor sees the key in other apps, a local one while Jarvis is in front.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            let info = (event.type, event.keyCode, event.modifierFlags,
                        event.type == .keyDown ? event.charactersIgnoringModifiers : nil)
            MainActor.assumeIsolated { self?.handle(type: info.0, keyCode: info.1, flags: info.2, characters: info.3) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            let info = (event.type, event.keyCode, event.modifierFlags,
                        event.type == .keyDown ? event.charactersIgnoringModifiers : nil)
            MainActor.assumeIsolated { self?.handle(type: info.0, keyCode: info.1, flags: info.2, characters: info.3) }
            return event
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    /// Until macOS trusts Jarvis the global monitor gets nothing: check every 2 s
    /// and reinstall the monitors once it does.
    private func waitForTrust() {
        trustTask?.cancel()
        trustTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.enabled else { return }
                if AXIsProcessTrusted() {
                    self.trusted = true
                    self.removeMonitors()
                    self.installMonitors()
                    return
                }
            }
        }
    }

    private func handle(type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .keyDown:
            if keyCode == UInt16(kVK_Escape) { apply(logic.escape()) }
            else if logic.phase == .idle, FlowPaste.isPasteAgain(characters: characters, flags: flags) { pasteAgain() }
            else { apply(logic.otherKey()) }
        case .flagsChanged where keyCode == key.keyCode:
            apply(key.isDown(flags) ? logic.keyDown(at: now) : logic.keyUp(at: now))
        default:
            break
        }
    }

    private func apply(_ action: FlowKeyLogic.Action) {
        switch action {
        case .none: break
        case .start: begin()
        case .restart: abort(); begin()
        case .lock: pill.setPhase(.locked)
        case .finish: finish()
        case .cancel: abort()
        }
        if case .tapWait(let until) = logic.phase { scheduleTick(at: until) }
    }

    private func scheduleTick(at until: Double) {
        tickTask?.cancel()
        let wait = max(0, until - ProcessInfo.processInfo.systemUptime) + 0.02
        tickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.apply(self.logic.tick(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    // MARK: listening

    private func begin() {
        let listen = Listen()
        current = listen
        listening = true
        bands.reset()
        pill.listen()
        NotificationCenter.default.post(name: .jarvisDictationStarted, object: nil)
        let bands = self.bands
        listen.opening = Task { @MainActor [weak self] in
            let session = await DictationEngines.make(Prefs.flowEngine, words: FlowStore.shared.words, bands: bands)
            guard !listen.cancelled else { return }
            listen.session = session
            if let failure = await session.start() {
                guard let self, self.current === listen else { return }
                self.logic.reset()
                self.end(listen)
                self.current = nil
                self.listening = false
                self.lastFailure = failure
                self.pill.flash(.failed)
                self.pill.announce(FlowAnnouncement(symbol: "mic.slash.fill", text: failure.message,
                                                    action: failure.settingsURL == nil ? nil : String(localized: "Open Settings"))) {
                    SpeechPermissions.open(failure.settingsURL)
                }
                return
            }
            self?.lastFailure = nil
            if listen.cancelled { session.cancel() }
        }
    }

    private func finish() {
        guard let listen = current else { pill.rest(); return }
        pill.setPhase(.thinking)
        listen.stoppedAt = Date()
        Task { @MainActor [weak self] in
            await listen.opening?.value
            try? await Task.sleep(for: Self.tail)
            guard let self, !listen.cancelled, let session = listen.session else { return }
            let heard = await session.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            self.end(listen)
            guard !listen.cancelled else { return }
            let store = FlowStore.shared
            let prepared = store.prepare(heard)
            var body = prepared.text
            let style = store.style(for: listen.app?.bundleIdentifier)
            if FlowCleanup.worthCleaning(body, style: style, enabled: Prefs.flowCleanup) {
                let cleaned = await FlowCleanup.clean(body, style: style, app: listen.app?.localizedName,
                                                      words: store.words, origin: AppModel.shared.apiOrigin)
                guard !listen.cancelled else { return }
                if FlowText.keepsMarks(cleaned, prepared.snippets) { body = cleaned }
            }
            let text = FlowText.finish(body, snippets: prepared.snippets).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let spoken = (listen.stoppedAt ?? Date()).timeIntervalSince(listen.startedAt)
                store.record(text: text, app: listen.app?.localizedName, seconds: spoken)
            }
            // A new listen may have begun meanwhile: its pill is left alone, but these words still go in.
            let latest = self.current === listen
            if latest {
                self.current = nil
                self.listening = false
            }
            guard !text.isEmpty else {
                if latest { self.pill.rest() }
                return
            }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard FlowPaste.sameTarget(started: listen.app?.processIdentifier, frontNow: front) else {
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(text, forType: .string)
                if latest { self.pill.rest() }
                self.announceMoved()
                return
            }
            let result = FlowPaste.insert(text)
            if latest { self.pill.rest() }
            switch result {
            case .pasted:
                break
            case .noAccess:
                self.trusted = false
                if !self.promptedThisRun {
                    self.promptedThisRun = true
                    self.askForAccessibility()
                }
                self.waitForTrust()
                self.announceNoAccess()
            case .noField:
                self.announceNoField()
            }
        }
    }

    private func abort() {
        tickTask?.cancel()
        if let listen = current {
            listen.cancelled = true
            listen.session?.cancel()
            end(listen)
        }
        current = nil
        listening = false
        pill.rest()
    }

    /// The microphone is given back: the wake word may listen again.
    private func end(_ listen: Listen) {
        guard !listen.ended else { return }
        listen.ended = true
        NotificationCenter.default.post(name: .jarvisDictationEnded, object: nil)
    }

    private func announceNoAccess() {
        pill.announce(FlowAnnouncement(symbol: "lock.fill",
                                       text: String(localized: "The words are on the clipboard. Allow Jarvis in Accessibility to paste."),
                                       action: String(localized: "Allow"))) { [weak self] in
            self?.openAccessibilitySettings()
        }
    }

    private func announceMoved() {
        pill.announce(FlowAnnouncement(symbol: "doc.on.clipboard.fill",
                                       text: String(localized: "You switched apps: the words are on the clipboard."),
                                       action: nil))
    }

    private func announceNoField() {
        pill.announce(FlowAnnouncement(symbol: "doc.on.clipboard.fill",
                                       text: String(localized: "No text field here: the words are on the clipboard."),
                                       action: nil))
    }
}
