import 'package:flutter/material.dart';

import '../../api/profiles.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/detail_sheet.dart';
import '../../widgets/form_sheet.dart';
import '../../widgets/glass.dart';
import '../../widgets/status_pill.dart';

/// Native "Profiles" screen at parity with the web Profiles panel: list every
/// profile, switch the active one, create new ones, and delete (non-default,
/// non-active) ones. The server has no profile-edit endpoint, so there is no
/// Edit action here by design.
class ProfilesPage extends StatefulWidget {
  const ProfilesPage({super.key});

  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  late final ProfilesApi _api = ProfilesApi(app.api);
  final AsyncViewController _ctrl = AsyncViewController();

  Future<Map<String, dynamic>> _load() => _api.list();

  // ── helpers ──────────────────────────────────────────────────────────────

  String _model(Map<String, dynamic> p) =>
      (p['model'] ?? p['default_model'] ?? '').toString();

  String _provider(Map<String, dynamic> p) =>
      (p['provider'] ?? p['model_provider'] ?? '').toString();

  bool _isDefault(Map<String, dynamic> p) {
    if (p['is_default'] == true) return true;
    return (p['name'] ?? '').toString() == 'default';
  }

  bool _gatewayRunning(Map<String, dynamic> p) => p['gateway_running'] == true;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── mutations ───────────────────────────────────────────────────────────

  Future<void> _switchTo(String name) async {
    try {
      final resp = await _api.switchTo(name);
      // The server reports the new active profile via `active`. If it does NOT
      // confirm the switch, surface that honestly rather than faking success.
      final confirmed = activeName(resp) == name;
      await _ctrl.refresh();
      if (!mounted) return;
      if (confirmed) {
        _toast('Switched to "$name".');
      } else {
        _toast('Switch to "$name" may not have applied.');
      }
    } catch (e) {
      _toast('$e');
    }
  }

  Future<void> _delete(String name) async {
    try {
      await _api.delete(name);
      await _ctrl.refresh();
      if (mounted) _toast('Deleted "$name".');
    } catch (e) {
      _toast('$e');
    }
  }

  Future<bool> _confirmDelete(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JcTheme.surface,
        title: const Text('Delete profile?',
            style: TextStyle(color: JcTheme.text)),
        content: Text(
          'This permanently deletes the "$name" profile and its data. '
          'This cannot be undone.',
          style: const TextStyle(color: JcTheme.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: JcTheme.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // ── detail sheet ─────────────────────────────────────────────────────────

  void _openDetail(Map<String, dynamic> p, String active) {
    final name = (p['name'] ?? '').toString();
    final isActive = name == active;
    final isDefault = _isDefault(p);
    final canDelete = !isDefault && !isActive;
    final running = _gatewayRunning(p);

    showDetailSheet<void>(
      context: context,
      title: name.isEmpty ? 'Profile' : name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (isActive)
                const StatusPill('ACTIVE', color: JcTheme.success),
              if (isDefault)
                const StatusPill('DEFAULT', color: JcTheme.blue),
              StatusPill(
                running ? 'GATEWAY RUNNING' : 'GATEWAY IDLE',
                color: running ? JcTheme.primaryBlue : JcTheme.muted,
                live: running,
              ),
            ],
          ),
          const SizedBox(height: 14),
          DetailRow('Name', name),
          DetailRow('Model', _model(p)),
          DetailRow('Provider', _provider(p)),
          DetailRow('Path', (p['path'] ?? '').toString()),
        ],
      ),
      actions: [
        if (!isActive)
          GlassButton(
            label: 'Switch to this profile',
            icon: Icons.swap_horiz_rounded,
            onPressed: () {
              Navigator.of(context).pop();
              _switchTo(name);
            },
          ),
        if (canDelete)
          GlassButton(
            label: 'Delete',
            ghost: true,
            icon: Icons.delete_outline,
            onPressed: () async {
              final yes = await _confirmDelete(name);
              if (!yes || !mounted) return;
              Navigator.of(context).pop();
              await _delete(name);
            },
          ),
      ],
    );
  }

  // ── create form ──────────────────────────────────────────────────────────

  Future<void> _create(List<Map<String, dynamic>> existing) async {
    final nameCtrl = TextEditingController();
    final baseUrlCtrl = TextEditingController();
    final apiKeyCtrl = TextEditingController();
    final modelCtrl = TextEditingController();
    final providerCtrl = TextEditingController();
    final names = existing
        .map((p) => (p['name'] ?? '').toString())
        .where((n) => n.isNotEmpty)
        .toList();
    String? cloneFrom; // null = none

    await showFormSheet(
      context: context,
      title: 'New profile',
      saveLabel: 'Create',
      fields: [
        FormTextField(
          label: 'Name (required)',
          controller: nameCtrl,
          hint: 'lowercase, digits, - or _',
        ),
        StatefulBuilder(
          builder: (ctx, setLocal) => FormDropdown<String?>(
            label: 'Clone from (optional)',
            value: cloneFrom,
            items: [
              const DropdownMenuItem<String?>(
                  value: null, child: Text('None')),
              ...names.map((n) =>
                  DropdownMenuItem<String?>(value: n, child: Text(n))),
            ],
            onChanged: (v) => setLocal(() => cloneFrom = v),
          ),
        ),
        FormTextField(
            label: 'Base URL', controller: baseUrlCtrl, hint: 'https://...'),
        FormTextField(label: 'API key', controller: apiKeyCtrl),
        FormTextField(label: 'Default model', controller: modelCtrl),
        FormTextField(label: 'Model provider', controller: providerCtrl),
      ],
      onSave: () async {
        final name = nameCtrl.text.trim();
        if (name.isEmpty) {
          _toast('Name is required.');
          return false;
        }
        final body = <String, dynamic>{'name': name};
        if (cloneFrom != null && cloneFrom!.isNotEmpty) {
          body['clone_from'] = cloneFrom;
          body['clone_config'] = true;
        }
        void put(String key, String value) {
          if (value.trim().isNotEmpty) body[key] = value.trim();
        }

        put('base_url', baseUrlCtrl.text);
        put('api_key', apiKeyCtrl.text);
        put('default_model', modelCtrl.text);
        put('model_provider', providerCtrl.text);

        try {
          await _api.create(body);
          await _ctrl.refresh();
          return true;
        } catch (e) {
          _toast('$e');
          return false;
        }
      },
    );

    nameCtrl.dispose();
    baseUrlCtrl.dispose();
    apiKeyCtrl.dispose();
    modelCtrl.dispose();
    providerCtrl.dispose();
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        context,
        title: 'Profiles',
        trailing: GlassIconButton(
          icon: Icons.add,
          onTap: () async {
            final data = await _api.list().catchError((_) => <String, dynamic>{});
            if (!mounted) return;
            _create(parseProfiles(data));
          },
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: AsyncView<Map<String, dynamic>>(
            controller: _ctrl,
            loader: _load,
            isEmpty: (d) => parseProfiles(d).isEmpty,
            emptyText: 'No profiles yet.',
            builder: (context, data, refresh) {
              final profiles = parseProfiles(data);
              final active = activeName(data);
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: profiles.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (_, i) {
                  final p = profiles[i];
                  return _ProfileCard(
                    profile: p,
                    isActive: (p['name'] ?? '').toString() == active,
                    isDefault: _isDefault(p),
                    running: _gatewayRunning(p),
                    model: _model(p),
                    provider: _provider(p),
                    onTap: () => _openDetail(p, active),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({
    required this.profile,
    required this.isActive,
    required this.isDefault,
    required this.running,
    required this.model,
    required this.provider,
    required this.onTap,
  });

  final Map<String, dynamic> profile;
  final bool isActive;
  final bool isDefault;
  final bool running;
  final String model;
  final String provider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = (profile['name'] ?? '').toString();
    final sub = [model, provider].where((s) => s.isNotEmpty).join(' · ');
    final dotColor = running ? JcTheme.primaryBlue : JcTheme.muted;
    return GlassCard(
      blur: false,
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
      borderColor: isActive
          ? JcTheme.success.withValues(alpha: 0.40)
          : JcTheme.glassBorder,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Leading gateway-state rail.
          Padding(
            padding: const EdgeInsets.only(top: 4, right: 12),
            child: running
                ? PulsingDot(color: dotColor, size: 9)
                : Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle, color: dotColor),
                  ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name.isEmpty ? '(unnamed)' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: JcTheme.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (isActive) ...[
                      const SizedBox(width: 8),
                      const StatusPill('ACTIVE',
                          color: JcTheme.success, dense: true),
                    ],
                    if (isDefault) ...[
                      const SizedBox(width: 6),
                      const StatusPill('DEFAULT',
                          color: JcTheme.blue, dense: true),
                    ],
                  ],
                ),
                if (sub.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.memory_rounded,
                          size: 13, color: JcTheme.muted),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: JcTheme.muted, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.chevron_right_rounded,
                color: JcTheme.muted.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }
}
