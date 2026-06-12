/// Deterministic matcher for a few simple, reliable, THIS-DEVICE commands the
/// on-device layer can fire instantly — WITHOUT the model (so it can't fabricate
/// args). Anything cross-device ("open X on my Mac"), or not recognized, returns
/// null so the turn falls through to the pre-gate / local answer.
library;

class MatchedCommand {
  MatchedCommand(this.name, this.args, this.confirmation);
  final String name;
  final Map<String, dynamic> args;
  final String confirmation;
}

class LocalCommandMatcher {
  static final _crossDevice = RegExp(
      r'\bon (my|the) (mac|macbook|laptop|computer|desktop|pc|watch|tv|ipad|tablet|server)\b',
      caseSensitive: false);

  static final _open = RegExp(
      r'^(?:can you |could you |please |hey,? )?(?:open|launch|start)(?: up)?(?: the)? (.+?)(?: app)?[.?! ]*$',
      caseSensitive: false);

  static final _flashOn = RegExp(
      r'(\b(turn on|enable|switch on)\b.*\b(flashlight|torch|light)\b)|(^(flashlight|torch) on$)',
      caseSensitive: false);
  static final _flashOff = RegExp(
      r'(\b(turn off|disable|switch off)\b.*\b(flashlight|torch|light)\b)|(^(flashlight|torch) off$)',
      caseSensitive: false);
  static final _vibrate =
      RegExp(r'^vibrate( the phone)?[.! ]*$|\bvibrate the phone\b', caseSensitive: false);
  static final _volume = RegExp(
      r'\b(?:set |change |turn )?(?:the )?volume (?:to |at |up to )?(\d{1,3})\s*%?\b',
      caseSensitive: false);
  static final _brightness = RegExp(
      r'\b(?:set |change )?(?:the )?brightness (?:to |at )?(\d{1,3})\s*%?\b',
      caseSensitive: false);
  // "text <name> <message>" / "send <name> a text saying <message>" etc.
  static final _sendMsg = RegExp(
      r'^(?:can you |please |hey,? )?'
      r'(?:text|message|imessage|(?:send|shoot)(?: an?)? (?:text|message|imessage|sms)?(?: to)?)\s+'
      r'(\w[\w .\-]*?)\s+'
      r'(?:saying |that |this:?\s*|:\s*|the message |a message saying )?'
      r'(.+)$',
      caseSensitive: false);

  static MatchedCommand? match(String text) {
    final t = text.trim();
    final lower = t.toLowerCase();
    if (lower.isEmpty) return null;
    // Cross-device → not a simple local command (let the server target it).
    if (_crossDevice.hasMatch(lower)) return null;

    if (_flashOn.hasMatch(lower)) {
      return MatchedCommand('flashlight_on', const {}, 'Flashlight on, sir.');
    }
    if (_flashOff.hasMatch(lower)) {
      return MatchedCommand('flashlight_off', const {}, 'Flashlight off, sir.');
    }
    if (_vibrate.hasMatch(lower)) {
      return MatchedCommand('vibrate', const {}, 'Right away, sir.');
    }

    final vol = _volume.firstMatch(lower);
    if (vol != null) {
      final pct = (int.tryParse(vol.group(1)!) ?? 50).clamp(0, 100);
      return MatchedCommand('phone_control',
          {'action': 'volume', 'value': '$pct'}, 'Volume set to $pct%, sir.');
    }
    final br = _brightness.firstMatch(lower);
    if (br != null) {
      final pct = (int.tryParse(br.group(1)!) ?? 50).clamp(0, 100);
      return MatchedCommand('phone_control',
          {'action': 'brightness', 'value': '$pct'}, 'Brightness set to $pct%, sir.');
    }

    // Send a message via the Shortcut (no native composer drawer).
    final sm = _sendMsg.firstMatch(t);
    if (sm != null) {
      final to = sm.group(1)!.trim();
      final msg = sm.group(2)!.trim();
      if (to.isNotEmpty && msg.isNotEmpty && to.split(RegExp(r'\s+')).length <= 4) {
        return MatchedCommand(
            'phone_control',
            {'action': 'send_message', 'to': to, 'message': msg},
            'Sent to $to, sir.');
      }
    }

    final open = _open.firstMatch(t);
    if (open != null) {
      final app = open.group(1)!.trim();
      if (app.isNotEmpty &&
          app.split(RegExp(r'\s+')).length <= 3 &&
          !lower.contains('open up to') &&
          !RegExp(r'\b(door|window|account|file|link|url|website|page|tab|settings?)\b')
              .hasMatch(app.toLowerCase())) {
        return MatchedCommand(
            'open_app', {'name': _titleCase(app)}, 'Opening $app, sir.');
      }
    }
    return null;
  }

  static String _titleCase(String s) => s
      .split(RegExp(r'\s+'))
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
