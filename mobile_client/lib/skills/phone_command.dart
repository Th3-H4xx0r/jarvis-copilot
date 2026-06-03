import 'dart:convert';

/// Pure helpers for the `phone_control` dispatcher command protocol. Kept free
/// of Flutter/platform dependencies so they can be unit-tested without a device.
///
/// See docs/superpowers/specs/2026-06-03-dynamic-shortcuts-dispatcher-design.md.

/// Verbs whose final action switches apps (so iOS leaves the user there and we
/// don't wait for an x-callback result). Everything else returns a value.
const Set<String> _launchActions = {'open_app', 'open_url'};

/// Skill args consumed by the Dart layer that must NOT be forwarded to the
/// Shortcut as part of the JSON command.
const Set<String> _internalKeys = {'timeout_seconds'};

/// True if `action` should wait for and parse the Shortcut's result. Unknown
/// actions default to true (safer: a user-added verb that returns a value still
/// gets its result back).
bool phoneActionAwaitsResult(String action) => !_launchActions.contains(action);

/// Build the JSON command map sent to the dispatcher: `action` (required) plus
/// any provided params, dropping nulls, empty strings, and internal-only keys.
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

/// Encode a query-parameter map as `key=value&…`, percent-encoding each part so
/// **spaces become `%20`**.
///
/// We can't use `Uri(queryParameters: …)` / `Uri.encodeQueryComponent`: those
/// emit `+` for spaces (application/x-www-form-urlencoded), and the iOS Shortcuts
/// app treats `+` as a LITERAL plus — so a name like "JarvisCopilot Runner"
/// arrives as "JarvisCopilot+Runner" and the Shortcut isn't found.
String encodeQueryWithPercent20(Map<String, String> params) => params.entries
    .map((e) =>
        '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
    .join('&');

/// If `command` targets something the app already does NATIVELY, return the name
/// of the native skill to use instead — so phone_control can refuse and redirect
/// rather than bounce the OPTIONAL Shortcut (the LLM can't be relied on to pick
/// the native skill from descriptions alone). Returns null for genuinely
/// Shortcut-only actions (set / scene / media / now_playing / user-added verbs),
/// which keeps the dispatcher extensible.
String? nativeRedirectSkill(Map<String, dynamic> command) {
  switch ((command['action'] ?? '').toString()) {
    case 'flashlight':
      return 'flashlight_on / flashlight_off';
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

/// Parse the Shortcut's textual output. A JSON object is returned as-is; any
/// other text (or null/empty) is wrapped as `{ok:true, result:<raw>}`.
Map<String, dynamic> parsePhoneOutput(String? raw) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return {'ok': true, 'result': ''};
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {/* not JSON — fall through */}
  return {'ok': true, 'result': text};
}

/// Description baked into the phone_control tool. Deliberately SCOPED to only the
/// iOS settings apps can't change directly, and it redirects everything else to
/// the dedicated native skills — so the LLM doesn't route common requests (open
/// app, battery, flashlight…) through the optional Shortcut.
const String phoneControlDescription =
    'Control iOS via the "JarvisCopilot Runner" Shortcut. Set `action` to the verb '
    'DIRECTLY and pass its value:\n'
    '• brightness / volume → value: 0.0–1.0   e.g. {"action":"brightness","value":0.3}\n'
    '• wifi / bluetooth / focus → value: 1 (on) or 0 (off)\n'
    '• open_app → app: the app name (e.g. "Spotify")\n'
    '• open_url → url: a URL\n'
    '• alarm → time: e.g. "7:00 AM"\n'
    'For battery, location, clipboard, flashlight, vibrate, notify, calls, texts, '
    'etc. use the dedicated NATIVE skills instead (they need no Shortcut). Returns '
    '{ok:…}; an error means the Shortcut is not installed (it is optional). Each '
    'run briefly flashes through the Shortcuts app.';
