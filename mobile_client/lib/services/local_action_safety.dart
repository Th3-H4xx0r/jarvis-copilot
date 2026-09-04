/// Heuristic: does a tool/skill name look like an outward-facing or
/// destructive action that should be confirmed before the on-device model
/// fires it autonomously? Small local models can mis-route, so we treat
/// anything that sends, deletes, calls, posts, or pays as needing confirmation.
///
/// Matching is on underscore-delimited NAME SEGMENTS (not raw substrings) so
/// innocent names like `text_to_speech` / `type_text` aren't flagged just for
/// containing "text".
library;

const Set<String> _riskySegments = {
  'send',
  'email',
  'mail',
  'sms',
  'call',
  'dial',
  'delete',
  'remove',
  'erase',
  'wipe',
  'purchase',
  'buy',
  'pay',
  'transfer',
  'post',
  'tweet',
  'publish',
  'share',
};

bool isOutwardOrDestructive(String name) {
  for (final seg in name.toLowerCase().split(RegExp(r'[_\s]+'))) {
    if (_riskySegments.contains(seg)) return true;
  }
  return false;
}

/// Skills the LOCAL EXECUTOR may fire on this device with no server round-trip
/// and no confirmation (plan 4.5). Deliberately a hard-coded ALLOW-list, not a
/// deny-list: a new skill is server-only until someone reviews it and adds it
/// here.
///
/// Every entry must be:
///   • confined to THIS phone (nothing that reaches another device or person),
///   • non-destructive and trivially reversible,
///   • unambiguous enough to drive from a small spoken grammar.
///
/// Deliberately absent: send_sms / make_call / share_text (outward), the
/// contacts + calendar readers (personal data, and the server has better
/// context), run_shortcut / tasker_invoke / type_text / tap_at (arbitrary
/// effects), record_audio, get_location.
const Set<String> kLocalActionAllowList = {
  'open_app',
  'open_url',
  'flashlight_on',
  'flashlight_off',
  'set_volume',
  'adjust_volume',
  'phone_control', // iOS volume/brightness only — the executor never emits other verbs
  'vibrate',
  'set_alarm',
  'notify',
  'clipboard_read',
  'clipboard_write',
  'take_photo',
  'play_audio',
};

/// True when [name] may be executed by the on-device local executor.
bool isLocallyAllowed(String name) =>
    kLocalActionAllowList.contains(name) && !isOutwardOrDestructive(name);
