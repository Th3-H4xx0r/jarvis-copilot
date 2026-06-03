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

/// Documented v1 vocabulary baked into the phone_control tool description, so the
/// LLM can act without a discovery round-trip for the stable core verbs.
const String phoneControlDescription =
    'Control this iPhone via the "JarvisCopilot Runner" Shortcut (must be '
    'installed — see setup). Pass an `action` plus params. Core verbs: '
    'open_app{app} / open_url{url} (open an app or URL — you then stay in that '
    'app, no value returned); set{setting,value} where setting is '
    'brightness|volume|low_power|wifi|bluetooth|cellular|focus|flashlight|'
    'orientation_lock; media{op} op=play|pause|next|previous; '
    'get{what} what=battery|clipboard|location|now_playing; scene{name} runs a '
    'HomeKit scene. Returns {ok:true,result:…} or {ok:false,error:…}. The user '
    'can add verbs to the Shortcut — call phone_capabilities to discover the '
    'live full list. Every run briefly flashes through the Shortcuts app.';
