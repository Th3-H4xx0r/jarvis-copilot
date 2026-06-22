import 'package:flutter/material.dart';

import '../../api/insights.dart';
import '../../main.dart' as app;
import '../../theme.dart';
import '../../widgets/async_view.dart';
import '../../widgets/glass.dart';
import '../../widgets/status_pill.dart';

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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _StatGrid(data: data),
        const SizedBox(height: 20),
        const SectionHeader('By model'),
        _ModelsCard(models: models),
        const SizedBox(height: 20),
        const SectionHeader('Activity'),
        _ActivityCard(daily: daily, byDay: byDay, byHour: byHour),
      ],
    );
  }
}

/// Top-of-screen totals as a 2-column grid of GlassCard stat tiles:
/// sessions, messages, in/out tokens, total tokens, cost.
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
      _Stat('Input tokens', formatTokensCompact(data['total_input_tokens']),
          Icons.south_west, JcTheme.primaryBlue),
      _Stat('Output tokens', formatTokensCompact(data['total_output_tokens']),
          Icons.north_east, JcTheme.accent),
      _Stat('Total tokens', formatTokensCompact(data['total_tokens']),
          Icons.memory, JcTheme.accentAlt),
      _Stat('Cost', formatCost(data['total_cost']),
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

/// Per-model breakdown: each model's sessions, token total, and cost.
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
                  '$sessions sessions · $tokens tokens',
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
          const _SubLabel('Daily tokens'),
          const SizedBox(height: 10),
          if (hasDaily)
            _BarList(data: _trimLeadingZeros(dailyBars))
          else
            const _EmptyBlock(
              icon: Icons.show_chart,
              text: 'No token usage recorded.',
            ),
          const SizedBox(height: 18),
          const Divider(height: 1, color: JcTheme.glassBorder),
          const SizedBox(height: 18),
          const _SubLabel('Sessions by weekday'),
          const SizedBox(height: 10),
          if (hasDow)
            _BarList(data: dowBars)
          else
            const _EmptyBlock(
              icon: Icons.calendar_today_outlined,
              text: 'No activity recorded.',
            ),
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
    if (data.isEmpty) {
      return const _EmptyBlock(icon: Icons.bar_chart, text: 'No data.');
    }
    final max = data.fold<num>(1, (m, b) => b.value > m ? b.value : m);
    return Column(
      children: data.map((b) {
        final frac = (b.value / max).clamp(0.0, 1.0).toDouble();
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
                child: LayoutBuilder(
                  builder: (context, c) => Stack(
                    children: [
                      Container(
                        height: 16,
                        decoration: BoxDecoration(
                          color: JcTheme.glassFill,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      Container(
                        height: 16,
                        width: (c.maxWidth * frac)
                            .clamp(b.value > 0 ? 8.0 : 0.0, c.maxWidth),
                        decoration: BoxDecoration(
                          gradient: blueGradient(),
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 50,
                child: Text(
                  b.valueLabel,
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

/// A small muted sub-label inside a card (e.g. the two chart sections).
class _SubLabel extends StatelessWidget {
  const _SubLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          color: JcTheme.text,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
      );
}

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
