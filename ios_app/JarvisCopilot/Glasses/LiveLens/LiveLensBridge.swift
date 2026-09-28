import Foundation
import Observation
import Combine

/// Shows Live Jarvis's transcript on the GO3 lens while Live records and
/// "Show on glasses" is on. Steps aside while an AI note, a translation or any
/// other lens app has the lens, and never takes it back from an app opened on
/// the glasses until that app closes.
@MainActor
@Observable
final class LiveLensBridge {
    static let shared = LiveLensBridge(source: LiveStore.shared)
    static let showKey = "glasses.liveCaptions.show"
    static let styleKey = "glasses.liveCaptions.style"
    /// Non-final captions at most this often.
    static let partialInterval: TimeInterval = 0.3

    enum Status: Equatable { case off, notRecording, glassesOff, pausedForLens, showing }

    private(set) var status: Status = .off
    private(set) var notice: String?

    var enabled: Bool {
        get { enabledValue }
        set {
            enabledValue = newValue
            defaults.set(newValue, forKey: Self.showKey)
            refresh()
        }
    }
    var style: LensCaptionStyle {
        get { styleValue }
        set {
            guard newValue != styleValue else { return }
            if open { surface?.close(); open = false }
            surface = nil
            styleValue = newValue
            defaults.set(newValue.rawValue, forKey: Self.styleKey)
            refresh()
        }
    }

    private var enabledValue: Bool
    private var styleValue: LensCaptionStyle
    private let source: LiveCaptionSource
    private let defaults: UserDefaults
    private let lensBusy: @MainActor () -> Bool
    private let glassesReady: @MainActor () -> Bool
    private let makeSurface: @MainActor (LensCaptionStyle) -> LensCaptionSurface
    private let now: () -> Date
    private var surface: LensCaptionSurface?
    private var open = false
    private var composer = LiveCaptionComposer()
    /// A lens app opened on the glasses (not ours) that has the lens until it closes.
    private var otherApp: Int?
    private var heldPartial: LensCaption?
    private var lastPartialAt = Date.distantPast
    private var observer: UUID?
    private var connection: AnyCancellable?
    private var tick: Task<Void, Never>?

    init(source: LiveCaptionSource, defaults: UserDefaults = .standard,
         lensBusy: @escaping @MainActor () -> Bool = { GlassesNoteRecorder.shared.phase != .idle || GlassesTranslator.shared.phase != .idle },
         glassesReady: @escaping @MainActor () -> Bool = { InmoSession.shared.state == .ready },
         surface: @escaping @MainActor (LensCaptionStyle) -> LensCaptionSurface = { $0.makeSurface() },
         now: @escaping () -> Date = Date.init) {
        self.source = source
        self.defaults = defaults
        self.lensBusy = lensBusy
        self.glassesReady = glassesReady
        self.makeSurface = surface
        self.now = now
        enabledValue = defaults.bool(forKey: Self.showKey)
        styleValue = defaults.string(forKey: Self.styleKey).flatMap(LensCaptionStyle.init(rawValue:)) ?? .subtitles
    }

    func install() {
        guard observer == nil else { return }
        observer = InmoSession.shared.addEventObserver { [weak self] event in
            guard let self, case let .message(type, fields, _) = event else { return }
            if type == 18, case let .exception(code)? = try? GlassesSubtitlesWire.parse(type: type, fields: fields) {
                self.handleSubtitlesException(code: code)
            } else if type == 15, let app = try? fields.firstField(18)?.nested() {
                self.handleLens(module: Int(app.firstField(1)?.varint ?? 0), opened: (app.firstField(2)?.varint ?? 0) == 0)
            }
        }
        connection = InmoSession.shared.$state.sink { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        watchLive()
        refresh()
    }

    /// Re-reads Live and the lens owners whenever any of them changes.
    private func watchLive() {
        withObservationTracking {
            _ = source.isCapturing
            _ = source.captionSnapshot()
            _ = lensBusy()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.watchLive()
            }
        }
    }

    func ownsLens(module: Int) -> Bool { open && surface?.module == module }

    // MARK: State

    func refresh() {
        let next: Status
        if !enabledValue { next = .off }
        else if !source.isCapturing { next = .notRecording }
        else if !glassesReady() { next = .glassesOff }
        else if lensBusy() || otherApp != nil { next = .pausedForLens }
        else { next = .showing }

        if next == .showing {
            if !open {
                let current = surface ?? makeSurface(styleValue)
                surface = current
                current.open()
                open = true
                heldPartial = nil
                lastPartialAt = .distantPast
                if let first = composer.begin(source.captionSnapshot()) { send(first) }
            } else {
                for caption in composer.update(source.captionSnapshot()) { send(caption) }
                flushHeld()
            }
        } else if open {
            open = false
            // Another app has the lens, or the glasses are gone: leave the lens alone.
            if next != .pausedForLens, next != .glassesOff { surface?.close() }
        }
        status = next
    }

    private func send(_ caption: LensCaption) {
        guard let surface else { return }
        if caption.final {
            heldPartial = nil
            surface.show(caption)
            return
        }
        if now().timeIntervalSince(lastPartialAt) >= Self.partialInterval {
            lastPartialAt = now()
            heldPartial = nil
            surface.show(caption)
        } else {
            heldPartial = caption
            scheduleTick()
        }
    }

    private func flushHeld() {
        guard let held = heldPartial, now().timeIntervalSince(lastPartialAt) >= Self.partialInterval else { return }
        send(held)
    }

    private func scheduleTick() {
        guard tick == nil else { return }
        tick = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self else { return }
            self.tick = nil
            if self.open { self.flushHeld() }
        }
    }

    // MARK: Glasses

    func handleLens(module: Int, opened: Bool) {
        // The app we are showing on: an open is our own echo; a close is the user
        // leaving it on the glasses.
        if open, module == surface?.module {
            if !opened {
                open = false
                enabledValue = false
                defaults.set(false, forKey: Self.showKey)
                status = .off
            }
            return
        }
        if module == GlassesSubtitlesWire.module {
            // Closing: the echo of our own close. Opening: the user asked for captions.
            guard opened else { return }
            enabledValue = true
            defaults.set(true, forKey: Self.showKey)
            if source.isCapturing { refresh(); return }
            Task { [weak self] in
                guard let self else { return }
                if await !self.source.startCapture() {
                    self.notice = "Live Jarvis couldn't start recording."
                    Task { try? await InmoSession.shared.send(InmoCommand.closeModule(module)) }
                }
                self.refresh()
            }
            return
        }
        if opened { otherApp = module } else if otherApp == module { otherApp = nil }
        refresh()
    }

    func handleSubtitlesException(code: UInt64) {
        InmoRuntimeDiagnostics.note("live captions: subtitles exception \(code)")
        notice = "The glasses' Subtitles app reported a problem (\(code))."
    }

    // MARK: Research

    /// Three test lines on the current lens style, to see how they look.
    func sendTestCaptions() async {
        let probe = makeSurface(styleValue)
        probe.open()
        try? await Task.sleep(for: .milliseconds(800))
        probe.show(LensCaption(text: "Speaker 2: testing one two", translation: "", final: false))
        try? await Task.sleep(for: .seconds(2))
        probe.show(LensCaption(text: "Maya: are we still on for six?", translation: "", final: true))
        try? await Task.sleep(for: .seconds(3))
        probe.show(LensCaption(text: "Luis: ¿Nos vemos a las seis?", translation: "Are we meeting at six?", final: true))
        try? await Task.sleep(for: .seconds(15))
        probe.close()
    }
}
