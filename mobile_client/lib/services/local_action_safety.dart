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
