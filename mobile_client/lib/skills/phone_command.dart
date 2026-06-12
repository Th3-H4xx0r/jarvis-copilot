import 'dart:convert';

/// Pure helpers for the `phone_control` per-verb Shortcut protocol. Kept free of
/// Flutter/platform dependencies so they can be unit-tested without a device.
///
/// Architecture (see docs/mobile/jarviscopilot-runner-shortcut.md): each iOS-
/// locked setting maps to its OWN tiny "JC <Verb>" Shortcut that takes the value
/// as PLAIN TEXT input and runs one action. We deliberately do NOT use a single
/// JSON dispatcher: iOS `Get Dictionary from Input` won't reliably parse a multi-
/// key payload, and the `If` action won't reliably branch on a verb — both were
/// proven flaky on-device. Per-verb shortcuts use only bulletproof primitives
/// (text input → `Get Numbers from Input` → the action), so there is no
/// dictionary, no key lookup, no conditional, and no value coercion anywhere.

/// The verbs phone_control drives, each to a same-named "JC <Verb>" Shortcut.
const Map<String, String> verbShortcutNames = {
  'brightness': 'JC Brightness',
  'volume': 'JC Volume',
  'wifi': 'JC WiFi',
  'bluetooth': 'JC Bluetooth',
  'focus': 'JC Focus',
  'open_url': 'JC Open URL',
  // Send an iMessage/SMS WITHOUT the native composer drawer (Shortcuts' Send
  // Message action can send directly). Input is "recipient␟message".
  'send_message': 'JC Send Message',
};

/// Delimiter between recipient and body in the JC Send Message shortcut input
/// (U+241F SYMBOL FOR UNIT SEPARATOR — won't occur in a normal message).
const String sendMessageDelimiter = '␟';

/// Skill args consumed by the Dart layer that must NOT be forwarded.
const Set<String> _internalKeys = {'timeout_seconds'};

/// Build the command map from skill args: `action` (required) plus any provided
/// params, dropping nulls, empty strings, and internal-only keys.
Map<String, dynamic> buildPhoneCommand(Map<String, dynamic> args) {
  final action = (args['action'] ?? '').toString();
  if (action.isEmpty) throw ArgumentError('action required');
  final out = <String, dynamic>{'action': action};
  args.forEach((k, v) {
    if (k == 'action' || _internalKeys.contains(k)) return;
    if (v == null) return;
    if (v is String && v.isEmpty) return;
    out[k] = v;
  });
  return out;
}

/// Normalize a verb's value into the RAW TEXT the matching Shortcut expects.
///
/// - wifi/bluetooth/focus → "1" / "0" (accepts on/off/true/false/yes/no).
/// - brightness/volume    → a 0.0–1.0 decimal; a percentage (30 or "30%") is
///   divided by 100, and the result is clamped to [0, 1].
/// - open_url             → the URL, passed through unchanged.
String rawValueForVerb(String action, Map<String, dynamic> command) {
  if (action == 'open_url') return (command['url'] ?? '').toString();
  if (action == 'send_message') {
    final to = (command['to'] ?? command['recipient'] ?? '').toString().trim();
    final msg = (command['message'] ?? command['body'] ?? command['value'] ?? '')
        .toString()
        .trim();
    return '$to$sendMessageDelimiter$msg';
  }
  final v = command['value'];
  if (action == 'wifi' || action == 'bluetooth' || action == 'focus') {
    final s = v.toString().toLowerCase().trim();
    if (['1', 'on', 'true', 'yes', 'enable', 'enabled'].contains(s)) return '1';
    if (['0', 'off', 'false', 'no', 'disable', 'disabled'].contains(s)) {
      return '0';
    }
    return s;
  }
  // brightness / volume: iOS Shortcuts' "Set Brightness"/"Set Volume" take a
  // PERCENTAGE (0–100). A 0.0–1.0 decimal was read as ~0% (the "always 0" bug),
  // so normalize to an integer percent. (0.3 → 30, 30 → 30, "30%" → 30.)
  final raw = v.toString().trim();
  final isPct = raw.endsWith('%');
  final n = double.tryParse(raw.replaceAll('%', '').trim());
  if (n == null) return raw;
  var pct = (isPct || n > 1) ? n : n * 100.0;
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  return pct.round().toString();
}

/// Resolve a phone_control command to the per-verb Shortcut name + its raw text
/// input. Returns null if the verb has no Shortcut (caller errors / redirects).
({String name, String input})? phoneShortcutFor(Map<String, dynamic> command) {
  final action = (command['action'] ?? '').toString();
  final name = verbShortcutNames[action];
  if (name == null) return null;
  return (name: name, input: rawValueForVerb(action, command));
}

/// Encode a query-parameter map as `key=value&…`, percent-encoding each part so
/// **spaces become `%20`**.
///
/// We can't use `Uri(queryParameters: …)` / `Uri.encodeQueryComponent`: those
/// emit `+` for spaces (application/x-www-form-urlencoded), and the iOS Shortcuts
/// app treats `+` as a LITERAL plus — so a name like "JC Brightness" arrives as
/// "JC+Brightness" and the Shortcut isn't found.
String encodeQueryWithPercent20(Map<String, String> params) => params.entries
    .map((e) =>
        '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
    .join('&');

/// If `command` targets something the app already does NATIVELY, return the name
/// of the native skill to use instead — so phone_control refuses and redirects
/// rather than bounce a Shortcut for it. Returns null for genuine Shortcut verbs.
String? nativeRedirectSkill(Map<String, dynamic> command) {
  switch ((command['action'] ?? '').toString()) {
    case 'flashlight':
      return 'flashlight_on / flashlight_off';
    case 'open_app':
      return 'open_app';
    case 'alarm':
      return 'set_alarm';
    case 'get':
      switch ((command['what'] ?? '').toString()) {
        case 'battery':
          return 'battery_level';
        case 'location':
          return 'get_location';
        case 'clipboard':
          return 'clipboard_read';
      }
      return null;
  }
  return null;
}

/// Parse a Shortcut's textual output. A JSON object is returned as-is; any other
/// text (or null/empty) is wrapped as `{ok:true, result:<raw>}`. Retained for
/// any verb that returns output; the setting verbs are fire-and-forget.
Map<String, dynamic> parsePhoneOutput(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return {'ok': true, 'result': ''};
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {/* not JSON — fall through */}
  return {'ok': true, 'result': text};
}

/// Description baked into the phone_control tool. Scoped to the iOS settings apps
/// can't change directly; everything else redirects to dedicated native skills.
const String phoneControlDescription =
    'Control iOS-locked settings via the per-verb "JC …" Shortcuts. Set `action` '
    'to the verb and pass its value:\n'
    '• brightness / volume → value: 0.0–1.0 (a percent like 30 is fine)   e.g. {"action":"brightness","value":0.3}\n'
    '• wifi / bluetooth / focus → value: 1 (on) or 0 (off)\n'
    '• open_url → url: a URL (to open an app, pass its URL scheme, e.g. "spotify://")\n'
    'For battery, location, clipboard, flashlight, vibrate, notify, calls, texts, '
    'opening an app by name, and alarms, use the dedicated NATIVE skills instead '
    '(they need no Shortcut). Each verb runs a tiny "JC <Verb>" Shortcut (one-time '
    'install); an error means that Shortcut is not installed. Each run briefly '
    'flashes through the Shortcuts app and changes the setting immediately.';
