import Foundation

/// Sensor + media skills: location, camera, speech, mic, playback.
///
/// Port of the matching entries in `mobile_client/lib/skills/common.dart`.
enum MediaSkills {

    // MARK: get_location

    static func getLocation(_ locator: any LocationFixing) -> AnySkill {
        AnySkill(
            name: "get_location",
            description: "Return a one-shot GPS fix (latitude, longitude, accuracy)."
        ) { _ in
            // 12 s cap, then the last known position: a cold GPS fix indoors can
            // otherwise hang all the way to the server's 30 s invoke timeout.
            let fix = try await locator.oneShot(timeout: 12)
            return [
                "latitude": fix.latitude,
                "longitude": fix.longitude,
                "accuracy_m": fix.accuracyMeters,
                "ts": ISO8601DateFormatter().string(from: fix.timestamp),
            ]
        }
    }

    // MARK: take_photo / pick_photo

    static func takePhoto(_ picker: any PhotoPicking) -> AnySkill {
        photo(name: "take_photo",
              description: "Open the camera so the user can take a photo; the server describes it "
                + "(pass `question` to ask something specific about it).",
              source: .camera, picker: picker)
    }

    static func pickPhoto(_ picker: any PhotoPicking) -> AnySkill {
        photo(name: "pick_photo",
              description: "Open the iOS photo picker so the user can choose a photo from their "
                + "library; the server describes it (pass `question` to ask something specific). "
                + "For 'my latest photo' use recent_photo instead — no picker needed.",
              source: .library, picker: picker)
    }

    /// The `question` arg is read by the SERVER (device_skill_tools) as the
    /// vision prompt; the skill only ships the pixels.
    private static let questionSchema = SkillSchema.object([
        "question": SkillSchema.string("What to look for / answer about the photo"),
    ])

    private static func photo(name: String, description: String,
                              source: PhotoSource, picker: any PhotoPicking) -> AnySkill {
        AnySkill(name: name, description: description, inputSchema: questionSchema,
                 requiresForeground: true) { _ in
            guard let image = try await picker.pick(source) else { return ["cancelled": true] }
            return [
                "base64": image.data.base64EncodedString(),
                "mime": image.mime,
                "bytes": image.data.count,
            ]
        }
    }

    // MARK: recent_photo

    static func recentPhoto(_ library: any PhotoLibraryReading) -> AnySkill {
        AnySkill(
            name: "recent_photo",
            description: "Read the user's most recent photo straight from the iOS photo library "
                + "(no picker): `index` 0 = newest, 1 = the one before, … The server describes "
                + "it; pass `question` to ask something specific about it.",
            inputSchema: SkillSchema.object([
                "index": SkillSchema.integer(min: 0, max: 50, description: "0 = newest"),
                "question": SkillSchema.string("What to look for / answer about the photo"),
            ])
        ) { args in
            let index = max(0, SkillArgs.int(args, "index") ?? 0)
            guard try await library.requestAuthorization() else {
                throw SkillError.permissionDenied("photo library")
            }
            guard let photo = try await library.recent(index: index, maxPixels: PhotoEncoding.defaultMaxPixels) else {
                return ["found": false, "error": "the library has no photo at index \(index)", "index": index]
            }
            var out: [String: Any] = [
                "found": true,
                "index": index,
                "base64": photo.data.base64EncodedString(),
                "mime": photo.mime,
                "bytes": photo.data.count,
                "width": photo.width,
                "height": photo.height,
                "library_count": photo.total,
            ]
            if let t = photo.takenAt { out["taken_at"] = DataSkills.isoString(t) }
            return out
        }
    }

    // MARK: text_to_speech

    static func textToSpeech(_ speech: any SpeechSynthesizing) -> AnySkill {
        AnySkill(
            name: "text_to_speech",
            description: "Speak the given text via the on-device TTS engine.",
            inputSchema: SkillSchema.object([
                "text": SkillSchema.string(),
                "voice": SkillSchema.string("Voice name or AVSpeechSynthesisVoice identifier."),
                "locale": SkillSchema.string("BCP-47 tag, default en-US."),
            ], required: ["text"])
        ) { args in
            let text = SkillArgs.string(args, "text")
            guard !text.isEmpty else { throw SkillError.badArgument("text required") }
            let locale = SkillArgs.string(args, "locale")
            let ok = try await speech.speak(text,
                                            voice: SkillArgs.string(args, "voice"),
                                            locale: locale.isEmpty ? "en-US" : locale)
            return ["ok": ok]
        }
    }

    // MARK: record_audio

    static func recordAudio(_ recorder: any AudioRecording) -> AnySkill {
        AnySkill(
            name: "record_audio",
            description: "Record a short audio clip from the mic and return it as base64. "
                + "Caller specifies duration in seconds (default 5, max 60).",
            inputSchema: SkillSchema.object([
                "duration_s": SkillSchema.integer(min: 1, max: 60),
            ])
        ) { args in
            let seconds = min(max(SkillArgs.int(args, "duration_s") ?? 5, 1), 60)
            do {
                let clip = try await recorder.record(seconds: seconds)
                return [
                    "recorded": true,
                    "base64": clip.data.base64EncodedString(),
                    "mime": clip.mime,
                    "bytes": clip.data.count,
                    "duration_s": clip.seconds,
                ]
            } catch {
                // Reported rather than thrown, same as the Flutter skill —
                // "mic permission denied" is an answer, not a tool failure.
                return ["recorded": false, "error": SystemSkills.message(error)]
            }
        }
    }

    // MARK: play_audio

    static func playAudio(_ player: any AudioPlaying) -> AnySkill {
        AnySkill(
            name: "play_audio",
            description: "Play an audio clip through this device's speaker — e.g. a "
                + "server-generated JARVIS-voice TTS clip. Pass audio_base64 (raw bytes; "
                + "mp3/wav/m4a/etc.) OR a url. Prefer this over text_to_speech when you want the "
                + "real JARVIS voice instead of the phone's built-in synthesizer.",
            inputSchema: SkillSchema.object([
                "audio_base64": SkillSchema.string(),
                "url": SkillSchema.string(),
                "volume": SkillSchema.number(min: 0, max: 1),
            ])
        ) { args in
            let base64 = SkillArgs.string(args, "audio_base64")
            let urlText = SkillArgs.string(args, "url")
            let volume = min(max(SkillArgs.number(args, "volume") ?? 1.0, 0), 1)
            do {
                if !base64.isEmpty {
                    let payload = base64.contains(",")
                        ? String(base64.split(separator: ",").last ?? "") : base64
                    guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
                        throw SkillError.badArgument("audio_base64 is not valid base64")
                    }
                    try await player.play(data: data, volume: volume)
                    return ["played": true, "bytes": data.count]
                }
                if !urlText.isEmpty {
                    guard let url = URL(string: urlText) else {
                        throw SkillError.badArgument("\"\(urlText)\" is not a URL")
                    }
                    // The player fetches whatever it's handed, so a `file://`
                    // would read any file the app can see and an `http://` would
                    // let anyone on the path choose what JARVIS says out loud.
                    guard url.scheme?.lowercased() == "https" else {
                        throw SkillError.badArgument("url must be https://")
                    }
                    try await player.play(url: url, volume: volume)
                    return ["played": true, "url": urlText]
                }
                return ["played": false, "error": "audio_base64 or url required"]
            } catch {
                return ["played": false, "error": SystemSkills.message(error)]
            }
        }
    }

    // MARK: media_control

    static let mediaActions = ["play", "pause", "toggle", "next", "previous", "status"]

    /// What media_control last asked for. Players hold the audio session for a few seconds
    /// after pausing, so for a moment our own record beats `isOtherAudioPlaying` — otherwise a
    /// second "pause" would run the toggle Shortcut and start the music again.
    private final class RecentPress {
        var playing = false
        var at: Date?
    }
    static let mediaTrust: TimeInterval = 15

    /// `settle` is the wait between checks while the playing app starts or stops its audio.
    static func mediaControl(_ media: any MediaControlling, settle: TimeInterval = 0.25,
                             now: @escaping () -> Date = Date.init) -> AnySkill {
        let recent = RecentPress()
        let isPlaying = { () async -> Bool in
            if let at = recent.at, now().timeIntervalSince(at) < mediaTrust { return recent.playing }
            return await media.othersPlaying()
        }
        return AnySkill(
            name: "media_control",
            description: "Control the music, podcast or video playing on this phone: play, pause, "
                + "toggle, next or previous track. Apple Music is driven directly, even with the phone "
                + "locked; any other app goes through the \"JC Play Pause\" / \"JC Next Track\" / "
                + "\"JC Previous Track\" Shortcuts, which need the phone unlocked. `play` and `pause` "
                + "do nothing when it's already in that state; `status` says what is playing.",
            inputSchema: SkillSchema.object([
                "action": SkillSchema.enumeration(mediaActions),
            ], required: ["action"])
        ) { args in
            let action = SkillArgs.string(args, "action").lowercased()
            guard mediaActions.contains(action) else {
                throw SkillError.badArgument("action must be one of \(mediaActions.joined(separator: ", "))")
            }
            let wait = { try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000)) }
            var out: [String: Any] = ["action": action]

            if action == "status" {
                let playing = await isPlaying()
                out["ok"] = true
                out["playing"] = playing
                if await media.musicState() == .playing {
                    out["player"] = "Apple Music"
                    if let now = await media.musicNowPlaying() { out["now_playing"] = json(now) }
                } else if playing {
                    out["player"] = "another app"
                }
                return out
            }

            if action == "next" || action == "previous" {
                let command: MediaCommand = action == "next" ? .next : .previous
                if await media.musicState() == .playing {
                    await media.sendToMusic(command)
                    await wait()
                    out["ok"] = true
                    out["changed"] = true
                    out["via"] = "apple_music"
                    if let now = await media.musicNowPlaying() { out["now_playing"] = json(now) }
                    return out
                }
                if finished(await media.runShortcut(command), &out) { return out }
                out["ok"] = true
                out["changed"] = true
                return out
            }

            let playing = await isPlaying()
            if action == "pause" && !playing || action == "play" && playing {
                out["ok"] = true
                out["changed"] = false
                out["playing"] = playing
                out["note"] = playing ? "already playing" : "nothing is playing"
                return out
            }
            let want = action == "toggle" ? !playing : action == "play"
            // Only a pause can go straight to Music: a play from silence has to resume whichever
            // app last had Now Playing, and only the system Play/Pause knows which one that is.
            if !want, await media.musicState() == .playing {
                await media.sendToMusic(.pause)
                out["via"] = "apple_music"
            } else if finished(await media.runShortcut(want ? .play : .pause), &out) {
                return out
            }
            recent.playing = want
            recent.at = now()
            var heard = playing
            for _ in 0..<12 where heard != want {
                await wait()
                heard = await media.othersPlaying()
            }
            out["ok"] = true
            out["changed"] = true
            out["playing"] = want
            if heard != want {
                out["confirmed"] = false
                out["note"] = want ? "Sent; nothing is making sound yet — the app may still be starting."
                    : "Sent; the app is still holding the audio, which some do for a few seconds after pausing."
            }
            return out
        }
    }

    /// Folds a Shortcut run into the reply; true when there is nothing left to check — it was
    /// queued behind a notification (the app is in the background) or it didn't run.
    private static func finished(_ result: [String: Any], _ out: inout [String: Any]) -> Bool {
        out["via"] = "shortcut"
        if let name = result["shortcut"] as? String { out["shortcut"] = name }
        if SkillArgs.bool(result, "queued") == true {
            out["ok"] = true
            out["queued"] = true
            out["note"] = result["note"] as? String ?? "Sent to your phone — tap the notification to run it."
            return true
        }
        if SkillArgs.bool(result, "ran") == false {
            out["ok"] = false
            out["error"] = result["error"] as? String ?? "The Shortcut didn't run."
            return true
        }
        return false
    }

    private static func json(_ now: NowPlaying) -> [String: Any] {
        var out: [String: Any] = [:]
        if let title = now.title { out["title"] = title }
        if let artist = now.artist { out["artist"] = artist }
        if let album = now.album { out["album"] = album }
        if let app = now.app { out["app"] = app }
        return out
    }
}
