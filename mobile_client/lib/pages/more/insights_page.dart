import 'package:flutter/material.dart';

import '../../api/insights.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/glass.dart';
import '../../widgets/status_pill.dart';

/// Native "Insights" screen — FULL parity with the web "Usage Analytics"
/// Insights panel. Top→bottom it shows: a period selector, host system health
/// (CPU/RAM/Disk), LLM Wiki status, the headline stat cards, a daily-token
/// chart, the per-message breakdown for the active conversation, a token
/// breakdown, and a per-model table — each as a glass card that only renders
/// when its data is present.
///
/// The four sub-fetches (overview, system health, wiki status, per-message)
/// run in parallel and degrade independently: a failed/empty sub-fetch hides
/// just its own section, never crashing the screen.
class InsightsPage extends StatefulWidget {
  const InsightsPage({super.key});

  @override
  State<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends State<InsightsPage> {
  late final InsightsApi _api = InsightsApi(app.api);
  final AsyncViewController _ctrl = AsyncViewController();

  int _days = 30;

  void _setDays(int days) {
    if (days == _days) return;
    setState(() => _days = days);
    _ctrl.refresh();
  }

  /// Fan-out load: overview + system health + wiki status + per-message (for
  /// the active session) in parallel. Each piece degrades on its own — a
  /// failed health/wiki/message fetch just yields an empty section.
  Future<_InsightsBundle> _load() async {
    final results = await Future.wait<dynamic>([
      _api.overview(days: _days),
      _api.systemHealth(),
      _api.wikiStatus(),
      _api.activeSessionId().then((id) async {
        if (id == null || id.isEmpty) return <String, dynamic>{'_noSession': true};
        final msgs = await _api.messages(sessionId: id);
        return <String, dynamic>{'session_id': id, 'messages': msgs};
      }),
    ]);
    final overview = (results[0] as Map<String, dynamic>);
    final health = (results[1] as Map<String, dynamic>);
    final wiki = (results[2] as Map<String, dynamic>);
    final msgEnvelope = (results[3] as Map<String, dynamic>);
    final hasSession = msgEnvelope['_noSession'] != true;
    return _InsightsBundle(
      overview: overview,
      health: health,
      wiki: wiki,
      hasSession: hasSession,
      messages: hasSession
          ? (msgEnvelope['messages'] as List).cast<Map<String, dynamic>>()
          : const [],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: glassAppBar(context, title: 'Insights'),
      body: AppBackground(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PeriodSelector(days: _days, onChanged: _setDays),
              Expanded(
                child: AsyncView<_InsightsBundle>(
                  controller: _ctrl,
                  loader: _load,
                  isEmpty: (b) => b.overview.isEmpty,
                  emptyText: 'No usage data yet.',
                  builder: (context, bundle, refresh) =>
                      _InsightsBody(bundle: bundle, days: _days),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The four parallel sub-fetches, bundled for the body. `hasSession` is false
/// when there's no open conversation to drill into (so the Messages section
/// hides entirely rather than showing an empty list).
class _InsightsBundle {
  const _InsightsBundle({
    required this.overview,
    required this.health,
    required this.wiki,
    required this.hasSession,
    required this.messages,
  });
  final Map<String, dynamic> overview;
  final Map<String, dynamic> health;
  final Map<String, dynamic> wiki;
  final bool hasSession;
  final List<Map<String, dynamic>> messages;
}

/// Segmented period control (7 / 30 / 90 / 365 days), wrapped in a glass pill
/// so it reads as one tidy control rather than a bare Material segment row.
class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({required this.days, required this.onChanged});
  final int days;
  final ValueChanged<int> onChanged;

  static const _options = <int, String>{
    7: '7d',
    30: '30d',
    90: '90d',
    365: '1y',
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: JcTheme.glassFill,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: JcTheme.glassBorder),
        ),
        child: Row(
          children: [
            for (final entry in _options.entries)
              Expanded(child: _segment(entry.key, entry.value)),
          ],
        ),
      ),
    );
  }

  Widget _segment(int value, String label) {
    final selected = value == days;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onChanged(value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 9),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: selected ? blueGradient() : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : JcTheme.muted,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

class _InsightsBody extends StatelessWidget {
  const _InsightsBody({required this.bundle, required this.days});
  final _InsightsBundle bundle;
  final int days;

  @override
  Widget build(BuildContext context) {
    final data = bundle.overview;
    final models = parseModelStats(data['models']);
    final daily = parseRows(data['daily_tokens']);

    final healthOk = bundle.health['available'] != false &&
        (bundle.health['cpu'] != null ||
            bundle.health['memory'] != null ||
            bundle.health['disk'] != null);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // 2. System health
        if (healthOk) ...[
          SectionHeader(
            'System health',
            trailing: StatusPill(
              bundle.health['status'] == 'partial' ? 'PARTIAL' : 'LIVE',
              color: bundle.health['status'] == 'partial'
                  ? JcTheme.blue
                  : JcTheme.success,
              live: true,
              dense: true,
            ),
          ),
          _SystemHealthCard(health: bundle.health),
          const SizedBox(height: 20),
        ],

        // 3. LLM Wiki
        const SectionHeader('LLM Wiki'),
        _WikiCard(wiki: bundle.wiki),
        const SizedBox(height: 20),

        // 4. Stat cards
        const SectionHeader('Overview'),
        _StatGrid(data: data),
        const SizedBox(height: 20),

        // 5. Daily tokens
        const SectionHeader('Daily tokens'),
        _DailyTokensCard(daily: daily),
        const SizedBox(height: 20),

        // 6. Messages (this conversation) — only when there's an open chat.
        if (bundle.hasSession) ...[
          const SectionHeader('Messages (this conversation)'),
          _MessagesCard(messages: bundle.messages),
          const SizedBox(height: 20),
        ],

        // 7. Token breakdown
        const SectionHeader('Token breakdown'),
        _TokenBreakdownCard(data: data),
        const SizedBox(height: 20),

        // 8. Models
        const SectionHeader('By model'),
        _ModelsCard(models: models),
        const SizedBox(height: 4),

        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text(
            'Local WebUI session data · last $days days',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: JcTheme.muted.withValues(alpha: 0.6),
              fontSize: 10.5,
            ),
          ),
        ),
      ],
    );
  }
}

// ── 2. System health ────────────────────────────────────────────────────────

/// CPU / RAM / Disk as labelled progress bars. RAM/Disk show a "used / total"
/// byte subtitle; CPU shows just the percent. Missing metrics are skipped.
class _SystemHealthCard extends StatelessWidget {
  const _SystemHealthCard({required this.health});
  final Map<String, dynamic> health;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    void add(String label, dynamic metric) {
      final pct = systemHealthPercent(metric);
      if (pct == null) return;
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 14));
      rows.add(_MetricBar(
        label: label,
        percent: pct,
        subtitle: systemHealthBytesLabel(metric),
      ));
    }

    add('CPU', health['cpu']);
    add('RAM', health['memory']);
    add('Disk', health['disk']);

    return GlassCard(
      child: rows.isEmpty
          ? const _EmptyBlock(
              icon: Icons.speed_outlined,
              text: 'Host metrics unavailable.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Current VPS resource usage',
                  style: TextStyle(color: JcTheme.muted, fontSize: 11.5),
                ),
                const SizedBox(height: 14),
                ...rows,
              ],
            ),
    );
  }
}

class _MetricBar extends StatelessWidget {
  const _MetricBar({
    required this.label,
    required this.percent,
    required this.subtitle,
  });
  final String label;
  final double percent; // 0..100
  final String subtitle;

  Color get _color {
    if (percent >= 90) return JcTheme.danger;
    if (percent >= 70) return JcTheme.accentAlt;
    return JcTheme.cyan;
  }

  @override
  Widget build(BuildContext context) {
    final frac = (percent / 100).clamp(0.0, 1.0);
    final pctText = '${percent.toStringAsFixed(percent % 1 == 0 ? 0 : 1)}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: const TextStyle(
                color: JcTheme.text,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 11),
                ),
              ),
            ] else
              const Spacer(),
            Text(
              pctText,
              style: TextStyle(
                color: _color,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              Container(height: 8, color: JcTheme.glassFill),
              FractionallySizedBox(
                widthFactor: frac,
                child: Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: _color,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── 3. LLM Wiki ─────────────────────────────────────────────────────────────

/// Knowledge-base observability: availability pill + status note + small stat
/// tiles (Enabled / Entries / Pages / Raw files / Last updated / Last writer).
class _WikiCard extends StatelessWidget {
  const _WikiCard({required this.wiki});
  final Map<String, dynamic> wiki;

  @override
  Widget build(BuildContext context) {
    final available = wiki['available'] == true;
    final status = (wiki['status'] ?? 'error').toString();
    final isReady = available && status == 'ready';
    final isEmpty = available && status == 'empty';
    final isError = status == 'error';

    final String badgeText;
    final Color badgeColor;
    if (isReady) {
      badgeText = 'Available';
      badgeColor = JcTheme.success;
    } else if (isError) {
      badgeText = 'Error';
      badgeColor = JcTheme.danger;
    } else if (isEmpty) {
      badgeText = 'Empty';
      badgeColor = JcTheme.accentAlt;
    } else {
      badgeText = 'Unavailable';
      badgeColor = JcTheme.muted;
    }

    final note = isReady
        ? 'LLM Wiki is configured and page metadata is visible without exposing wiki content.'
        : isEmpty
            ? 'LLM Wiki exists but has no entity, concept, comparison, or query pages yet.'
            : isError
                ? 'Unable to inspect LLM Wiki status${wiki['error'] != null ? ': ${wiki['error']}' : ''}.'
                : 'No LLM Wiki directory was found. Set WIKI_PATH or skills.config.wiki.path to enable status visibility.';

    final tiles = <_KV>[
      _KV('Enabled', wiki['enabled'] == true ? 'Yes' : 'No'),
      _KV('Entries', formatTokenCount(wiki['entry_count'])),
      _KV('Pages', formatTokenCount(wiki['page_count'])),
      _KV('Raw files', formatTokenCount(wiki['raw_source_count'])),
      _KV('Last updated', _formatTimestamp(wiki['last_updated'])),
      _KV('Last writer', (wiki['last_writer'] ?? 'Not available').toString()),
    ];

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Knowledge-base observability',
                  style: TextStyle(color: JcTheme.muted, fontSize: 11.5),
                ),
              ),
              StatusPill(badgeText, color: badgeColor, dense: true),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            note,
            style: const TextStyle(color: JcTheme.text, fontSize: 12.5, height: 1.35),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [for (final t in tiles) _KvTile(kv: t)],
          ),
        ],
      ),
    );
  }

  static String _formatTimestamp(dynamic value) {
    if (value == null) return 'Never';
    final s = value.toString();
    final dt = DateTime.tryParse(s);
    if (dt == null) return s;
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}

class _KV {
  const _KV(this.label, this.value);
  final String label;
  final String value;
}

/// A compact key/value chip used in the Wiki card grid (label over value).
class _KvTile extends StatelessWidget {
  const _KvTile({required this.kv});
  final _KV kv;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        // Two-up grid that survives narrow phones; 6px gutter from Wrap spacing.
        final width = (c.maxWidth - 10) / 2;
        return Container(
          width: width.clamp(120.0, 480.0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: JcTheme.glassFill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: JcTheme.glassBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                kv.label.toUpperCase(),
                style: const TextStyle(
                  color: JcTheme.muted,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                kv.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: JcTheme.text,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ── 4. Stat cards ───────────────────────────────────────────────────────────

/// Headline totals as a 2-column grid of GlassCard stat tiles:
/// sessions, messages, tokens, cost (matching the web's four overview cards).
class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final tiles = <_Stat>[
      _Stat('Sessions', formatTokenCount(data['total_sessions']),
          Icons.forum_outlined, JcTheme.cyan),
      _Stat('Messages', formatTokenCount(data['total_messages']),
          Icons.tag, JcTheme.blue),
      _Stat('Tokens', formatTokensCompact(data['total_tokens']),
          Icons.memory, JcTheme.accent),
      _Stat('Est. cost', formatCost(data['total_cost']),
          Icons.attach_money, JcTheme.success),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.65,
      children: tiles.map((s) => _StatTile(stat: s)).toList(),
    );
  }
}

class _Stat {
  const _Stat(this.label, this.value, this.icon, this.color);
  final String label;
  final String value;
  final IconData icon;
  final Color color;
}

/// A single stat tile: tinted icon chip, then a big number over a muted label.
class _StatTile extends StatelessWidget {
  const _StatTile({required this.stat});
  final _Stat stat;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      blur: false,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: stat.color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(stat.icon, size: 17, color: stat.color),
          ),
          const SizedBox(height: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                stat.value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: JcTheme.text,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                stat.label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: JcTheme.muted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── 5. Daily tokens ─────────────────────────────────────────────────────────

/// Daily token usage as proportional horizontal bars (input vs output stacked
/// in a single bar where both exist), with date labels. No chart package.
class _DailyTokensCard extends StatelessWidget {
  const _DailyTokensCard({required this.daily});
  final List<Map<String, dynamic>> daily;

  @override
  Widget build(BuildContext context) {
    final bars = daily
        .map((r) => _DailyBar(
              label: _dayLabel(r['date']),
              input: insightsNum(r['input_tokens']),
              output: insightsNum(r['output_tokens']),
            ))
        .toList();
    final trimmed = _trim(bars);
    final hasData = trimmed.any((b) => b.total > 0);

    return GlassCard(
      child: hasData
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DailyBarList(data: trimmed),
                const SizedBox(height: 12),
                const _Legend(),
              ],
            )
          : const _EmptyBlock(
              icon: Icons.show_chart,
              text: 'No token usage recorded.',
            ),
    );
  }

  // Drop leading all-zero days, then keep at most the last 30 buckets so the
  // inline list stays readable on a 1y window.
  List<_DailyBar> _trim(List<_DailyBar> bars) {
    var start = 0;
    while (start < bars.length - 1 && bars[start].total == 0) {
      start++;
    }
    final t = bars.sublist(start);
    return t.length > 30 ? t.sublist(t.length - 30) : t;
  }

  static String _dayLabel(dynamic date) {
    final s = (date ?? '').toString();
    return s.length >= 10 ? s.substring(5) : s; // "2026-06-21" → "06-21"
  }
}

class _DailyBar {
  const _DailyBar({
    required this.label,
    required this.input,
    required this.output,
  });
  final String label;
  final num input;
  final num output;
  num get total => input + output;
}

class _DailyBarList extends StatelessWidget {
  const _DailyBarList({required this.data});
  final List<_DailyBar> data;

  @override
  Widget build(BuildContext context) {
    final max = data.fold<num>(1, (m, b) => b.total > m ? b.total : m);
    return Column(
      children: data.map((b) {
        final inFrac = (b.input / max).clamp(0.0, 1.0).toDouble();
        final outFrac = (b.output / max).clamp(0.0, 1.0).toDouble();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 46,
                child: Text(
                  b.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 11),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    children: [
                      Container(height: 16, color: JcTheme.glassFill),
                      Row(
                        children: [
                          if (inFrac > 0)
                            Expanded(
                              flex: (inFrac * 1000).round(),
                              child: Container(
                                height: 16,
                                color: JcTheme.primaryBlue,
                              ),
                            ),
                          if (outFrac > 0)
                            Expanded(
                              flex: (outFrac * 1000).round(),
                              child: Container(
                                height: 16,
                                color: JcTheme.accent,
                              ),
                            ),
                          // Remaining track space (keeps bars proportional).
                          Expanded(
                            flex: (((1 - inFrac - outFrac).clamp(0.0, 1.0)) *
                                    1000)
                                .round()
                                .clamp(0, 1000),
                            child: const SizedBox(height: 16),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 52,
                child: Text(
                  formatTokensCompact(b.total),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: JcTheme.text,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    Widget item(Color c, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration:
                  BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
            ),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(color: JcTheme.muted, fontSize: 11)),
          ],
        );
    return Row(
      children: [
        item(JcTheme.primaryBlue, 'Input'),
        const SizedBox(width: 16),
        item(JcTheme.accent, 'Output'),
      ],
    );
  }
}

// ── 6. Messages (this conversation) ─────────────────────────────────────────

/// Per-message rows for the active conversation: # / Input / Output / Total,
/// each with a small input-composition colour bar where one is available.
class _MessagesCard extends StatelessWidget {
  const _MessagesCard({required this.messages});
  final List<Map<String, dynamic>> messages;

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return const GlassCard(
        child: _EmptyBlock(
          icon: Icons.chat_bubble_outline,
          text: 'No messages recorded yet.',
        ),
      );
    }
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _MsgHeaderRow(),
          const SizedBox(height: 6),
          const Divider(height: 1, color: JcTheme.glassBorder),
          for (final (i, m) in messages.indexed) ...[
            if (i > 0) const Divider(height: 1, color: JcTheme.glassBorder),
            _MessageRow(message: m),
          ],
          const SizedBox(height: 8),
          Text(
            'Input composition is estimated (~chars ÷ 4); in/out totals are exact.',
            style: TextStyle(
              color: JcTheme.muted.withValues(alpha: 0.8),
              fontSize: 10.5,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _MsgHeaderRow extends StatelessWidget {
  const _MsgHeaderRow();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: JcTheme.muted,
      fontSize: 10.5,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.4,
    );
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 34, child: Text('#', style: style)),
          Expanded(child: Text('INPUT', textAlign: TextAlign.right, style: style)),
          Expanded(child: Text('OUTPUT', textAlign: TextAlign.right, style: style)),
          Expanded(child: Text('TOTAL', textAlign: TextAlign.right, style: style)),
        ],
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.message});
  final Map<String, dynamic> message;

  @override
  Widget build(BuildContext context) {
    final turn = (message['turn'] ?? '').toString();
    final inT = insightsNum(message['input_tokens']);
    final outT = insightsNum(message['output_tokens']);
    final cached = insightsNum(message['cache_read_tokens']) > 0;
    final comp = messageComposition(message);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _showComposition(context, message),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
              SizedBox(
                width: 34,
                child: Text(
                  '#$turn',
                  style: const TextStyle(
                    color: JcTheme.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (cached) ...[
                      const Icon(Icons.bolt, size: 12, color: JcTheme.cyan),
                      const SizedBox(width: 2),
                    ],
                    Text(
                      formatTokensCompact(inT),
                      style: const TextStyle(color: JcTheme.text, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Text(
                  formatTokensCompact(outT),
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: JcTheme.text, fontSize: 12.5),
                ),
              ),
              Expanded(
                child: Text(
                  formatTokensCompact(inT + outT),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: JcTheme.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
              if (comp.isNotEmpty) ...[
                const SizedBox(height: 7),
                _CompositionBar(composition: comp),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A thin stacked bar of the input-composition sections (largest first),
/// coloured per section. Mirrors the web's `_compositionBar`.
class _CompositionBar extends StatelessWidget {
  const _CompositionBar({required this.composition});
  final Map<String, num> composition;

  @override
  Widget build(BuildContext context) {
    final entries = composition.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = entries.fold<num>(0, (s, e) => s + e.value);
    if (total <= 0) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 6,
        child: Row(
          children: [
            for (final e in entries)
              Expanded(
                flex: (e.value / total * 1000).round().clamp(1, 1000),
                child: Container(color: _sectionColor(e.key)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Section → colour, mirroring the web panel's `_INSIGHTS_SECTION_META`.
Color _sectionColor(String key) {
  switch (key) {
    case 'identity':
      return const Color(0xFF7C5CFF);
    case 'behavioral_guidance':
      return const Color(0xFF4F8CFF);
    case 'tool_use_guidance':
      return const Color(0xFF3FB6C9);
    case 'lazy_manifest':
      return const Color(0xFF2DBF7E);
    case 'skills_catalog':
      return const Color(0xFF8BC34A);
    case 'env_profile':
      return const Color(0xFFC9B03F);
    case 'context_files':
      return const Color(0xFFE0913A);
    case 'memory':
      return const Color(0xFFE0573A);
    case 'external_memory':
      return const Color(0xFFD24B86);
    case 'timestamp':
      return const Color(0xFF9AA0A6);
    case 'system_prompt':
      return const Color(0xFF7C5CFF);
    case 'tool_schemas':
      return const Color(0xFFA06BFF);
    case 'conversation_history':
      return const Color(0xFF5B6FB0);
    case 'user_message':
      return const Color(0xFF34C759);
    default:
      return const Color(0xFF6B7280);
  }
}

/// Section → human label, mirroring the web panel's `_INSIGHTS_SECTION_META`.
String _sectionLabel(String key) {
  switch (key) {
    case 'identity':
      return 'Identity / SOUL.md';
    case 'behavioral_guidance':
      return 'Behavioral guidance';
    case 'tool_use_guidance':
      return 'Tool-use guidance';
    case 'lazy_manifest':
      return 'Deferred-tools manifest';
    case 'skills_catalog':
      return 'Skills catalog';
    case 'env_profile':
      return 'Environment & profile';
    case 'context_files':
      return 'Context files';
    case 'memory':
      return 'Memory (MEMORY/USER.md)';
    case 'external_memory':
      return 'External memory';
    case 'timestamp':
      return 'Timestamp';
    case 'system_prompt':
      return 'System prompt';
    case 'tool_schemas':
      return 'Tool schemas';
    case 'conversation_history':
      return 'Conversation history';
    case 'user_message':
      return 'User message';
    case 'other':
      return 'Other (system)';
    default:
      return key; // unknown keys (e.g. system_message) show their raw key
  }
}

/// Tap-through composition modal for a single message — mirrors the web's
/// `showMsgComposition`: per-section token counts + percentages, sorted desc.
void _showComposition(BuildContext context, Map<String, dynamic> message) {
  final comp = messageComposition(message);
  final entries = comp.entries.where((e) => e.value > 0).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final total = entries.fold<num>(0, (s, e) => s + e.value);
  final turn = (message['turn'] ?? '').toString();
  final inT = insightsNum(message['input_tokens']);
  final outT = insightsNum(message['output_tokens']);
  final cache = insightsNum(message['cache_read_tokens']);
  final reasoning = insightsNum(message['reasoning_tokens']);
  final latency = message['latency_s'];
  final model = (message['model'] ?? '').toString();

  Widget hdr(String label, num value) => Text.rich(TextSpan(children: [
        TextSpan(
            text: '$label: ',
            style: const TextStyle(color: JcTheme.muted, fontSize: 12.5)),
        TextSpan(
            text: formatTokenCount(value),
            style: const TextStyle(
                color: JcTheme.text,
                fontSize: 12.5,
                fontWeight: FontWeight.w700)),
      ]));

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: JcTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) => ConstrainedBox(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: JcTheme.muted.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text('Composition — #$turn',
                      style: const TextStyle(
                          color: JcTheme.text,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                ),
                GestureDetector(
                  onTap: () => Navigator.of(ctx).pop(),
                  child: const Icon(Icons.close_rounded,
                      color: JcTheme.muted, size: 22),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                hdr('Input', inT),
                hdr('Output', outT),
                if (cache > 0) hdr('Cache hit', cache),
                if (reasoning > 0) hdr('Reasoning', reasoning),
                if (latency is num)
                  Text('${latency.toStringAsFixed(1)}s',
                      style: const TextStyle(
                          color: JcTheme.muted, fontSize: 12.5)),
                if (model.isNotEmpty)
                  Text(model,
                      style: const TextStyle(
                          color: JcTheme.cyan,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Input composition is estimated (~chars ÷ 4); the in/out totals '
              'are exact from the API.',
              style: TextStyle(
                  color: JcTheme.muted.withValues(alpha: 0.8),
                  fontSize: 11,
                  height: 1.3),
            ),
            const SizedBox(height: 14),
            Flexible(
              child: entries.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text('No composition data for this message.',
                          style: TextStyle(color: JcTheme.muted)),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        children: [
                          for (final e in entries)
                            _CompRow(
                              label: _sectionLabel(e.key),
                              color: _sectionColor(e.key),
                              value: e.value,
                              pct: total > 0 ? e.value / total * 100 : 0,
                            ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// One section row in the composition modal: dot + label + value/% + bar.
class _CompRow extends StatelessWidget {
  const _CompRow({
    required this.label,
    required this.color,
    required this.value,
    required this.pct,
  });
  final String label;
  final Color color;
  final num value;
  final double pct;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                    color: color, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: JcTheme.text, fontSize: 13.5)),
              ),
              const SizedBox(width: 8),
              Text(
                '${formatTokenCount(value)}  (${pct.toStringAsFixed(1)}%)',
                style: const TextStyle(color: JcTheme.muted, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: SizedBox(
              height: 6,
              child: Row(
                children: [
                  Expanded(
                    flex: (pct * 10).round().clamp(1, 1000),
                    child: Container(color: color),
                  ),
                  Expanded(
                    flex: ((100 - pct) * 10).round().clamp(0, 1000),
                    child: Container(color: JcTheme.glassFill),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── 7. Token breakdown ──────────────────────────────────────────────────────

/// Input / Output / Total rows from the overview totals.
class _TokenBreakdownCard extends StatelessWidget {
  const _TokenBreakdownCard({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        children: [
          _row('Input tokens', formatTokensCompact(data['total_input_tokens'])),
          const Divider(height: 18, color: JcTheme.glassBorder),
          _row('Output tokens', formatTokensCompact(data['total_output_tokens'])),
          const Divider(height: 18, color: JcTheme.glassBorder),
          _row('Total', formatTokensCompact(data['total_tokens']), bold: true),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: bold ? JcTheme.text : JcTheme.muted,
              fontSize: 13.5,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: JcTheme.text,
              fontSize: 14.5,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ],
      );
}

// ── 8. Models ───────────────────────────────────────────────────────────────

/// Per-model breakdown: Model · Sessions · Tokens · Cost · Share.
class _ModelsCard extends StatelessWidget {
  const _ModelsCard({required this.models});
  final List<Map<String, dynamic>> models;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: models.isEmpty
          ? const _EmptyBlock(
              icon: Icons.layers_outlined,
              text: 'No model usage in this period.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, m) in models.indexed) ...[
                  if (i > 0)
                    const Divider(height: 1, color: JcTheme.glassBorder),
                  _ModelRow(model: m),
                ],
              ],
            ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.model});
  final Map<String, dynamic> model;

  @override
  Widget build(BuildContext context) {
    final name = (model['model'] ?? 'unknown').toString();
    final sessions = formatTokenCount(model['sessions']);
    final tokens = formatTokensCompact(model['total_tokens']);
    final cost = formatCost(model['cost']);
    final share = insightsNum(
            model['cost_share'] ?? model['token_share'] ?? model['session_share'])
        .round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: JcTheme.text,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '$sessions sessions · $tokens tokens · $share% share',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          StatusPill(cost, color: JcTheme.cyan, dense: true),
        ],
      ),
    );
  }
}

// ── Shared ──────────────────────────────────────────────────────────────────

/// Icon + text empty state for a card body.
class _EmptyBlock extends StatelessWidget {
  const _EmptyBlock({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: JcTheme.muted),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                style: const TextStyle(color: JcTheme.muted, fontSize: 13),
              ),
            ),
          ],
        ),
      );
}
