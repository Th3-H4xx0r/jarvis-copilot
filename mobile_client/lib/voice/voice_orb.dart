import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'voice_state.dart';

/// State-aware voice orb — a native take on the webui's canvas particle
/// orb. A rotating particle sphere with depth-cued colouring, two
/// counter-rotating chrome rings, and an amplitude-driven spike rim that
/// shows while listening/speaking. Colour comes from [state]; motion and
/// spike length come from [amplitude].
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.state,
    required this.amplitude,
    this.size = 260,
  });

  final VoiceState state;

  /// 0..1 — mic RMS while listening, playback envelope while speaking.
  final ValueListenable<double> amplitude;
  final double size;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  )..repeat();

  // Golden-spiral particle directions, computed once.
  late final List<_P> _particles = _buildParticles(240);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  static List<_P> _buildParticles(int n) {
    final out = <_P>[];
    final golden = math.pi * (3 - math.sqrt(5));
    for (var i = 0; i < n; i++) {
      final y = 1 - (i / (n - 1)) * 2; // 1..-1
      final radius = math.sqrt(1 - y * y);
      final theta = golden * i;
      out.add(_P(math.cos(theta) * radius, y, math.sin(theta) * radius,
          i * 0.6));
    }
    return out;
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
              t: _ctrl.value * 24, // seconds
              amp: widget.amplitude.value.clamp(0.0, 1.0).toDouble(),
              state: widget.state,
              particles: _particles,
            ),
          );
        },
      ),
    );
  }
}

class _P {
  const _P(this.x, this.y, this.z, this.phase);
  final double x, y, z, phase;
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.t,
    required this.amp,
    required this.state,
    required this.particles,
  });

  final double t;
  final double amp;
  final VoiceState state;
  final List<_P> particles;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final scale = size.shortestSide / 2;
    final colors = state.palette;
    final c0 = colors[0], c1 = colors[1], c2 = colors[2], rim = colors[3];

    final showSpikes =
        state == VoiceState.listening || state == VoiceState.speaking;
    // Thinking/connecting self-pulse; listening/speaking swell with amp.
    final pulsing = state == VoiceState.thinking ||
        state == VoiceState.connecting;
    final ampBoost = pulsing
        ? 0.85 + 0.15 * math.sin(t * 4.2)
        : 1 + 0.12 * amp;

    // 1. Background radial glow.
    final bgRad = scale * 0.98;
    final glow = Paint()
      ..shader = RadialGradient(
        colors: [
          c0.withValues(alpha: 0.22),
          c1.withValues(alpha: 0.10),
          const Color(0x00000000),
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: bgRad));
    canvas.drawCircle(center, bgRad, glow);

    // 2. Two counter-rotating chrome rings.
    _ring(canvas, center, scale * 0.86, t * 0.3, 18, rim.withValues(alpha: 0.30));
    _ring(canvas, center, scale * 0.78, -t * 0.2, 24, rim.withValues(alpha: 0.18));

    // 3. Particle sphere (additive blend for a luminous core).
    canvas.saveLayer(
      Rect.fromCircle(center: center, radius: scale),
      Paint()..blendMode = BlendMode.plus,
    );
    final rotY = t * 0.5;
    final wobX = math.sin(t * 0.18) * 0.4;
    final cosY = math.cos(rotY), sinY = math.sin(rotY);
    final cosX = math.cos(wobX), sinX = math.sin(wobX);
    final sphereR = scale * 0.62 * ampBoost;
    final dot = Paint();
    for (final p in particles) {
      // Rotate around Y then X.
      var x = p.x * cosY + p.z * sinY;
      var z = -p.x * sinY + p.z * cosY;
      var y = p.y * cosX - z * sinX;
      z = p.y * sinX + z * cosX;
      final wobble = 1 + 0.04 * math.sin(t * 1.8 + p.phase);
      final px = center.dx + x * sphereR * wobble;
      final py = center.dy + y * sphereR * wobble;
      final depth = (z + 1) / 2; // 0 (back) .. 1 (front)
      final color = Color.lerp(c2, Color.lerp(c1, c0, depth)!, depth)!;
      dot.color = color.withValues(alpha: (0.10 + depth * 0.7).clamp(0.0, 1.0));
      canvas.drawCircle(Offset(px, py), 1.0 + depth * 1.6, dot);
    }
    canvas.restore();

    // 4. Amplitude spike rim (listening / speaking only).
    if (showSpikes) {
      const spikes = 80;
      final baseR = scale * 0.66;
      final ampUse = state == VoiceState.speaking
          ? math.max(0.25, 0.4 + 0.6 * amp)
          : math.max(0.12, amp);
      final paint = Paint()
        ..color = c0.withValues(alpha: 0.6)
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < spikes; i++) {
        final a = (i / spikes) * math.pi * 2;
        final wob = 0.5 + 0.5 * math.sin(t * 5 + i * 0.6);
        final len = scale * 0.16 * ampUse * wob;
        final ca = math.cos(a), sa = math.sin(a);
        canvas.drawLine(
          Offset(center.dx + ca * baseR, center.dy + sa * baseR),
          Offset(center.dx + ca * (baseR + len), center.dy + sa * (baseR + len)),
          paint,
        );
      }
    }
  }

  void _ring(Canvas canvas, Offset c, double r, double rot, int segments,
      Color color) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final seg = (math.pi * 2) / segments;
    for (var i = 0; i < segments; i++) {
      final start = rot + i * seg;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        start,
        seg * 0.62, // gap between segments
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) =>
      old.t != t || old.amp != amp || old.state != state;
}
