import 'dart:async';

import 'package:flutter/material.dart';

import '../services/local_ai_settings.dart';
import '../services/on_device_ai.dart';
import '../services/on_device_ai_types.dart';
import '../theme.dart';
import '../widgets/glass.dart';

/// Configuration for the on-device AI layer: tier, per-surface toggles, the
/// active local engine/model (+ downloads), tunables, and a debug generate box.
class OnDeviceAiSettingsPage extends StatefulWidget {
  const OnDeviceAiSettingsPage({super.key});

  @override
  State<OnDeviceAiSettingsPage> createState() => _OnDeviceAiSettingsPageState();
}

class _OnDeviceAiSettingsPageState extends State<OnDeviceAiSettingsPage> {
  final _s = LocalAiSettings.instance;
  final _ai = OnDeviceAi.instance;

  OnDeviceAvailability? _avail;
  List<LocalModelInfo> _models = const [];
  final Map<String, double> _downloading = {}; // id -> progress
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final avail = await _ai.availability();
    final models = await _ai.listModels();
    if (!mounted) return;
    setState(() {
      _avail = avail;
      _models = models;
      _loading = false;
    });
  }

  Future<void> _save() async {
    await _s.save();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('On-device AI'),
        backgroundColor: Colors.transparent,
        centerTitle: true,
      ),
      body: AppBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _availabilityCard(),
              glassSectionLabel('Mode'),
              GlassGroup(children: _tierRows()),
              glassSectionLabel('Use on-device for'),
              GlassGroup(children: [
                _switchTile('Chat', _s.chatEnabled, (v) {
                  setState(() => _s.chatEnabled = v);
                  _save();
                }),
                _switchTile('Voice', _s.voiceEnabled, (v) {
                  setState(() => _s.voiceEnabled = v);
                  _save();
                }),
              ]),
              glassSectionLabel('Local model'),
              GlassGroup(children: _modelRows()),
              glassSectionLabel('Advanced'),
              GlassGroup(children: _advancedRows()),
              glassSectionLabel('Test'),
              const _DebugGenerate(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _availabilityCard() {
    final a = _avail;
    final ok = a?.available == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        child: Row(
          children: [
            Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                color: ok ? JcTheme.cyan : JcTheme.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _loading
                    ? 'Checking on-device engine…'
                    : ok
                        ? 'On-device engine ready (${a?.engine ?? "?"})'
                        : 'Unavailable: ${a?.reason ?? "unknown"}',
                style: const TextStyle(color: JcTheme.text),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh_rounded, color: JcTheme.muted),
              onPressed: _refresh,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _tierRows() {
    Widget tile(LocalAiTier t, String title, String sub) {
      final selected = _s.tier == t;
      return ListTile(
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? JcTheme.cyan : JcTheme.muted,
        ),
        title: Text(title, style: const TextStyle(color: JcTheme.text)),
        subtitle: Text(sub, style: const TextStyle(color: JcTheme.muted, fontSize: 12)),
        onTap: () {
          setState(() => _s.tier = t);
          _save();
        },
      );
    }
    return [
      tile(LocalAiTier.off, 'Off', 'Everything runs on the server.'),
      tile(LocalAiTier.routerCommands, 'Router + instant commands',
          'Answer trivial turns + fire device commands locally; escalate the rest.'),
      tile(LocalAiTier.fullLocalFirst, 'Full local-first',
          'Also attempt local tool calls; escalate only when needed.'),
    ];
  }

  List<Widget> _modelRows() {
    if (_models.isEmpty) {
      return [
        const ListTile(
          title: Text('No local models', style: TextStyle(color: JcTheme.text)),
          subtitle: Text('Apple Foundation Models needs iOS 26 + Apple Intelligence.',
              style: TextStyle(color: JcTheme.muted, fontSize: 12)),
        ),
      ];
    }
    return _models.map((m) {
      final selected = _s.activeLocalModelId == m.id;
      final dl = _downloading[m.id];
      return ListTile(
        leading: Icon(
          m.engine == 'apple-fm' ? Icons.apple : Icons.memory_rounded,
          color: selected ? JcTheme.cyan : JcTheme.muted,
        ),
        title: Text(m.label, style: const TextStyle(color: JcTheme.text)),
        subtitle: Text(
          dl != null
              ? 'Downloading ${(dl * 100).round()}%'
              : m.installed
                  ? (m.ramHintMb != null ? '~${m.ramHintMb} MB RAM' : 'Installed')
                  : 'Not downloaded${m.sizeBytes != null ? " · ${(m.sizeBytes! / 1e6).round()} MB" : ""}',
          style: const TextStyle(color: JcTheme.muted, fontSize: 12),
        ),
        trailing: _modelTrailing(m, selected, dl),
        onTap: m.installed
            ? () {
                setState(() => _s.activeLocalModelId = m.id);
                _save();
              }
            : null,
      );
    }).toList();
  }

  Widget _modelTrailing(LocalModelInfo m, bool selected, double? dl) {
    if (dl != null) {
      return const SizedBox(
          width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (!m.installed) {
      return IconButton(
        icon: const Icon(Icons.download_rounded, color: JcTheme.cyan),
        onPressed: () => _download(m.id),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (selected) const Icon(Icons.check_rounded, color: JcTheme.cyan),
      if (m.engine != 'apple-fm')
        IconButton(
          icon: const Icon(Icons.delete_outline_rounded, color: JcTheme.muted),
          onPressed: () async {
            await _ai.deleteModel(m.id);
            _refresh();
          },
        ),
    ]);
  }

  void _download(String id) {
    setState(() => _downloading[id] = 0);
    _ai.downloadModel(id).listen(
      (p) => setState(() => _downloading[id] = p),
      onError: (_) => setState(() => _downloading.remove(id)),
      onDone: () {
        setState(() => _downloading.remove(id));
        _refresh();
      },
    );
  }

  List<Widget> _advancedRows() {
    return [
      ListTile(
        title: const Text('Escalation deadline', style: TextStyle(color: JcTheme.text)),
        subtitle: Text('${_s.deadlineMs} ms — local attempt is dropped past this',
            style: const TextStyle(color: JcTheme.muted, fontSize: 12)),
      ),
      Slider(
        value: _s.deadlineMs.toDouble().clamp(200, 2000),
        min: 200,
        max: 2000,
        divisions: 18,
        activeColor: JcTheme.cyan,
        label: '${_s.deadlineMs} ms',
        onChanged: (v) => setState(() => _s.deadlineMs = v.round()),
        onChangeEnd: (_) => _save(),
      ),
      _switchTile('Confirm outward/destructive actions', _s.confirmLocalActions, (v) {
        setState(() => _s.confirmLocalActions = v);
        _save();
      }),
      _switchTile('Device commands short-circuit', _s.commandShortCircuit, (v) {
        setState(() => _s.commandShortCircuit = v);
        _save();
      }),
      _switchTile('Show "on-device" badge', _s.showBadge, (v) {
        setState(() => _s.showBadge = v);
        _save();
      }),
    ];
  }

  Widget _switchTile(String title, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeThumbColor: JcTheme.cyan,
      title: Text(title, style: const TextStyle(color: JcTheme.text)),
    );
  }
}

/// A tiny on-device generate tester — types a prompt, streams the local model's
/// raw output (bypasses the router; pure engine check).
class _DebugGenerate extends StatefulWidget {
  const _DebugGenerate();

  @override
  State<_DebugGenerate> createState() => _DebugGenerateState();
}

class _DebugGenerateState extends State<_DebugGenerate> {
  final _ctrl = TextEditingController();
  String _out = '';
  StreamSubscription<String>? _sub;
  bool _running = false;

  @override
  void dispose() {
    _sub?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _run() {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _running) return;
    setState(() {
      _out = '';
      _running = true;
    });
    final req = LocalRequest(
      userText: text,
      surface: VoiceSurface.chat,
      toolCatalogJson: '[]',
      tier: LocalAiTier.fullLocalFirst,
    );
    _sub = OnDeviceAi.instance.generate(req).listen(
      (t) => setState(() => _out += t),
      onError: (e) => setState(() {
        _out += '\n[error: $e]';
        _running = false;
      }),
      onDone: () => setState(() => _running = false),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _ctrl,
            style: const TextStyle(color: JcTheme.text),
            decoration: const InputDecoration(
              hintText: 'Prompt the local model…',
              hintStyle: TextStyle(color: JcTheme.muted),
              border: InputBorder.none,
            ),
            onSubmitted: (_) => _run(),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: GlassButton(
              label: _running ? 'Running…' : 'Generate',
              onPressed: _running ? null : _run,
            ),
          ),
          if (_out.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_out, style: const TextStyle(color: JcTheme.muted, fontSize: 13)),
          ],
        ],
      ),
    );
  }
}
