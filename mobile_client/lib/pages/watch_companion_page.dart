import 'package:flutter/material.dart';

import '../services/watch_sync.dart';
import '../theme.dart';
import '../widgets/glass.dart';

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
    return (label: 'Connected', color: JcTheme.success, icon: Icons.check_circle);
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
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        context,
        title: 'Apple Watch',
        back: true,
        trailing: GlassIconButton(
          icon: Icons.refresh_rounded,
          onTap: _loading ? null : _load,
          size: 38,
          iconSize: 19,
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                  children: [
                    // Headline status banner.
                    GlassCard(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                      child: Row(
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: h.color.withValues(alpha: 0.12),
                              border: Border.all(color: h.color.withValues(alpha: 0.35)),
                            ),
                            child: Icon(h.icon, color: h.color, size: 26),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              h.label,
                              style: TextStyle(
                                color: h.color,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),
                    glassSectionLabel('Status'),
                    const SizedBox(height: 8),

                    // Status rows in a frosted GlassGroup.
                    GlassGroup(
                      children: [
                        _glassStatusRow(
                          icon: Icons.watch_rounded,
                          title: 'Apple Watch paired',
                          ok: _supported && _paired,
                          sub: 'A watch is paired with this iPhone',
                        ),
                        _glassStatusRow(
                          icon: Icons.apps_rounded,
                          title: 'Watch app installed',
                          ok: _installed,
                          sub: 'The JarvisCopilot app is installed on the watch as this app\'s companion',
                        ),
                        _glassStatusRow(
                          icon: Icons.wifi_rounded,
                          title: 'Reachable now',
                          ok: _reachable,
                          sub: 'The watch can exchange live messages with this app right now',
                        ),
                        GlassRow(
                          icon: Icons.info_outline_rounded,
                          title: 'Session state',
                          subtitle: _activationLabel(_status['activationState']),
                          last: true,
                          trailing: const SizedBox.shrink(),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),

                    // Info card.
                    const GlassCard(
                      padding: EdgeInsets.all(18),
                      child: Text(
                        'The watch app is a voice-only companion: you dictate on the '
                        'watch and this iPhone app relays it to JarvisCopilot and '
                        'speaks the reply back. It works only while this app is '
                        'reachable (it can be in the background). If "Watch app '
                        'installed" is off, the watch app must be built as a '
                        'companion of this app and installed on the watch.',
                        style: TextStyle(fontSize: 13, color: JcTheme.muted, height: 1.5),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  /// A GlassRow-style status row with a coloured ok/fail icon.
  Widget _glassStatusRow({
    required IconData icon,
    required String title,
    required bool ok,
    required String sub,
  }) {
    final statusColor = ok ? JcTheme.success : JcTheme.muted;
    return GlassRow(
      icon: icon,
      title: title,
      subtitle: sub,
      trailing: Icon(
        ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
        color: statusColor,
        size: 20,
      ),
    );
  }
}
