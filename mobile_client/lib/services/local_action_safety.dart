/// Heuristic: does a tool/skill name look like an outward-facing or
/// destructive action that should be confirmed before the on-device model
/// fires it autonomously? Small local models can mis-route, so we treat
/// anything that sends, deletes, calls, posts, or pays as needing confirmation.
library;

const Set<String> _riskyTokens = {
  'send',
  'email',
  'mail',
  'text',
  'message',
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
  'archive',
};

bool isOutwardOrDestructive(String name) {
  final lower = name.toLowerCase();
  for (final t in _riskyTokens) {
    if (lower.contains(t)) return true;
  }
  return false;
}
