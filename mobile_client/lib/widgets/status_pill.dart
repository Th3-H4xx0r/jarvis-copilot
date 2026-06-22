import 'package:flutter/material.dart';

import '../theme.dart';

/// A compact status chip: a coloured label with a soft tinted background, used
/// across the More-tab screens for consistent status presentation. When [live]
/// is true it shows a gently pulsing leading dot (e.g. a running task).
class StatusPill extends StatelessWidget {
  const StatusPill(
    this.label, {
    super.key,
    required this.color,
    this.live = false,
    this.dense = false,
  });

  final String label;
  final Color color;
  final bool live;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: dense ? 7 : 9, vertical: dense ? 2 : 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (live) ...[
            PulsingDot(color: color, size: dense ? 6 : 7),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: dense ? 10 : 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small dot that breathes (opacity + halo) — signals a live/active state.
class PulsingDot extends StatefulWidget {
  const PulsingDot({super.key, required this.color, this.size = 8});
  final Color color;
  final double size;

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final t = _c.value;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.25 + 0.45 * (1 - t)),
                blurRadius: 2 + 5 * t,
                spreadRadius: 0.5 + 2.5 * t,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A bold section heading used inside detail sheets and dashboards.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Row(
        children: [
          Text(
            text.toUpperCase(),
            style: const TextStyle(
              color: JcTheme.muted,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
