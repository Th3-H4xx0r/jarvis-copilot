import 'dart:async';

import 'package:flutter/foundation.dart';

import '../skills/registry.dart';
import 'credentials.dart';
import 'invoke_runner.dart';
import 'local_action_safety.dart';

/// Lane 0 of the latency rehaul (plan 4.3 / 4.5): run a spoken device command
/// on the phone ITSELF — no server, no network, no model — and speak a local
/// ack, so "flashlight on" completes in well under a second even on a bad link.
///
/// [classify] is a PURE function: text + the skills this device actually has
/// → either a [LocalRun] (a concrete allow-listed skill + args) or a
/// [LocalSkip] carrying the reason it belongs on the server. Everything the
/// safety rules care about is decided here, which is why it takes no I/O and is
/// exhaustively unit tested.
///
/// The grammar is deliberately SMALL and literal. A miss costs one server
/// round-trip (the normal path); a false positive would fire the wrong action
/// on someone's phone. So: guards first, then a short list of verb patterns,
/// and anything ambiguous escalates.

sealed class LocalDecision {
  const LocalDecision();
}

/// Run [skill] with [args] on this device now, then say [ack].
class LocalRun extends LocalDecision {
  const LocalRun(this.skill, this.args, this.ack);
  final String skill;
  final Map<String, dynamic> args;

  /// Short spoken confirmation, in JARVIS's register.
  final String ack;

  @override
  String toString() => 'LocalRun($skill, $args)';
}

/// Not a local action — hand the turn to the server with [reason] for the log.
class LocalSkip extends LocalDecision {
  const LocalSkip(this.reason);
  final String reason;

  @override
  String toString() => 'LocalSkip($reason)';
}

/// Outcome of actually running a [LocalRun].
class LocalRunOutcome {
  const LocalRunOutcome({required this.ok, required this.spoken, this.detail});
  final bool ok;

  /// What we said out loud.
  final String spoken;

  /// One-line result for the async server report.
  final String? detail;
}

class LocalExecutor {
  LocalExecutor(this._runner);
  final InvokeRunner _runner;

  // ── Spoken acks ───────────────────────────────────────────────────────────
  // Kept terse: the whole point is that the user hears something within a few
  // hundred ms of finishing their sentence (plan 4.4).
  static const String kFailureAck = "Sorry, that didn't work.";

  /// Skill names available on THIS device right now: everything registered,
  /// minus what the user switched off in Settings.
  static Set<String> deviceSkills() {
    final disabled = Credentials.instance.skillsDisabled;
    return SkillRegistry.instance
        .names()
        .where((n) => !disabled.contains(n))
        .toSet();
  }

  /// Execute a classified action and return what we should say. Never throws.
  Future<LocalRunOutcome> execute(LocalRun plan) async {
    // Belt and braces: the allow-list is enforced at classification AND at
    // execution, so no future caller can hand us an arbitrary skill name.
    if (!isLocallyAllowed(plan.skill)) {
      return LocalRunOutcome(
          ok: false, spoken: kFailureAck, detail: 'blocked:${plan.skill}');
    }
    final res = await _runner.run(plan.skill, plan.args);
    // A skill that ran but didn't achieve its effect (open_app with no URL
    // scheme) is NOT a success — the caller escalates instead of lying.
    if (res.error != null || localToolMissed(plan.skill, res)) {
      return LocalRunOutcome(
        ok: false,
        spoken: kFailureAck,
        detail: 'error:${res.error ?? 'no-effect'}',
      );
    }
    return LocalRunOutcome(
      ok: true,
      spoken: plan.ack,
      detail: _resultLine(res.result),
    );
  }

  /// One line describing a completed local action, for the async server report
  /// (`/api/session/append`) so memory + the web transcript still see it.
  static String reportLine(LocalRun plan, LocalRunOutcome outcome) {
    final args = plan.args.entries.map((e) => '${e.key}=${e.value}').join(' ');
    final status = outcome.ok ? 'ok' : (outcome.detail ?? 'failed');
    return '[done locally] ${plan.skill}${args.isEmpty ? '' : ' $args'} → $status';
  }

  static String? _resultLine(Object? result) {
    if (result == null) return null;
    final s = result.toString();
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Classification
  // ══════════════════════════════════════════════════════════════════════════

  /// Decide whether [text] is a device-local action this phone can run itself.
  /// [skills] is the device's own capability set (see [deviceSkills]).
  static LocalDecision classify(String text, {Set<String>? skills}) {
    final available = skills ?? deviceSkills();
    final t = text.trim();
    if (t.isEmpty) return const LocalSkip('empty');
    final lower = _strip(t).toLowerCase();
    if (lower.length < 3) return const LocalSkip('too-short');

    // ── Guards (plan 4.5) — checked BEFORE any verb match, so a phrase that
    // looks like a local command but touches another device / another person /
    // money / data always goes to the server.
    if (_otherDevice.hasMatch(lower)) return const LocalSkip('other-device');
    if (_outwardComms.hasMatch(lower)) return const LocalSkip('outward-comms');
    if (_commerce.hasMatch(lower)) return const LocalSkip('commerce');
    if (_destructive.hasMatch(lower)) return const LocalSkip('destructive');

    // ── Negation / interrogative guard (review CRITICAL) ────────────────────
    // "don't turn on the flashlight" and "should I turn on the flashlight?"
    // must never run: the verb-family grammar below is anchored to a command
    // opener, so on its own it wouldn't match these anyway, but a leading
    // negation or a permission-seeking question is checked explicitly first
    // so the escalation reason is legible in the log even if a future verb
    // pattern is added without the anchor.
    if (_leadingNegation.hasMatch(lower)) return const LocalSkip('negated');
    if (_interrogativeOpener.hasMatch(lower)) {
      return const LocalSkip('interrogative');
    }

    // ── Third-party target guard (review IMPORTANT) ─────────────────────────
    // "set an alarm for Dad", "turn on the flashlight for Mom" — the action
    // reads as being FOR another person, which is ambiguous enough (whose
    // alarm? on whose behalf?) to hand to the server. Time/date phrases like
    // "for 5 minutes" / "for tomorrow" are excluded.
    if (_hasThirdPartyTarget(t)) return const LocalSkip('third-party-target');

    final plan = _match(t, lower, available);
    if (plan == null) return const LocalSkip('no-local-match');
    if (!isLocallyAllowed(plan.skill)) return LocalSkip('not-allowed:${plan.skill}');
    if (!available.contains(plan.skill)) {
      return LocalSkip('skill-unavailable:${plan.skill}');
    }
    return plan;
  }

  /// The verb grammar. Returns null when nothing matches (→ escalate).
  static LocalRun? _match(String raw, String lower, Set<String> available) {
    // ── flashlight ─────────────────────────────────────────────────────────
    if (_flashOn.hasMatch(lower)) {
      return const LocalRun('flashlight_on', {}, 'Flashlight on, sir.');
    }
    if (_flashOff.hasMatch(lower)) {
      return const LocalRun('flashlight_off', {}, 'Flashlight off, sir.');
    }

    // ── vibrate ────────────────────────────────────────────────────────────
    if (_vibrate.hasMatch(lower)) {
      return const LocalRun('vibrate', {}, 'Right away, sir.');
    }

    // ── volume ─────────────────────────────────────────────────────────────
    if (_volumeWord.hasMatch(lower)) {
      final abs = _volumeLevel.firstMatch(lower);
      if (abs != null) {
        final pct = (int.tryParse(abs.group(1)!) ?? 50).clamp(0, 100);
        // Android exposes a real set_volume skill; iOS can only do it through
        // the "JC Volume" Shortcut behind phone_control.
        if (available.contains('set_volume')) {
          return LocalRun('set_volume', {'level': pct}, 'Volume at $pct%, sir.');
        }
        return LocalRun('phone_control', {'action': 'volume', 'value': '$pct'},
            'Volume at $pct%, sir.');
      }
      final dir = _volumeDirection.firstMatch(lower);
      if (dir != null && available.contains('adjust_volume')) {
        final word = dir.group(1)!;
        final direction = switch (word) {
          'louder' => 'up',
          'quieter' || 'softer' => 'down',
          _ => word,
        };
        return LocalRun('adjust_volume', {'direction': direction},
            direction == 'up' ? 'Turning it up, sir.' : 'Turning it down, sir.');
      }
      // "set the volume" with no level and no direction — don't guess.
      return null;
    }

    // ── alarms + timers ────────────────────────────────────────────────────
    if (_alarmWord.hasMatch(lower)) {
      final rel = _relativeMinutes(lower);
      if (rel != null) {
        return LocalRun('set_alarm', {'in_minutes': rel},
            'Alarm set for $rel ${rel == 1 ? 'minute' : 'minutes'} from now, sir.');
      }
      final clock = _clockTime(lower);
      if (clock != null) {
        final h = clock.$1, m = clock.$2;
        final hh = h.toString().padLeft(2, '0');
        final mm = m.toString().padLeft(2, '0');
        return LocalRun(
            'set_alarm', {'hour': h, 'minute': m}, 'Alarm set for $hh:$mm, sir.');
      }
      return null; // "set an alarm" with no time — ask the server.
    }

    // ── clipboard ──────────────────────────────────────────────────────────
    final write = _clipWrite.firstMatch(raw);
    if (write != null) {
      final body = write.group(1)!.trim();
      if (body.isEmpty) return null;
      return LocalRun('clipboard_write', {'text': body}, 'Copied, sir.');
    }
    if (_clipRead.hasMatch(lower)) {
      return const LocalRun('clipboard_read', {}, 'Reading your clipboard, sir.');
    }

    // ── camera ─────────────────────────────────────────────────────────────
    if (_takePhoto.hasMatch(lower)) {
      return const LocalRun('take_photo', {}, 'Camera up, sir.');
    }

    // ── local notification ─────────────────────────────────────────────────
    final notify = _notify.firstMatch(raw);
    if (notify != null) {
      final body = notify.group(1)!.trim().replaceFirst(RegExp(r'[.!?]+$'), '');
      if (body.isEmpty) return null;
      return LocalRun('notify', {'title': body}, 'Noted, sir.');
    }

    // ── open a URL / an app ────────────────────────────────────────────────
    final open = _open.firstMatch(raw);
    if (open != null) {
      // Trailing politeness first, THEN the "… app" suffix — "launch the
      // Spotify app please" has to shed both, in that order.
      var target = open.group(1)!.trim();
      target = target.replaceFirst(_trailingPolite, '');
      target = target.replaceFirst(_trailingAppWord, '');
      if (target.isEmpty) return null;
      final url = _asUrl(target);
      if (url != null) {
        return LocalRun('open_url', {'url': url}, 'Opening it now, sir.');
      }
      final lowerTarget = target.toLowerCase();
      if (_ambiguousTarget.hasMatch(lowerTarget)) return null;
      if (_notAnApp.hasMatch(lowerTarget)) return null;
      if (target.split(RegExp(r'\s+')).length > 3) return null;
      return LocalRun('open_app', {'app': _titleCase(target), 'name': _titleCase(target)},
          'Opening $target, sir.');
    }

    return null;
  }

  // ── Guard patterns ─────────────────────────────────────────────────────────

  /// "on my Mac", "on the watch" — another device is the server's job (it owns
  /// the bridge to them).
  static final RegExp _otherDevice = RegExp(
      r'\bon (?:my |the )?(mac|macbook|laptop|computer|desktop|pc|watch|tv|ipad|tablet|server|browser|chrome tab)\b',
      caseSensitive: false);

  /// Anything aimed at another person: messaging, calling, contacts.
  static final RegExp _outwardComms = RegExp(
      r"\b(text|texts?|sms|imessage|whatsapp|dm|tweet|email|e-mail|call|calling|dial|"
      r"facetime|message|messages|voicemail|contacts?)\b"
      r"|\bsend\b"
      r"|\b\w+'s (number|phone|address|email)\b",
      caseSensitive: false);

  /// Money / ordering. Never local, never without the server's confirmation.
  static final RegExp _commerce = RegExp(
      r'\b(buy|purchase|order|pay|paying|venmo|checkout|reserve|book|refund|'
      r'dollars?|bucks|price|cart)\b',
      caseSensitive: false);

  /// Destructive verbs — the local lane only does reversible things.
  static final RegExp _destructive = RegExp(
      r'\b(delete|erase|wipe|uninstall|factory reset|clear my|remove my)\b',
      caseSensitive: false);

  // ── Verb patterns ──────────────────────────────────────────────────────────
  //
  // Every family below is ANCHORED to the start of the utterance (after an
  // optional polite/request prefix), the same way `_open`/`_notify` already
  // were (review CRITICAL). An unanchored `\bturn on\b...\bflashlight\b`
  // substring match would fire on "don't turn on the flashlight" or "should I
  // turn on the flashlight?" just as readily as on the imperative form — the
  // bug this anchoring fixes. The shared prefix is also what lets a polite
  // question ("could you turn on the flashlight?") still run: it's listed
  // explicitly, unlike the permission-seeking openers rejected above.

  static const String _kPolitePrefix =
      r'(?:hey,?\s+|please\s+|can you\s+|could you\s+|would you\s+|will you\s+)*';

  static final RegExp _flashOn = RegExp(
      '^$_kPolitePrefix'
      r'(?:turn on|switch on|enable)\b[^.?!]*\b(?:flashlight|torch)\b'
      '|^$_kPolitePrefix'
      r'(?:flashlight|torch) on\b',
      caseSensitive: false);
  static final RegExp _flashOff = RegExp(
      '^$_kPolitePrefix'
      r'(?:turn off|switch off|disable|kill)\b[^.?!]*\b(?:flashlight|torch)\b'
      '|^$_kPolitePrefix'
      r'(?:flashlight|torch) off\b',
      caseSensitive: false);

  static final RegExp _vibrate = RegExp(
      '^$_kPolitePrefix'
      r'(?:vibrate|buzz)\b(?:\s+(?:the\s+)?(?:phone|device))?\b',
      caseSensitive: false);

  /// Gate for the volume family: requires a command verb ahead of "volume",
  /// not just the word "volume" anywhere in the sentence.
  static final RegExp _volumeWord = RegExp(
      '^$_kPolitePrefix'
      r'(?:set|turn|change|adjust|make|put|increase|decrease|raise|lower|crank|bump)\b'
      r'[^.?!]*\bvolume\b',
      caseSensitive: false);
  static final RegExp _volumeLevel = RegExp(
      r'\bvolume\b[^0-9]{0,20}(\d{1,3})\s*%?', caseSensitive: false);
  static final RegExp _volumeDirection = RegExp(
      r'\bvolume\b[^.]{0,20}?\b(up|down|louder|quieter|softer|mute|unmute)\b'
      r'|\b(louder|quieter)\b[^.]{0,20}\bvolume\b',
      caseSensitive: false);

  static final RegExp _alarmWord = RegExp(
      '^$_kPolitePrefix'
      r'(?:set|create|start|schedule)\b[^.?!]*\b(?:alarm|timer)\b'
      '|^$_kPolitePrefix'
      r'wake me(?: up)?\b',
      caseSensitive: false);

  static final RegExp _clipWrite = RegExp(
      '^$_kPolitePrefix'
      r'(?:copy|put)\s+(.+?)\s+(?:to|into|on|in)\s+(?:my |the )?clipboard\b',
      caseSensitive: false);
  static final RegExp _clipRead = RegExp(
      '^$_kPolitePrefix'
      r"(?:read|what'?s|what is|show me|show|get|check|tell me)\b[^.?!]*\bclipboard\b",
      caseSensitive: false);

  static final RegExp _takePhoto = RegExp(
      '^$_kPolitePrefix'
      r'take (?:a |another )?(?:photo|picture|selfie|snapshot|shot)\b',
      caseSensitive: false);

  /// Leading negation — "don't", "do not", "never", "no need to", "stop" —
  /// makes ANY of the six families above a thing to escalate, not run.
  static final RegExp _leadingNegation = RegExp(
      r"^(?:well,?\s+|hey,?\s+|so,?\s+)*"
      r"(?:don'?t|do\s*not|never|no\s+need\s+to|stop)\b",
      caseSensitive: false);

  /// Permission-seeking questions — "should I…", "can I…?" — are the user
  /// thinking out loud, not commanding the phone. Distinct from "can you" /
  /// "could you", which ARE commands (see `_kPolitePrefix`).
  static final RegExp _interrogativeOpener = RegExp(
      r'^(?:well,?\s+|hey,?\s+|so,?\s+)*'
      r'(?:should i|can i|could i|would i|do i|am i supposed to|'
      r'is it (?:ok|okay) to)\b',
      caseSensitive: false);

  static final RegExp _notify = RegExp(
      r'^(?:hey,?\s+|please\s+|can you\s+|could you\s+)*'
      r'notify me\s+(?:that\s+|saying\s+|about\s+|:\s*)?(.+)$',
      caseSensitive: false);

  static final RegExp _open = RegExp(
      r'^(?:hey,?\s+|please\s+|can you\s+|could you\s+|would you\s+)*'
      r'(?:open|launch|start|go to|bring up)(?: up)?(?: the)?\s+(.+?)[.?!]*$',
      caseSensitive: false);

  static final RegExp _trailingPolite =
      RegExp(r'(\s+(please|now|for me|thanks))+$', caseSensitive: false);
  static final RegExp _trailingAppWord =
      RegExp(r'\s+app$', caseSensitive: false);

  /// Pronouns / placeholders — we will not guess what "it" is.
  static final RegExp _ambiguousTarget = RegExp(
      r'^(it|that|this|those|these|them|there|something|anything|that thing|the thing|stuff)$',
      caseSensitive: false);

  /// Nouns that mean "open" in a non-app sense.
  static final RegExp _notAnApp = RegExp(
      r'\b(door|window|gate|account|file|folder|link|url|website|site|page|tab|'
      r'settings?|drawer|box|bottle|blinds|curtains)\b',
      caseSensitive: false);

  // ── Third-party target guard (review IMPORTANT) ─────────────────────────────

  /// Any "for <word>" in the utterance.
  static final RegExp _forTarget =
      RegExp(r"\bfor\s+(my\s+)?([A-Za-z][\w'-]*)");

  /// Family members / relations — "for my mom" is unambiguously a person.
  static const Set<String> _relationWords = {
    'mom', 'mum', 'mother', 'dad', 'father', 'sister', 'brother', 'wife',
    'husband', 'son', 'daughter', 'grandma', 'grandpa', 'grandmother',
    'grandfather', 'boss', 'girlfriend', 'boyfriend', 'roommate', 'kid',
    'kids', 'parents', 'partner', 'fiancee', 'fiance', 'friend',
  };

  /// Words that legitimately follow a bare "for" and are NOT a person's name
  /// — durations, relative dates, and the speaker themselves.
  static const Set<String> _forTargetExclusions = {
    'a', 'an', 'the', 'minute', 'minutes', 'min', 'mins', 'hour', 'hours',
    'hr', 'hrs', 'second', 'seconds', 'sec', 'secs', 'day', 'days', 'week',
    'weeks', 'month', 'months', 'year', 'years', 'tomorrow', 'today',
    'tonight', 'now', 'later', 'forever', 'ever', 'good', 'sure', 'while',
    'moment', 'me', 'us', 'monday', 'tuesday', 'wednesday', 'thursday',
    'friday', 'saturday', 'sunday', 'january', 'february', 'march', 'april',
    'may', 'june', 'july', 'august', 'september', 'october', 'november',
    'december',
  };

  /// True when [raw] names another person as the target/beneficiary of the
  /// action — "set an alarm for Dad", "turn on the flashlight for Mom" — as
  /// opposed to a duration/date phrase like "for 5 minutes" / "for tomorrow".
  static bool _hasThirdPartyTarget(String raw) {
    for (final m in _forTarget.allMatches(raw)) {
      final word = m.group(2)!;
      final lower = word.toLowerCase();
      if (m.group(1) != null) {
        // "for my <word>" — only a third party when it's a relation word;
        // "for my keys" / "for my alarm" isn't a person.
        if (_relationWords.contains(lower)) return true;
        continue;
      }
      if (_forTargetExclusions.contains(lower)) continue;
      // Lowercase STT transcripts ("for dad", "for grandma") carry no
      // capitalization hint — a bare relation word is still a third party.
      if (_relationWords.contains(lower)) return true;
      // A capitalized word in the ORIGINAL text that isn't a known
      // non-person term reads as a proper name ("for Dad", "for Priya").
      if (word[0] != word[0].toLowerCase() && word[0] == word[0].toUpperCase()) {
        return true;
      }
    }
    return false;
  }

  // ── Small parsers ──────────────────────────────────────────────────────────

  static final RegExp _minutes = RegExp(
      r'\b(?:in|for)\s+(\d{1,3})\s*(minutes?|mins?|m)\b', caseSensitive: false);
  static final RegExp _hours =
      RegExp(r'\b(?:in|for)\s+(\d{1,2})\s*(hours?|hrs?|h)\b', caseSensitive: false);

  static int? _relativeMinutes(String lower) {
    final m = _minutes.firstMatch(lower);
    if (m != null) {
      final v = int.tryParse(m.group(1)!);
      if (v != null && v >= 1 && v <= 1440) return v;
    }
    final h = _hours.firstMatch(lower);
    if (h != null) {
      final v = int.tryParse(h.group(1)!);
      if (v != null && v >= 1 && v <= 24) return v * 60;
    }
    return null;
  }

  static final RegExp _clock = RegExp(
      r'\b(?:at|for)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?\b',
      caseSensitive: false);

  /// (hour24, minute) from "at 7:30 am" / "at 6 pm" / "at 07:05".
  static (int, int)? _clockTime(String lower) {
    final m = _clock.firstMatch(lower);
    if (m == null) return null;
    var h = int.tryParse(m.group(1)!);
    final min = int.tryParse(m.group(2) ?? '0') ?? 0;
    final ap = (m.group(3) ?? '').replaceAll('.', '').toLowerCase();
    if (h == null || min > 59) return null;
    if (ap == 'pm' && h < 12) h += 12;
    if (ap == 'am' && h == 12) h = 0;
    // A bare number with no am/pm and no colon is only a time if it's plausible
    // as one; "at 40" is not.
    if (h > 23) return null;
    if (ap.isEmpty && m.group(2) == null && h > 12) return null;
    return (h, min);
  }

  /// Recognize an explicit URL or a bare `something.tld` domain.
  static final RegExp _explicitUrl =
      RegExp(r'^(https?://\S+)$', caseSensitive: false);
  static final RegExp _bareDomain = RegExp(
      r'^(?:www\.)?[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)*\.'
      r'(com|org|net|io|dev|app|ai|co|edu|gov|tv|me|uk|us)(/\S*)?$',
      caseSensitive: false);

  static String? _asUrl(String target) {
    final t = target.trim();
    if (_explicitUrl.hasMatch(t)) return t;
    if (t.contains(' ')) return null;
    if (_bareDomain.hasMatch(t)) return 'https://$t';
    return null;
  }

  /// Normalize smart quotes + collapse whitespace so the patterns above see
  /// what the user actually said, however the STT punctuated it.
  static String _strip(String s) => s
      .replaceAll('’', "'")
      .replaceAll('“', '"')
      .replaceAll('”', '"')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _titleCase(String s) => s
      .split(RegExp(r'\s+'))
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}

/// Debug helper — one line per classification, so a mis-route is visible in the
/// device log without dumping the transcript at INFO.
void debugLogLocalDecision(LocalDecision d) {
  debugPrint('[local-exec] ${d.runtimeType}'
      '${d is LocalRun ? ' ${d.skill}' : ' ${(d as LocalSkip).reason}'}');
}
