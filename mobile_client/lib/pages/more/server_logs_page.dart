import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/server_logs.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/glass.dart';
import '../../widgets/status_pill.dart';

/// Native "Server logs" screen — at parity with the web logs panel
/// (`webui/static/panels.js` `loadLogs`). Tails an active-profile server log
/// file (agent / errors / gateway) via `GET /api/logs`, with file + tail-size
/// + severity-filter dropdowns, line wrap, 5s auto-refresh, and copy-all.
class ServerLogsPage extends StatefulWidget {
  const ServerLogsPage({super.key});

  @override
  State<ServerLogsPage> createState() => _ServerLogsPageState();
}

/// Severity filter modes (mirrors the web panel: all / warnings+ / errors).
enum _SeverityFilter { all, warnings, errors }

class _ServerLogsPageState extends State<ServerLogsPage> {
  late final ServerLogsApi _api = ServerLogsApi(app.api);

  String _file = 'agent';
  int _tail = 1000;
  _SeverityFilter _filter = _SeverityFilter.all;
  bool _wrap = true;
  bool _autoRefresh = false;

  List<String> _lines = const [];
  bool _truncated = false;
  int _totalBytes = 0;
  num? _mtime;
  String _hint = '';

  bool _loading = false;
  String? _error;
  Timer? _timer;

  // Lines render newest-first (latest at the TOP). We auto-scroll to the top on
  // open and keep it pinned there as new lines arrive — but only while the user
  // is parked at the top; once they scroll down to read older lines we stop
  // yanking them back.
  final ScrollController _scroll = ScrollController();
  bool _followLatest = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.hasClients) _followLatest = _scroll.offset <= 24;
    });
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _stickToTop() {
    if (_followLatest && _scroll.hasClients) {
      _scroll.jumpTo(0);
    }
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await _api.tail(file: _file, tail: _tail);
      if (!mounted) return;
      setState(() {
        _lines = (data['lines'] as List).cast<String>();
        _truncated = data['truncated'] == true;
        _totalBytes = (data['total_bytes'] as int?) ?? 0;
        _mtime = data['mtime'] as num?;
        _hint = (data['hint'] ?? '').toString();
      });
      // After the new lines render, keep the latest (top) in view if following.
      WidgetsBinding.instance.addPostFrameCallback((_) => _stickToTop());
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _syncAutoRefresh() {
    _timer?.cancel();
    if (_autoRefresh) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        // Skip this tick if a load is still in flight so calls can't stack up
        // when a load takes longer than the 5s interval.
        if (!mounted || _loading) return;
        _load();
      });
    }
  }

  List<String> get _filtered {
    if (_filter == _SeverityFilter.all) return _lines;
    return _lines.where((line) {
      final sev = logSeverity(line);
      if (_filter == _SeverityFilter.errors) return sev == 'error';
      // warnings+: warnings and errors
      return sev == 'warn' || sev == 'error';
    }).toList(growable: false);
  }

  Color _lineColor(String sev) {
    switch (sev) {
      case 'error':
        return JcTheme.danger;
      case 'warn':
        return JcTheme.blue; // amber-ish accent isn't in the palette; warm blue reads as a caution tier
      default:
        return JcTheme.muted;
    }
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _filtered.join('\n')));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logs copied'), duration: Duration(seconds: 1)),
      );
    }
  }

  String _mtimeLabel() {
    final m = _mtime;
    if (m == null) return 'no mtime';
    final dt = DateTime.fromMillisecondsSinceEpoch((m * 1000).round());
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  String _bytesLabel(int bytes) {
    // Group thousands so big logs read cleanly (matches the web's toLocaleString).
    final s = bytes.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return '${buf.toString()} bytes';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(
        context,
        title: 'Server logs',
        trailing: GlassIconButton(
          icon: Icons.refresh,
          onTap: _loading ? null : _load,
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _controls(),
              Expanded(child: _body()),
              _footer(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: GlassCard(
        blur: false,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _dropdown<String>(
                  label: 'File',
                  value: _file,
                  items: [
                    for (final f in serverLogFiles)
                      DropdownMenuItem(value: f, child: Text(f)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _file = v);
                    _load();
                  },
                ),
                _dropdown<int>(
                  label: 'Tail',
                  value: _tail,
                  items: const [
                    DropdownMenuItem(value: 100, child: Text('100')),
                    DropdownMenuItem(value: 200, child: Text('200')),
                    DropdownMenuItem(value: 500, child: Text('500')),
                    DropdownMenuItem(value: 1000, child: Text('1000')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _tail = v);
                    _load();
                  },
                ),
                _dropdown<_SeverityFilter>(
                  label: 'Show',
                  value: _filter,
                  items: const [
                    DropdownMenuItem(value: _SeverityFilter.all, child: Text('All')),
                    DropdownMenuItem(
                        value: _SeverityFilter.warnings, child: Text('Warn+')),
                    DropdownMenuItem(
                        value: _SeverityFilter.errors, child: Text('Errors')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _filter = v);
                  },
                ),
                _copyButton(),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(height: 1, color: JcTheme.glassBorder),
            const SizedBox(height: 8),
            Row(
              children: [
                _toggle(
                  label: 'Wrap',
                  value: _wrap,
                  onChanged: (v) => setState(() => _wrap = v),
                ),
                const SizedBox(width: 8),
                _toggle(
                  label: 'Live',
                  value: _autoRefresh,
                  onChanged: (v) {
                    setState(() => _autoRefresh = v);
                    _syncAutoRefresh();
                  },
                ),
                const Spacer(),
                _legend(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Compact severity legend so the line colours are decodable at a glance.
  Widget _legend() {
    Widget chip(Color c, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(shape: BoxShape.circle, color: c),
            ),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(color: JcTheme.muted, fontSize: 11)),
          ],
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        chip(JcTheme.danger, 'Error'),
        const SizedBox(width: 10),
        chip(JcTheme.blue, 'Warn'),
        const SizedBox(width: 10),
        chip(JcTheme.muted, 'Info'),
      ],
    );
  }

  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: JcTheme.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: JcTheme.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(
                  color: JcTheme.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3)),
          const SizedBox(width: 6),
          DropdownButton<T>(
            value: value,
            items: items,
            onChanged: onChanged,
            isDense: true,
            underline: const SizedBox.shrink(),
            dropdownColor: JcTheme.surface,
            borderRadius: BorderRadius.circular(12),
            style: const TextStyle(
                color: JcTheme.text, fontSize: 14, fontWeight: FontWeight.w600),
            icon: const Icon(Icons.arrow_drop_down, color: JcTheme.muted),
          ),
        ],
      ),
    );
  }

  Widget _toggle({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(color: JcTheme.text, fontSize: 13)),
        Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: JcTheme.accent,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }

  Widget _copyButton() {
    final disabled = _filtered.isEmpty;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: disabled ? null : _copyAll,
        child: Opacity(
          opacity: disabled ? 0.5 : 1,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: JcTheme.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: JcTheme.glassBorder),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.copy_all_outlined, size: 15, color: JcTheme.text),
                SizedBox(width: 6),
                Text('Copy',
                    style: TextStyle(
                        color: JcTheme.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading && _lines.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  size: 32, color: JcTheme.danger),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: JcTheme.danger)),
              const SizedBox(height: 12),
              TextButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    // Newest-first so the latest line sits at the top of the view.
    final lines = _filtered.reversed.toList(growable: false);
    if (lines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.article_outlined,
                  size: 32, color: JcTheme.muted),
              const SizedBox(height: 12),
              Text(
                _hint.isNotEmpty ? _hint : 'No log lines.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: JcTheme.muted),
              ),
            ],
          ),
        ),
      );
    }

    final list = ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      itemCount: lines.length,
      itemBuilder: (_, i) {
        final line = lines[i];
        final sev = logSeverity(line);
        final color = _lineColor(sev);
        // A thin coloured rail in front of warn/error lines so they stand out
        // even when scanning fast; info lines get a transparent rail to align.
        final railColor =
            sev == 'info' ? Colors.transparent : color.withValues(alpha: 0.7);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1.5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 3,
                margin: const EdgeInsets.only(top: 2, right: 8),
                height: 13,
                decoration: BoxDecoration(
                  color: railColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Text(
                  line,
                  softWrap: _wrap,
                  overflow: _wrap ? TextOverflow.clip : TextOverflow.visible,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.4,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    if (_wrap) return list;
    // Wrap OFF → let long lines scroll horizontally.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: MediaQuery.of(context).size.width,
        ),
        child: SizedBox(
          width: 2000,
          child: list,
        ),
      ),
    );
  }

  Widget _footer() {
    final total = _lines.length;
    final shown = _filtered.length;
    final countLabel =
        _filter == _SeverityFilter.all ? '$total' : '$shown / $total';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: JcTheme.glassBorder)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_autoRefresh) ...[
                const PulsingDot(color: JcTheme.success, size: 7),
                const SizedBox(width: 6),
                const Text('LIVE',
                    style: TextStyle(
                      color: JcTheme.success,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    )),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _metaItem(Icons.notes_outlined, '$countLabel lines'),
                    _metaItem(
                        Icons.straighten_outlined, _bytesLabel(_totalBytes)),
                    _metaItem(Icons.schedule, _mtimeLabel()),
                  ],
                ),
              ),
            ],
          ),
          if (_truncated) ...[
            const SizedBox(height: 6),
            const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.content_cut, size: 13, color: JcTheme.blue),
                SizedBox(width: 5),
                Text(
                  'Truncated — showing the tail of a large file.',
                  style: TextStyle(color: JcTheme.blue, fontSize: 12),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _metaItem(IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: JcTheme.muted),
          const SizedBox(width: 5),
          Text(text,
              style: const TextStyle(color: JcTheme.muted, fontSize: 12)),
        ],
      );
}
