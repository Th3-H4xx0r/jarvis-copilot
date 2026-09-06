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
              description: "Open the camera, return the captured photo as base64.",
              source: .camera, picker: picker)
    }

    static func pickPhoto(_ picker: any PhotoPicking) -> AnySkill {
        photo(name: "pick_photo",
              description: "Open the gallery picker, return the chosen photo as base64.",
              source: .library, picker: picker)
    }

    private static func photo(name: String, description: String,
                              source: PhotoSource, picker: any PhotoPicking) -> AnySkill {
        AnySkill(name: name, description: description, requiresForeground: true) { _ in
            guard let image = try await picker.pick(source) else { return ["cancelled": true] }
            return [
                "base64": image.data.base64EncodedString(),
                "mime": image.mime,
                "bytes": image.data.count,
            ]
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
}
