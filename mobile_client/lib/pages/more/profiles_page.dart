import 'package:flutter/material.dart';

import '../../api/profiles.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/detail_sheet.dart';
import '../../widgets/form_sheet.dart';
import '../../widgets/glass.dart';

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

    showDetailSheet<void>(
      context: context,
      title: name.isEmpty ? 'Profile' : name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                  final name = (p['name'] ?? '').toString();
                  final isActive = name == active;
                  final model = _model(p);
                  final provider = _provider(p);
                  final sub = [model, provider]
                      .where((s) => s.isNotEmpty)
                      .join(' · ');
                  return GlassCard(
                    onTap: () => _openDetail(p, active),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name.isEmpty ? '(unnamed)' : name,
                                style: const TextStyle(
                                  color: JcTheme.text,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              if (sub.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  sub,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: JcTheme.muted, fontSize: 13),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (isActive) ...[
                          const SizedBox(width: 10),
                          _activeBadge(),
                        ],
                        const SizedBox(width: 6),
                        Icon(Icons.chevron_right_rounded,
                            color: JcTheme.muted.withValues(alpha: 0.7)),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _activeBadge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: JcTheme.success.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Text(
          'ACTIVE',
          style: TextStyle(
            color: JcTheme.success,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      );
}
