import 'package:flutter/material.dart';

import '../main.dart' as app;
import '../services/credentials.dart';
import '../skills/registry.dart';
import '../theme.dart';

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
      backgroundColor: JcTheme.bg,
      appBar: AppBar(title: const Text('Skills')),
      body: ListView.builder(
        itemCount: all.length,
        itemBuilder: (_, i) {
          final e = all[i];
          final enabled = !_disabled.contains(e.name);
          return SwitchListTile(
            value: enabled,
            onChanged: (v) => _toggle(e.name, v),
            title: Text(e.name,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            subtitle: Text(
              e.description,
              style: const TextStyle(color: JcTheme.muted, fontSize: 12),
            ),
            secondary: e.requiresOptIn
                ? const Icon(Icons.shield_outlined, color: JcTheme.accent, size: 18)
                : null,
          );
        },
      ),
    );
  }
}
