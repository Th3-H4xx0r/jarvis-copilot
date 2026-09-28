import Foundation
import Observation
import Translation

/// Where a heard sentence gets translated.
enum GlassesTranslateEngine: String, CaseIterable, Identifiable {
    /// Apple's speech recognition + Apple Translation, on the iPhone. Instant, offline.
    case onDevice
    /// On-device speech recognition; each finished sentence goes through the app to
    /// the Jarvis server's model (`/api/translate/text`).
    case jarvis
    /// The glasses' audio streams to the Jarvis server, which runs Soniox's
    /// real-time transcription + translation (`/api/translate/ws`).
    case soniox
    var id: String { rawValue }
    var label: String {
        switch self { case .onDevice: return "On device"; case .jarvis: return "Jarvis"; case .soniox: return "Soniox" }
    }
    var detail: String {
        switch self {
        case .onDevice: return "Apple speech + Apple Translation on this iPhone. Instant and offline."
        case .jarvis: return "Heard on this iPhone; each sentence is translated by Jarvis's model on the server."
        case .soniox: return "Audio goes to the Jarvis server, which uses Soniox to hear and translate."
        }
    }
}

/// Live translation through the GO3: the glasses' microphone is heard, each line
/// is translated, and the lens shows the line and its translation — the official
/// app's TranslationMaster flow with Jarvis doing the work instead of INMO.
@MainActor
@Observable
final class GlassesTranslator {
    static let shared = GlassesTranslator()

    enum Phase: Equatable { case idle, starting, running, stopping }
    struct Line: Identifiable, Equatable {
        let id: Int
        var original: String
        var translation: String
        var final: Bool
        var ms: Int
    }

    private(set) var phase: Phase = .idle
    private(set) var mode: GlassesTranslateWire.Mode = .simultaneous
    private(set) var lines: [Line] = []
    /// The line being heard right now.
    private(set) var hearing = ""
    private(set) var paused = false
    private(set) var problem: String?
    private(set) var engineInUse: GlassesTranslateEngine = .onDevice

    static let sourceKey = "glasses.translate.source"
    static let targetKey = "glasses.translate.target"
    static let engineKey = "glasses.translate.engine"
    static let onlyTranslationKey = "glasses.translate.onlyTranslation"
    static let fromGlassesKey = "glasses.translate.startFromGlasses"

    var source: String { defaults.string(forKey: Self.sourceKey) ?? "es" }
    var target: String { defaults.string(forKey: Self.targetKey) ?? "en" }
    var engine: GlassesTranslateEngine {
        defaults.string(forKey: Self.engineKey).flatMap(GlassesTranslateEngine.init(rawValue:)) ?? .onDevice
    }
    var onlyTranslation: Bool { defaults.bool(forKey: Self.onlyTranslationKey) }
    var startsFromGlasses: Bool { defaults.object(forKey: Self.fromGlassesKey) as? Bool ?? true }

    private let defaults: UserDefaults
    private let store: GlassesNotesStore
    private let recognizer = DefaultSpeechRecognizing()
    private var observer: UUID?
    private var decoder: InmoOpusDecoder?
    private var speech: SpeechSession?
    private var socket: VoiceSocket?
    private var sonioxFinished = false
    private var translation: AnyObject?
    private var lens = GlassesNoteLens()
    private var nextID = 1
    private var startedAt = Date()
    private var sendChain: Task<Void, Never>?
    private var translateChain: Task<Void, Never>?
    private var pendingTranslations = 0
    private var heldPartial: String?
    private var lastPartialSent = Date.distantPast
    private var sonioxLines: [Int: Int] = [:]
    private var audioMessages = 0
    private var idleFinalize: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, store: GlassesNotesStore = .shared) {
        self.defaults = defaults
        self.store = store
    }

    func install() {
        guard observer == nil else { return }
        observer = InmoSession.shared.addEventObserver { [weak self] in self?.receive($0) }
    }

    static func base(_ code: String) -> String { String(code.split(separator: "-").first ?? Substring(code)) }
    static func name(_ code: String) -> String { Locale.current.localizedString(forLanguageCode: base(code)) ?? code }

    // MARK: Start / stop

    func start(mode: GlassesTranslateWire.Mode = .simultaneous, fromGlasses: Bool = false) async {
        guard phase == .idle else { return }
        phase = .starting
        problem = nil
        let engine = self.engine
        do {
            try await InmoSession.shared.ensureConnected()
            decoder = try InmoOpusDecoder()
            switch engine {
            case .onDevice, .jarvis:
                let locale = Locale(identifier: source)
                let ready = await recognizer.prepare(locales: [locale], onProgress: { _ in })
                guard ready == .ready,
                      let session = await recognizer.startSession(sampleRate: 16000, prompt: true, locales: [locale]) else {
                    throw InmoProtocolError.unavailable("Speech recognition for \(Self.name(source)) isn't available on this iPhone.")
                }
                if engine == .onDevice { try await prepareOnDeviceTranslation() }
                speech = session
                session.onPartial = { [weak self] text in self?.heard(text) }
            case .soniox:
                try await openSoniox()
            }
            engineInUse = engine
            self.mode = mode
            lines = []; hearing = ""; paused = false; nextID = 1; lens = GlassesNoteLens()
            pendingTranslations = 0; heldPartial = nil; sonioxLines = [:]; audioMessages = 0
            startedAt = Date()
            if !fromGlasses { post(InmoCommand.openModule(mode.module)) }
            post(GlassesTranslateWire.setting(mode: mode, source: Self.base(source), target: Self.base(target),
                                              onlyTranslation: onlyTranslation))
            phase = .running
            InmoRuntimeDiagnostics.note("translate started mode=\(mode) engine=\(engine.rawValue) \(Self.base(source))→\(Self.base(target))")
        } catch {
            teardown()
            phase = .idle
            problem = error.localizedDescription
            if fromGlasses, InmoSession.shared.state == .ready { post(InmoCommand.closeModule(mode.module)) }
        }
    }

    func stop() async {
        guard phase == .running else { return }
        phase = .stopping
        idleFinalize?.cancel(); idleFinalize = nil
        // Words still in the recogniser become the last line.
        if let speech {
            let final = await voiceStopWithDeadline(speech, after: 3000, clock: SystemVoiceClock())
            for line in lens.finish(final) where line.final && Self.isSpeech(line.text) { finalize(line.text) }
            self.speech = nil
        }
        if let socket {
            sonioxFinished = false
            socket.send(text: #"{"type":"stop"}"#)
            let end = Date().addingTimeInterval(4)
            while !sonioxFinished, Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        }
        // Let the last translations land (bounded: a slow server must not hold the lens).
        let end = Date().addingTimeInterval(8)
        while pendingTranslations > 0, Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        if InmoSession.shared.state == .ready {
            post(GlassesTranslateWire.saved())
            post(InmoCommand.closeModule(mode.module))
        }
        saveRecord()
        teardown()
        phase = .idle
    }

    private func teardown() {
        idleFinalize?.cancel(); idleFinalize = nil
        speech?.cancel(); speech = nil
        socket?.close(); socket = nil
        decoder = nil
        translation = nil
        hearing = ""
    }

    private func saveRecord() {
        let heard = lines.filter { !$0.original.isEmpty }
        guard !heard.isEmpty else { return }
        let id = String(UInt64(startedAt.timeIntervalSince1970 * 1000))
        let title = "Translation · \(Self.name(source)) → \(Self.name(target))"
        let text = heard.map { $0.translation.isEmpty ? $0.original : "\($0.original)\n→ \($0.translation)" }.joined(separator: "\n\n")
        let note = GlassesNote(id: id, createdAt: startedAt, duration: Date().timeIntervalSince(startedAt), title: title,
                               text: text, segments: heard.map { .init(ms: $0.ms, text: $0.original, translation: $0.translation) },
                               photos: [], summary: nil, chatSessionID: nil)
        do { try store.save(note) } catch { problem = "Couldn't save the translation: \(error.localizedDescription)" }
    }

    // MARK: Glasses traffic

    private func receive(_ event: InmoEvent) {
        switch event {
        case .connectionChanged(let state):
            if phase == .running, state == .disconnected || state == .failed {
                problem = "Glasses disconnected."
                Task { await stop() }
            }
        case .message(let type, let fields, _):
            guard [0, 8, 15].contains(type) else { return }
            let parsed: GlassesTranslateWire.Event?
            do { parsed = try GlassesTranslateWire.parse(type: type, fields: fields) } catch {
                if phase == .running { InmoRuntimeDiagnostics.note("translate message unreadable type=\(type): \(error)") }
                return
            }
            guard let parsed else { return }
            switch parsed {
            case .opened(let opened):
                // The glasses echo our own open; only an idle phone answers theirs.
                if phase == .idle, startsFromGlasses { Task { await start(mode: opened, fromGlasses: true) } }
                // The official app sends the languages once the lens app is open:
                // repeat them on the echo in case ours arrived before it was ready.
                else if phase == .running, opened == mode {
                    InmoRuntimeDiagnostics.note("translate lens app open; settings resent")
                    post(GlassesTranslateWire.setting(mode: mode, source: Self.base(source), target: Self.base(target),
                                                      onlyTranslation: onlyTranslation))
                }
            case .closed(let closed):
                if phase == .running, closed == mode { Task { await stop() } }
            case .paused: paused = true
            case .resumed: paused = false
            case .audio(let packets):
                guard phase == .running, !paused, let decoder else { return }
                var pcm = Data()
                for packet in packets { if let decoded = try? decoder.decode(packet) { pcm += decoded } }
                audioMessages += 1
                if audioMessages == 1 || audioMessages % 300 == 0 {
                    InmoRuntimeDiagnostics.note("translate audio msgs=\(audioMessages) packets=\(packets.count) pcm=\(pcm.count)B")
                }
                guard !pcm.isEmpty else { return }
                if let speech { speech.feed(pcm) } else if let socket { socket.send(data: pcm) }
            }
        }
    }

    // MARK: On-device / Jarvis: recogniser → sentences → translation

    private func heard(_ text: String) {
        guard phase == .running, !paused else { return }
        if hearing.isEmpty, lines.isEmpty { InmoRuntimeDiagnostics.note("translate first words heard chars=\(text.count)") }
        take(lens.update(text))
        // A sentence used to end only when the NEXT words began, so the last thing
        // someone said waited (untranslated) until they spoke again or you pressed
        // Stop. A short pause now ends the line, the way Soniox's endpointing does.
        idleFinalize?.cancel()
        idleFinalize = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.pauseEndsLineMs))
            guard let self, !Task.isCancelled, self.phase == .running else { return }
            self.take(self.lens.finish(text))
        }
    }

    /// How long a pause ends the line being heard.
    static let pauseEndsLineMs = 900

    private func take(_ updates: [GlassesNoteLens.Line]) {
        for line in updates where Self.isSpeech(line.text) {
            if line.final { hearing = ""; finalize(line.text) } else { hearing = line.text; showPartial(line.text) }
        }
    }

    /// The recogniser often revises a line it already gave (adds "?" or "."), which
    /// after a pause-ended line shows up as a new line of punctuation alone.
    static func isSpeech(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .alphanumerics) != nil
    }

    private func finalize(_ original: String) {
        let id = nextID; nextID += 1
        lines.append(Line(id: id, original: original, translation: "", final: false, ms: elapsedMs))
        post(GlassesTranslateWire.line(original: original, translation: "", finished: false))
        pendingTranslations += 1
        let previous = translateChain
        translateChain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let translated = await self.translate(original)
            self.pendingTranslations -= 1
            self.setTranslation(id, translated, final: true)
            if self.pendingTranslations == 0, let held = self.heldPartial { self.heldPartial = nil; self.showPartial(held) }
        }
    }

    private func translate(_ text: String) async -> String {
        switch engineInUse {
        case .onDevice:
            if #available(iOS 26.0, *), let session = translation as? TranslationSession {
                do { return try await session.translate(text).targetText } catch {
                    problem = "On-device translation failed: \(error.localizedDescription)"
                }
            }
            return ""
        case .jarvis:
            do {
                let response = try await JarvisAPI.shared.post("/api/translate/text",
                    json: ["text": text, "source": Self.base(source), "target": Self.base(target)], timeout: 25)
                return (try response.object()["translation"] as? String) ?? ""
            } catch {
                problem = "Jarvis couldn't translate: \(error.localizedDescription)"
                return ""
            }
        case .soniox:
            return ""
        }
    }

    private func prepareOnDeviceTranslation() async throws {
        guard #available(iOS 26.0, *) else {
            throw InmoProtocolError.unavailable("On-device translation needs iOS 26. Pick Jarvis or Soniox.")
        }
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        let status = await LanguageAvailability().status(from: from, to: to)
        switch status {
        case .installed:
            translation = TranslationSession(installedSource: from, target: to)
        case .supported:
            throw InmoProtocolError.unavailable("Download \(Self.name(source)) and \(Self.name(target)) first (Download languages, below).")
        default:
            throw InmoProtocolError.unavailable("On-device translation can't do \(Self.name(source)) → \(Self.name(target)). Pick Jarvis or Soniox.")
        }
    }

    // MARK: Soniox through the Jarvis server

    private func openSoniox() async throws {
        let url = try VoiceAPI().socketURL(path: "/api/translate/ws")
        let socket = try await URLSessionVoiceSocketConnector().connect(url: url, headers: JarvisAPI.shared.credentials.headers)
        socket.onFrame = { [weak self] frame in
            if case .text(let text) = frame { self?.sonioxFrame(text) }
        }
        socket.onClose = { [weak self] error in
            guard let self else { return }
            self.sonioxFinished = true
            // A dead socket leaves nothing listening: end the session, say why.
            guard self.phase == .running, self.socket != nil else { return }
            self.problem = Self.serverProblem(error)
            self.socket = nil
            Task { await self.stop() }
        }
        let start: [String: Any] = ["type": "start", "source": Self.base(source), "target": Self.base(target)]
        let body = try JSONSerialization.data(withJSONObject: start)
        socket.send(text: String(decoding: body, as: UTF8.self))
        self.socket = socket
    }

    private func sonioxFrame(_ text: String) {
        guard let frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        switch frame["type"] as? String {
        case "partial":
            guard phase == .running, let words = frame["text"] as? String else { return }
            hearing = words
            showPartial(words)
        case "line":
            guard let key = frame["key"] as? Int, let original = frame["text"] as? String else { return }
            let translated = frame["translation"] as? String ?? ""
            let id = nextID; nextID += 1
            sonioxLines[key] = id
            hearing = ""
            lines.append(Line(id: id, original: original, translation: translated, final: !translated.isEmpty, ms: elapsedMs))
            post(GlassesTranslateWire.line(original: original, translation: translated, finished: !translated.isEmpty))
        case "translation":
            guard let key = frame["key"] as? Int, let id = sonioxLines[key], let translated = frame["text"] as? String else { return }
            setTranslation(id, translated, final: true)
        case "error":
            // The server drops a failed stream: nothing more will be heard.
            problem = frame["message"] as? String ?? "Soniox error"
            if phase == .running { let dead = socket; socket = nil; dead?.close(); Task { await stop() } }
        case "done":
            sonioxFinished = true
        default:
            break
        }
    }

    /// The upgrade to /api/translate/ws fails as a bad server response when the
    /// server is older than this app (no such socket).
    static func serverProblem(_ error: Error?) -> String {
        if let url = error as? URLError, url.code == .badServerResponse {
            return "The Jarvis server doesn't have live translation yet — it needs updating."
        }
        return "Lost the Jarvis server" + (error.map { ": \($0.localizedDescription)" } ?? ".")
    }

    // MARK: Lens

    private func setTranslation(_ id: Int, _ text: String, final: Bool) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].translation = text
        lines[i].final = final
        if phase == .running || phase == .stopping {
            post(GlassesTranslateWire.line(original: lines[i].original, translation: text, finished: final))
        }
    }

    /// The line being heard, at most ~3×/s, and never on top of a sentence still
    /// waiting for its translation (the lens would flip back to the older line).
    private func showPartial(_ text: String) {
        guard pendingTranslations == 0 else { heldPartial = text; return }
        guard Date().timeIntervalSince(lastPartialSent) >= 0.3 else { heldPartial = text; scheduleHeld(); return }
        lastPartialSent = Date()
        heldPartial = nil
        post(GlassesTranslateWire.line(original: text, translation: "", finished: false))
    }

    private func scheduleHeld() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self, self.phase == .running, self.pendingTranslations == 0, let held = self.heldPartial else { return }
            self.showPartial(held)
        }
    }

    private var elapsedMs: Int { Int(Date().timeIntervalSince(startedAt) * 1000) }

    private func post(_ message: Data) {
        let previous = sendChain
        sendChain = Task {
            await previous?.value
            do { try await InmoSession.shared.send(message) } catch {
                InmoRuntimeDiagnostics.note("translate send failed: \(error.localizedDescription)")
            }
        }
    }
}
