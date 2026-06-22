import 'package:flutter/material.dart';

import '../../api/code_memory.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/detail_sheet.dart';
import '../../widgets/form_sheet.dart';
import '../../widgets/glass.dart';
import '../../widgets/status_pill.dart';

/// Native "Code memory" screen at parity with the web Code-memory panel: the
/// shared per-project store of code-knowledge + session handoffs that Claude /
/// the JarvisCopilot agent write while working in a repo.
///
/// Top: a stats header (total projects / knowledge / handoffs). Below: a
/// searchable project list. Tapping a project opens a tabbed detail screen
/// (Knowledge / Handoffs) where each entry can be viewed, edited, or deleted.
class CodeMemoryPage extends StatefulWidget {
  const CodeMemoryPage({super.key});

  @override
  State<CodeMemoryPage> createState() => _CodeMemoryPageState();
}

class _CodeMemoryPageState extends State<CodeMemoryPage> {
  late final CodeMemoryApi _api = CodeMemoryApi(app.api);
  final AsyncViewController _ctrl = AsyncViewController();
  final TextEditingController _searchCtrl = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Load stats + projects together. Both are independent GETs; if stats fails
  /// we still want the project list, so derive stats from projects as a
  /// fallback.
  Future<_CmOverview> _load() async {
    Map<String, dynamic> stats = const {};
    try {
      stats = await _api.stats();
    } catch (_) {
      stats = const {};
    }
    final projects = await _api.projects();
    return _CmOverview(stats: stats, projects: projects);
  }

  int _asInt(dynamic v) => v is int ? v : (v is num ? v.toInt() : 0);

  int _projKnowledge(Map<String, dynamic> p) =>
      _asInt(p['knowledge_count'] ?? p['knowledge']);

  int _projHandoffs(Map<String, dynamic> p) =>
      _asInt(p['sessions_count'] ?? p['sessions']);

  // ── stats header ──────────────────────────────────────────────────────────

  Widget _statsHeader(_CmOverview o) {
    // Prefer the server's flat stats; fall back to deriving from the projects
    // list so the header is never blank when /stats is unavailable.
    final s = o.stats;
    final totalProjects = s['projects'] != null
        ? _asInt(s['projects'])
        : o.projects.length;
    final totalKnowledge = s['knowledge'] != null
        ? _asInt(s['knowledge'])
        : o.projects.fold<int>(0, (a, p) => a + _projKnowledge(p));
    final totalHandoffs = s['sessions'] != null
        ? _asInt(s['sessions'])
        : o.projects.fold<int>(0, (a, p) => a + _projHandoffs(p));
    final lastActivity = s['last_activity'];
    final rel = lastActivity == null ? '' : relativeTime(lastActivity);

    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _stat(Icons.folder_outlined, JcTheme.blue, 'Projects',
                  '$totalProjects'),
              _statDivider(),
              _stat(Icons.lightbulb_outline, JcTheme.cyan, 'Knowledge',
                  '$totalKnowledge'),
              _statDivider(),
              _stat(Icons.history_edu_outlined, JcTheme.accent, 'Handoffs',
                  '$totalHandoffs'),
            ],
          ),
          if (rel.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 14, 8, 0),
              child: Divider(height: 1, color: JcTheme.glassBorder),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.schedule, size: 13, color: JcTheme.muted),
                  const SizedBox(width: 6),
                  Text(
                    'Last active $rel',
                    style: const TextStyle(color: JcTheme.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statDivider() => Container(
        width: 1,
        height: 40,
        color: JcTheme.glassBorder,
      );

  Widget _stat(IconData icon, Color color, String label, String num) =>
      Expanded(
        child: Column(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(height: 6),
            Text(num,
                style: const TextStyle(
                    color: JcTheme.text,
                    fontSize: 22,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(color: JcTheme.muted, fontSize: 12)),
          ],
        ),
      );

  // ── project row ──────────────────────────────────────────────────────────

  Widget _projectRow(Map<String, dynamic> p) {
    final slug = (p['slug'] ?? '').toString();
    final name = (p['name'] ?? '').toString();
    final title = name.isNotEmpty ? name : slug;
    final know = _projKnowledge(p);
    final hand = _projHandoffs(p);
    final lastSeen = p['last_seen'];
    final rel = relativeTime(lastSeen);

    return GlassCard(
      blur: false,
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => _CmProjectPage(
          api: _api,
          slug: slug,
          name: title,
          onChanged: () => _ctrl.refresh(),
        ),
      )),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Leading repo icon.
          Container(
            width: 40,
            height: 40,
            margin: const EdgeInsets.only(right: 12, top: 2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: JcTheme.blue.withValues(alpha: 0.12),
              border: Border.all(color: JcTheme.glassBorder),
            ),
            child: const Icon(Icons.account_tree_outlined,
                size: 19, color: JcTheme.blue),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.isEmpty ? '(unnamed)' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: JcTheme.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w700),
                ),
                if (slug.isNotEmpty && slug != title) ...[
                  const SizedBox(height: 2),
                  Text(slug,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: JcTheme.muted, fontSize: 12)),
                ],
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusPill('$know knowledge',
                        color: JcTheme.cyan, dense: true),
                    StatusPill('$hand handoffs',
                        color: JcTheme.accent, dense: true),
                    if (rel.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.schedule,
                              size: 12, color: JcTheme.muted),
                          const SizedBox(width: 4),
                          Text(rel,
                              style: const TextStyle(
                                  color: JcTheme.muted, fontSize: 12)),
                        ],
                      ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 10, left: 4),
            child: Icon(Icons.chevron_right_rounded,
                color: JcTheme.muted.withValues(alpha: 0.7)),
          ),
        ],
      ),
    );
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(context, title: 'Code memory'),
      body: AppBackground(
        child: SafeArea(
          child: AsyncView<_CmOverview>(
            controller: _ctrl,
            loader: _load,
            isEmpty: (o) => o.projects.isEmpty,
            emptyText: 'No code memory yet.\n\nKnowledge and session handoffs '
                'appear here as Claude or the JarvisCopilot agent stores them '
                'for a repo.',
            builder: (context, o, refresh) {
              final f = _filter.trim().toLowerCase();
              final shown = f.isEmpty
                  ? o.projects
                  : o.projects.where((p) {
                      final name = (p['name'] ?? '').toString().toLowerCase();
                      final slug = (p['slug'] ?? '').toString().toLowerCase();
                      return name.contains(f) || slug.contains(f);
                    }).toList();
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _statsHeader(o),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _filter = v),
                    style: const TextStyle(color: JcTheme.text),
                    decoration: InputDecoration(
                      hintText: 'Search projects…',
                      prefixIcon:
                          const Icon(Icons.search, color: JcTheme.muted),
                      isDense: true,
                      suffixIcon: _filter.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close,
                                  color: JcTheme.muted, size: 18),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _filter = '');
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (shown.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 48),
                      child: _EmptyState(
                        icon: Icons.search_off_rounded,
                        message: 'No matching projects.',
                      ),
                    )
                  else
                    for (final p in shown) ...[
                      _projectRow(p),
                      const SizedBox(height: 12),
                    ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Combined stats + projects payload for the overview screen.
class _CmOverview {
  _CmOverview({required this.stats, required this.projects});
  final Map<String, dynamic> stats;
  final List<Map<String, dynamic>> projects;
}

// =============================================================================
// Per-project detail screen — Knowledge / Handoffs tabs.
// =============================================================================
class _CmProjectPage extends StatelessWidget {
  const _CmProjectPage({
    required this.api,
    required this.slug,
    required this.name,
    required this.onChanged,
  });

  final CodeMemoryApi api;
  final String slug;
  final String name;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: glassAppBar(context, title: name.isEmpty ? slug : name),
        body: AppBackground(
          child: SafeArea(
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  decoration: BoxDecoration(
                    color: JcTheme.glassFill,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: JcTheme.glassBorder),
                  ),
                  child: const TabBar(
                    indicator: BoxDecoration(
                      color: JcTheme.accent,
                      borderRadius: BorderRadius.all(Radius.circular(11)),
                    ),
                    indicatorSize: TabBarIndicatorSize.tab,
                    indicatorPadding: EdgeInsets.all(4),
                    dividerColor: Colors.transparent,
                    labelColor: Colors.white,
                    unselectedLabelColor: JcTheme.muted,
                    labelStyle:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                    unselectedLabelStyle:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    tabs: [
                      Tab(text: 'Knowledge'),
                      Tab(text: 'Handoffs'),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _CmEntriesTab(
                        api: api,
                        slug: slug,
                        kind: 'knowledge',
                        onChanged: onChanged,
                      ),
                      _CmEntriesTab(
                        api: api,
                        slug: slug,
                        kind: 'sessions',
                        onChanged: onChanged,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One tab: a searchable list of entries of a single [kind]. Empty query lists
/// all entries (full bodies); a non-empty query hits the server search and
/// hydrates the compact rows into full bodies on demand.
class _CmEntriesTab extends StatefulWidget {
  const _CmEntriesTab({
    required this.api,
    required this.slug,
    required this.kind,
    required this.onChanged,
  });

  final CodeMemoryApi api;
  final String slug;
  final String kind; // knowledge | sessions
  final VoidCallback onChanged;

  @override
  State<_CmEntriesTab> createState() => _CmEntriesTabState();
}

class _CmEntriesTabState extends State<_CmEntriesTab> {
  final AsyncViewController _ctrl = AsyncViewController();
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  bool get _isSessions => widget.kind == 'sessions';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final q = _query.trim();
    if (q.isEmpty) {
      return widget.api.entries(widget.slug, kind: widget.kind);
    }
    // Search returns compact rows ({id, ..., first_line}); hydrate the bodies
    // so the list/detail can show full content. Fall back to the compact rows
    // if hydration fails for any reason.
    final hits = await widget.api.search(widget.slug, q, kind: widget.kind);
    if (hits.isEmpty) return const [];
    final ids = hits
        .map((e) => (e['id'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toList();
    try {
      final full = await widget.api.byIds(ids);
      if (full.isNotEmpty) return full;
    } catch (_) {
      // fall through to compact rows
    }
    return hits;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _entryTitle(Map<String, dynamic> e) {
    final content = (e['content'] ?? e['first_line'] ?? '').toString().trim();
    final firstLine = content.isEmpty
        ? ''
        : content.split('\n').first.trim();
    if (firstLine.isNotEmpty) return firstLine;
    return (e['entry_type'] ?? (_isSessions ? 'handoff' : 'note')).toString();
  }

  // ── mutations ───────────────────────────────────────────────────────────

  Future<void> _edit(Map<String, dynamic> e) async {
    final id = (e['id'] ?? '').toString();
    if (id.isEmpty) {
      _toast('This entry has no id; cannot edit.');
      return;
    }
    final ctrl =
        TextEditingController(text: (e['content'] ?? '').toString());
    await showFormSheet(
      context: context,
      title: 'Edit entry',
      saveLabel: 'Save',
      fields: [
        FormTextField(
          label: 'Content',
          controller: ctrl,
          maxLines: 12,
        ),
      ],
      onSave: () async {
        final text = ctrl.text;
        if (text.trim().isEmpty) {
          _toast('Content cannot be empty.');
          return false;
        }
        try {
          await widget.api.update(id, text);
          await _ctrl.refresh();
          widget.onChanged();
          return true;
        } catch (err) {
          _toast('$err');
          return false;
        }
      },
    );
    ctrl.dispose();
  }

  Future<bool> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JcTheme.surface,
        title: const Text('Delete entry?',
            style: TextStyle(color: JcTheme.text)),
        content: const Text(
          'This permanently removes this entry. This cannot be undone.',
          style: TextStyle(color: JcTheme.muted),
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

  Future<void> _delete(Map<String, dynamic> e) async {
    final id = (e['id'] ?? '').toString();
    try {
      if (id.isNotEmpty) {
        await widget.api.deleteEntry(id: id);
      } else {
        // Fall back to (slug, kind, ts) when no precise id is present.
        await widget.api.deleteEntry(
          slug: (e['slug'] ?? widget.slug).toString(),
          kind: (e['kind'] ?? widget.kind).toString(),
          ts: e['ts'],
        );
      }
      await _ctrl.refresh();
      widget.onChanged();
      _toast('Entry deleted.');
    } catch (err) {
      _toast('$err');
    }
  }

  // ── detail sheet ─────────────────────────────────────────────────────────

  void _open(Map<String, dynamic> e) {
    final type = (e['entry_type'] ?? (_isSessions ? 'handoff' : 'note'))
        .toString();
    final ts = relativeTime(e['ts']);
    final content = (e['content'] ?? e['first_line'] ?? '').toString();

    showDetailSheet<void>(
      context: context,
      title: type,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusPill(
                type,
                color: _isSessions ? JcTheme.accent : JcTheme.cyan,
                dense: true,
              ),
              if (ts.isNotEmpty) ...[
                const SizedBox(width: 8),
                const Icon(Icons.schedule, size: 13, color: JcTheme.muted),
                const SizedBox(width: 4),
                Text(ts,
                    style: const TextStyle(color: JcTheme.muted, fontSize: 12)),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: JcTheme.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SelectableText(
              content.isEmpty ? '(empty)' : content,
              style: const TextStyle(
                  color: JcTheme.text, fontSize: 14.5, height: 1.45),
            ),
          ),
        ],
      ),
      actions: [
        GlassButton(
          label: 'Edit',
          ghost: true,
          icon: Icons.edit_outlined,
          onPressed: () {
            Navigator.of(context).pop();
            _edit(e);
          },
        ),
        GlassButton(
          label: 'Delete',
          ghost: true,
          icon: Icons.delete_outline,
          onPressed: () async {
            final yes = await _confirmDelete();
            if (!yes || !mounted) return;
            Navigator.of(context).pop();
            await _delete(e);
          },
        ),
      ],
    );
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _searchCtrl,
            onSubmitted: (v) {
              setState(() => _query = v);
              _ctrl.refresh();
            },
            onChanged: (v) {
              // Re-run on clear so the full list returns without a submit.
              if (v.trim().isEmpty && _query.isNotEmpty) {
                setState(() => _query = '');
                _ctrl.refresh();
              }
            },
            style: const TextStyle(color: JcTheme.text),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText:
                  _isSessions ? 'Search handoffs…' : 'Search knowledge…',
              prefixIcon: const Icon(Icons.search, color: JcTheme.muted),
              isDense: true,
              suffixIcon: _searchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close,
                          color: JcTheme.muted, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        if (_query.isNotEmpty) {
                          setState(() => _query = '');
                          _ctrl.refresh();
                        }
                      },
                    ),
            ),
          ),
        ),
        Expanded(
          child: AsyncView<List<Map<String, dynamic>>>(
            controller: _ctrl,
            loader: _load,
            isEmpty: (l) => l.isEmpty,
            emptyText: _query.trim().isEmpty
                ? (_isSessions
                    ? 'No session handoffs yet.'
                    : 'No knowledge stored yet.')
                : 'No matches.',
            builder: (context, entries, refresh) {
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: entries.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) {
                  final e = entries[i];
                  final type =
                      (e['entry_type'] ?? (_isSessions ? 'handoff' : 'note'))
                          .toString();
                  final rel = relativeTime(e['ts']);
                  return GlassCard(
                    blur: false,
                    padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
                    onTap: () => _open(e),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1, right: 11),
                          child: Icon(
                            _isSessions
                                ? Icons.history_edu_outlined
                                : Icons.lightbulb_outline,
                            size: 18,
                            color: _isSessions ? JcTheme.accent : JcTheme.cyan,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _entryTitle(e),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: JcTheme.text,
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w600,
                                    height: 1.35),
                              ),
                              const SizedBox(height: 7),
                              Row(
                                children: [
                                  StatusPill(
                                    type,
                                    color: _isSessions
                                        ? JcTheme.accent
                                        : JcTheme.cyan,
                                    dense: true,
                                  ),
                                  const Spacer(),
                                  if (rel.isNotEmpty)
                                    Text(rel,
                                        style: const TextStyle(
                                            color: JcTheme.muted,
                                            fontSize: 12)),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// A simple icon + message empty state, centered.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 38, color: JcTheme.muted.withValues(alpha: 0.7)),
          const SizedBox(height: 12),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: JcTheme.muted, fontSize: 13)),
        ],
      ),
    );
  }
}

/// Format a timestamp as a short relative string ("just now", "5m ago",
/// "3d ago", or an absolute date for older). Accepts epoch SECONDS, epoch
/// MILLISECONDS, or an ISO-8601 string (the server emits ISO like
/// `2026-06-21T12:00:00Z`). Returns '' for null/unparseable input.
///
/// Pure — unit-tested. Uses [DateTime.now] for the delta.
String relativeTime(dynamic ts) {
  final dt = _parseTs(ts);
  if (dt == null) return '';
  final now = DateTime.now();
  final secs = now.difference(dt).inSeconds;
  // Future timestamps (clock skew) read as "just now".
  if (secs < 60) return 'just now';
  if (secs < 3600) return '${secs ~/ 60}m ago';
  if (secs < 86400) return '${secs ~/ 3600}h ago';
  if (secs < 604800) return '${secs ~/ 86400}d ago';
  // Older than a week → absolute date (YYYY-MM-DD), locale-independent.
  final local = dt.toLocal();
  final mm = local.month.toString().padLeft(2, '0');
  final dd = local.day.toString().padLeft(2, '0');
  return '${local.year}-$mm-$dd';
}

DateTime? _parseTs(dynamic ts) {
  if (ts == null) return null;
  if (ts is DateTime) return ts;
  if (ts is num) {
    // Heuristic: >= 1e12 ⇒ already in milliseconds; otherwise seconds.
    final ms = ts >= 1e12 ? ts.toInt() : (ts * 1000).toInt();
    return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
  final s = ts.toString().trim();
  if (s.isEmpty) return null;
  // Numeric string → epoch.
  final asNum = num.tryParse(s);
  if (asNum != null) return _parseTs(asNum);
  return DateTime.tryParse(s);
}
