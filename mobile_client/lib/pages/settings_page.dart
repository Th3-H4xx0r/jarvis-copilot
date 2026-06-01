import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart' as app;
import '../services/android_accessibility.dart';
import '../services/credentials.dart';
import '../services/watch_sync.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import 'pair_page.dart';
import 'watch_companion_page.dart';
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
  Map<String, dynamic> _watchStatus = const {};

  @override
  void initState() {
    super.initState();
    _allowShell = Credentials.instance.allowShell;
    _paused = app.runner.paused.value;
    _trackLocation = Credentials.instance.trackLocation;
    _loadWatchStatus();
  }

  Future<void> _loadWatchStatus() async {
    final s = await WatchSync.getStatus();
    if (mounted) setState(() => _watchStatus = s);
  }

  String _watchLabel() {
    final s = _watchStatus;
    if (s.isEmpty) return 'Checking…';
    if (s['supported'] != true) return 'Not available on this device';
    if (s['paired'] != true) return 'No Apple Watch paired';
    if (s['watchAppInstalled'] != true) return 'Watch app not installed';
    if (s['reachable'] == true) return 'Connected';
    return 'Installed — not reachable';
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
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            // ── Connection summary card (gradient hero, ref "Want more") ──
            _ConnectionCard(
              server: Credentials.instance.serverUrl ?? '—',
              device: Credentials.instance.deviceName ?? '—',
            ),
            const SizedBox(height: 26),

            // ── Assistant toggles ──
            _sectionLabel('Assistant'),
            _SettingsGroup(children: [
              _SwitchRow(
                icon: Icons.my_location_rounded,
                title: 'Track my location',
                subtitle: 'Background location history for the assistant. '
                    'Needs "Always"; uses battery.',
                value: _trackLocation,
                onChanged: _toggleTrackLocation,
              ),
              _SwitchRow(
                icon: Icons.pause_circle_outline_rounded,
                title: 'Pause skill execution',
                subtitle: 'Server invokes return "paused" until off.',
                value: _paused,
                onChanged: (v) {
                  setState(() => _paused = v);
                  app.runner.paused.value = v;
                },
              ),
              _SwitchRow(
                icon: Icons.terminal_rounded,
                title: 'Allow shell skill',
                subtitle: 'Opt-in for the (Android-only) shell skill.',
                value: _allowShell,
                onChanged: (v) {
                  setState(() => _allowShell = v);
                  Credentials.instance.saveAllowShell(v);
                },
                last: true,
              ),
            ]),
            const SizedBox(height: 26),

            // ── Navigation rows ──
            _sectionLabel('More'),
            _SettingsGroup(children: [
              _NavRow(
                icon: Icons.tune_rounded,
                title: 'Server settings',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const WebViewPage(
                    title: 'Server settings',
                    path: '/?panel=settings',
                  ),
                )),
              ),
              _NavRow(
                icon: Icons.accessibility_new_rounded,
                title: 'Accessibility access',
                onTap: _openAccessibilitySettings,
              ),
              _NavRow(
                icon: Icons.watch_rounded,
                title: 'Apple Watch companion',
                subtitle: _watchLabel(),
                onTap: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const WatchCompanionPage(),
                  ));
                  _loadWatchStatus();
                },
                last: true,
              ),
            ]),
            const SizedBox(height: 26),

            // ── Danger ──
            _SettingsGroup(children: [
              _NavRow(
                icon: Icons.logout_rounded,
                title: 'Unpair this device',
                danger: true,
                onTap: _unpair,
                last: true,
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 10),
        child: Text(
          text,
          style: const TextStyle(
            color: JcTheme.text,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
}

/// Gradient hero card summarising the paired connection.
class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.server, required this.device});
  final String server, device;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A2452), Color(0xFF101428)],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: JcTheme.glassBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: iridescentGradient(),
            ),
            child: const Icon(Icons.check_rounded, color: Colors.white, size: 26),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Connected',
                    style: TextStyle(
                        color: JcTheme.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(device,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: JcTheme.text, fontSize: 13)),
                Text(server,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: JcTheme.muted,
                        fontSize: 12,
                        fontFamily: 'monospace')),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A rounded grouped container (like iOS inset-grouped lists).
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: JcTheme.glassFill,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: JcTheme.glassBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

Widget _circleIcon(IconData icon, {Color? color}) => Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: (color ?? JcTheme.text).withValues(alpha: 0.10),
        border: Border.all(color: JcTheme.glassBorder),
      ),
      child: Icon(icon, size: 20, color: color ?? JcTheme.text),
    );

/// A tappable nav row with a circular icon + chevron.
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.last = false,
    this.danger = false,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool last, danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? JcTheme.danger : JcTheme.text;
    return Column(
      children: [
        ListTile(
          onTap: onTap,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: _circleIcon(icon, color: danger ? JcTheme.danger : null),
          title: Text(title,
              style: TextStyle(
                  color: color, fontSize: 15, fontWeight: FontWeight.w600)),
          subtitle: subtitle == null
              ? null
              : Text(subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 12)),
          trailing: Icon(Icons.chevron_right_rounded,
              color: JcTheme.muted.withValues(alpha: 0.7)),
        ),
        if (!last)
          const Divider(height: 1, indent: 68, color: JcTheme.glassBorder),
      ],
    );
  }
}

/// A toggle row with a circular icon (matches _NavRow styling).
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.last = false,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SwitchListTile(
          value: value,
          onChanged: onChanged,
          activeThumbColor: Colors.white,
          activeTrackColor: JcTheme.accent,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          secondary: _circleIcon(icon),
          title: Text(title,
              style: const TextStyle(
                  color: JcTheme.text, fontSize: 15, fontWeight: FontWeight.w600)),
          subtitle: subtitle == null
              ? null
              : Text(subtitle!,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 12)),
        ),
        if (!last)
          const Divider(height: 1, indent: 68, color: JcTheme.glassBorder),
      ],
    );
  }
}
