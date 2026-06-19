import 'package:flutter/material.dart';

import '../api/island_designs.dart';
import '../island/island_models.dart';
import '../main.dart' as app;
import '../theme.dart';
import '../widgets/glass.dart';

/// Settings tab for Dynamic Island designs (iOS only).
///
/// A single radio group picks what shows on the Dynamic Island: **Auto** (rules
/// decide), or a specific design pinned — including the built-in Voice + Coding
/// islands. Below, a management list toggles each entry's inclusion in Auto and
/// deletes custom designs. Designs themselves are authored by Jarvis via the
/// dynamic-island skill, not here.
class IslandDesignsPage extends StatefulWidget {
  const IslandDesignsPage({super.key});

  @override
  State<IslandDesignsPage> createState() => _IslandDesignsPageState();
}

class _IslandDesignsPageState extends State<IslandDesignsPage> {
  static const _autoKey = '__auto__';

  late final IslandApi _api = IslandApi(app.api);
  IslandCatalog _catalog = IslandCatalog.empty;
  bool _loading = true;
  String? _error;
  bool _busy = false;

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
      final cat = await _api.fetchCatalog();
      if (!mounted) return;
      setState(() {
        _catalog = cat;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load designs. Check the server connection.';
      });
    }
  }

  String get _selectedKey =>
      _catalog.selection.isAuto ? _autoKey : (_catalog.selection.pinnedId ?? _autoKey);

  Future<void> _guard(Future<void> Function() op) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await op();
      await _load();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That didn’t go through. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _select(String key) => _guard(() => key == _autoKey
      ? _api.setSelection('auto')
      : _api.setSelection('pinned', pinnedId: key));

  Future<void> _setEnabled(String id, bool v) =>
      _guard(() => _api.setRules(id, enabled: v));

  Future<void> _delete(IslandCatalogEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete “${e.name}”?'),
        content: const Text(
            'This removes the design. Jarvis can recreate it later via the '
            'dynamic-island skill.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) await _guard(() => _api.deleteDesign(e.id));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(context, title: 'Dynamic Island', back: true),
      body: AppBackground(
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _buildBody(),
                ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    final entries = _catalog.entries;
    final custom = entries.where((e) => !e.builtin).toList(growable: false);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        const _Intro(),
        const SizedBox(height: 22),
        if (_error != null) ...[
          _ErrorCard(_error!),
          const SizedBox(height: 18),
        ],

        // ── Selection (the radio group) ──
        glassSectionLabel('Show on Dynamic Island'),
        GlassGroup(children: [
          _RadioRow(
            value: _autoKey,
            groupValue: _selectedKey,
            icon: Icons.auto_mode_rounded,
            title: 'Auto',
            subtitle: 'Let rules pick the right island at the right time.',
            onChanged: _busy ? null : _select,
          ),
          for (var i = 0; i < entries.length; i++)
            _RadioRow(
              value: entries[i].id,
              groupValue: _selectedKey,
              icon: _iconFor(entries[i]),
              title: entries[i].name,
              subtitle: _entrySubtitle(entries[i]),
              onChanged: _busy ? null : _select,
              last: i == entries.length - 1,
            ),
        ]),
        const SizedBox(height: 26),

        // ── Manage (enable in Auto pool + delete) ──
        glassSectionLabel('In the Auto rotation'),
        GlassGroup(
          children: [
            for (var i = 0; i < entries.length; i++)
              _ManageRow(
                entry: entries[i],
                busy: _busy,
                onEnabled: (v) => _setEnabled(entries[i].id, v),
                onDelete: entries[i].builtin ? null : () => _delete(entries[i]),
                last: i == entries.length - 1,
              ),
          ],
        ),

        if (custom.isEmpty) ...[
          const SizedBox(height: 18),
          const _EmptyHint(),
        ],
      ],
    );
  }

  String _entrySubtitle(IslandCatalogEntry e) {
    final bits = <String>[];
    if (e.builtin) bits.add('Built-in');
    if (!e.enabled) bits.add('Off in Auto');
    bits.add('Priority ${e.priority}');
    return bits.join(' · ');
  }

  IconData _iconFor(IslandCatalogEntry e) {
    if (e.isVoice) return Icons.graphic_eq_rounded;
    if (e.isCoding) return Icons.code_rounded;
    return Icons.dashboard_customize_rounded;
  }
}

class _RadioRow extends StatelessWidget {
  const _RadioRow({
    required this.value,
    required this.groupValue,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onChanged,
    this.last = false,
  });
  final String value, groupValue, title, subtitle;
  final IconData icon;
  final ValueChanged<String>? onChanged;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final selected = value == groupValue;
    return Column(
      children: [
        InkWell(
          onTap: onChanged == null ? null : () => onChanged!(value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: JcTheme.glassFill,
                    border: Border.all(color: JcTheme.glassBorder),
                  ),
                  child: Icon(icon, size: 20, color: JcTheme.text),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              color: JcTheme.text,
                              fontSize: 15,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: const TextStyle(
                              color: JcTheme.muted, fontSize: 12)),
                    ],
                  ),
                ),
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? JcTheme.primaryBlue : JcTheme.muted,
                ),
              ],
            ),
          ),
        ),
        if (!last)
          const Divider(height: 1, indent: 68, color: JcTheme.glassBorder),
      ],
    );
  }
}

class _ManageRow extends StatelessWidget {
  const _ManageRow({
    required this.entry,
    required this.busy,
    required this.onEnabled,
    required this.onDelete,
    this.last = false,
  });
  final IslandCatalogEntry entry;
  final bool busy;
  final ValueChanged<bool> onEnabled;
  final VoidCallback? onDelete;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(entry.name,
                    style: const TextStyle(
                        color: JcTheme.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
              if (onDelete != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded,
                      color: JcTheme.muted),
                  onPressed: busy ? null : onDelete,
                  tooltip: 'Delete',
                ),
              Switch(
                value: entry.enabled,
                onChanged: busy ? null : onEnabled,
                activeThumbColor: Colors.white,
                activeTrackColor: JcTheme.primaryBlue,
              ),
            ],
          ),
        ),
        if (!last)
          const Divider(height: 1, indent: 14, color: JcTheme.glassBorder),
      ],
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();
  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          'Pick which Dynamic Island shows — or let Auto choose by time and '
          'context. Jarvis creates custom designs for you; they appear here.',
          style: TextStyle(color: JcTheme.muted, fontSize: 13, height: 1.4),
        ),
      );
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: JcTheme.glassFill,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: JcTheme.glassBorder),
        ),
        child: const Text(
          'No custom designs yet. Ask Jarvis to make one — e.g. “make a Dynamic '
          'Island that shows my next meeting”.',
          style: TextStyle(color: JcTheme.muted, fontSize: 13, height: 1.4),
        ),
      );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.red.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
        ),
        child: Text(message,
            style: const TextStyle(color: JcTheme.text, fontSize: 13)),
      );
}
