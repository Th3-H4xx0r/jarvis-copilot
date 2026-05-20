import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// Animated audio-level orb for the Voice page. Driven by a 0..1
/// amplitude stream (e.g. RMS from the mic). When amplitude == 0 the
/// orb sits at idle pulse; high amplitude swells the radius and
/// rotates the gradient ring.
class OrbVisualizer extends StatefulWidget {
  const OrbVisualizer({
    super.key,
    required this.amplitude,
    this.size = 220,
  });

  /// 0..1 — most callers feed an RMS from the mic stream.
  final ValueListenable<double> amplitude;
  final double size;

  @override
  State<OrbVisualizer> createState() => _OrbVisualizerState();
}

class _OrbVisualizerState extends State<OrbVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([_ctrl, widget.amplitude]),
        builder: (context, _) {
          return CustomPaint(
            painter: _OrbPainter(
              t: _ctrl.value,
              amp: widget.amplitude.value.clamp(0.0, 1.0).toDouble(),
            ),
          );
        },
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.t, required this.amp});
  final double t;
  final double amp;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final swell = 1.0 + amp * 0.18;

    // Outer rotating gradient ring.
    final ringPaint = Paint()
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        transform: GradientRotation(t * math.pi * 2),
        colors: const [
          JcTheme.accent,
          JcTheme.accentAlt,
          JcTheme.accent,
        ],
      ).createShader(Rect.fromCircle(center: c, radius: r))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 + amp * 5;
    canvas.drawCircle(c, r * 0.92 * swell, ringPaint);

    // Inner soft fill.
    final fillPaint = Paint()
      ..shader = const RadialGradient(
        colors: [
          Color(0xFFFFD27A),
          Color(0x33FFA15A),
          Color(0x00000000),
        ],
      ).createShader(Rect.fromCircle(center: c, radius: r * 0.85));
    canvas.drawCircle(c, r * 0.78 * swell, fillPaint);

    // Pulsing inner dot.
    final innerPaint = Paint()
      ..shader = const RadialGradient(
        colors: [Colors.white, JcTheme.accent],
      ).createShader(Rect.fromCircle(center: c, radius: r * 0.18));
    canvas.drawCircle(c, r * 0.18 * (1 + amp * 0.4), innerPaint);
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) {
    return old.t != t || old.amp != amp;
  }
}
