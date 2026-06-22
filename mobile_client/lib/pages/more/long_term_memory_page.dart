import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/jarvis_memory.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/glass.dart';

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
      padding: const EdgeInsets.fromLTRB(24, 80, 24, 24),
      children: [
        const Icon(Icons.memory_outlined, size: 48, color: JcTheme.muted),
        const SizedBox(height: 16),
        const Text(
          'Long-term memory store unavailable',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: JcTheme.text, fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Text(
          message ??
              'The jarvis_memory store isn’t initialized yet. Run '
                  'memory setup and choose jarvis_memory, then chat — turns are '
                  'captured automatically and become searchable here.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: JcTheme.muted, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 20),
        Center(
          child: TextButton(onPressed: _reload, child: const Text('Retry')),
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
            crossAxisAlignment: CrossAxisAlignment.end,
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
              const SizedBox(width: 8),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  'memories',
                  style: TextStyle(color: JcTheme.muted, fontSize: 13),
                ),
              ),
            ],
          ),
          if (namespaces.isNotEmpty) ...[
            const SizedBox(height: 12),
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
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(msg,
              textAlign: TextAlign.center,
              style: const TextStyle(color: JcTheme.muted, fontSize: 13)),
        ),
      );
    }
    return Column(
      children: [
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
        Row(
          children: [
            const Expanded(child: glassReflectionsLabel),
            GlassButton(
              label: 'Run reflection',
              icon: Icons.auto_awesome,
              ghost: true,
              onPressed: _runReflections,
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (reflections.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No insights yet — they appear as Jarvis reviews your memory.',
              style: TextStyle(color: JcTheme.muted, fontSize: 13),
            ),
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

const Widget glassReflectionsLabel = Text(
  'Reflections',
  style: TextStyle(
      color: JcTheme.text, fontSize: 18, fontWeight: FontWeight.w700),
);

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
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        blur: false,
        fill: JcTheme.surface,
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              body,
              style: const TextStyle(
                  color: JcTheme.text, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (meta.isNotEmpty)
                  Expanded(
                    child: Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: JcTheme.muted, fontSize: 11)),
                  )
                else
                  const Spacer(),
                if (score is num) ...[
                  const SizedBox(width: 8),
                  _ScorePill(score: score.toDouble()),
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

class _ScorePill extends StatelessWidget {
  const _ScorePill({required this.score});
  final double score;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: JcTheme.cyan.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        score.toStringAsFixed(2),
        style: const TextStyle(
            color: JcTheme.cyan, fontSize: 11, fontWeight: FontWeight.w700),
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
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        blur: false,
        fill: JcTheme.surface,
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                        color: JcTheme.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                if (kind.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: JcTheme.accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(kind,
                        style: const TextStyle(
                            color: JcTheme.accent,
                            fontSize: 10,
                            fontWeight: FontWeight.w700)),
                  ),
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
              const SizedBox(height: 4),
              Text(body,
                  style: const TextStyle(
                      color: JcTheme.muted, fontSize: 12, height: 1.4)),
            ],
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
