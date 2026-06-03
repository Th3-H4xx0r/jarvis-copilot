/// Human title for the LOCAL notification posted when a foreground-required
/// action is deferred (app backgrounded). Mirrors the server's
/// `format_action_banner` so the banner reads the same whoever posts it.
/// Pure — unit-tested.
String actionBannerTitle(String skill, Map<String, dynamic> args) {
  String s(String k) => (args[k] ?? '').toString();
  String pct(Object? v) {
    final n = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    if (n == null) return '';
    final d = n <= 1 ? n * 100 : n;
    return '${d.round()}%';
  }

  bool truthy(Object? v) =>
      const ['1', 'on', 'true', 'yes'].contains('${v ?? ''}'.toLowerCase().trim());

  String title;
  switch (skill) {
    case 'open_url':
      final url = s('url');
      String host = url;
      try {
        host = Uri.parse(url).host;
        if (host.isEmpty) host = url;
      } catch (_) {/* keep raw */}
      title = 'Open $host';
      break;
    case 'open_app':
      final name = s('app').isNotEmpty ? s('app') : (s('name').isNotEmpty ? s('name') : 'app');
      title = 'Open $name';
      break;
    case 'run_shortcut':
      title = 'Run ${s('name').isNotEmpty ? s('name') : 'shortcut'}';
      break;
    case 'create_shortcut':
      title = 'Add a Shortcut';
      break;
    case 'send_sms':
      title = 'Send a text';
      break;
    case 'phone_control':
      final action = s('action');
      final value = args['value'];
      if (action == 'brightness' || action == 'volume') {
        final p = pct(value);
        title = p.isEmpty ? 'Set $action' : 'Set $action $p';
      } else if (action == 'wifi' || action == 'bluetooth' || action == 'focus') {
        const names = {'wifi': 'Wi-Fi', 'bluetooth': 'Bluetooth', 'focus': 'Focus'};
        title = 'Turn ${truthy(value) ? 'on' : 'off'} ${names[action]}';
      } else {
        title = 'Phone control';
      }
      break;
    default:
      title = 'JARVIS action ready';
  }
  return title.length > 100 ? title.substring(0, 100) : title;
}
