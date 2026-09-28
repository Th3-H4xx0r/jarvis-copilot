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
    /// Live is built only when captions are wanted: building LiveStore at launch
    /// sets up the mic engine and spool (LiveCaptureBeacon).
    static let shared = LiveLensBridge(source: { LiveStore.shared })
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
            if newValue { watchLive() }
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
    private let sourceProvider: @MainActor () -> LiveCaptionSource
    @ObservationIgnored private var sourceStorage: LiveCaptionSource?
    private var source: LiveCaptionSource {
        if let sourceStorage { return sourceStorage }
        let made = sourceProvider()
        sourceStorage = made
        return made
    }
    @ObservationIgnored private var watching = false
    /// The lens app the test action has open: its echoes are ours, not the user's.
    private var probeModule: Int?
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
    /// An answer or fact-check is on the lens: live captions wait until it's read.
    private var blockActive = false
    private var lastPartialAt = Date.distantPast
    private var observer: UUID?
    private var connection: AnyCancellable?
    private var tick: Task<Void, Never>?

    init(source: @escaping @MainActor () -> LiveCaptionSource, defaults: UserDefaults = .standard,
         lensBusy: @escaping @MainActor () -> Bool = { GlassesNoteRecorder.shared.phase != .idle || GlassesTranslator.shared.phase != .idle },
         glassesReady: @escaping @MainActor () -> Bool = { InmoSession.shared.state == .ready },
         surface: @escaping @MainActor (LensCaptionStyle) -> LensCaptionSurface = { $0.makeSurface() },
         now: @escaping () -> Date = Date.init) {
        self.sourceProvider = source
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
            Task { @MainActor in self?.connectionChanged() }
        }
        if enabledValue { watchLive() }
        refresh()
    }

    /// A lost link forgets which other app had the lens: its close never came.
    func connectionChanged() {
        otherApp = nil
        refresh()
    }

    /// Re-reads Live and the lens owners whenever any of them changes. Started only
    /// once captions are wanted, so Live is not built at every launch.
    private func watchLive() {
        guard !watching else { return }
        watching = true
        track()
    }

    private func track() {
        withObservationTracking {
            _ = source.isCapturing
            _ = source.captionSnapshot()
            _ = lensBusy()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.track()
            }
        }
    }

    func ownsLens(module: Int) -> Bool { (open && surface?.module == module) || probeModule == module }

    func beginProbe(module: Int) { probeModule = module }
    func endProbe() { probeModule = nil }

    // MARK: State

    func refresh() {
        let next: Status
        if !enabledValue { next = .off }
        else if !source.isCapturing { next = .notRecording }
        else if !glassesReady() { next = .glassesOff }
        else if lensBusy() || otherApp != nil { next = .pausedForLens }
        else { next = .showing }
        if next == .showing { notice = nil }

        if next == .showing {
            if !open {
                let current = surface ?? makeSurface(styleValue)
                surface = current
                current.open()
                open = true
                heldPartial = nil
                lastPartialAt = .distantPast
                if let first = composer.begin(source.captionSnapshot()) { send(first) }
            } else if !blockActive {
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

    // MARK: Blocks (answers, fact-checks)

    static let blockBar = String(repeating: "━", count: 22)
    /// Characters of body per lens chunk: about four lens lines.
    static let blockChunk = 150

    /// Shows Jarvis's answer or a fact-check inside the captions, framed as a
    /// text block so it reads apart from what people said. Long ones go up in
    /// chunks a few seconds apart; live captions wait until it's been read.
    /// Without captions on the lens it falls back to a lens card.
    func showBlock(title: String, body: String) {
        guard open, let surface else {
            InmoSession.shared.forwardNotification(title: title, body: String(body.prefix(400)))
            return
        }
        let chunks = Self.frame(title: title, body: body)
        blockActive = true
        Task { [weak self] in
            for (index, chunk) in chunks.enumerated() {
                guard let self, self.open else { break }
                surface.show(LensCaption(text: chunk, translation: "", final: true))
                if index < chunks.count - 1 { try? await Task.sleep(for: .seconds(3.5)) }
            }
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            self.blockActive = false
            self.refresh()
        }
    }

    static func frame(title: String, body: String) -> [String] {
        let header = "━━━ 【\(title)】 ━━━"
        var chunks: [String] = []
        var current = ""
        for word in body.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if !current.isEmpty, current.count + word.count + 1 > blockChunk {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + word
        }
        if !current.isEmpty || chunks.isEmpty { chunks.append(current) }
        chunks[0] = header + "\n" + chunks[0]
        chunks[chunks.count - 1] += "\n" + blockBar
        return chunks
    }

    // MARK: Glasses

    func handleLens(module: Int, opened: Bool) {
        // The test action's own echoes.
        if module == probeModule { return }
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
            let was = enabledValue
            enabledValue = true
            otherApp = nil
            watchLive()
            if source.isCapturing { refresh(); return }
            Task { [weak self] in
                guard let self else { return }
                if await self.source.startCapture() {
                    self.defaults.set(true, forKey: Self.showKey)
                } else {
                    // Leave the toggle as it was; tell him why nothing shows.
                    self.enabledValue = was
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
        let lines = [LensCaption(text: "Speaker 2 — testing one two", translation: "", final: false),
                     LensCaption(text: "Maya — are we still on for six?", translation: "", final: true),
                     LensCaption(text: "Luis — ¿Nos vemos a las seis?", translation: "Are we meeting at six?", final: true)]
        // Captions already showing: the test lines go through them; nothing opens or closes.
        if open, let surface {
            for line in lines { surface.show(line); try? await Task.sleep(for: .seconds(2)) }
            return
        }
        let probe = makeSurface(styleValue)
        beginProbe(module: probe.module)
        probe.open()
        try? await Task.sleep(for: .milliseconds(800))
        for line in lines { probe.show(line); try? await Task.sleep(for: .seconds(2.5)) }
        try? await Task.sleep(for: .seconds(12))
        probe.close()
        // Let the close echo arrive before its echoes count again.
        try? await Task.sleep(for: .seconds(2))
        endProbe()
    }
}
