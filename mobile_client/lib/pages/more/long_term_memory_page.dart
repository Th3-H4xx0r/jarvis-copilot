import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/jarvis_memory.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/glass.dart';
import '../../widgets/status_pill.dart';

/// Native "Long-term memory" screen — the jarvis_memory semantic store (the
/// same data the webui "Long-term memory" panel renders).
///
/// Shows: a stats header (total count) + namespace chips, a semantic search box
/// with a results list (each result deletable), and a "Reflections" (insights)
/// section with per-card Dismiss + a "Run reflection" button. When the store
/// isn't initialized the server fail-softs to `{available:false, error:…}`, and
/// we render a clear unavailable state (with the message) instead of crashing.
class LongTermMemoryPage extends StatefulWidget {
  const LongTermMemoryPage({super.key});

  @override
  State<LongTermMemoryPage> createState() => _LongTermMemoryPageState();
}

/// The whole-screen payload we load in one shot so the AsyncView can decide
/// availability vs. content from a single future.
class _MemoryData {
  const _MemoryData({
    required this.stats,
    required this.status,
    required this.reflections,
  });

  final Map<String, dynamic> stats;
  final Map<String, dynamic> status;
  final List<Map<String, dynamic>> reflections;

  /// The store is usable only if neither stats nor status reported a failure.
  bool get available =>
      stats['available'] != false && status['available'] != false;

  /// A human-readable reason the store is unavailable, if the backend gave one.
  String? get unavailableMessage {
    final e = stats['error'] ?? status['error'];
    return (e == null || '$e'.trim().isEmpty) ? null : '$e';
  }

  int get count => JarvisMemoryApi.asInt(stats['count']);

  List<Map<String, dynamic>> get namespaces =>
      JarvisMemoryApi.parseNamespaces(stats);
}

class _LongTermMemoryPageState extends State<LongTermMemoryPage> {
  late final JarvisMemoryApi _api = JarvisMemoryApi(app.api);

  // Loaded once for the header/namespaces/reflections.
  Future<_MemoryData>? _future;

  // Search is its own little async lifecycle so the header doesn't reload on
  // every keystroke.
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _debounce;
  int _searchReq = 0;
  bool _searching = false;
  List<Map<String, dynamic>> _results = const [];
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    _reload();
    // Populate the recent-entries list on open: the backend returns recent
    // entries for an empty query (mirrors the webui panel, which searches on
    // open). Safe when the store is unavailable — search just returns empty.
    _runSearch('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<_MemoryData> _loadAll() async {
    final stats = await _api.stats();
    final status = await _api.status();
    // Reflections can fail-soft independently; never let it sink the page.
    List<Map<String, dynamic>> refl = const [];
    try {
      refl = await _api.reflections();
    } catch (_) {
      refl = const [];
    }
    return _MemoryData(stats: stats, status: status, reflections: refl);
  }

  void _reload() {
    setState(() => _future = _loadAll());
  }

  Future<void> _refresh() async {
    final f = _loadAll();
    setState(() => _future = f);
    await f.catchError((_) => const _MemoryData(
          stats: {},
          status: {},
          reflections: [],
        ));
    // Re-run the current search against the fresh store too.
    await _runSearch(_searchCtrl.text);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── search ───────────────────────────────────────────────────────────────

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      _runSearch(value);
    });
  }

  Future<void> _runSearch(String query) async {
    final id = ++_searchReq;
    if (mounted) {
      setState(() {
        _searching = true;
        _lastQuery = query.trim();
      });
    }
    try {
      final res = await _api.search(query.trim());
      if (!mounted || id != _searchReq) return;
      setState(() => _results = res);
    } catch (e) {
      if (!mounted || id != _searchReq) return;
      setState(() => _results = const []);
      _snack('$e');
    } finally {
      if (mounted && id == _searchReq) setState(() => _searching = false);
    }
  }

  Future<void> _deleteEntry(Map<String, dynamic> entry) async {
    final id = (entry['id'] ?? '').toString();
    if (id.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: JcTheme.surface,
        title: const Text('Forget this memory?',
            style: TextStyle(color: JcTheme.text)),
        content: const Text(
          'This removes the entry from the long-term store and cannot be undone.',
          style: TextStyle(color: JcTheme.muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child:
                const Text('Forget', style: TextStyle(color: JcTheme.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _api.deleteEntry(id);
      // Optimistically drop it, then refresh stats so the count updates.
      if (mounted) {
        setState(() =>
            _results = _results.where((e) => '${e['id']}' != id).toList());
      }
      _reload();
    } catch (e) {
      _snack('$e');
    }
  }

  // ── reflections ────────────────────────────────────────────────────────

  Future<void> _dismissReflection(Map<String, dynamic> r) async {
    final id = (r['id'] ?? '').toString();
    if (id.isEmpty) return;
    try {
      await _api.dismissReflection(id);
      _reload();
    } catch (e) {
      _snack('$e');
    }
  }

  Future<void> _runReflections() async {
    try {
      await _api.runReflections();
      if (!mounted) return;
      _snack('Reflection started');
      _reload();
    } catch (e) {
      _snack('$e');
    }
  }

  // ── build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        context,
        title: 'Long-term memory',
        trailing: GlassIconButton(icon: Icons.refresh, onTap: _reload),
      ),
      body: AppBackground(
        child: SafeArea(
          child: FutureBuilder<_MemoryData>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting &&
                  !snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError && !snap.hasData) {
                return _CenterMsg('${snap.error}',
                    color: JcTheme.danger, onRetry: _reload);
              }
              final data = snap.data ??
                  const _MemoryData(stats: {}, status: {}, reflections: []);
              if (!data.available) {
                return _unavailable(data.unavailableMessage);
              }
              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: [
                    _statsHeader(data),
                    const SizedBox(height: 16),
                    _searchBox(),
                    const SizedBox(height: 12),
                    _resultsList(),
                    const SizedBox(height: 24),
                    _reflectionsSection(data.reflections),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _unavailable(String? message) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 64, 16, 24),
      children: [
        GlassCard(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
          child: Column(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: JcTheme.muted.withValues(alpha: 0.12),
                  border: Border.all(color: JcTheme.glassBorder),
                ),
                child: const Icon(Icons.cloud_off_rounded,
                    size: 30, color: JcTheme.muted),
              ),
              const SizedBox(height: 18),
              const Text(
                'Memory store unavailable',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: JcTheme.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text(
                message ??
                    'The jarvis_memory store isn’t initialized yet. Run '
                        'memory setup and choose jarvis_memory, then chat — '
                        'turns are captured automatically and become '
                        'searchable here.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: JcTheme.muted, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 20),
              GlassButton(
                label: 'Retry',
                icon: Icons.refresh,
                ghost: true,
                onPressed: _reload,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statsHeader(_MemoryData data) {
    final namespaces = data.namespaces;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: JcTheme.accent.withValues(alpha: 0.14),
                  border: Border.all(color: JcTheme.glassBorder),
                ),
                child: const Icon(Icons.psychology_outlined,
                    size: 24, color: JcTheme.accent),
              ),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${data.count}',
                    style: const TextStyle(
                      color: JcTheme.text,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'memories stored',
                    style: TextStyle(color: JcTheme.muted, fontSize: 13),
                  ),
                ],
              ),
            ],
          ),
          if (namespaces.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Divider(height: 1, color: JcTheme.glassBorder),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final ns in namespaces)
                  _NamespaceChip(
                    name: '${ns['namespace']}',
                    count: ns['count'] as int? ?? 0,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _searchBox() {
    return TextField(
      controller: _searchCtrl,
      style: const TextStyle(color: JcTheme.text),
      textInputAction: TextInputAction.search,
      onChanged: _onQueryChanged,
      onSubmitted: _runSearch,
      decoration: InputDecoration(
        hintText: 'Search your long-term memory…',
        prefixIcon: const Icon(Icons.search, color: JcTheme.muted),
        suffixIcon: _searching
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : (_searchCtrl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, color: JcTheme.muted),
                    onPressed: () {
                      _searchCtrl.clear();
                      _runSearch('');
                    },
                  )),
      ),
    );
  }

  Widget _resultsList() {
    if (_results.isEmpty) {
      // Before the first search runs (_lastQuery=='' and never searched) the
      // backend returns recent entries for an empty query, so an empty list
      // genuinely means "nothing".
      final msg = _lastQuery.isEmpty
          ? 'No memories captured yet.'
          : 'No memories match “$_lastQuery”.';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: _SectionEmpty(
          icon: _lastQuery.isEmpty
              ? Icons.inventory_2_outlined
              : Icons.search_off_rounded,
          message: msg,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          _lastQuery.isEmpty ? 'Recent' : 'Results',
          trailing: StatusPill('${_results.length}',
              color: JcTheme.cyan, dense: true),
        ),
        for (final e in _results)
          _MemoryEntryCard(
            entry: e,
            onDelete: () => _deleteEntry(e),
          ),
      ],
    );
  }

  Widget _reflectionsSection(List<Map<String, dynamic>> reflections) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          'Reflections',
          trailing: reflections.isEmpty
              ? null
              : StatusPill('${reflections.length}',
                  color: JcTheme.accent, dense: true),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: GlassButton(
            label: 'Run reflection',
            icon: Icons.auto_awesome,
            full: true,
            onPressed: _runReflections,
          ),
        ),
        const SizedBox(height: 14),
        if (reflections.isEmpty)
          const _SectionEmpty(
            icon: Icons.auto_awesome_outlined,
            message:
                'No insights yet — they appear as Jarvis reviews your memory.',
          )
        else
          for (final r in reflections)
            _ReflectionCard(
              reflection: r,
              onDismiss: () => _dismissReflection(r),
            ),
      ],
    );
  }
}

class _NamespaceChip extends StatelessWidget {
  const _NamespaceChip({required this.name, required this.count});
  final String name;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: JcTheme.glassFill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: JcTheme.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name,
              style: const TextStyle(
                  color: JcTheme.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: JcTheme.accent.withValues(alpha: 0.20),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text('$count',
                style: const TextStyle(
                    color: JcTheme.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _MemoryEntryCard extends StatelessWidget {
  const _MemoryEntryCard({required this.entry, required this.onDelete});
  final Map<String, dynamic> entry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final body = (entry['body'] ?? entry['text'] ?? '').toString();
    final source = (entry['source'] ?? '').toString();
    final namespace = (entry['namespace'] ?? '').toString();
    final score = entry['score'];
    final meta =
        [source, namespace].where((s) => s.isNotEmpty).join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        blur: false,
        fill: JcTheme.surface,
        padding: const EdgeInsets.fromLTRB(14, 13, 8, 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              body,
              style: const TextStyle(
                  color: JcTheme.text, fontSize: 14, height: 1.45),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                if (meta.isNotEmpty)
                  Expanded(
                    child: Row(
                      children: [
                        Icon(Icons.label_outline,
                            size: 13,
                            color: JcTheme.muted.withValues(alpha: 0.8)),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: JcTheme.muted, fontSize: 11.5)),
                        ),
                      ],
                    ),
                  )
                else
                  const Spacer(),
                if (score is num) ...[
                  const SizedBox(width: 8),
                  StatusPill(score.toDouble().toStringAsFixed(2),
                      color: JcTheme.cyan, dense: true),
                ],
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: JcTheme.danger),
                  onPressed: onDelete,
                  tooltip: 'Forget',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ReflectionCard extends StatelessWidget {
  const _ReflectionCard({required this.reflection, required this.onDismiss});
  final Map<String, dynamic> reflection;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final title =
        (reflection['title'] ?? reflection['body'] ?? '').toString();
    final kind = (reflection['kind'] ?? '').toString();
    final body = (reflection['body'] ?? '').toString();
    final showBody = body.isNotEmpty && body != title;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        blur: false,
        fill: JcTheme.surface,
        padding: const EdgeInsets.fromLTRB(14, 13, 8, 13),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(Icons.auto_awesome,
                    size: 16, color: JcTheme.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                        color: JcTheme.text,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700),
                  ),
                ),
                if (kind.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  StatusPill(kind, color: JcTheme.accent, dense: true),
                ],
                TextButton(
                  onPressed: onDismiss,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: JcTheme.muted,
                  ),
                  child: const Text('Dismiss', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            if (showBody) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 24, right: 6),
                child: Text(body,
                    style: const TextStyle(
                        color: JcTheme.muted, fontSize: 12.5, height: 1.45)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A compact in-list empty state: a soft icon above a muted message.
class _SectionEmpty extends StatelessWidget {
  const _SectionEmpty({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: JcTheme.muted.withValues(alpha: 0.7)),
            const SizedBox(height: 10),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: JcTheme.muted, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

/// Centered message + optional retry (mirrors AsyncView's error/empty state).
class _CenterMsg extends StatelessWidget {
  const _CenterMsg(this.text, {this.color = JcTheme.muted, this.onRetry});
  final String text;
  final Color color;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text,
                  textAlign: TextAlign.center, style: TextStyle(color: color)),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                TextButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ],
          ),
        ),
      );
}
