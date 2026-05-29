import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart' as app;
import '../services/android_accessibility.dart';
import '../services/credentials.dart';
import '../services/watch_sync.dart';
import '../theme.dart';
import 'pair_page.dart';
import 'webview_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _allowShell = false;
  bool _paused = false;
  bool _trackLocation = false;
  Map<String, dynamic> _locDiag = const {};

  @override
  void initState() {
    super.initState();
    _allowShell = Credentials.instance.allowShell;
    _paused = app.runner.paused.value;
    _trackLocation = Credentials.instance.trackLocation;
    _loadLocDiag();
  }

  Future<void> _loadLocDiag() async {
    final d = await app.location.diag();
    if (mounted) setState(() => _locDiag = d);
  }

  static String _ago(Object? ts) {
    final secs = (ts is num) ? ts.toDouble() : 0.0;
    if (secs <= 0) return 'never';
    final dt = DateTime.fromMillisecondsSinceEpoch((secs * 1000).round());
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _toggleTrackLocation(bool v) async {
    if (v) {
      final ok = await app.location.setEnabled(true);
      if (!ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Location permission needed. Enable Location → Always for '
                'JarvisCopilot in iOS Settings.'),
          ));
        }
        return; // leave the switch off
      }
    } else {
      await app.location.setEnabled(false);
    }
    setState(() => _trackLocation = v);
    await Credentials.instance.saveTrackLocation(v);
    await _loadLocDiag();
  }

  Future<void> _unpair() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Unpair this device?'),
        content: const Text(
          'Stored credentials will be cleared and the app will return '
          'to the pair screen. The server still has a record until you '
          'revoke it from the Devices tab.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Unpair')),
        ],
      ),
    );
    if (ok != true) return;
    await app.ws.stop();
    await Credentials.instance.clear();
    // Tell the watch it's logged out (clears its creds, flips to setup screen).
    unawaited(WatchSync.sync());
    if (!mounted) return;
    // MaterialApp only configures `home:`, no named routes — so we
    // pop everything and push a fresh PairPage manually.
    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const PairPage()),
      (_) => false,
    );
  }

  Future<void> _openAccessibilitySettings() async {
    final opened = await AndroidAccessibility.openSettings();
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Rebuild and reinstall the app to enable this settings shortcut.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: JcTheme.bg,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            title: const Text('Server'),
            subtitle: Text(
              Credentials.instance.serverUrl ?? '—',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          ListTile(
            title: const Text('Device name'),
            subtitle: Text(Credentials.instance.deviceName ?? '—'),
          ),
          ListTile(
            title: const Text('TLS pin'),
            subtitle: Text(
              Credentials.instance.certFingerprint?.substring(0, 16) ?? '—',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('Track my location'),
            subtitle: const Text(
                'Records location history (~every 10 min) for the assistant '
                'to query, and keeps it connected in the background. Needs '
                '"Always" location; uses battery.'),
            value: _trackLocation,
            onChanged: _toggleTrackLocation,
          ),
          if (_trackLocation)
            ListTile(
              dense: true,
              title: const Text('Background location status',
                  style: TextStyle(fontSize: 13)),
              subtitle: Text(
                'Last movement event: ${_ago(_locDiag['lastSlc'])}\n'
                'Last background push: ${_ago(_locDiag['lastPush'])}'
                '${(_locDiag['lastPushStatus'] ?? '').toString().isEmpty ? '' : ' — ${_locDiag['lastPushStatus']}'}',
                style: const TextStyle(fontSize: 12),
              ),
              isThreeLine: true,
              trailing: IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _loadLocDiag,
              ),
            ),
          SwitchListTile(
            title: const Text('Pause skill execution'),
            subtitle: const Text('Server invokes return "paused" until off.'),
            value: _paused,
            onChanged: (v) {
              setState(() => _paused = v);
              app.runner.paused.value = v;
            },
          ),
          SwitchListTile(
            title: const Text('Allow shell skill'),
            subtitle: const Text('Opt-in for the (Android-only) shell skill.'),
            value: _allowShell,
            onChanged: (v) {
              setState(() => _allowShell = v);
              Credentials.instance.saveAllowShell(v);
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: const Text('Server settings'),
            subtitle: const Text('Open the full settings page in webview'),
            onTap: () {
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const WebViewPage(
                  title: 'Server settings',
                  path: '/?panel=settings',
                ),
              ));
            },
          ),
          ListTile(
            leading: const Icon(Icons.accessibility_new),
            title: const Text('Accessibility access'),
            subtitle: const Text('Enable typing, tapping, and app-control skills'),
            onTap: _openAccessibilitySettings,
          ),
          const Divider(),
          ListTile(
            title: const Text('Unpair this device',
                style: TextStyle(color: JcTheme.danger)),
            onTap: _unpair,
          ),
        ],
      ),
    );
  }
}
