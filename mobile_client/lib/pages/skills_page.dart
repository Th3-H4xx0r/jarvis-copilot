import 'package:flutter/material.dart';

import '../main.dart' as app;
import '../services/credentials.dart';
import '../skills/registry.dart';
import '../theme.dart';
import '../widgets/glass.dart';

/// Per-device skill ACL: lets the user toggle which skills the server
/// is allowed to invoke on *this* device. Toggled-off skills aren't
/// included in the bridge's register manifest, so the server doesn't
/// even see them as available.
class SkillsPage extends StatefulWidget {
  const SkillsPage({super.key});

  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  late Set<String> _disabled;

  @override
  void initState() {
    super.initState();
    _disabled = {...Credentials.instance.skillsDisabled};
  }

  Future<void> _toggle(String name, bool enabled) async {
    setState(() {
      if (enabled) {
        _disabled.remove(name);
      } else {
        _disabled.add(name);
      }
    });
    await Credentials.instance.saveSkillsDisabled(_disabled);
    // Bounce the WS so the server sees the new manifest.
    await app.ws.stop();
    await app.ws.start();
  }

  @override
  Widget build(BuildContext context) {
    final all = SkillRegistry.instance.all();
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(context, title: 'Skills', back: false),
      body: AppBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              GlassGroup(
                children: List.generate(all.length, (i) {
                  final e = all[i];
                  final enabled = !_disabled.contains(e.name);
                  final isLast = i == all.length - 1;
                  return _SkillRow(
                    entry: e,
                    enabled: enabled,
                    last: isLast,
                    onToggle: (v) => _toggle(e.name, v),
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SkillRow extends StatelessWidget {
  const _SkillRow({
    required this.entry,
    required this.enabled,
    required this.last,
    required this.onToggle,
  });

  final SkillEntry entry;
  final bool enabled;
  final bool last;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: _circleIcon(
            entry.requiresOptIn
                ? Icons.shield_outlined
                : Icons.code_rounded,
            color: entry.requiresOptIn ? JcTheme.accent : null,
          ),
          title: Text(
            entry.name,
            style: const TextStyle(
              color: JcTheme.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
          subtitle: Text(
            entry.description,
            style: const TextStyle(color: JcTheme.muted, fontSize: 12),
          ),
          trailing: Switch(
            value: enabled,
            onChanged: onToggle,
            activeThumbColor: JcTheme.primaryBlue,
          ),
        ),
        if (!last)
          const Divider(height: 1, indent: 68, color: JcTheme.glassBorder),
      ],
    );
  }

  static Widget _circleIcon(IconData icon, {Color? color}) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: (color ?? JcTheme.text).withValues(alpha: 0.10),
          border: Border.all(color: JcTheme.glassBorder),
        ),
        child: Icon(icon, size: 20, color: color ?? JcTheme.text),
      );
}
