import AppKit
import Carbon.HIToolbox
import Observation

/// Push to talk on one key (Settings → Voice → Hold to talk): hold it and
/// Jarvis listens, let go and what you said is sent; the answer comes in the
/// small voice island under the notch. Held for a beat before it starts, so
/// the key still works as ⌥ for typing (⌥E never talks).
struct TalkKeyLogic: Equatable {
    static let startDelay: Double = 0.15

    enum Phase: Equatable { case idle, waiting(since: Double), talking }
    enum Action: Equatable { case none, start, send }

    private(set) var phase: Phase = .idle

    mutating func keyDown(at t: Double) -> Action {
        if phase == .idle { phase = .waiting(since: t) }
        return .none
    }

    /// Called while waiting: held long enough, it starts.
    mutating func tick(at t: Double) -> Action {
        guard case .waiting(let since) = phase, t - since >= Self.startDelay - 1e-6 else { return .none }
        phase = .talking
        return .start
    }

    /// Another key while waiting: it was ⌥ for typing. Once talking, typing
    /// doesn't stop it — only letting go does.
    mutating func otherKey() -> Action {
        if case .waiting = phase { phase = .idle }
        return .none
    }

    mutating func keyUp(at t: Double) -> Action {
        defer { phase = .idle }
        return phase == .talking ? .send : .none
    }
}

/// One key, one job: the talk key and Flow dictation's key can't be the same
/// while Flow is on.
enum TalkKeyChoice {
    static func clashes(talk: FlowKey?, flow: FlowKey, flowOn: Bool) -> Bool {
        flowOn && talk == flow
    }

    /// Where Flow can go when Jarvis takes its key.
    static func otherKey(than key: FlowKey) -> FlowKey {
        [FlowKey.fn, .rightCommand, .rightControl, .rightOption].first { $0 != key } ?? .fn
    }
}

/// Watches the talk key everywhere (a global monitor — it needs Accessibility,
/// like Flow) and in Jarvis's own windows (a local one).
@MainActor
@Observable
final class TalkKeyWatcher {
    static let shared = TalkKeyWatcher()

    /// The key went down long enough / came back up.
    @ObservationIgnored var onStart: (() -> Void)?
    @ObservationIgnored var onSend: (() -> Void)?

    private(set) var trusted = AXIsProcessTrusted()
    @ObservationIgnored private var logic = TalkKeyLogic()
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var trustTask: Task<Void, Never>?
    @ObservationIgnored private var key: FlowKey?

    /// Follow the setting: watch the chosen key, or nothing. A key Flow uses
    /// stays Flow's until one of them moves.
    func sync() {
        removeMonitors()
        let chosen = Prefs.talkKey
        key = chosen
        guard let chosen, !TalkKeyChoice.clashes(talk: chosen, flow: Prefs.flowKey, flowOn: Prefs.flowEnabled) else { return }
        trusted = AXIsProcessTrusted()
        install(chosen)
        if !trusted { waitForTrust() }
    }

    private func install(_ key: FlowKey) {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            let info = (event.type, event.keyCode, event.modifierFlags)
            MainActor.assumeIsolated { self?.handle(info.0, keyCode: info.1, flags: info.2) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            let info = (event.type, event.keyCode, event.modifierFlags)
            MainActor.assumeIsolated { self?.handle(info.0, keyCode: info.1, flags: info.2) }
            return event
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        tickTask?.cancel()
        if logic.phase == .talking { onSend?() }
        logic = TalkKeyLogic()
    }

    /// Until macOS trusts Jarvis the global monitor gets nothing: check every
    /// 2 s and reinstall once it does.
    private func waitForTrust() {
        trustTask?.cancel()
        trustTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.sync()
                    return
                }
            }
        }
    }

    private func handle(_ type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        // Flow may have taken the key since (its own settings): Flow keeps it.
        guard let key, !TalkKeyChoice.clashes(talk: key, flow: Prefs.flowKey, flowOn: Prefs.flowEnabled) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .keyDown:
            apply(logic.otherKey())
        case .flagsChanged where keyCode == key.keyCode:
            if key.isDown(flags) {
                apply(logic.keyDown(at: now))
                scheduleTick()
            } else {
                tickTask?.cancel()
                apply(logic.keyUp(at: now))
            }
        default:
            break
        }
    }

    private func scheduleTick() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(TalkKeyLogic.startDelay + 0.01))
            guard let self, !Task.isCancelled else { return }
            self.apply(self.logic.tick(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    private func apply(_ action: TalkKeyLogic.Action) {
        switch action {
        case .none: break
        case .start: onStart?()
        case .send: onSend?()
        }
    }
}
