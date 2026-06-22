import 'package:flutter/material.dart';

import '../../api/insights.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/glass.dart';

/// Native "Insights" screen — token usage / cost analytics at parity with the
/// web Insights panel. Shows totals, a per-model breakdown, a daily-token trend
/// and an activity histogram (by weekday, falling back to nothing if absent),
/// for a selectable lookback window (7 / 30 / 90 / 365 days).
///
/// The web panel's per-message list is keyed on a single `session_id`, which we
/// don't have a picker for here, so it's omitted (the web panel only shows it
/// when one session is selected) — the overview dashboard is the parity target.
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
                child: AsyncView<Map<String, dynamic>>(
                  controller: _ctrl,
                  loader: () => _api.overview(days: _days),
                  isEmpty: (d) => d.isEmpty,
                  emptyText: 'No usage data yet.',
                  builder: (context, data, refresh) =>
                      _InsightsBody(data: data, days: _days),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({required this.days, required this.onChanged});
  final int days;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 7, label: Text('7d')),
          ButtonSegment(value: 30, label: Text('30d')),
          ButtonSegment(value: 90, label: Text('90d')),
          ButtonSegment(value: 365, label: Text('1y')),
        ],
        selected: {days},
        onSelectionChanged: (sel) => onChanged(sel.first),
        showSelectedIcon: false,
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected)
                  ? JcTheme.accent.withValues(alpha: 0.30)
                  : JcTheme.surfaceAlt),
          foregroundColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected)
                  ? JcTheme.text
                  : JcTheme.muted),
          side: const WidgetStatePropertyAll(
            BorderSide(color: JcTheme.glassBorder),
          ),
        ),
      ),
    );
  }
}

class _InsightsBody extends StatelessWidget {
  const _InsightsBody({required this.data, required this.days});
  final Map<String, dynamic> data;
  final int days;

  @override
  Widget build(BuildContext context) {
    final models = parseModelStats(data['models']);
    final daily = parseRows(data['daily_tokens']);
    final byDay = parseRows(data['activity_by_day']);
    final byHour = parseRows(data['activity_by_hour']);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        _TotalsCard(data: data),
        const SizedBox(height: 12),
        _ModelsCard(models: models),
        const SizedBox(height: 12),
        _ActivityCard(daily: daily, byDay: byDay, byHour: byHour),
      ],
    );
  }
}

/// Top-of-screen totals: sessions, messages, in/out tokens, cost.
class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final tiles = <_Stat>[
      _Stat('Sessions', formatTokenCount(data['total_sessions']),
          Icons.forum_outlined),
      _Stat('Messages', formatTokenCount(data['total_messages']),
          Icons.tag),
      _Stat('Input tokens', formatTokenCount(data['total_input_tokens']),
          Icons.south_west),
      _Stat('Output tokens', formatTokenCount(data['total_output_tokens']),
          Icons.north_east),
      _Stat('Total tokens', formatTokenCount(data['total_tokens']),
          Icons.memory),
      _Stat('Cost', formatCost(data['total_cost']),
          Icons.attach_money),
    ];
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle('Totals'),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2.4,
            children: tiles.map((s) => _StatTile(stat: s)).toList(),
          ),
        ],
      ),
    );
  }
}

class _Stat {
  const _Stat(this.label, this.value, this.icon);
  final String label;
  final String value;
  final IconData icon;
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.stat});
  final _Stat stat;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: JcTheme.glassFill,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: JcTheme.glassBorder),
      ),
      child: Row(
        children: [
          Icon(stat.icon, size: 18, color: JcTheme.primaryBlue),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  stat.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: JcTheme.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  stat.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Per-model breakdown: each model's sessions, token total, and cost.
class _ModelsCard extends StatelessWidget {
  const _ModelsCard({required this.models});
  final List<Map<String, dynamic>> models;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle('By model'),
          const SizedBox(height: 8),
          if (models.isEmpty)
            const _EmptyLine('No model usage in this period.')
          else
            ...models.map((m) => _ModelRow(model: m)),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
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
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$sessions sessions · $tokens tokens',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            cost,
            style: const TextStyle(
              color: JcTheme.cyan,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Activity card: a daily-token mini bar chart, plus an activity-by-weekday
/// histogram. Both are Container-width-proportional bars (no chart package).
class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.daily,
    required this.byDay,
    required this.byHour,
  });
  final List<Map<String, dynamic>> daily;
  final List<Map<String, dynamic>> byDay;
  final List<Map<String, dynamic>> byHour;

  @override
  Widget build(BuildContext context) {
    // Daily-token rows: bar value = input + output tokens for the day.
    final dailyBars = daily
        .map((r) => _BarDatum(
              label: _dayLabel(r['date']),
              value: insightsNum(r['input_tokens']) +
                  insightsNum(r['output_tokens']),
              valueLabel: formatTokensCompact(
                  insightsNum(r['input_tokens']) +
                      insightsNum(r['output_tokens'])),
            ))
        .toList();

    // Activity-by-day rows (weekday → sessions).
    final dowBars = byDay
        .map((r) => _BarDatum(
              label: (r['day'] ?? '').toString(),
              value: insightsNum(r['sessions']),
              valueLabel: formatTokenCount(r['sessions']),
            ))
        .toList();

    final hasDaily = dailyBars.any((b) => b.value > 0);
    final hasDow = dowBars.any((b) => b.value > 0);

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle('Activity'),
          const SizedBox(height: 10),
          const Text('Daily tokens',
              style: TextStyle(
                  color: JcTheme.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (hasDaily)
            _BarList(data: _trimLeadingZeros(dailyBars))
          else
            const _EmptyLine('No token usage recorded.'),
          const SizedBox(height: 16),
          const Text('Sessions by weekday',
              style: TextStyle(
                  color: JcTheme.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (hasDow)
            _BarList(data: dowBars)
          else
            const _EmptyLine('No activity recorded.'),
        ],
      ),
    );
  }

  // Drop leading all-zero days so a 1y window doesn't bury real data; keep at
  // most the last 30 buckets so the inline list stays readable.
  List<_BarDatum> _trimLeadingZeros(List<_BarDatum> bars) {
    var start = 0;
    while (start < bars.length - 1 && bars[start].value == 0) {
      start++;
    }
    final trimmed = bars.sublist(start);
    if (trimmed.length > 30) {
      return trimmed.sublist(trimmed.length - 30);
    }
    return trimmed;
  }

  static String _dayLabel(dynamic date) {
    final s = (date ?? '').toString();
    // "2026-06-21" → "06-21"
    return s.length >= 10 ? s.substring(5) : s;
  }
}

class _BarDatum {
  const _BarDatum({
    required this.label,
    required this.value,
    required this.valueLabel,
  });
  final String label;
  final num value;
  final String valueLabel;
}

/// A column of proportional horizontal bars. Robust to empty input.
class _BarList extends StatelessWidget {
  const _BarList({required this.data});
  final List<_BarDatum> data;

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const _EmptyLine('No data.');
    final max = data.fold<num>(1, (m, b) => b.value > m ? b.value : m);
    return Column(
      children: data.map((b) {
        final frac = (b.value / max).clamp(0.0, 1.0).toDouble();
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
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
              const SizedBox(width: 8),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, c) => Stack(
                    children: [
                      Container(
                        height: 14,
                        decoration: BoxDecoration(
                          color: JcTheme.glassFill,
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                      Container(
                        height: 14,
                        width: (c.maxWidth * frac)
                            .clamp(b.value > 0 ? 6.0 : 0.0, c.maxWidth),
                        decoration: BoxDecoration(
                          gradient: JcTheme.brandGradient,
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 48,
                child: Text(
                  b.valueLabel,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: JcTheme.text, fontSize: 11),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _CardTitle extends StatelessWidget {
  const _CardTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: JcTheme.text,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      );
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text,
            style: const TextStyle(color: JcTheme.muted, fontSize: 13)),
      );
}
