import Foundation
import Observation
import Combine

@MainActor
@Observable
final class InmoAIChannel {
    static let shared = InmoAIChannel()
    private(set) var enabled = false
    private(set) var status = "Glasses AI is off" { didSet { if oldValue != status { InmoRuntimeDiagnostics.note("AI status: " + status) } } }
    private var audioMessages = 0
    private var decodedBytes = 0
    private let input = InmoAudioInput()
    private var observer: UUID?
    private var connectionObservation: AnyCancellable?
    private var reconnect: Task<Void, Never>?
    private var decoder: InmoOpusDecoder?
    private var generation = 0
    private var active = false
    private var poll: Task<Void, Never>?
    private var pending: [Data] = []
    private let defaults: UserDefaults
    private var restored = false
    static let enabledPreference = "inmo.jarvisAI.enabled"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Command rendering is available independently of automatic wake takeover.
    func install(on device: InmoGo3Device) {
        if !restored {
            restored = true
            if defaults.bool(forKey: Self.enabledPreference) {
                Task { await self.setEnabled(true) }
            }
        }
        device.featureHandlers["glasses_show_transcription"] = { args in
            let (text, final) = try Self.renderArguments(args)
            let payload = InmoWireCodec.uint(1, 2) + InmoWireCodec.bytes(4,
                InmoWireCodec.string(1, text) + InmoWireCodec.uint(2, final ? 1 : 0))
            try await InmoSession.shared.send(InmoCommand.envelope(type: 11, field: 14, payload: payload))
            return ["status": "sent", "final": final]
        }
        device.featureHandlers["glasses_show_answer"] = { args in
            let (text, final) = try Self.renderArguments(args)
            let payload = InmoWireCodec.uint(1, 1) + InmoWireCodec.bytes(3,
                InmoWireCodec.uint(1, 1) + InmoWireCodec.string(2, text) + InmoWireCodec.uint(5, 4))
            try await InmoSession.shared.send(InmoCommand.envelope(type: 11, field: 14, payload: payload))
            if final {
                let done = InmoWireCodec.uint(1, 1) + InmoWireCodec.bytes(3,
                    InmoWireCodec.uint(1, 1) + InmoWireCodec.uint(5, 5))
                try await InmoSession.shared.send(InmoCommand.envelope(type: 11, field: 14, payload: done))
            }
            return ["status": "sent", "final": final]
        }
    }
    static func renderArguments(_ args: [String: Any]) throws -> (String, Bool) {
        guard let text = args["text"] as? String, !text.isEmpty, text.utf8.count <= 16000 else {
            throw InmoProtocolError.malformed("AI text must contain 1–16000 UTF-8 bytes")
        }
        if let value = args["final"], !(value is Bool) {
            throw InmoProtocolError.malformed("AI final must be a boolean")
        }
        return (text, args["final"] as? Bool ?? false)
    }

    func setEnabled(_ value: Bool) async {
        defaults.set(value, forKey: Self.enabledPreference)
        guard value != enabled else { return }
        generation += 1
        InmoRuntimeDiagnostics.note("AI enabled=\(value)")
        enabled = value
        let enableEpoch = generation
        if value {
            if observer == nil {
                observer = InmoSession.shared.addEventObserver { [weak self] in self?.receive($0) }
            }
            connectionObservation = InmoSession.shared.$state.sink { [weak self] state in
                guard let self, self.enabled else { return }
                if state == .disconnected || state == .failed || state == .unavailable {
                    self.reconnect?.cancel()
                    self.reconnect = Task { [weak self] in
                        guard let self else { return }
                        let reconnectEpoch = self.generation + 1
                        await self.cancel()
                        guard self.enabled, self.generation == reconnectEpoch, !Task.isCancelled else { return }
                        self.status = "GO3 disconnected; waiting to reconnect"
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled, self.enabled, self.generation == reconnectEpoch else { return }
                        do {
                            try await InmoSession.shared.ensureConnected()
                            guard self.enabled, self.generation == reconnectEpoch else { return }
                            await self.armWake()
                            self.status = "Waiting for glasses AI activation"
                        } catch { if self.generation == reconnectEpoch { self.status = "GO3 AI connection unavailable: \(error.localizedDescription)" } }
                    }
                }
            }
            do {
                try await InmoSession.shared.ensureConnected()
                guard enabled, generation == enableEpoch else { return }
                await armWake()
                status = "Ready for a glasses AI activation; Jarvis must remain running"
            } catch { if generation == enableEpoch { status = "GO3 AI connection unavailable: \(error.localizedDescription)" } }
        } else {
            if let observer { InmoSession.shared.removeEventObserver(observer) }
            observer = nil
            connectionObservation = nil
            reconnect?.cancel(); reconnect = nil
            await cancel()
            // cancel owns the final status only while its generation is current.
        }
    }

    private func receive(_ event: InmoEvent) {
        guard enabled else { return }
        guard case let .message(type, fields, _) = event else {
            return
        }
        do {
            if type == 15, let app = try fields.firstField(18)?.nested(),
               app.firstField(1)?.varint == 4 {
                InmoRuntimeDiagnostics.note("AI module event action=\(app.firstField(2)?.varint ?? 0)")
                let opening = (app.firstField(2)?.varint ?? 0) == 0
                if opening && active { return }
                if !opening && !active { return }
                generation += 1
                let request = generation
                if (app.firstField(2)?.varint ?? 0) == 0 {
                    Task { guard enabled, generation == request else { return }; await begin() }
                } else {
                    active = false
                    Task { guard generation == request else { return }; await cancel(closeModule: false) }
                }
            } else if type == 0, active, let audio = try fields.firstField(3)?.nested() {
                let (data, lengths) = try Self.audioPayload(audio)
                audioMessages += 1
                var offset = 0
                for length in lengths where length > 0 {
                    let pcm = try decoder?.decode(data.subdata(in: offset ..< offset + length)) ?? Data()
                    decodedBytes += pcm.count
                    if input.isRunning { input.receive(pcm) }
                    else if pending.reduce(0, { $0 + $1.count }) < 96000 { pending.append(pcm) }
                    offset += length
                }
                if audioMessages % 25 == 1 { InmoRuntimeDiagnostics.note("audio messages=\(audioMessages) decoded_bytes=\(decodedBytes) input_running=\(input.isRunning)") }
            } else if type == 11, let chat = try fields.firstField(14)?.nested(),
                      chat.firstField(2)?.varint == 2 {
                VoiceStore.shared.interrupt()
            }
        } catch {
            generation += 1
            let request = generation
            active = false
            status = "Glasses audio could not be decoded: \(error)"
            Task { guard generation == request else { return }; await cancel(preserveStatus: true) }
        }
    }

    /// `audioType` 2 is the AI assistant's stream; 3 is AI notes (same framing).
    /// `paired` false: each frame is already one raw Opus packet (live
    /// translation, type 8) — split by the frame lengths, no stream wrapper.
    nonisolated static func audioPayload(_ audio: [InmoWireField], audioType: UInt64 = 2,
                                         paired: Bool = true) throws -> (Data, [Int]) {
                let header = try audio.firstField(1)?.nested() ?? []
                guard header.firstField(1)?.varint == 16000,
                      header.firstField(2)?.varint == 1,
                      header.firstField(4)?.varint == audioType,
                      let data = audio.firstField(4)?.bytes,
                      audio.firstField(3)?.varint == UInt64(data.count) else {
                    throw InmoAudioError.unsupportedFormat
                }
                var lengths: [Int] = []
                for field in audio where field.number == 5 {
                    if let value = field.varint {
                        guard value <= 2566 else { throw InmoAudioError.invalidPacket }
                        lengths.append(Int(value))
                    }
                    if let bytes = field.bytes {
                        var value: UInt64 = 0; var shift = 0
                        for byte in bytes {
                            guard shift < 63 else { throw InmoAudioError.invalidPacket }
                            value |= UInt64(byte & 127) << shift
                            if byte & 128 == 0 {
                                guard value <= 2566 else { throw InmoAudioError.invalidPacket }
                                lengths.append(Int(value)); value = 0; shift = 0
                            }
                            else { shift += 7 }
                        }
                        guard shift == 0 else { throw InmoAudioError.invalidPacket }
                    }
                }
                guard !lengths.isEmpty, lengths.allSatisfy({ $0 >= 0 && $0 <= 2566 }),
                      lengths.reduce(0, +) == data.count else { throw InmoAudioError.invalidPacket }
        if !paired { return (data, lengths.filter { $0 > 0 }) }
        // Each protobuf frame is a pair of independently encoded streams:
        // BE32 length, 4 opaque bytes, Opus; then the same for stream two.
        // Android AI forwards only stream one. Feeding the wrapper to an Opus
        // decoder can succeed syntactically while producing unintelligible PCM.
        var selected = Data()
        var selectedLengths: [Int] = []
        var offset = 0
        for length in lengths where length > 0 {
            let frame = data.subdata(in: offset ..< offset + length)
            offset += length
            guard frame.count >= 16 else { throw InmoAudioError.invalidPacket }
            func bigEndianLength(at index: Int) -> Int {
                frame[index ..< index + 4].reduce(0) { ($0 << 8) | Int($1) }
            }
            let first = bigEndianLength(at: 0)
            guard first > 0, first <= 1275, frame.count >= first + 16 else {
                throw InmoAudioError.invalidPacket
            }
            let second = bigEndianLength(at: first + 8)
            guard second > 0, second <= 1275, frame.count == first + second + 16 else {
                throw InmoAudioError.invalidPacket
            }
            selected.append(frame.subdata(in: 8 ..< first + 8))
            selectedLengths.append(first)
        }
        return (selected, selectedLengths)
    }

    func startFromPhone() async {
        await setEnabled(true)
        do {
            try await InmoSession.shared.ensureConnected()
            try await InmoSession.shared.send(InmoCommand.openModule(4))
            // Some firmware sends a matching OPEN; others only start audio.
            // An echoed OPEN is ignored once this same session is active.
            if !active { await begin() }
        } catch { status = "Could not open glasses AI: \(error.localizedDescription)" }
    }

    /// The firmware detects the phrase locally. Restore the documented setting
    /// and close any orphaned AI UI from an earlier process before waiting.
    private func armWake() async {
        guard enabled, !active, InmoSession.shared.state == .ready else { return }
        let epoch = generation
        do {
            try await InmoSession.shared.send(InmoCommand.settings(type: 21, field: 2, value: 1))
            guard enabled, !active, generation == epoch else { return }
            // Close an orphaned AI screen only when the glasses said it is the one
            // open: on a fresh connect nothing is known, and a blind close shut
            // down whatever else was running on the lens (an INMO note, 2026-09-27).
            if InmoSession.shared.status.module == 4 {
                try await InmoSession.shared.send(InmoCommand.closeModule(4))
                InmoRuntimeDiagnostics.note("AI voice wake enabled; orphaned module closed")
            } else {
                InmoRuntimeDiagnostics.note("AI voice wake enabled")
            }
        } catch {
            status = "Could not enable glasses voice wake: \(error.localizedDescription)"
        }
    }

    private func begin() async {
        InmoRuntimeDiagnostics.note("AI begin requested")
        guard enabled else { return }
        let epoch = generation + 1
        await cancel(closeModule: false)
        guard enabled, generation == epoch else { return }
        GlassesAudioLink.shared.refresh()
        // An idle output route is not proof that proprietary microphone input
        // is unavailable. AudioSession activation resolves playback separately.
        InmoRuntimeDiagnostics.note("AI starting; GO3 selected output=\(GlassesAudioLink.shared.state.speakers)")
        do { decoder = try InmoOpusDecoder() }
        catch { status = "Raw Opus decoder unavailable on this device"; return }
        active = true
        status = "Listening through GO3"
        await VoiceStore.shared.useExternalInput(input, isCurrent: { self.enabled && self.generation == epoch })
        guard enabled, generation == epoch else { return }
        await VoiceStore.shared.beginExternalTurn(isCurrent: { self.enabled && self.generation == epoch })
        guard enabled, generation == epoch else { return }
        pending.forEach(input.receive); pending.removeAll()
        var completionBaseline = VoiceStore.shared.responseCompletionGeneration
        var questionBaseline = VoiceStore.shared.questionGeneration
        var interruptionBaseline = VoiceStore.shared.interruptionGeneration
        poll = Task { [weak self] in
            var transcript = ""; var speaking = false; var finalSent = false
            var question = ""
            var renderer = InmoAIResponseRenderer()
            while !Task.isCancelled, let self, self.active, self.generation == epoch {
                let voice = VoiceStore.shared
                if voice.interruptionGeneration != interruptionBaseline || voice.questionGeneration != questionBaseline {
                    questionBaseline = voice.questionGeneration
                    interruptionBaseline = voice.interruptionGeneration
                    completionBaseline = voice.responseCompletionGeneration
                    renderer = InmoAIResponseRenderer()
                    question = ""; transcript = ""; finalSent = false
                    // Stay on the same raw input and connection for the new
                    // utterance; a barge-in is not normal response completion.
                    InmoRuntimeDiagnostics.note("AI new question; renderer reset")
                }
                let text = voice.livePartial.isEmpty ? voice.userTranscript : voice.livePartial
                let final = voice.state == .thinking || voice.state == .speaking
                if !text.isEmpty, text != transcript || (final && !finalSent) {
                    transcript = text
                    finalSent = final
                    await self.sendASR(text, final: final)
                }
                guard self.generation == epoch, self.active, !Task.isCancelled else { return }
                if final, question.isEmpty, !text.isEmpty { question = text }
                if !question.isEmpty {
                    let completed = voice.responseCompletionGeneration != completionBaseline
                    do {
                        let messages = try renderer.update(question: question, answer: voice.assistantText, finished: completed, thinking: voice.responsePending)
                        for message in messages {
                            guard self.generation == epoch, self.active, !Task.isCancelled else { return }
                            await self.send(message)
                        }
                    } catch {
                        self.status = "Could not render glasses answer: \(error.localizedDescription)"
                    }
                }
                guard self.generation == epoch, self.active, !Task.isCancelled else { return }
                let nowSpeaking = voice.state == .speaking
                if nowSpeaking != speaking { speaking = nowSpeaking; await self.sendSpeech(speaking) }
                guard self.generation == epoch, self.active, !Task.isCancelled else { return }
                self.status = voice.state == .listening ? "Listening through GO3" :
                    (voice.responsePending ? "Jarvis is thinking" : "Jarvis is speaking")
                if voice.state == .idle {
                    self.poll = nil
                    await self.cancel()
                    return
                }
                if voice.error != nil { self.status = voice.error ?? "Voice failed"; self.poll = nil; await self.cancel(preserveStatus: true); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    private func cancel(preserveStatus: Bool = false, closeModule: Bool = true) async {
        generation += 1; active = false
        let epoch = generation
        poll?.cancel(); poll = nil
        pending.removeAll(); decoder = nil
        await input.stop()
        guard generation == epoch else { return }
        if VoiceStore.shared.input === input {
            await VoiceStore.shared.useExternalInput(nil, isCurrent: { self.generation == epoch })
        }
        guard generation == epoch else { return }
        if InmoSession.shared.state == .ready {
            await sendSpeech(false)
            if closeModule, generation == epoch {
                try? await InmoSession.shared.send(InmoCommand.closeModule(4))
            }
        }
        guard generation == epoch else { return }
        if !preserveStatus { status = enabled ? "Waiting for glasses AI activation" : "Glasses AI is off" }
    }
    private func send(_ payload: Data) async {
        let epoch = generation
        if let fields = try? InmoWireCodec.decode(payload) {
            let content = try? fields.firstField(3)?.nested()
            InmoRuntimeDiagnostics.note("AI send type=\(fields.firstField(1)?.varint ?? 0) role=\(content?.firstField(1)?.varint ?? 0) state=\(content?.firstField(5)?.varint ?? 0) text_bytes=\(content?.firstField(2)?.bytes?.count ?? 0)")
        }
        do { try await InmoSession.shared.send(InmoCommand.envelope(type: 11, field: 14, payload: payload)) }
        catch { if generation == epoch { status = "Could not update glasses AI: \(error.localizedDescription)" } }
    }
    private func sendASR(_ text: String, final: Bool) async {
        await send(InmoWireCodec.uint(1, 2) + InmoWireCodec.bytes(4,
            InmoWireCodec.string(1, text) + InmoWireCodec.uint(2, final ? 1 : 0)))
    }
    private func sendAnswer(_ text: String, state: UInt64) async {
        await send(InmoWireCodec.uint(1, 1) + InmoWireCodec.bytes(3,
            InmoWireCodec.uint(1, 1) + InmoWireCodec.string(2, text) + InmoWireCodec.uint(5, state)))
    }
    private func sendAnswerState(_ state: UInt64) async {
        await send(InmoWireCodec.uint(1, 1) + InmoWireCodec.bytes(3,
            InmoWireCodec.uint(1, 1) + InmoWireCodec.uint(5, state)))
    }
    private func sendSpeech(_ speaking: Bool) async {
        await send(InmoWireCodec.uint(1, 12) + InmoWireCodec.bytes(14, InmoWireCodec.uint(1, speaking ? 1 : 0)))
    }
}
