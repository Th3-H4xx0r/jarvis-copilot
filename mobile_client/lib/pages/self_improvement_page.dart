import 'package:flutter/material.dart';

import '../api/self_improvement.dart';
import '../main.dart' as app;
import '../theme.dart';
import '../widgets/glass.dart';

/// Shows what the agent has been learning on its own: skills auto-created or
/// patched, memory updated, and rejected/failed attempts — sourced from the
/// server's self_improvement.log via /api/self-improvement/recent.
class SelfImprovementPage extends StatefulWidget {
  const SelfImprovementPage({super.key});

  @override
  State<SelfImprovementPage> createState() => _SelfImprovementPageState();
}

class _SelfImprovementPageState extends State<SelfImprovementPage> {
  late final SelfImprovementApi _api = SelfImprovementApi(app.api);
  List<Map<String, dynamic>> _events = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _events = await _api.recent();
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Color _kindColor(String kind) {
    switch (kind) {
      case 'fail':
        return JcTheme.danger;
      case 'rejected':
        return JcTheme.accent;
      case 'noop':
        return JcTheme.muted;
      default:
        return JcTheme.success;
    }
  }

  String _kindLabel(String kind) {
    switch (kind) {
      case 'fail':
        return 'FAILED';
      case 'rejected':
        return 'REJECTED';
      case 'noop':
        return 'REVIEWED';
      default:
        return 'LEARNED';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: JcTheme.bg,
      appBar: AppBar(
        title: const Text('Learning'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: AppBackground(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!,
                        style: const TextStyle(color: JcTheme.danger)),
                  ),
                )
              : _events.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No self-improvement activity yet.\n'
                          'After a substantial task, skills/memory the agent '
                          'saves on its own will show up here.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: JcTheme.muted),
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _refresh,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _events.length,
                        itemBuilder: (_, i) {
                          final e = _events[i];
                          final kind = (e['kind'] ?? 'change').toString();
                          final origin = (e['origin'] ?? '').toString();
                          final ts = (e['ts'] ?? '').toString();
                          final text = (e['text'] ?? '').toString();
                          final color = _kindColor(kind);
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 6),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: color.withValues(alpha: 0.18),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          _kindLabel(kind),
                                          style: TextStyle(
                                            color: color,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      if (origin.isNotEmpty)
                                        Expanded(
                                          child: Text(
                                            origin,
                                            style: const TextStyle(
                                              color: JcTheme.muted,
                                              fontSize: 12,
                                            ),
                                          ),
                                        )
                                      else
                                        const Spacer(),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(text,
                                      style:
                                          const TextStyle(color: JcTheme.text)),
                                  if (ts.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text(ts,
                                        style: const TextStyle(
                                            color: JcTheme.muted,
                                            fontSize: 11)),
                                  ],
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    )),
    );
  }
}
