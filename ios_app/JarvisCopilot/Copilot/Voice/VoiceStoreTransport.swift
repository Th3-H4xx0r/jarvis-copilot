import Foundation

// The transport half of `VoiceStore`: opening the realtime socket, decoding what
// the server sends, the push-to-talk round trip, speaking a local reply in the
// JARVIS voice, and the Live Activity snapshot. Split out to keep either file
// readable; nothing here is called from outside the store.
extension VoiceStore {

    // MARK: - Realtime transport

    func openTransport() async {
        let epoch = turnEpoch
        do {
            // Own + activate the audio session BEFORE the mic/playback start, so
            // the loud speaker route is locked in for the whole conversation.
            try acquireAudioSession()
            let sid = try await ensureSession()
            note("session \(sid.isEmpty ? "(none)" : "ok")")
            // Clear any stream the server still thinks is running for this
            // session (e.g. the app was backgrounded mid-turn) — otherwise the
            // next turn fails with "session already has an active stream".
            await voice.cancelActiveStream(sessionID: sid)
            // Resolving the session is three round trips through the tunnel; a
            // Stop during them used to leave a socket opening behind the
            // teardown that was supposed to close it, with the mic already off.
            guard epoch == turnEpoch, machine.state == .connecting else {
                note("open transport superseded")
                return
            }
            try await session.open()
            session.send(beginTurn(sessionID: sid))
            raise(.connected)
        } catch {
            raise(.failed("Could not start voice: \(JcLog.report(JcLog.voice, "open transport", error))"))
        }
    }

    /// The `begin_turn` frame, with this surface's model choice attached.
    ///
    /// Flutter puts `_voiceModelFields()` on every turn body: the voice surface
    /// has its OWN model (`sel_voice_model`), independent of chat, and omitting
    /// it silently ran every turn on the server's default instead of the one the
    /// user picked in the Voice picker.
    func beginTurn(sessionID: String) -> VoiceClientMessage {
        let fields = voiceTurnModelFields()
        return .beginTurn(sampleRate: Self.micRate, sessionID: sessionID,
                          model: fields["model"] as? String,
                          provider: fields["model_provider"] as? String)
    }

    /// Raise voice's claim on the process-wide `AVAudioSession` and make sure it
    /// is active.
    ///
    /// Called from `startMic` and NOT only from `openTransport`, because
    /// push-to-talk never opens a transport: its `startRequested` goes straight
    /// to `.startMic`. Without this the mic started against whatever category the
    /// app was last left in — `.soloAmbient` by default, or `.playback` once
    /// `BackgroundKeepalive` arms (which it does for the whole launch on a paired
    /// phone). Neither permits recording, so `AVAudioEngine.inputNode` reports no
    /// input route and `DefaultAudioInput` fails all five attempts.
    ///
    /// Both calls now land in `AudioSessionArbiter` (via
    /// `DefaultAudioSessionControlling`), which holds the union of this claim and
    /// the keepalive's: voice wins the category for the length of the turn, and
    /// the matching `setActive(false)` in `stop()` only DROPS the claim — it
    /// deactivates nothing while the keepalive still needs the session.
    func acquireAudioSession() throws {
        try audioSession.configureForConversation()
        try audioSession.setActive(true)
    }

    /// `generation` is the mic effect that asked for this start. The engine
    /// retries for up to ~1.75 s, so a start can outlive the turn that wanted it
    /// (Stop, a failure, a mode switch) — and a live mic at `.idle` is a privacy
    /// bug, not just a battery one.
    func startMic(generation: Int) async {
        do {
            // Both modes route through here, so this is the one place that can
            // guarantee the session is recordable before the engine is built.
            try acquireAudioSession()
            try await input.start(sampleRate: Self.micRate)
            guard generation == micGeneration, machine.state.isActive else {
                await input.stop()
                note("mic start superseded (gen \(generation))")
                return
            }
            note("mic started @\(Self.micRate)")
        } catch {
            guard generation == micGeneration else { return }
            raise(.failed(JcLog.report(JcLog.voice, "start mic", error)))
        }
    }

    /// The server's dedicated, persistent "Voice" chat — NOT whatever session is
    /// most-recent. The old Flutter code grabbed index 0 of `/api/sessions`,
    /// which is sorted recent-first and includes coding/CLI/Telegram channels;
    /// voice then ran against a session wired to a provider+model it couldn't use
    /// (e.g. Codex with an empty model) and silently failed. The server
    /// get-or-creates this one with a valid model/provider.
    func ensureSession() async throws -> String {
        if let sessionID, !sessionID.isEmpty { return sessionID }
        do {
            let id = try await voice.voiceSessionID()
            if !id.isEmpty {
                sessionID = id
                return id
            }
        } catch {
            // Older servers have no /api/voice/session; fall through and create
            // a plain chat instead.
            JcLog.dropped(JcLog.voice, "resolve voice session", error)
        }
        // Fallback for older servers without /api/voice/session: a plain chat
        // titled "Voice".
        let created = try await voice.api.post("/api/session/new",
                                               json: ["title": "Voice"]).object()
        let session = created.dict("session") ?? created
        let id = session.string("session_id") ?? ""
        guard !id.isEmpty else { throw APIError.badResponse("could not create a voice session") }
        sessionID = id
        return id
    }

    /// Ask the server to run the agent on this turn. When the on-device
    /// recognizer already has the text we hand it over and the server skips its
    /// own STT; otherwise `end_turn` goes out now (the PCM has been streaming all
    /// along, so this costs nothing).
    func sendTurnToServer() {
        if machine.mode == .quality {
            Task { await postQualityTurn() }
            return
        }
        // "Try on server": this turn's text was decided by the on-device lane,
        // so there is no recognizer to wait on and no new audio to endpoint.
        if let retry = pendingRetryText {
            pendingRetryText = nil
            sendEndTurn(text: retry)
            return
        }
        if let running = speech {
            speech = nil
            let epoch = turnEpoch
            Task { await finishStreamedTurn(running, epoch: epoch) }
            return
        }
        sendEndTurn(text: nil)
    }

    private func sendEndTurn(text: String?) {
        // A send into a socket that is already gone used to vanish, leaving the
        // turn in `thinking` waiting for a reply that can never arrive.
        guard session.send(.endTurn(text: text, clientTs: nowMs(),
                                    speechEndTs: speechEndMs, turnID: turnID)) else {
            raise(.failed(Self.connectionLostNotice))
            return
        }
    }

    /// The on-device recognizer already has this turn's text, so asking for it
    /// costs nothing and lets `end_turn` carry `text`.
    private func finishStreamedTurn(_ running: SpeechSession, epoch: Int) async {
        let final = await voiceStopWithDeadline(running, after: Self.sttFinalTimeoutMs, clock: clock)
        let transcript = final.trimmingCharacters(in: .whitespacesAndNewlines)
        guard epoch == turnEpoch, machine.state.isActive else { return }
        guard !transcript.isEmpty else {
            sendEndTurn(text: nil) // recognizer produced nothing → server STT
            return
        }
        userTranscript = transcript
        pushLiveActivity()
        // The on-device lane gets first refusal: when it finishes the turn here
        // there is no `end_turn`, so the server never runs the agent for it.
        if await tryLocalTurn(transcript, epoch: epoch) {
            guard epoch == turnEpoch, machine.state.isActive else { return }
            resetServerTurn()
            return
        }
        guard epoch == turnEpoch, machine.state.isActive else { return }
        sendEndTurn(text: transcript)
    }

    // MARK: - Server frames

    func handle(_ frame: VoiceServerFrame) {
        switch frame {
        case .ready:
            break

        case .transcript(let text):
            userTranscript = text
            pushLiveActivity() // show your line on the island while listening

        case .assistantText(let text):
            reply.append(text)
            toolStatus = nil
            raise(.serverOutput)

        case .tool(let name, let status):
            toolStatus = status == "completed" ? nil : "Running \(name)"
            raise(.serverOutput)

        case .audioMeta(let format, let sampleRate):
            inFormat = format
            inRate = sampleRate
            // Claim the karaoke segment NOW: PCM is played as it arrives (plan
            // 1.7), so there is no flush point left at which to pair them.
            pcmTag = reply.claimSegmentTag()
            segMp3.removeAll()
            raise(.serverOutput)

        case .audioEnd:
            flushSegment()

        case .endTurn(let reason):
            // Flush any audio that didn't get an explicit audio_end.
            flushSegment()
            let producedReply = audio.isBusy || !reply.isEmpty
            toolStatus = nil
            if VoiceTurnMachine.failureReasons.contains(reason), !producedReply {
                // Drop the cached session id so the NEXT connect re-resolves the
                // voice session — guards against a wedged turn repeating forever
                // if the cached id ever goes bad server-side.
                sessionID = nil
            }
            raise(.turnEnded(reason: reason, producedReply: producedReply))

        case .latency:
            // A server-side span for this turn (plan 0.2). Correlated by turn_id
            // in the server's own trace; nothing to do on the client.
            break

        case .escalationResult(let text):
            // The slow lane finished after we already answered this turn. Read it
            // out if the user is still on the voice screen (plan 4.4).
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, machine.state.isActive else { return }
            raise(.serverOutput)
            Task { await speakLocally(trimmed) }

        case .audio(let data):
            handleAudioFrame(data)

        case .other:
            break
        }
    }

    private func handleAudioFrame(_ data: Data) {
        if inFormat == "mp3" {
            segMp3.append(data)
            return
        }
        // Stream it straight into the player instead of buffering the whole
        // segment (plan 1.7) — the first ~160 ms starts playing immediately.
        if pcmTag == nil { pcmTag = reply.claimSegmentTag() } // text may land after audio_meta
        noteFirstAudio()
        audio.appendPcm(data, sampleRate: inRate, tag: pcmTag)
    }

    /// End of one reply segment. MP3 is still whole-buffer (the decoder needs a
    /// complete file); PCM only has to close out the stream.
    private func flushSegment() {
        if inFormat == "mp3" {
            guard !segMp3.isEmpty else { return }
            noteFirstAudio()
            audio.enqueueMp3(segMp3, tag: reply.claimSegmentTag())
            segMp3.removeAll()
        } else {
            audio.endPcmSegment(tag: pcmTag)
            pcmTag = nil
        }
    }

    // MARK: - Quality mode (push-to-talk)

    func postQualityTurn() async {
        let clip = qualityPcm
        qualityPcm.removeAll()
        amplitude = 0
        guard clip.count >= Self.minQualityBytes else {
            raise(.failed("Didn't catch that — try again."))
            return
        }
        do {
            // The session id is REQUIRED here (the server 400s without one),
            // unlike the realtime socket where it is optional.
            let sid = try await ensureSession()
            note("quality turn \(clip.count)B session=ok")
            let stream = voice.qualityTurn(audio: clip, sessionID: sid,
                                           sampleRate: Self.micRate,
                                           extra: voiceTurnModelFields())
            qualityTask.replace(Task { @MainActor [weak self] in
                do {
                    for try await event in stream {
                        guard let self else { return }
                        self.handleQuality(event)
                    }
                    guard let self else { return }
                    // The stream is done; if nothing is playing, settle to idle.
                    self.raise(.qualityStreamDone(playbackBusy: self.audio.isBusy))
                } catch is CancellationError {
                    return
                } catch {
                    self?.raise(.failed(JcLog.report(JcLog.voice, "quality turn", error)))
                }
            })
        } catch {
            raise(.failed(JcLog.report(JcLog.voice, "quality turn", error)))
        }
    }

    func handleQuality(_ event: VoiceQualityEvent) {
        switch event.type {
        case "transcript":
            userTranscript = event.text ?? ""
            pushLiveActivity()

        case "segment":
            if event.kind == "tool" {
                let status = event.status ?? "started"
                toolStatus = status == "completed" ? nil : "Running \(event.name ?? "tool")"
                raise(.serverOutput)
            } else if event.kind == "text" {
                // Quality mode hands text + audio together, so the clip pairs
                // with the segment THIS event added — and only that one.
                // `segments.count - 1` tagged the PREVIOUS segment whenever the
                // frame carried audio but no usable text, which re-ran that
                // segment's word highlight against a clip it doesn't own.
                var tag: Int?
                if let text = event.text, !text.isEmpty { tag = reply.append(text) }
                if let data = event.audio, !data.isEmpty {
                    if let tag { reply.assignAudio(to: tag) }
                    noteFirstAudio()
                    audio.enqueueMp3(data, tag: tag)
                }
                raise(.serverOutput)
            }

        case "error":
            raise(.failed(event.error ?? "Voice request failed"))

        case "done":
            toolStatus = nil
            raise(.qualityStreamDone(playbackBusy: audio.isBusy))

        default:
            break
        }
    }

    // MARK: - Speaking a reply in the JARVIS voice

    /// Split `text` into sentence-sized chunks and TTS each as its OWN clip +
    /// karaoke segment — exactly like the server path. This is what makes the
    /// word highlight advance (a single big clip leaves it stuck) and lets
    /// playback start after the first sentence. Offline (no TTS bytes) the reply
    /// stays on screen as text and we resume listening.
    func speakLocally(_ text: String) async {
        let epoch = turnEpoch
        let chunks = voiceSplitForSpeech(voicePlainSpeech(text))
        guard !chunks.isEmpty else {
            raise(.playbackDrained)
            return
        }
        // Append karaoke segments up front (the reply renders immediately and the
        // word count is stable), recording each chunk's real segment index — a
        // chunk that markdown-strips to empty adds no segment, so skip it rather
        // than mis-tagging.
        var tags: [Int] = []
        var speak: [String] = []
        for chunk in chunks {
            if let tag = reply.append(chunk) {
                tags.append(tag)
                speak.append(chunk)
            }
        }
        guard epoch == turnEpoch, machine.state.isActive else { return }
        guard !speak.isEmpty else {
            if !audio.isBusy {
                reply.finalizeSpoken()
                raise(.playbackDrained)
            }
            return
        }
        // Synthesize ALL clips CONCURRENTLY and WAIT for the whole set before
        // enqueuing any: enqueuing in index order as each resolved let a slow
        // middle clip drain the queue between clips, which flipped us to
        // "thinking" and let the resume-grace timer abandon the reply. The wait
        // is the MAX (not the sum) of the calls and the text is already on
        // screen, so for short replies it's negligible.
        let api = voice
        let engine = settings.engine
        let voiceName = settings.voice
        var clips = [Data](repeating: Data(), count: speak.count)
        await withTaskGroup(of: (Int, Data).self) { group in
            for (index, chunk) in speak.enumerated() {
                group.addTask {
                    (index, await api.synthesizeOrEmpty(text: chunk, voice: voiceName, engine: engine))
                }
            }
            for await (index, data) in group {
                // A barge-in / Stop while the sentences are still synthesizing:
                // drop the rest instead of paying for TTS nobody will hear.
                guard epoch == turnEpoch else {
                    group.cancelAll()
                    break
                }
                clips[index] = data
            }
        }
        guard epoch == turnEpoch, machine.state.isActive else { return }
        var anyAudio = false
        for (index, data) in clips.enumerated() where !data.isEmpty {
            reply.assignAudio(to: tags[index])
            noteFirstAudio()
            audio.enqueueMp3(data, tag: tags[index])
            anyAudio = true
        }
        // `synthesizeOrEmpty` turns a TTS failure into silence; say so rather
        // than leaving a reply on screen that mysteriously never gets spoken.
        if clips.contains(where: \.isEmpty) { error = Self.ttsUnavailableNotice }
        if !anyAudio, !audio.isBusy {
            // Offline / no audio → the reply is shown as text; resume listening.
            reply.finalizeSpoken()
            raise(.playbackDrained)
        }
    }

    /// Speak `text` with the PHONE's synthesizer — the sub-100 ms voice, for
    /// acknowledging something that already happened locally. Falls back to the
    /// JARVIS voice when there's no synthesizer.
    func acknowledgeLocally(_ text: String) async {
        if await synthesizer.speak(text, rate: DefaultVoiceSynthesizing.defaultRate) {
            reply.append(text)
            noteFirstAudio()
            reply.finalizeSpoken()
            raise(.playbackDrained)
        } else {
            await speakLocally(text)
        }
    }

    // MARK: - On-device recognizer

    /// Open a live recognizer for the next utterance. Best-effort and silent: a
    /// device without streaming STT simply runs the server-STT path.
    func startSpeechSession() async {
        guard speech == nil, machine.mode == .realtime else { return }
        // Only PROMPT for Speech when the user opted into on-device AI for voice
        // (Flutter passes `LocalAiSettings.enabledForVoice` here). Otherwise we
        // take the session only if permission was already granted, so enabling
        // nothing still changes nothing.
        let prompt = local != nil && LocalAiSettings.shared.enabledForVoice
        guard let session = await recognizer.startSession(sampleRate: Self.micRate,
                                                          prompt: prompt) else { return }
        guard machine.state.isActive else {
            session.cancel()
            return
        }
        speech = session
    }

    /// Drop any in-flight recognizer (barge-in, stop, teardown).
    func abortSpeechSession() {
        let running = speech
        speech = nil
        running?.cancel()
    }

    // MARK: - Live Activity (Dynamic Island)

    /// Recompute the desired content and hand it to the throttle. Called on every
    /// state change and whenever a line of text changes.
    func pushLiveActivity() {
        maybeRefreshDevices()
        let snapshot = VoiceLiveActivitySnapshot(
            // `connecting` shows as `thinking`: the island has no distinct art
            // for it and flipping between the two reads as a glitch.
            state: machine.state == .connecting ? "thinking" : machine.state.rawValue,
            transcript: voiceFirstLine(userTranscript),
            activity: voiceOutputLine(error: error, toolStatus: toolStatus,
                                      state: machine.state, assistantText: reply.text),
            connected: voice.api.isPaired,
            devices: deviceKinds)
        let terminal = machine.state == .idle || machine.state == .error
        liveActivity.offer(snapshot, terminal: terminal)
    }

    /// Refresh the online-device list (for the Live Activity strip) at most once
    /// every 15 s, and only while a turn is live. Fire-and-forget: failures keep
    /// the last-known list.
    private func maybeRefreshDevices() {
        guard machine.state.isActive, !devicesFetching else { return }
        guard clock.now.timeIntervalSince(devicesAt) >= Self.devicesRefreshSeconds else { return }
        devicesFetching = true
        let api = voice.api
        Task { @MainActor [weak self] in
            var kinds: [String]?
            do {
                // Named key, not `.array()`: that helper scans a fixed key list
                // and hands back whichever it meets FIRST, so a reply that also
                // carries another array (`sessions`, `items`, …) would quietly
                // give us the wrong one.
                kinds = try await api.get("/api/devices").array(key: "devices")
                    .compactMap { $0 as? [String: Any] }
                    .filter { $0.bool("online") ?? false }
                    .map(deviceIconKind)
            } catch {
                // The island keeps its last-known strip; only the log cares.
                JcLog.dropped(JcLog.voice, "refresh devices", error)
            }
            guard let self else { return }
            self.devicesFetching = false
            self.devicesAt = self.clock.now // back off on error too
            guard let kinds else { return }
            let trimmed = Array(kinds.prefix(VoiceLiveActivityThrottle.maxDevices))
            guard trimmed != self.deviceKinds else { return }
            self.deviceKinds = trimmed
            self.pushLiveActivity() // guarded by devicesAt, so this can't recurse
        }
    }
}
