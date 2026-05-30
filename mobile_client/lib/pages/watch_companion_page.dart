import 'package:flutter/material.dart';

import '../services/watch_sync.dart';
import '../theme.dart';

/// Shows the live Apple Watch companion connection status (from WCSession on
/// the iOS side) and explains what each state means.
class WatchCompanionPage extends StatefulWidget {
  const WatchCompanionPage({super.key});

  @override
  State<WatchCompanionPage> createState() => _WatchCompanionPageState();
}

class _WatchCompanionPageState extends State<WatchCompanionPage> {
  Map<String, dynamic> _status = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final s = await WatchSync.getStatus();
    if (!mounted) return;
    setState(() {
      _status = s;
      _loading = false;
    });
  }

  bool get _supported => _status['supported'] == true;
  bool get _paired => _status['paired'] == true;
  bool get _installed => _status['watchAppInstalled'] == true;
  bool get _reachable => _status['reachable'] == true;

  /// Headline state for the banner.
  ({String label, Color color, IconData icon}) get _headline {
    if (!_supported) {
      return (label: 'Not available', color: JcTheme.muted, icon: Icons.watch_off);
    }
    if (!_paired) {
      return (label: 'No Apple Watch paired', color: JcTheme.muted, icon: Icons.watch_off);
    }
    if (!_installed) {
      return (label: 'Watch app not installed', color: JcTheme.danger, icon: Icons.error_outline);
    }
    if (!_reachable) {
      return (label: 'Installed — not reachable', color: Colors.orange, icon: Icons.cloud_off);
    }
    return (label: 'Connected', color: Colors.green, icon: Icons.check_circle);
  }

  static String _activationLabel(Object? raw) {
    switch ((raw is num) ? raw.toInt() : -1) {
      case 0:
        return 'Not activated';
      case 1:
        return 'Inactive';
      case 2:
        return 'Activated';
      default:
        return '—';
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = _headline;
    return Scaffold(
      backgroundColor: JcTheme.bg,
      appBar: AppBar(
        title: const Text('Apple Watch companion'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    children: [
                      Icon(h.icon, color: h.color, size: 40),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          h.label,
                          style: TextStyle(
                              color: h.color,
                              fontSize: 20,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                _statusRow('Apple Watch paired', _supported && _paired,
                    sub: 'A watch is paired with this iPhone'),
                _statusRow('Watch app installed', _installed,
                    sub: 'The JarvisCopilot app is installed on the watch as this app’s companion'),
                _statusRow('Reachable now', _reachable,
                    sub: 'The watch can exchange live messages with this app right now'),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Session state'),
                  subtitle: Text(_activationLabel(_status['activationState'])),
                ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
                  child: Text(
                    'The watch app is a voice-only companion: you dictate on the '
                    'watch and this iPhone app relays it to JarvisCopilot and '
                    'speaks the reply back. It works only while this app is '
                    'reachable (it can be in the background). If "Watch app '
                    'installed" is off, the watch app must be built as a '
                    'companion of this app and installed on the watch.',
                    style: TextStyle(fontSize: 13, color: JcTheme.muted),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _statusRow(String title, bool ok, {required String sub}) {
    return ListTile(
      leading: Icon(
        ok ? Icons.check_circle : Icons.cancel,
        color: ok ? Colors.green : JcTheme.muted,
      ),
      title: Text(title),
      subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
      isThreeLine: sub.length > 40,
    );
  }
}
