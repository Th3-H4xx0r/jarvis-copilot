import 'dart:async';

import 'package:flutter/material.dart';

import '../main.dart' as app;
import '../services/android_accessibility.dart';
import '../services/credentials.dart';
import '../services/local_ai_settings.dart';
import '../services/on_device_ai_types.dart';
import '../services/watch_sync.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import 'ondevice_ai_settings_page.dart';
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
  bool _liveActivities = true;
  Map<String, dynamic> _watchStatus = const {};

  @override
  void initState() {
    super.initState();
    _allowShell = Credentials.instance.allowShell;
    _paused = app.runner.paused.value;
    _trackLocation = Credentials.instance.trackLocation;
    _liveActivities = Credentials.instance.liveActivitiesEnabled;
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

  String _onDeviceLabel() {
    switch (LocalAiSettings.instance.tier) {
      case LocalAiTier.off:
        return 'Off — everything on the server';
      case LocalAiTier.routerCommands:
        return 'Router + instant commands';
      case LocalAiTier.fullLocalFirst:
        return 'Full local-first';
    }
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
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(context, title: 'Settings', back: true),
      body: AppBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              // ── Connection summary card (gradient hero, blue accent) ──
              _ConnectionCard(
                server: Credentials.instance.serverUrl ?? '—',
                device: Credentials.instance.deviceName ?? '—',
              ),
              const SizedBox(height: 26),

              // ── Assistant toggles ──
              glassSectionLabel('Assistant'),
              GlassGroup(children: [
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
                ),
                _SwitchRow(
                  icon: Icons.dynamic_feed_rounded,
                  title: 'Live Activities',
                  subtitle: 'Show coding sessions on the Lock Screen / Dynamic '
                      'Island (iOS).',
                  value: _liveActivities,
                  onChanged: (v) {
                    setState(() => _liveActivities = v);
                    Credentials.instance.saveLiveActivities(v);
                    app.liveActivityCoordinator.setEnabled(v);
                  },
                  last: true,
                ),
              ]),
              const SizedBox(height: 26),

              // ── Navigation rows ──
              glassSectionLabel('More'),
              GlassGroup(children: [
                GlassRow(
                  icon: Icons.auto_awesome_rounded,
                  title: 'On-device AI',
                  subtitle: _onDeviceLabel(),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const OnDeviceAiSettingsPage(),
                    ));
                    if (mounted) setState(() {});
                  },
                ),
                GlassRow(
                  icon: Icons.tune_rounded,
                  title: 'Server settings',
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const WebViewPage(
                      title: 'Server settings',
                      path: '/?panel=settings',
                    ),
                  )),
                ),
                GlassRow(
                  icon: Icons.accessibility_new_rounded,
                  title: 'Accessibility access',
                  onTap: _openAccessibilitySettings,
                ),
                GlassRow(
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
              GlassGroup(children: [
                GlassRow(
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
      ),
    );
  }
}

/// Gradient hero card summarising the paired connection — blue accent.
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
          colors: [Color(0xFF15224A), Color(0xFF0C1020)],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: JcTheme.glassBorder),
        boxShadow: [
          BoxShadow(
            color: JcTheme.primaryBlue.withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: blueGradient(),
              boxShadow: [
                BoxShadow(
                  color: JcTheme.primaryBlue.withValues(alpha: 0.4),
                  blurRadius: 16,
                ),
              ],
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

/// A toggle row styled to match GlassRow — circular icon chip + Switch.
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
          activeTrackColor: JcTheme.primaryBlue,
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

  static Widget _circleIcon(IconData icon) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: JcTheme.glassFill,
          border: Border.all(color: JcTheme.glassBorder),
        ),
        child: Icon(icon, size: 20, color: JcTheme.text),
      );
}
