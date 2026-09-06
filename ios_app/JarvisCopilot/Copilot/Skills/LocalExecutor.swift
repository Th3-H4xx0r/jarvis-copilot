import Foundation

/// Run `skill` with `args` on this device now, then say `ack`.
struct LocalRun {
    let skill: String
    let args: [String: Any]
    /// Short spoken confirmation, in JARVIS's register.
    let ack: String
}

/// What `LocalExecutor.classify` decided about one utterance.
enum LocalDecision {
    case run(LocalRun)
    /// Not a local action — hand the turn to the server with this reason.
    case skip(String)
}

extension LocalDecision: CustomStringConvertible {
    var description: String {
        switch self {
        case .run(let plan): return "LocalRun(\(plan.skill), \(plan.args))"
        case .skip(let reason): return "LocalSkip(\(reason))"
        }
    }
}

/// Outcome of actually running a `LocalRun`.
struct LocalRunOutcome {
    let ok: Bool
    /// What we said out loud.
    let spoken: String
    /// One-line result for the async server report.
    let detail: String?
}

/// Lane 0 of the latency work: run a spoken device command on the phone ITSELF —
/// no server, no network, no model — and speak a local ack, so "flashlight on"
/// completes in well under a second even on a bad link.
///
/// `classify` is a PURE function: text + the skills this device actually has →
/// either a `.run` (a concrete allow-listed skill + args) or a `.skip` carrying
/// the reason it belongs on the server. Everything the safety rules care about
/// is decided here, which is why it takes no I/O and is exhaustively tested.
///
/// The grammar is deliberately SMALL and literal. A miss costs one server
/// round-trip (the normal path); a false positive would fire the wrong action on
/// someone's phone. So: guards first, then a short list of verb patterns, and
/// anything ambiguous escalates.
///
/// Port of `mobile_client/lib/services/local_executor.dart`.
///
/// Deliberately NOT actor-isolated: `classify` and the whole grammar are pure
/// and get called from any context (tests included); only `execute` and the
/// registry lookup hop to the main actor.
final class LocalExecutor {
    private let runner: InvokeRunner

    @MainActor
    init(_ runner: InvokeRunner) { self.runner = runner }

    // ── Spoken acks ───────────────────────────────────────────────────────────
    // Kept terse: the whole point is that the user hears something within a few
    // hundred ms of finishing their sentence.
    static let failureAck = "Sorry, that didn't work."

    /// Skill names available on THIS device right now: everything registered,
    /// minus what the user switched off in Settings.
    @MainActor
    static func deviceSkills(registry: SkillRegistry = .shared) -> Set<String> {
        Set(registry.enabledNames)
    }

    /// Execute a classified action and return what we should say. Never throws.
    @MainActor
    func execute(_ plan: LocalRun) async -> LocalRunOutcome {
        // Belt and braces: the allow-list is enforced at classification AND at
        // execution, so no future caller can hand us an arbitrary skill name.
        guard isLocallyAllowed(plan.skill) else {
            return LocalRunOutcome(ok: false, spoken: Self.failureAck,
                                   detail: "blocked:\(plan.skill)")
        }
        let res = await runner.run(plan.skill, plan.args)
        // A skill that ran but didn't achieve its effect (open_app with no URL
        // scheme) is NOT a success — the caller escalates instead of lying.
        if res.error != nil || localToolMissed(plan.skill, res) {
            return LocalRunOutcome(ok: false, spoken: Self.failureAck,
                                   detail: "error:\(res.error ?? "no-effect")")
        }
        return LocalRunOutcome(ok: true, spoken: plan.ack, detail: Self.resultLine(res.result))
    }

    /// One line describing a completed local action, for the async server report
    /// (`/api/session/append`) so memory + the web transcript still see it.
    static func reportLine(_ plan: LocalRun, _ outcome: LocalRunOutcome) -> String {
        let args = plan.args.keys.sorted()
            .map { "\($0)=\(SkillArgs.text(plan.args[$0]))" }
            .joined(separator: " ")
        let status = outcome.ok ? "ok" : (outcome.detail ?? "failed")
        return "[done locally] \(plan.skill)\(args.isEmpty ? "" : " " + args) → \(status)"
    }

    private static func resultLine(_ result: [String: Any]?) -> String? {
        guard let result else { return nil }
        let s = String(describing: result)
        return s.count > 200 ? String(s.prefix(200)) + "…" : s
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Classification
    // ══════════════════════════════════════════════════════════════════════════

    /// Decide whether `text` is a device-local action this phone can run itself.
    /// `skills` is the device's own capability set (see `deviceSkills`).
    static func classify(_ text: String, skills: Set<String>) -> LocalDecision {
        let available = skills
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .skip("empty") }
        let lower = strip(t).lowercased()
        if lower.count < 3 { return .skip("too-short") }

        // ── Guards — checked BEFORE any verb match, so a phrase that looks like
        // a local command but touches another device / another person / money /
        // data always goes to the server.
        if otherDevice.hasMatch(lower) { return .skip("other-device") }
        if outwardComms.hasMatch(lower) { return .skip("outward-comms") }
        if commerce.hasMatch(lower) { return .skip("commerce") }
        if destructive.hasMatch(lower) { return .skip("destructive") }

        // ── Negation / interrogative guard ──────────────────────────────────
        // "don't turn on the flashlight" and "should I turn on the flashlight?"
        // must never run: the verb grammar below is anchored to a command
        // opener, so on its own it wouldn't match these anyway, but a leading
        // negation or a permission-seeking question is checked explicitly first
        // so the escalation reason is legible in the log even if a future verb
        // pattern is added without the anchor.
        if leadingNegation.hasMatch(lower) { return .skip("negated") }
        if interrogativeOpener.hasMatch(lower) { return .skip("interrogative") }

        // ── Third-party target guard ─────────────────────────────────────────
        // "set an alarm for Dad", "turn on the flashlight for Mom" — the action
        // reads as being FOR another person, which is ambiguous enough (whose
        // alarm? on whose behalf?) to hand to the server. Time/date phrases like
        // "for 5 minutes" / "for tomorrow" are excluded.
        if hasThirdPartyTarget(t) { return .skip("third-party-target") }

        guard let plan = match(raw: t, lower: lower, available: available) else {
            return .skip("no-local-match")
        }
        if !isLocallyAllowed(plan.skill) { return .skip("not-allowed:\(plan.skill)") }
        if !available.contains(plan.skill) { return .skip("skill-unavailable:\(plan.skill)") }
        return .run(plan)
    }

    /// The verb grammar. Returns nil when nothing matches (→ escalate).
    private static func match(raw: String, lower: String,
                                          available: Set<String>) -> LocalRun? {
        // ── flashlight ─────────────────────────────────────────────────────
        if flashOn.hasMatch(lower) {
            return LocalRun(skill: "flashlight_on", args: [:], ack: "Flashlight on, sir.")
        }
        if flashOff.hasMatch(lower) {
            return LocalRun(skill: "flashlight_off", args: [:], ack: "Flashlight off, sir.")
        }

        // ── vibrate ────────────────────────────────────────────────────────
        if vibrate.hasMatch(lower) {
            return LocalRun(skill: "vibrate", args: [:], ack: "Right away, sir.")
        }

        // ── volume ─────────────────────────────────────────────────────────
        if volumeWord.hasMatch(lower) {
            if let abs = volumeLevel.firstMatch(lower), let digits = abs.group(1) {
                let pct = min(max(Int(digits) ?? 50, 0), 100)
                // Android exposes a real set_volume skill; iOS can only do it
                // through the "JC Volume" Shortcut behind phone_control.
                if available.contains("set_volume") {
                    return LocalRun(skill: "set_volume", args: ["level": pct],
                                    ack: "Volume at \(pct)%, sir.")
                }
                return LocalRun(skill: "phone_control",
                                args: ["action": "volume", "value": "\(pct)"],
                                ack: "Volume at \(pct)%, sir.")
            }
            // The second alternative of `volumeDirection` ("louder … volume")
            // fills group 2 instead of group 1.
            if let dir = volumeDirection.firstMatch(lower),
               let word = dir.group(1) ?? dir.group(2),
               available.contains("adjust_volume") {
                let direction: String
                switch word {
                case "louder": direction = "up"
                case "quieter", "softer": direction = "down"
                default: direction = word
                }
                return LocalRun(skill: "adjust_volume", args: ["direction": direction],
                                ack: direction == "up" ? "Turning it up, sir." : "Turning it down, sir.")
            }
            // "set the volume" with no level and no direction — don't guess.
            return nil
        }

        // ── alarms + timers ────────────────────────────────────────────────
        if alarmWord.hasMatch(lower) {
            if let rel = relativeMinutes(lower) {
                return LocalRun(skill: "set_alarm", args: ["in_minutes": rel],
                                ack: "Alarm set for \(rel) \(rel == 1 ? "minute" : "minutes") from now, sir.")
            }
            if let clock = clockTime(lower) {
                let hh = String(format: "%02d", clock.hour)
                let mm = String(format: "%02d", clock.minute)
                return LocalRun(skill: "set_alarm",
                                args: ["hour": clock.hour, "minute": clock.minute],
                                ack: "Alarm set for \(hh):\(mm), sir.")
            }
            return nil   // "set an alarm" with no time — ask the server.
        }

        // ── clipboard ──────────────────────────────────────────────────────
        if let write = clipWrite.firstMatch(raw), let body = write.group(1)?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            if body.isEmpty { return nil }
            return LocalRun(skill: "clipboard_write", args: ["text": body], ack: "Copied, sir.")
        }
        if clipRead.hasMatch(lower) {
            return LocalRun(skill: "clipboard_read", args: [:], ack: "Reading your clipboard, sir.")
        }

        // ── camera ─────────────────────────────────────────────────────────
        if takePhoto.hasMatch(lower) {
            return LocalRun(skill: "take_photo", args: [:], ack: "Camera up, sir.")
        }

        // ── local notification ─────────────────────────────────────────────
        if let notif = notify.firstMatch(raw), let captured = notif.group(1) {
            let body = trailingPunctuation.replacingFirst(
                in: captured.trimmingCharacters(in: .whitespacesAndNewlines))
            if body.isEmpty { return nil }
            return LocalRun(skill: "notify", args: ["title": body], ack: "Noted, sir.")
        }

        // ── open a URL / an app ────────────────────────────────────────────
        if let open = open.firstMatch(raw), let captured = open.group(1) {
            // Trailing politeness first, THEN the "… app" suffix — "launch the
            // Spotify app please" has to shed both, in that order.
            var target = captured.trimmingCharacters(in: .whitespacesAndNewlines)
            target = trailingPolite.replacingFirst(in: target)
            target = trailingAppWord.replacingFirst(in: target)
            if target.isEmpty { return nil }
            if let url = asURL(target) {
                return LocalRun(skill: "open_url", args: ["url": url], ack: "Opening it now, sir.")
            }
            let lowerTarget = target.lowercased()
            if ambiguousTarget.hasMatch(lowerTarget) { return nil }
            if notAnApp.hasMatch(lowerTarget) { return nil }
            if target.split(whereSeparator: { $0.isWhitespace }).count > 3 { return nil }
            let titled = SkillArgs.titleCase(target)
            return LocalRun(skill: "open_app", args: ["app": titled, "name": titled],
                            ack: "Opening \(target), sir.")
        }

        return nil
    }

    // ── Guard patterns ────────────────────────────────────────────────────────

    /// "on my Mac", "on the watch" — another device is the server's job (it owns
    /// the bridge to them).
    private static let otherDevice = Rx(
        #"\bon (?:my |the )?(mac|macbook|laptop|computer|desktop|pc|watch|tv|ipad|tablet|server|browser|chrome tab)\b"#)

    /// Anything aimed at another person: messaging, calling, contacts.
    private static let outwardComms = Rx(
        #"\b(text|texts?|sms|imessage|whatsapp|dm|tweet|email|e-mail|call|calling|dial|"#
        + #"facetime|message|messages|voicemail|contacts?)\b"#
        + #"|\bsend\b"#
        + #"|\b\w+'s (number|phone|address|email)\b"#)

    /// Money / ordering. Never local, never without the server's confirmation.
    private static let commerce = Rx(
        #"\b(buy|purchase|order|pay|paying|venmo|checkout|reserve|book|refund|"#
        + #"dollars?|bucks|price|cart)\b"#)

    /// Destructive verbs — the local lane only does reversible things.
    private static let destructive = Rx(
        #"\b(delete|erase|wipe|uninstall|factory reset|clear my|remove my)\b"#)

    // ── Verb patterns ─────────────────────────────────────────────────────────
    //
    // Every family below is ANCHORED to the start of the utterance (after an
    // optional polite/request prefix). An unanchored `\bturn on\b…\bflashlight\b`
    // substring match would fire on "don't turn on the flashlight" or "should I
    // turn on the flashlight?" just as readily as on the imperative form. The
    // shared prefix is also what lets a polite question ("could you turn on the
    // flashlight?") still run: it's listed explicitly, unlike the
    // permission-seeking openers rejected above.

    private static let politePrefix =
        #"(?:hey,?\s+|please\s+|can you\s+|could you\s+|would you\s+|will you\s+)*"#

    private static let flashOn = Rx(
        "^" + politePrefix + #"(?:turn on|switch on|enable)\b[^.?!]*\b(?:flashlight|torch)\b"#
        + "|^" + politePrefix + #"(?:flashlight|torch) on\b"#)
    private static let flashOff = Rx(
        "^" + politePrefix + #"(?:turn off|switch off|disable|kill)\b[^.?!]*\b(?:flashlight|torch)\b"#
        + "|^" + politePrefix + #"(?:flashlight|torch) off\b"#)

    private static let vibrate = Rx(
        "^" + politePrefix + #"(?:vibrate|buzz)\b(?:\s+(?:the\s+)?(?:phone|device))?\b"#)

    /// Gate for the volume family: requires a command verb ahead of "volume",
    /// not just the word "volume" anywhere in the sentence.
    private static let volumeWord = Rx(
        "^" + politePrefix
        + #"(?:set|turn|change|adjust|make|put|increase|decrease|raise|lower|crank|bump)\b"#
        + #"[^.?!]*\bvolume\b"#)
    private static let volumeLevel = Rx(#"\bvolume\b[^0-9]{0,20}(\d{1,3})\s*%?"#)
    private static let volumeDirection = Rx(
        #"\bvolume\b[^.]{0,20}?\b(up|down|louder|quieter|softer|mute|unmute)\b"#
        + #"|\b(louder|quieter)\b[^.]{0,20}\bvolume\b"#)

    private static let alarmWord = Rx(
        "^" + politePrefix + #"(?:set|create|start|schedule)\b[^.?!]*\b(?:alarm|timer)\b"#
        + "|^" + politePrefix + #"wake me(?: up)?\b"#)

    private static let clipWrite = Rx(
        "^" + politePrefix + #"(?:copy|put)\s+(.+?)\s+(?:to|into|on|in)\s+(?:my |the )?clipboard\b"#)
    private static let clipRead = Rx(
        "^" + politePrefix
        + #"(?:read|what'?s|what is|show me|show|get|check|tell me)\b[^.?!]*\bclipboard\b"#)

    private static let takePhoto = Rx(
        "^" + politePrefix + #"take (?:a |another )?(?:photo|picture|selfie|snapshot|shot)\b"#)

    /// Leading negation — "don't", "do not", "never", "no need to", "stop" —
    /// makes ANY of the families above a thing to escalate, not run.
    private static let leadingNegation = Rx(
        #"^(?:well,?\s+|hey,?\s+|so,?\s+)*"#
        + #"(?:don'?t|do\s*not|never|no\s+need\s+to|stop)\b"#)

    /// Permission-seeking questions — "should I…", "can I…?" — are the user
    /// thinking out loud, not commanding the phone. Distinct from "can you" /
    /// "could you", which ARE commands (see `politePrefix`).
    private static let interrogativeOpener = Rx(
        #"^(?:well,?\s+|hey,?\s+|so,?\s+)*"#
        + #"(?:should i|can i|could i|would i|do i|am i supposed to|"#
        + #"is it (?:ok|okay) to)\b"#)

    private static let notify = Rx(
        #"^(?:hey,?\s+|please\s+|can you\s+|could you\s+)*"#
        + #"notify me\s+(?:that\s+|saying\s+|about\s+|:\s*)?(.+)$"#)

    private static let open = Rx(
        #"^(?:hey,?\s+|please\s+|can you\s+|could you\s+|would you\s+)*"#
        + #"(?:open|launch|start|go to|bring up)(?: up)?(?: the)?\s+(.+?)[.?!]*$"#)

    private static let trailingPolite = Rx(#"(\s+(please|now|for me|thanks))+$"#)
    private static let trailingAppWord = Rx(#"\s+app$"#)
    private static let trailingPunctuation = Rx(#"[.!?]+$"#)

    /// Pronouns / placeholders — we will not guess what "it" is.
    private static let ambiguousTarget = Rx(
        #"^(it|that|this|those|these|them|there|something|anything|that thing|the thing|stuff)$"#)

    /// Nouns that mean "open" in a non-app sense.
    private static let notAnApp = Rx(
        #"\b(door|window|gate|account|file|folder|link|url|website|site|page|tab|"#
        + #"settings?|drawer|box|bottle|blinds|curtains)\b"#)

    // ── Third-party target guard ──────────────────────────────────────────────

    /// Any "for <word>" in the utterance. CASE-SENSITIVE on purpose: the
    /// capitalization of the captured word is the signal that it's a name.
    private static let forTarget = Rx(#"\bfor\s+(my\s+)?([A-Za-z][\w'-]*)"#, caseInsensitive: false)

    /// Family members / relations — "for my mom" is unambiguously a person.
    private static let relationWords: Set<String> = [
        "mom", "mum", "mother", "dad", "father", "sister", "brother", "wife",
        "husband", "son", "daughter", "grandma", "grandpa", "grandmother",
        "grandfather", "boss", "girlfriend", "boyfriend", "roommate", "kid",
        "kids", "parents", "partner", "fiancee", "fiance", "friend",
    ]

    /// Words that legitimately follow a bare "for" and are NOT a person's name
    /// — durations, relative dates, and the speaker themselves.
    private static let forTargetExclusions: Set<String> = [
        "a", "an", "the", "minute", "minutes", "min", "mins", "hour", "hours",
        "hr", "hrs", "second", "seconds", "sec", "secs", "day", "days", "week",
        "weeks", "month", "months", "year", "years", "tomorrow", "today",
        "tonight", "now", "later", "forever", "ever", "good", "sure", "while",
        "moment", "me", "us", "monday", "tuesday", "wednesday", "thursday",
        "friday", "saturday", "sunday", "january", "february", "march", "april",
        "may", "june", "july", "august", "september", "october", "november",
        "december",
    ]

    /// True when `raw` names another person as the target/beneficiary of the
    /// action — "set an alarm for Dad", "turn on the flashlight for Mom" — as
    /// opposed to a duration/date phrase like "for 5 minutes" / "for tomorrow".
    private static func hasThirdPartyTarget(_ raw: String) -> Bool {
        for m in forTarget.allMatches(raw) {
            guard let word = m.group(2), let first = word.first else { continue }
            let lower = word.lowercased()
            if m.group(1) != nil {
                // "for my <word>" — only a third party when it's a relation
                // word; "for my keys" / "for my alarm" isn't a person.
                if relationWords.contains(lower) { return true }
                continue
            }
            if forTargetExclusions.contains(lower) { continue }
            // Lowercase STT transcripts ("for dad", "for grandma") carry no
            // capitalization hint — a bare relation word is still a third party.
            if relationWords.contains(lower) { return true }
            // A capitalized word in the ORIGINAL text that isn't a known
            // non-person term reads as a proper name ("for Dad", "for Priya").
            if String(first) != String(first).lowercased(),
               String(first) == String(first).uppercased() {
                return true
            }
        }
        return false
    }

    // ── Small parsers ─────────────────────────────────────────────────────────

    private static let minutesRx = Rx(#"\b(?:in|for)\s+(\d{1,3})\s*(minutes?|mins?|m)\b"#)
    private static let hoursRx = Rx(#"\b(?:in|for)\s+(\d{1,2})\s*(hours?|hrs?|h)\b"#)

    private static func relativeMinutes(_ lower: String) -> Int? {
        if let m = minutesRx.firstMatch(lower), let digits = m.group(1), let v = Int(digits),
           v >= 1, v <= 1440 {
            return v
        }
        if let h = hoursRx.firstMatch(lower), let digits = h.group(1), let v = Int(digits),
           v >= 1, v <= 24 {
            return v * 60
        }
        return nil
    }

    private static let clockRx = Rx(
        #"\b(?:at|for)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?\b"#)

    /// (hour24, minute) from "at 7:30 am" / "at 6 pm" / "at 07:05".
    private static func clockTime(_ lower: String) -> (hour: Int, minute: Int)? {
        guard let m = clockRx.firstMatch(lower), let hourText = m.group(1),
              var h = Int(hourText) else { return nil }
        let minuteGroup = m.group(2)
        let minute = Int(minuteGroup ?? "0") ?? 0
        let ap = (m.group(3) ?? "").replacingOccurrences(of: ".", with: "").lowercased()
        if minute > 59 { return nil }
        if ap == "pm", h < 12 { h += 12 }
        if ap == "am", h == 12 { h = 0 }
        // A bare number with no am/pm and no colon is only a time if it's
        // plausible as one; "at 40" is not.
        if h > 23 { return nil }
        if ap.isEmpty, minuteGroup == nil, h > 12 { return nil }
        return (h, minute)
    }

    /// Recognize an explicit URL or a bare `something.tld` domain.
    private static let explicitURL = Rx(#"^(https?://\S+)$"#)
    private static let bareDomain = Rx(
        #"^(?:www\.)?[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)*\."#
        + #"(com|org|net|io|dev|app|ai|co|edu|gov|tv|me|uk|us)(/\S*)?$"#)

    private static func asURL(_ target: String) -> String? {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if explicitURL.hasMatch(t) { return t }
        if t.contains(" ") { return nil }
        if bareDomain.hasMatch(t) { return "https://\(t)" }
        return nil
    }

    /// Normalize smart quotes + collapse whitespace so the patterns above see
    /// what the user actually said, however the STT punctuated it.
    private static func strip(_ s: String) -> String {
        let normalized = s
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        return normalized.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

/// Debug helper — one line per classification, so a mis-route is visible in the
/// device log without dumping the transcript.
func debugLogLocalDecision(_ d: LocalDecision) {
    #if DEBUG
    print("[local-exec] \(d)")
    #endif
}
