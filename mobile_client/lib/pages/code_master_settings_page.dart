import 'package:flutter/material.dart';

import '../api/coding_sessions.dart';
import '../main.dart' as app;
import '../services/api_client.dart' show apiErrorMessage;
import '../theme.dart';
import '../widgets/glass.dart';

/// Global "Code Master settings" screen — a mobile port of the WebUI
/// `codingCodeMasterSettings` panel. Controls which coding events notify you on
/// which channels (the notification matrix), whether the account-usage rings
/// show, and whether tool-permission prompts relay to the phone for remote
/// approval.
///
/// Backed by `GET/POST /api/coding/settings`:
///   { events: { finished|needs_input|error: {telegram,mobile,toast,photon} },
///     usage_display: bool, remote_approvals: bool }
///
/// Rendered as one glass card per EVENT with the four channel switches inside —
/// a true 3×4 table is too cramped on a phone. Loads on init, merges over
/// sensible defaults so missing keys are filled in, saves the full payload.
class CodeMasterSettingsPage extends StatefulWidget {
  const CodeMasterSettingsPage({super.key});

  @override
  State<CodeMasterSettingsPage> createState() => _CodeMasterSettingsPageState();
}

/// (key, label) pairs in WebUI order.
const List<(String, String)> _kEvents = [
  ('finished', 'Finished'),
  ('needs_input', 'Needs input'),
  ('error', 'Error'),
];
const List<(String, String, IconData)> _kChannels = [
  ('telegram', 'Telegram', Icons.send_rounded),
  ('mobile', 'Mobile push', Icons.phone_iphone_rounded),
  ('toast', 'WebUI toast', Icons.notifications_active_outlined),
  ('photon', 'iMessage', Icons.sms_outlined),
];

/// Backend per-channel defaults for an event (overlaid by whatever GET returns).
const Map<String, bool> _kChannelDefaults = {
  'telegram': false,
  'mobile': true,
  'toast': true,
  'photon': false,
};

class _CodeMasterSettingsPageState extends State<CodeMasterSettingsPage> {
  final CodingSessionsApi _api = CodingSessionsApi(app.api);

  // events[eventKey][channelKey] = bool — the editable matrix state.
  final Map<String, Map<String, bool>> _events = {
    for (final e in _kEvents)
      e.$1: {for (final c in _kChannels) c.$1: _kChannelDefaults[c.$1]!},
  };
  bool _usageDisplay = true; // default on
  bool _remoteApprovals = false; // default off

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await _api.getCodeMasterSettings();
      if (!mounted) return;
      // Merge-on-load: start from defaults, overlay whatever the server returns
      // for each event×channel; leave defaults for any missing key.
      final ev = (s['events'] as Map?) ?? const {};
      for (final e in _kEvents) {
        final row = (ev[e.$1] as Map?) ?? const {};
        for (final c in _kChannels) {
          final v = row[c.$1];
          _events[e.$1]![c.$1] = v is bool ? v : _kChannelDefaults[c.$1]!;
        }
      }
      setState(() {
        // usage_display defaults true unless the server explicitly says false.
        _usageDisplay = s['usage_display'] != false;
        _remoteApprovals = s['remote_approvals'] == true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = apiErrorMessage(e);
        _loading = false;
      });
    }
  }

  Map<String, dynamic> _payload() => {
        'events': {
          for (final e in _kEvents)
            e.$1: {
              for (final c in _kChannels) c.$1: _events[e.$1]![c.$1] ?? false,
            },
        },
        'usage_display': _usageDisplay,
        'remote_approvals': _remoteApprovals,
      };

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await _api.saveCodeMasterSettings(_payload());
      if (!mounted) return;
      // Reflect the server's canonical settings back into the UI.
      final ev = (saved['events'] as Map?) ?? const {};
      for (final e in _kEvents) {
        final row = (ev[e.$1] as Map?) ?? const {};
        for (final c in _kChannels) {
          final v = row[c.$1];
          if (v is bool) _events[e.$1]![c.$1] = v;
        }
      }
      setState(() {
        if (saved.containsKey('usage_display')) {
          _usageDisplay = saved['usage_display'] != false;
        }
        if (saved.containsKey('remote_approvals')) {
          _remoteApprovals = saved['remote_approvals'] == true;
        }
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Code Master settings saved')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = apiErrorMessage(e);
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't save settings")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(context, title: 'Code Master settings', back: true),
      body: AppBackground(
        child: SafeArea(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: JcTheme.primaryBlue))
              : SingleChildScrollView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 4),
                      const Text(
                        'Code Master settings',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: JcTheme.text,
                        ),
                      ),
                      const SizedBox(height: 22),

                      // ── Notifications matrix (one card per event) ──────────
                      glassSectionLabel('Notifications'),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(4, 0, 4, 14),
                        child: Text(
                          'Which coding events notify you, and on which '
                          'channels.',
                          style: TextStyle(
                              color: JcTheme.muted, fontSize: 13, height: 1.4),
                        ),
                      ),
                      for (final e in _kEvents) ...[
                        _EventCard(
                          label: e.$2,
                          channels: _events[e.$1]!,
                          onChanged: (ch, v) =>
                              setState(() => _events[e.$1]![ch] = v),
                        ),
                        const SizedBox(height: 12),
                      ],

                      const SizedBox(height: 12),

                      // ── Usage rings ────────────────────────────────────────
                      glassSectionLabel('Usage rings'),
                      GlassCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 2),
                        child: _SettingSwitch(
                          title: 'Show the 5-hour / weekly account-usage rings',
                          value: _usageDisplay,
                          onChanged: (v) => setState(() => _usageDisplay = v),
                        ),
                      ),

                      const SizedBox(height: 22),

                      // ── Remote approvals ───────────────────────────────────
                      glassSectionLabel('Remote approvals'),
                      GlassCard(
                        padding: const EdgeInsets.fromLTRB(12, 2, 12, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _SettingSwitch(
                              title:
                                  'Approve tool permissions from your phone '
                                  '(relays prompts to the mobile app)',
                              value: _remoteApprovals,
                              onChanged: (v) =>
                                  setState(() => _remoteApprovals = v),
                            ),
                            const Padding(
                              padding: EdgeInsets.only(left: 4, right: 4),
                              child: Text(
                                "Turn on when you're away from the terminal. "
                                'While off, sessions prompt locally as usual.',
                                style: TextStyle(
                                    color: JcTheme.muted,
                                    fontSize: 12,
                                    height: 1.4),
                              ),
                            ),
                          ],
                        ),
                      ),

                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 18),
                          child: Text(_error!,
                              style: const TextStyle(color: JcTheme.danger)),
                        ),

                      const SizedBox(height: 26),
                      GlassButton(
                        label: _saving ? 'Saving…' : 'Save settings',
                        full: true,
                        onPressed: _saving ? null : _save,
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// One event's card: a bold event label plus the four channel switches.
class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.label,
    required this.channels,
    required this.onChanged,
  });

  final String label;
  final Map<String, bool> channels;
  final void Function(String channelKey, bool value) onChanged;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
                color: JcTheme.text, fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          for (final c in _kChannels)
            _ChannelRow(
              icon: c.$3,
              label: c.$2,
              value: channels[c.$1] ?? false,
              onChanged: (v) => onChanged(c.$1, v),
            ),
        ],
      ),
    );
  }
}

/// A single channel toggle inside an event card: icon + label + a compact
/// switch.
class _ChannelRow extends StatelessWidget {
  const _ChannelRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          children: [
            Icon(icon, size: 18, color: JcTheme.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                    color: JcTheme.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w500),
              ),
            ),
            Transform.scale(
              scale: 0.85,
              child: Switch(
                value: value,
                onChanged: onChanged,
                activeThumbColor: Colors.white,
                activeTrackColor: JcTheme.primaryBlue,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A full-width labelled switch row (Usage rings / Remote approvals).
class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeThumbColor: Colors.white,
      activeTrackColor: JcTheme.primaryBlue,
      contentPadding: EdgeInsets.zero,
      title: Text(
        title,
        style: const TextStyle(
            color: JcTheme.text, fontSize: 14, fontWeight: FontWeight.w600),
      ),
    );
  }
}
