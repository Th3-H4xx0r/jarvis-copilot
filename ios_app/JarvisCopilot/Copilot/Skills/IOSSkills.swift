import Foundation

/// iOS-only skills: the Messages composer and everything that goes through the
/// Shortcuts app.
///
/// Port of `mobile_client/lib/skills/ios.dart`.
enum IOSSkills {

    /// A `ShortcutOutcome` in the `{ran, result, error, note}` shape the Flutter
    /// skill returned, so the server prompt keeps reading the same.
    static func json(_ outcome: ShortcutOutcome) -> [String: Any] {
        var out: [String: Any] = ["ran": outcome.ran]
        if let result = outcome.result { out["result"] = result }
        if let error = outcome.error { out["error"] = error }
        if let note = outcome.note { out["note"] = note }
        if !outcome.ran, outcome.launched { out["launched"] = true }
        return out
    }

    // MARK: send_sms

    static func sendSMS(_ composer: any SmsComposing) -> AnySkill {
        AnySkill(
            name: "send_sms",
            description: "Send a text via the iOS Messages composer, pre-filled with the "
                + "recipient and body. ALWAYS confirm the recipient AND the exact wording with "
                + "the user in chat BEFORE invoking this. iOS then also requires the user to tap "
                + "Send in the composer — never a silent send — so texting is double-gated.",
            inputSchema: SkillSchema.object([
                "number": SkillSchema.string(),
                "message": SkillSchema.string(),
            ], required: ["number", "message"]),
            requiresForeground: true
        ) { args in
            let number = SkillArgs.string(args, "number").trimmingCharacters(in: .whitespaces)
            let message = SkillArgs.string(args, "message")
            guard !number.isEmpty else { throw SkillError.badArgument("number required") }
            guard !message.isEmpty else { throw SkillError.badArgument("message required") }
            do {
                return try await composer.compose(number: number, message: message).json
            } catch {
                return ["shown": false, "error": SystemSkills.message(error)]
            }
        }
    }

    // MARK: run_shortcut

    static func runShortcut(_ shortcuts: any ShortcutRunning) -> AnySkill {
        AnySkill(
            name: "run_shortcut",
            description: "Run an iOS Shortcut by name and return its text output. Shortcuts are "
                + "the main way to control an iPhone: a Shortcut can toggle settings (Low Power "
                + "Mode, Wi-Fi, Focus, brightness, volume), control HomeKit scenes/devices, "
                + "play/pause media, get battery/location/clipboard, send messages, open apps or "
                + "URLs, run SSH/HTTP requests, and more. Pass the exact Shortcut name "
                + "(case-sensitive) and optional text 'input'. Returns {ran:true, result:<the "
                + "shortcut's output text>} or {ran:false, error}. If the Shortcut produces no "
                + "output you may get an empty result. To change iOS-locked settings "
                + "(brightness, volume, wifi, bluetooth, focus) prefer the phone_control skill, "
                + "which drives the per-verb 'JC …' Shortcuts.",
            inputSchema: SkillSchema.object([
                "name": SkillSchema.string("Exact Shortcut name as it appears in the Shortcuts app."),
                "input": SkillSchema.string("Optional text passed as the Shortcut input."),
                "timeout_seconds": SkillSchema.integer(
                    min: 5, max: 300,
                    description: "How long to wait for the Shortcut to finish (default 90)."),
            ], required: ["name"]),
            requiresForeground: true
        ) { args in
            let name = SkillArgs.string(args, "name")
            guard !name.isEmpty else { throw SkillError.badArgument("name required") }
            let timeout = SkillArgs.int(args, "timeout_seconds") ?? 90
            return json(await shortcuts.run(name: name,
                                            input: SkillArgs.string(args, "input"),
                                            timeoutSeconds: timeout,
                                            awaitResult: true))
        }
    }

    // MARK: shortcuts_list

    static func shortcutsList(_ shortcuts: any ShortcutRunning) -> AnySkill {
        AnySkill(
            name: "shortcuts_list",
            description: "Return names of installed user Shortcuts (best-effort)."
        ) { _ in
            guard let names = await shortcuts.installedNames() else {
                return [
                    "names": [String](),
                    "note": "iOS exposes no API for listing a user's Shortcuts — ask the user "
                        + "for the exact name instead.",
                ]
            }
            return ["names": names]
        }
    }

    // MARK: create_shortcut

    static func createShortcut(_ shortcuts: any ShortcutRunning) -> AnySkill {
        AnySkill(
            name: "create_shortcut",
            description: "Create an iOS Shortcut. iOS has NO API to author Shortcuts silently, "
                + "so this opens the Shortcuts app: with no args it opens a blank new-shortcut "
                + "editor; with import_url (a hosted .shortcut file / iCloud share link) it "
                + "opens the import-confirm screen so the user taps Add. To RUN an existing "
                + "Shortcut afterwards, use run_shortcut.",
            inputSchema: SkillSchema.object([
                "import_url": SkillSchema.string(
                    "URL of a hosted .shortcut file or iCloud share link to import."),
                "name": SkillSchema.string("Suggested name when importing."),
            ]),
            requiresForeground: true
        ) { args in
            let importURL = SkillArgs.string(args, "import_url")
            let opened = await shortcuts.openEditor(importURL: importURL,
                                                    suggestedName: SkillArgs.string(args, "name"))
            var out: [String: Any] = ["opened": opened,
                                      "mode": importURL.isEmpty ? "create" : "import"]
            if !opened { out["error"] = "Could not open Shortcuts (is it installed?)" }
            return out
        }
    }

    // MARK: phone_control

    static func phoneControl(_ shortcuts: any ShortcutRunning,
                             contacts: any ContactsStore,
                             sms: any SmsComposing) -> AnySkill {
        AnySkill(
            name: "phone_control",
            description: PhoneCommand.controlDescription,
            inputSchema: SkillSchema.object([
                "action": SkillSchema.string(),
                "app": SkillSchema.string(),
                "url": SkillSchema.string(),
                "setting": SkillSchema.string(),
                // `value` is deliberately untyped: brightness takes a number,
                // wifi takes 1/0, send_message takes text.
                "value": [String: Any](),
                "op": SkillSchema.string(),
                "what": SkillSchema.string(),
                "name": SkillSchema.string(),
                "to": SkillSchema.string(),
                "message": SkillSchema.string(),
                "timeout_seconds": SkillSchema.integer(min: 5, max: 120),
            ], required: ["action"]),
            requiresForeground: true
        ) { args in
            var command = try PhoneCommand.build(args)
            // Texting is NEVER silent. This verb used to run a "JC Send Message"
            // Shortcut, which sends outright — no composer, no confirmation
            // anywhere in the app. It now goes through the same iOS Messages
            // composer `send_sms` uses, so iOS itself requires the user to tap
            // Send, and the deferred-action banner names the recipient and body.
            if SkillArgs.string(command, "action") == "send_message" {
                // Resolve the recipient NAME to a phone number against the
                // device contacts first: the composer takes a handle, and a bare
                // number needs no conversion. Falls back to the raw name on no
                // permission / no match.
                var to = SkillArgs.text(command["to"] ?? command["recipient"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !to.isEmpty { to = await ContactLookup.resolveRecipient(to, store: contacts) }
                let message = SkillArgs.text(
                    command["message"] ?? command["body"] ?? command["value"])
                guard !to.isEmpty else {
                    return ["ok": false, "error": "to (the recipient) is required"]
                }
                guard !message.isEmpty else {
                    return ["ok": false, "error": "message is required"]
                }
                do {
                    var out = try await sms.compose(number: to, message: message).json
                    out["ok"] = out["sent"] as? Bool ?? false
                    out["via"] = "composer"
                    out["to"] = to
                    return out
                } catch {
                    return ["ok": false, "error": SystemSkills.message(error)]
                }
            }
            // Refuse anything with a native equivalent so we never bounce a
            // Shortcut for open_app/battery/flashlight/alarm — point JARVIS at
            // the native skill instead.
            if let native = PhoneCommand.nativeRedirectSkill(command) {
                return [
                    "ok": false,
                    "error": "phone_control is only for iOS-locked settings (brightness, volume, "
                        + "wifi, bluetooth, focus) and open_url. Use the native '\(native)' skill "
                        + "for this — it needs no Shortcut and no setup.",
                ]
            }
            guard let target = PhoneCommand.shortcut(for: command) else {
                return [
                    "ok": false,
                    "error": "Unsupported verb '\(SkillArgs.string(command, "action"))'. "
                        + "phone_control handles: \(PhoneCommand.verbOrder.joined(separator: ", ")).",
                ]
            }
            // Await the x-success callback so iOS bounces BACK here after the
            // setting changes, instead of stranding the user in Shortcuts. The
            // verb shortcuts emit no output and finish in ~1 s.
            let timeout = SkillArgs.int(args, "timeout_seconds") ?? 30
            let res = await shortcuts.run(name: target.name, input: target.input,
                                          timeoutSeconds: timeout, awaitResult: true)
            if !res.ran {
                return [
                    "ok": false,
                    "shortcut": target.name,
                    "value": target.input,
                    "error": "Could not run '\(target.name)'. Make sure that Shortcut is "
                        + "installed (one-time setup).",
                ]
            }
            var out: [String: Any] = ["ok": true, "shortcut": target.name, "value": target.input]
            if let note = res.note { out["note"] = note }
            return out
        }
    }

    // MARK: phone_capabilities

    static func phoneCapabilities() -> AnySkill {
        AnySkill(
            name: "phone_capabilities",
            description: "List the iOS-locked settings phone_control can change on this iPhone "
                + "(each backed by a one-time \"JC <Verb>\" Shortcut). Static — no Shortcut bounce."
        ) { _ in
            [
                "ok": true,
                "verbs": PhoneCommand.verbOrder,
                "shortcuts": PhoneCommand.verbShortcutNames,
                "note": "Each verb runs the matching \"JC <Verb>\" Shortcut. brightness/volume "
                    + "take 0.0–1.0; wifi/bluetooth/focus take 1/0; open_url takes a URL. If a "
                    + "verb errors, that Shortcut is not installed. send_message is the "
                    + "exception: it needs no Shortcut and opens the iOS Messages composer "
                    + "pre-filled — the user still has to tap Send, so confirm the recipient "
                    + "and the exact wording in chat first.",
            ]
        }
    }
}
