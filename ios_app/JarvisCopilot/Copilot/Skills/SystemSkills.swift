import Foundation

/// The always-available phone skills: URLs, apps, notifications, clipboard,
/// sharing, device info, battery, haptics, torch, dialer.
///
/// Port of the `_common` list in `mobile_client/lib/skills/common.dart` plus the
/// iOS `open_app` from `skills/ios.dart`. Each factory takes the boundary it
/// needs so tests drive the same skill against a mock.
enum SystemSkills {

    // MARK: open_url

    static func openURL(_ urls: any URLOpening) -> AnySkill {
        AnySkill(
            name: "open_url",
            description: "Open a URL in the default browser on this device. http, https, mailto "
                + "and tel links, plus the URL scheme of a known app — to open an app, prefer "
                + "the open_app skill.",
            inputSchema: SkillSchema.object(["url": SkillSchema.string()], required: ["url"]),
            requiresForeground: true
        ) { args in
            let text = SkillArgs.string(args, "url")
            guard !text.isEmpty else { throw SkillError.badArgument("url required") }
            guard let url = URL(string: text) else {
                throw SkillError.badArgument("\"\(text)\" is not a URL")
            }
            // open_url runs unconfirmed (it's on `kLocalActionAllowList`), so it
            // may only reach schemes that are links, not private control
            // surfaces — `shortcuts://` in particular would run an arbitrary
            // Shortcut past a disabled `run_shortcut`.
            guard isOpenableURL(url) else {
                throw SkillError.badArgument(
                    "\"\(url.scheme ?? text)\" URLs are not allowed — open_url handles "
                    + "http, https, mailto, tel and known app schemes.")
            }
            return ["launched": await urls.open(url)]
        }
    }

    // MARK: open_app

    static func openApp(_ apps: any AppOpening, shortcuts: any ShortcutRunning) -> AnySkill {
        AnySkill(
            name: "open_app",
            description: "Open another iOS app by name (twitter, instagram, slack, …) or by URL "
                + "scheme. Limited by the iOS sandbox to apps that register a URL scheme; falls "
                + "back to the \"JC Open App\" Shortcut, which can open any installed app.",
            inputSchema: SkillSchema.object([
                "app": SkillSchema.string("Friendly app name, e.g. \"spotify\"."),
                "scheme_url": SkillSchema.string("Explicit URL scheme, e.g. \"spotify://\"."),
            ]),
            requiresForeground: true
        ) { args in
            let appName = SkillArgs.text(args["app"] ?? args["name"])
                .trimmingCharacters(in: .whitespaces)
            let schemeURL = SkillArgs.string(args, "scheme_url").trimmingCharacters(in: .whitespaces)
            // Same gate as open_url: `open_app` is unconfirmed too, and a
            // hand-written `scheme_url` is otherwise an arbitrary-URL primitive
            // (`shortcuts://x-callback-url/run-shortcut?…`). A name-derived bare
            // scheme carries no payload and stays allowed.
            if let candidate = AppSchemeTable.resolve(appName: appName, schemeURL: schemeURL),
               !isOpenableAppScheme(candidate) {
                return AppOpenOutcome(
                    launched: false,
                    schemeURL: candidate,
                    error: "\"\(candidate)\" is not an app this skill may open").json
            }
            let outcome = await apps.open(appName: appName, schemeURL: schemeURL)
            if outcome.launched { return outcome.json }
            // iOS had no usable URL scheme. Fall back to the system "Open App"
            // action via the JC Open App Shortcut — it opens ANY installed app
            // by name (what Siri does), not just scheme-registered ones.
            //
            // Fire-and-forget: "Open App" hands control to the target app, so we
            // must NOT pass an x-success callback (it would yank the user back
            // here the instant the target opens). That means we can't observe
            // success, only that Shortcuts itself opened.
            if !appName.isEmpty {
                let viaShortcut = await shortcuts.run(name: "JC Open App", input: appName,
                                                      timeoutSeconds: 90, awaitResult: false)
                if viaShortcut.ran {
                    return ["launched": true, "via": "shortcut", "app": appName]
                }
            }
            return outcome.json
        }
    }

    // MARK: notify

    static func notify(_ notifier: any Notifying) -> AnySkill {
        AnySkill(
            name: "notify",
            description: "Show a local notification on this device.",
            inputSchema: SkillSchema.object([
                "title": SkillSchema.string(),
                "body": SkillSchema.string(),
            ], required: ["title"])
        ) { args in
            let title = SkillArgs.string(args, "title")
            guard !title.isEmpty else { throw SkillError.badArgument("title required") }
            let identifier = try await notifier.post(LocalNotificationRequest(
                title: title, body: SkillArgs.string(args, "body")))
            return ["shown": true, "id": identifier]
        }
    }

    // MARK: clipboard

    static func clipboardRead(_ clipboard: any Clipboarding) -> AnySkill {
        AnySkill(
            name: "clipboard_read",
            description: "Read the current clipboard text."
        ) { _ in
            ["text": await clipboard.read() ?? ""]
        }
    }

    static func clipboardWrite(_ clipboard: any Clipboarding) -> AnySkill {
        AnySkill(
            name: "clipboard_write",
            description: "Replace the clipboard contents with the given text.",
            inputSchema: SkillSchema.object(["text": SkillSchema.string()], required: ["text"])
        ) { args in
            let text = SkillArgs.string(args, "text")
            await clipboard.write(text)
            return ["wrote": text.count]
        }
    }

    // MARK: share

    static func shareText(_ share: any SharePresenting) -> AnySkill {
        AnySkill(
            name: "share_text",
            description: "Open the system share sheet with given text.",
            inputSchema: SkillSchema.object([
                "text": SkillSchema.string(),
                "subject": SkillSchema.string(),
            ], required: ["text"]),
            requiresForeground: true
        ) { args in
            let text = SkillArgs.string(args, "text")
            guard !text.isEmpty else { throw SkillError.badArgument("text required") }
            let subject = SkillArgs.string(args, "subject")
            let shared = try await share.present(.text(text, subject: subject.isEmpty ? nil : subject))
            return ["shared": shared]
        }
    }

    static func shareImage(_ share: any SharePresenting) -> AnySkill {
        AnySkill(
            name: "share_image",
            description: "Open the system share sheet with an image (base64-encoded bytes) and an "
                + "optional caption.",
            inputSchema: SkillSchema.object([
                "image_base64": SkillSchema.string(),
                "mime": SkillSchema.string("Defaults to image/jpeg."),
                "caption": SkillSchema.string(),
            ], required: ["image_base64"]),
            requiresForeground: true
        ) { args in
            let base64 = SkillArgs.string(args, "image_base64")
            guard !base64.isEmpty else { throw SkillError.badArgument("image_base64 required") }
            // A data: URI prefix is common in agent output — strip it.
            let payload = base64.contains(",") ? String(base64.split(separator: ",").last ?? "") : base64
            guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else {
                throw SkillError.badArgument("image_base64 is not valid base64")
            }
            let mime = SkillArgs.string(args, "mime")
            let caption = SkillArgs.string(args, "caption")
            let shared = try await share.present(
                .image(data, mime: mime.isEmpty ? "image/jpeg" : mime,
                       caption: caption.isEmpty ? nil : caption))
            return ["shared": shared, "bytes": data.count]
        }
    }

    // MARK: device_info

    static func deviceInfo(_ provider: any DeviceInfoProviding) -> AnySkill {
        AnySkill(
            name: "device_info",
            description: "Return model, OS, locale info for this device."
        ) { _ in
            await provider.info()
        }
    }

    // MARK: battery_level

    static func batteryLevel(_ battery: any BatteryReading) -> AnySkill {
        AnySkill(
            name: "battery_level",
            description: "Return battery percentage (0-100) and charging state."
        ) { _ in
            let snapshot = await battery.snapshot()
            return ["level": snapshot.level, "state": snapshot.state]
        }
    }

    // MARK: vibrate

    /// iOS has no public arbitrary-duration vibration API (the Flutter client
    /// used the `vibration` plugin, which only works on Android for durations),
    /// so a requested duration or wait/vibrate pattern is turned into a burst of
    /// haptic taps of roughly the same length. The schema is unchanged so the
    /// server-side prompt and any stored tool call keep working.
    static func vibrate(_ haptics: any Vibrating) -> AnySkill {
        AnySkill(
            name: "vibrate",
            description: "Vibrate the device. Pass duration_ms for a single buzz (up to 30s), OR "
                + "a pattern of alternating wait/vibrate millisecond steps "
                + "(e.g. [0,500,250,500] = buzz 500, pause 250, buzz 500). Optional repeat loops "
                + "the buzz/pattern. Use a long duration or a repeated pattern for an insistent, "
                + "alarm-style haptic. On iPhone this becomes a burst of taptic pulses of about "
                + "the same length — iOS has no continuous-vibration API.",
            inputSchema: SkillSchema.object([
                "duration_ms": SkillSchema.integer(min: 1, max: 30000),
                "pattern": [
                    "type": "array",
                    "items": ["type": "integer"],
                    "description": "Alternating wait/vibrate ms; overrides duration_ms.",
                ],
                "repeat": SkillSchema.integer(min: 1, max: 20),
            ])
        ) { args in
            guard haptics.isAvailable else { return ["vibrated": false, "reason": "no vibrator"] }
            let repeatCount = min(max(SkillArgs.int(args, "repeat") ?? 1, 1), 20)

            if let raw = SkillArgs.intList(args, "pattern") {
                let pattern = raw.map { min(max($0, 0), 30000) }
                var pulses = 0
                for _ in 0..<repeatCount {
                    for (index, step) in pattern.enumerated() {
                        if index.isMultiple(of: 2) {
                            // Even indices are waits (matching the Android
                            // pattern convention the schema documents).
                            try? await Task.sleep(nanoseconds: UInt64(step) * 1_000_000)
                        } else {
                            pulses += await Self.pulse(haptics, forMilliseconds: step)
                        }
                    }
                }
                return ["vibrated": true, "pattern": pattern, "repeat": repeatCount, "pulses": pulses]
            }

            let duration = min(max(SkillArgs.int(args, "duration_ms") ?? 300, 1), 30000)
            var pulses = 0
            for i in 0..<repeatCount {
                pulses += await Self.pulse(haptics, forMilliseconds: duration)
                if repeatCount > 1, i < repeatCount - 1 {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            return ["vibrated": true, "duration_ms": duration, "repeat": repeatCount, "pulses": pulses]
        }
    }

    /// One "buzz of length x": a tap every 140 ms for x ms, capped so a 30 s
    /// request can't queue thousands of pulses.
    private static func pulse(_ haptics: any Vibrating, forMilliseconds ms: Int) async -> Int {
        let count = min(max(Int((Double(ms) / 140.0).rounded()), 1), 120)
        for i in 0..<count {
            await haptics.buzz()
            if i < count - 1 { try? await Task.sleep(nanoseconds: 140_000_000) }
        }
        return count
    }

    // MARK: flashlight

    static func flashlightOn(_ torch: any Torching) -> AnySkill {
        AnySkill(
            name: "flashlight_on",
            description: "Turn on the device flashlight / torch."
        ) { _ in
            // Returned rather than thrown, same as the Flutter skill: the agent
            // gets a usable answer ("no torch on this device") instead of a
            // tool error it has to interpret.
            do { return ["on": try await torch.setTorch(on: true)] }
            catch { return ["on": false, "error": Self.message(error)] }
        }
    }

    static func flashlightOff(_ torch: any Torching) -> AnySkill {
        AnySkill(
            name: "flashlight_off",
            description: "Turn off the device flashlight / torch."
        ) { _ in
            do { return ["on": try await torch.setTorch(on: false)] }
            catch { return ["on": true, "error": Self.message(error)] }
        }
    }

    // MARK: make_call

    static func makeCall(_ urls: any URLOpening) -> AnySkill {
        AnySkill(
            name: "make_call",
            description: "Open the system dialer with the given phone number.",
            inputSchema: SkillSchema.object(["number": SkillSchema.string()], required: ["number"]),
            requiresForeground: true
        ) { args in
            let number = SkillArgs.string(args, "number")
            guard !number.isEmpty else { throw SkillError.badArgument("number required") }
            guard let url = URL(string: "tel:\(ContactLookup.cleanNumber(number))") else {
                throw SkillError.badArgument("\"\(number)\" is not dialable")
            }
            return ["launched": await urls.open(url)]
        }
    }

    static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
