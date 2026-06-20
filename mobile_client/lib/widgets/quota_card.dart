import 'package:flutter/material.dart';

import '../api/quota.dart';
import '../main.dart' as app;
import '../theme.dart';
import 'glass.dart';

/// Loads the quota/usage for every configured provider. Overridable in tests.
typedef QuotaLoader = Future<List<QuotaProvider>> Function({bool refresh});

/// Settings "Quota & Usage" card: one block per configured quota-capable
/// provider (Claude Code, Codex, …), each limit window shown with a progress
/// bar + percentage + reset countdown. Reuses the same usage data as the web
/// Providers panel and the Dynamic Island via `/api/provider/quota/all`.
class QuotaUsageCard extends StatefulWidget {
  const QuotaUsageCard({super.key, this.loader});

  /// Test seam; defaults to `QuotaApi(app.api).getAll`.
  final QuotaLoader? loader;

  @override
  State<QuotaUsageCard> createState() => _QuotaUsageCardState();
}

class _QuotaUsageCardState extends State<QuotaUsageCard> {
  late final QuotaLoader _load = widget.loader ??
      ({bool refresh = false}) => QuotaApi(app.api).getAll(refresh: refresh);

  List<QuotaProvider>? _providers;
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh(initial: true);
  }

  Future<void> _refresh({bool initial = false, bool force = false}) async {
    if (!initial && mounted) setState(() => _refreshing = true);
    try {
      final providers = await _load(refresh: force);
      if (!mounted) return;
      setState(() {
        _providers = providers;
        _error = null;
        _loading = false;
        _refreshing = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Couldn’t load usage';
        _loading = false;
        _refreshing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Row(
            children: [
              const Text('Quota & Usage',
                  style: TextStyle(
                      color: JcTheme.text,
                      fontSize: 18,
                      fontWeight: FontWeight.w700)),
              const Spacer(),
              _refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: JcTheme.muted))
                  : IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: const Icon(Icons.refresh_rounded,
                          size: 20, color: JcTheme.muted),
                      onPressed: () => _refresh(force: true),
                    ),
            ],
          ),
        ),
        GlassCard(padding: const EdgeInsets.all(16), child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: JcTheme.muted),
          ),
        ),
      );
    }
    final providers = _providers ?? const [];
    if (_error != null && providers.isEmpty) {
      return _note(_error!, onRetry: () => _refresh(force: true));
    }
    if (providers.isEmpty) {
      return _note('No quota-capable providers configured.');
    }
    final blocks = <Widget>[];
    for (var i = 0; i < providers.length; i++) {
      if (i > 0) {
        blocks.add(const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Divider(height: 1, color: JcTheme.glassBorder),
        ));
      }
      blocks.add(_providerBlock(providers[i]));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: blocks,
    );
  }

  Widget _note(String text, {VoidCallback? onRetry}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(text,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 13)),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      );

  Widget _providerBlock(QuotaProvider p) {
    final children = <Widget>[
      Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: JcTheme.text.withValues(alpha: 0.10),
              border: Border.all(color: JcTheme.glassBorder),
            ),
            child: Icon(_iconFor(p.provider), size: 16, color: JcTheme.text),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              p.plan != null && p.plan!.isNotEmpty
                  ? '${p.displayName} · ${p.plan}'
                  : p.displayName,
              style: const TextStyle(
                  color: JcTheme.text, fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
    ];
    if (p.windows.isEmpty) {
      children.add(const Text('No active limits.',
          style: TextStyle(color: JcTheme.muted, fontSize: 12)));
    }
    for (var i = 0; i < p.windows.length; i++) {
      if (i > 0) children.add(const SizedBox(height: 12));
      children.add(_windowRow(p.windows[i]));
    }
    for (final d in p.details) {
      children.add(const SizedBox(height: 8));
      children.add(Text(d,
          style: const TextStyle(color: JcTheme.muted, fontSize: 11.5, height: 1.35)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  Widget _windowRow(QuotaWindow w) {
    final used = w.usedPercent ??
        (w.remainingPercent != null ? 100.0 - w.remainingPercent! : null);
    final pctText = used == null ? '—' : '${used.clamp(0, 100).round()}%';
    final reset = _resetText(w.resetAt);
    final sub = [
      if (reset != null) reset,
      if (w.detail != null) w.detail!,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(w.label,
                  style: const TextStyle(color: JcTheme.muted, fontSize: 12.5)),
            ),
            Text(pctText,
                style: const TextStyle(
                    color: JcTheme.text, fontSize: 13, fontWeight: FontWeight.w700)),
          ],
        ),
        const SizedBox(height: 6),
        _QuotaBar(usedPercent: used),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(sub, style: const TextStyle(color: JcTheme.muted, fontSize: 11)),
        ],
      ],
    );
  }

  static String? _resetText(DateTime? at) {
    if (at == null) return null;
    final secs = at.difference(DateTime.now()).inSeconds;
    if (secs <= 0) return 'resets now';
    if (secs < 60) return 'resets in <1m';
    final d = secs ~/ 86400;
    final h = (secs % 86400) ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    if (d > 0) return 'resets in ${d}d ${h}h';
    if (h > 0) return 'resets in ${h}h ${m}m';
    return 'resets in ${m}m';
  }

  static IconData _iconFor(String provider) {
    switch (provider) {
      case 'claude-code':
      case 'anthropic':
        return Icons.bolt_rounded;
      case 'openai-codex':
        return Icons.smart_toy_rounded;
      case 'openrouter':
        return Icons.alt_route_rounded;
      default:
        return Icons.speed_rounded;
    }
  }
}

/// A thin usage bar whose fill width tracks [usedPercent] (0..100) and whose
/// colour shifts amber/red as it nears the limit. A null value renders an empty
/// track (paired with a "—" label) rather than a misleading full/empty bar.
class _QuotaBar extends StatelessWidget {
  const _QuotaBar({required this.usedPercent});

  final double? usedPercent;

  @override
  Widget build(BuildContext context) {
    final p = usedPercent;
    final frac = (p == null) ? 0.0 : (p.clamp(0, 100) / 100.0);
    final List<Color> colors = (p == null)
        ? const [JcTheme.muted, JcTheme.muted]
        : (p >= 90)
            ? const [Color(0xFFEF4444), Color(0xFFF97316)]
            : (p >= 75)
                ? const [Color(0xFFF59E0B), Color(0xFFFBBF24)]
                : const [JcTheme.cyan, JcTheme.accent];
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 6,
        color: JcTheme.glassBorder,
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: frac == 0 ? 0.0 : frac.toDouble(),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: LinearGradient(colors: colors),
            ),
          ),
        ),
      ),
    );
  }
}
