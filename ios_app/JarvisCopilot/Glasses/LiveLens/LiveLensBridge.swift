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
    /// Raw sends to the glasses, in order with the captions' own.
    private let post: @MainActor (Data) -> Void
    private var surface: LensCaptionSurface?
    private var open = false
    private var composer = LiveCaptionComposer()
    /// A lens app opened on the glasses (not ours) that has the lens until it closes.
    private var otherApp: Int?
    private var heldPartial: LensCaption?
    /// An answer or fact-check is on the lens: live captions wait until it's read.
    private var blockActive = false
    /// Blocks show one after another, each whole, never interleaved.
    @ObservationIgnored private var blockChain: Task<Void, Never>?
    @ObservationIgnored private var pendingBlocks = 0
    @ObservationIgnored private var lastBlock: (key: String, at: Date)?
    /// When Jarvis last opened or closed a lens app: the glasses echo it back, and
    /// an echo inside this window is ours, not a gesture.
    @ObservationIgnored private var lastOwnLensChange = Date.distantPast
    static let echoWindow: TimeInterval = 2
    /// When the learned gesture last fired, and the lens app it opened (holding GO
    /// opens Face Link): that app gets closed and captions come back.
    @ObservationIgnored private var gestureAt = Date.distantPast
    @ObservationIgnored private var gestureApp: Int?
    static let gestureWindow: TimeInterval = 4
    /// Pause between closing the gesture's app and reopening captions.
    @ObservationIgnored var reopenDelay: Duration = .milliseconds(600)
    /// Time between the chunks of one block, and after a block before the next.
    @ObservationIgnored var chunkGap: Duration = .seconds(3.5)
    @ObservationIgnored var blockGap: Duration = .seconds(4)

    static let gestureKey = "glasses.liveCaptions.factCheckGesture"
    /// The glasses message (hex) that means "fact-check now", learned in the app.
    private(set) var factCheckGesture: String?
    private(set) var learningGesture = false
    private(set) var gestureNotice: String?
    /// What the glasses send on their own; never taken as a gesture.
    static let noiseTypes: Set<Int> = [0, 4, 17, 20, 24, 35]
    private var lastPartialAt = Date.distantPast
    private var observer: UUID?
    private var connection: AnyCancellable?
    private var tick: Task<Void, Never>?

    init(source: @escaping @MainActor () -> LiveCaptionSource, defaults: UserDefaults = .standard,
         lensBusy: @escaping @MainActor () -> Bool = { GlassesNoteRecorder.shared.phase != .idle || GlassesTranslator.shared.phase != .idle },
         glassesReady: @escaping @MainActor () -> Bool = { InmoSession.shared.state == .ready },
         surface: @escaping @MainActor (LensCaptionStyle) -> LensCaptionSurface = { $0.makeSurface() },
         now: @escaping () -> Date = Date.init,
         post: @escaping @MainActor (Data) -> Void = { LensSendQueue.shared.post($0) }) {
        self.sourceProvider = source
        self.defaults = defaults
        self.lensBusy = lensBusy
        self.glassesReady = glassesReady
        self.makeSurface = surface
        self.now = now
        self.post = post
        enabledValue = defaults.bool(forKey: Self.showKey)
        factCheckGesture = defaults.string(forKey: Self.gestureKey)
        styleValue = defaults.string(forKey: Self.styleKey).flatMap(LensCaptionStyle.init(rawValue:)) ?? .subtitles
    }

    func install() {
        guard observer == nil else { return }
        observer = InmoSession.shared.addEventObserver { [weak self] event in
            guard let self, case let .message(type, fields, raw) = event else { return }
            self.handleGlasses(type: type, fields: fields, raw: raw)
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
                lastOwnLensChange = now()
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
            if next != .pausedForLens, next != .glassesOff {
                lastOwnLensChange = now()
                surface?.close()
            }
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
    /// Between the parts of a block (the question and its answer).
    static let blockDivider = String(repeating: "─", count: 22)
    /// Characters of body per lens chunk: about four lens lines.
    static let blockChunk = 150

    /// Shows Jarvis's answer or a fact-check inside the captions, framed as a
    /// text block so it reads apart from what people said. Long ones go up in
    /// chunks a few seconds apart; live captions wait until it's been read.
    /// Without captions on the lens it falls back to a lens card.
    func showBlock(title: String, body: String) { showBlock(title: title, parts: [body]) }

    func showBlock(title: String, parts: [String]) {
        // The same verdict from two paths (the gesture and the Live screen) shows once.
        let key = title + "|" + parts.joined(separator: "|")
        if let last = lastBlock, last.key == key, Date().timeIntervalSince(last.at) < 60 { return }
        lastBlock = (key, Date())
        guard open, surface != nil else {
            InmoSession.shared.forwardNotification(title: title, body: String(parts.joined(separator: "\n").prefix(400)))
            return
        }
        let chunks = Self.frame(title: title, parts: parts)
        blockActive = true
        pendingBlocks += 1
        let previous = blockChain
        blockChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            for (index, chunk) in chunks.enumerated() {
                guard self.open, let surface = self.surface else { break }
                // A blank line before each block's header sets it apart.
                surface.show(LensCaption(text: index == 0 ? "\n" + chunk : chunk, translation: "", final: true))
                if index < chunks.count - 1 { try? await Task.sleep(for: self.chunkGap) }
            }
            try? await Task.sleep(for: self.blockGap)
            self.pendingBlocks -= 1
            if self.pendingBlocks == 0 {
                self.blockActive = false
                self.refresh()
            }
        }
    }

    // MARK: Gesture → fact-check

    /// The next message the glasses send (not their own chatter) becomes the
    /// fact-check gesture.
    func learnGesture() {
        learningGesture = true
        gestureNotice = "Now do the gesture on the glasses…"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.learningGesture else { return }
            self.learningGesture = false
            self.gestureNotice = "The glasses didn't send anything for that gesture. Try another — the GO button, a double tap or a long press."
        }
    }

    func forgetGesture() {
        factCheckGesture = nil
        defaults.removeObject(forKey: Self.gestureKey)
        gestureNotice = nil
    }

    /// Every message from the glasses: a learned gesture first, then lens app
    /// opens/closes and Subtitles errors.
    func handleGlasses(type: Int, fields: [InmoWireField], raw: Data) {
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        if learningGesture, !Self.noiseTypes.contains(type), !isOwnEcho(type: type, fields: fields) {
            learningGesture = false
            factCheckGesture = hex
            defaults.set(hex, forKey: Self.gestureKey)
            gestureNotice = "Saved (\(Self.describe(type: type, fields: fields))). Do it while captions show to fact-check."
            undoGestureSideEffect(type: type, fields: fields)
            return
        }
        if let gesture = factCheckGesture, gesture == hex, enabledValue, !isOwnEcho(type: type, fields: fields) {
            InmoRuntimeDiagnostics.note("live captions: fact-check gesture")
            Task { [weak self] in
                guard let self, let verdict = await self.source.runFactCheck() else { return }
                self.showBlock(title: verdict.title, parts: [verdict.text])
            }
            undoGestureSideEffect(type: type, fields: fields)
            return
        }
        if type == 18, case let .exception(code)? = try? GlassesSubtitlesWire.parse(type: type, fields: fields) {
            handleSubtitlesException(code: code)
        } else if type == 15, let app = try? fields.firstField(18)?.nested() {
            handleLens(module: Int(app.firstField(1)?.varint ?? 0), opened: (app.firstField(2)?.varint ?? 0) == 0)
        }
    }

    /// An open/close of our own lens app within a moment of making it is its echo.
    private func isOwnEcho(type: Int, fields: [InmoWireField]) -> Bool {
        guard type == 15, let app = try? fields.firstField(18)?.nested() else { return false }
        let module = Int(app.firstField(1)?.varint ?? 0)
        if module == probeModule { return true }
        let ours = module == surface?.module || module == GlassesSubtitlesWire.module
        return ours && now().timeIntervalSince(lastOwnLensChange) < Self.echoWindow
    }

    /// A gesture that opened another lens app gets it closed again and captions
    /// put back; one that closed ours gets captions reopened.
    private func undoGestureSideEffect(type: Int, fields: [InmoWireField]) {
        guard type == 15, let app = try? fields.firstField(18)?.nested() else { return }
        let module = Int(app.firstField(1)?.varint ?? 0)
        let opened = (app.firstField(2)?.varint ?? 0) == 0
        gestureAt = now()
        if opened, module != surface?.module {
            gestureApp = module
            post(InmoCommand.closeModule(module))
            reopenCaptions(after: reopenDelay)
        } else if !opened, module == surface?.module {
            reopenCaptions(after: .zero)
        }
    }

    /// The glasses left the captions app for the gesture: open it again.
    private func reopenCaptions(after delay: Duration) {
        guard delay > .zero else { open = false; refresh(); return }
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.open = false
            self.refresh()
        }
    }

    /// The lens app the gesture just opened (and is closing again): Face Link
    /// must not start its camera for it.
    func gestureOpened(module: Int) -> Bool {
        gestureApp == module && now().timeIntervalSince(gestureAt) < Self.gestureWindow
    }

    static func describe(type: Int, fields: [InmoWireField]) -> String {
        if type == 15, let app = try? fields.firstField(18)?.nested() {
            let module = app.firstField(1)?.varint ?? 0
            let closes = (app.firstField(2)?.varint ?? 0) == 1
            if module == UInt64(GlassesSubtitlesWire.module) { return closes ? "leaving Subtitles" : "opening Subtitles" }
            return (closes ? "closes" : "opens") + " glasses app \(module)"
        }
        return "glasses message type \(type)"
    }

    static func frame(title: String, body: String) -> [String] { frame(title: title, parts: [body]) }

    /// Header bar, the parts with a divider line between them, closing bar — in
    /// lens-sized chunks. A short block is one chunk.
    static func frame(title: String, parts: [String]) -> [String] {
        let header = "━━━ 【\(title)】 ━━━"
        var lines: [String] = []
        for (index, part) in parts.enumerated() {
            if index > 0 { lines.append(blockDivider) }
            var current = ""
            for word in part.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
                if !current.isEmpty, current.count + word.count + 1 > blockChunk {
                    lines.append(current)
                    current = ""
                }
                current += (current.isEmpty ? "" : " ") + word
            }
            if !current.isEmpty { lines.append(current) }
        }
        // Pack lines into chunks of about `blockChunk` characters.
        var chunks: [String] = []
        var chunk = header
        for line in lines {
            if chunk != header, chunk.count + line.count + 1 > blockChunk + header.count {
                chunks.append(chunk)
                chunk = line
            } else {
                chunk += "\n" + line
            }
        }
        chunks.append(chunk + "\n" + blockBar)
        return chunks
    }

    // MARK: Glasses

    func handleLens(module: Int, opened: Bool) {
        // The test action's own echoes.
        if module == probeModule { return }
        // The app we are showing on: an open is our own echo; a close is the user
        // leaving it on the glasses.
        if open, module == surface?.module {
            // The lens left captions for the gesture's app; they're coming back.
            if !opened, now().timeIntervalSince(gestureAt) < Self.gestureWindow { return }
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
