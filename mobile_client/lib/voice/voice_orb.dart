import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'voice_state.dart';

/// Voice orb — a dark glass bubble with soft, flowing light FILAMENTS curling
/// inside it (ref: the blue "Voice Assessment" orb). The energy is wispy curved
/// strands (a few smooth Bézier ribbons that drift and breathe), not hard
/// orbital rings — so it reads as flowing light rather than a gyroscope.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.state,
    required this.amplitude,
    this.size = 248,
  });

  final VoiceState state;
  final ValueListenable<double> amplitude;
  final double size;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  )..repeat();

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
        builder: (context, _) => CustomPaint(
          painter: _OrbPainter(
            t: _ctrl.value * 2 * math.pi,
            amp: widget.amplitude.value.clamp(0.0, 1.0).toDouble(),
            state: widget.state,
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.t, required this.amp, required this.state});

  final double t;
  final double amp;
  final VoiceState state;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final R = size.shortestSide / 2;
    final pal = state.palette; // [highlight, core, dark, accent]
    final hi = pal[0], core = pal[1], accent = pal[3];

    final reactive =
        state == VoiceState.listening || state == VoiceState.speaking;
    final energy = reactive ? (0.55 + 0.45 * amp) : (0.55 + 0.07 * math.sin(t));
    final speed = reactive ? (0.6 + 1.0 * amp) : 0.45;

    final sphereR = R * 0.82;

    // 1. Outer glow halo.
    canvas.drawCircle(
      c,
      R,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0x00000000),
            core.withValues(alpha: 0.10 + 0.16 * energy),
            const Color(0x00000000),
          ],
          stops: const [0.6, 0.85, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: R)),
    );

    // 2. Dark glass bubble body (translucent, darkest at centre).
    canvas.drawCircle(
      c,
      sphereR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF04060F).withValues(alpha: 0.94),
            const Color(0xFF04060F).withValues(alpha: 0.72),
            core.withValues(alpha: 0.16),
            core.withValues(alpha: 0.30),
          ],
          stops: const [0.0, 0.45, 0.85, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: sphereR)),
    );

    // 3. Flowing light filaments — clipped to the bubble, additive so overlaps
    //    bloom. Each strand is a smooth curve whose control points orbit slowly
    //    on Lissajous paths, giving the organic "sweeping forms" of the ref.
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: sphereR)));
    canvas.saveLayer(
      Rect.fromCircle(center: c, radius: sphereR),
      Paint()..blendMode = BlendMode.plus,
    );

    final strands = <_Strand>[
      _Strand(color: hi, phase: 0.0, fx: 1.0, fy: 1.0, amp: 0.62, width: 3.2),
      _Strand(color: core, phase: 1.9, fx: 1.0, fy: 1.0, amp: 0.55, width: 2.6),
      _Strand(color: accent, phase: 3.5, fx: 1.0, fy: 1.0, amp: 0.48, width: 2.2),
      _Strand(color: hi, phase: 5.1, fx: 1.0, fy: 1.0, amp: 0.40, width: 1.8),
      _Strand(color: core, phase: 2.6, fx: 1.0, fy: 1.0, amp: 0.34, width: 1.6),
    ];
    for (final s in strands) {
      _drawStrand(canvas, c, sphereR, s, energy, speed);
    }
    canvas.restore();
    canvas.restore();

    // 4. Glass rim + top sheen + specular dot.
    canvas.drawCircle(
      c,
      sphereR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = R * 0.013
        ..shader = SweepGradient(
          startAngle: math.pi * 0.85,
          endAngle: math.pi * 2.1,
          colors: [
            const Color(0x00FFFFFF),
            Colors.white.withValues(alpha: 0.30),
            accent.withValues(alpha: 0.22),
            const Color(0x00FFFFFF),
          ],
          stops: const [0.0, 0.22, 0.6, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: sphereR)),
    );
    final spec = Offset(c.dx - sphereR * 0.32, c.dy - sphereR * 0.44);
    canvas.drawCircle(
      spec,
      sphereR * 0.20,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white.withValues(alpha: 0.20), const Color(0x00FFFFFF)],
        ).createShader(Rect.fromCircle(center: spec, radius: sphereR * 0.20)),
    );
  }

  /// One flowing filament: sample a smooth closed-ish curve whose shape is a
  /// rotating ellipse warped by two sine terms, then stroke it twice (a wide
  /// soft glow + a thin bright core) so it looks like light, not a line.
  void _drawStrand(Canvas canvas, Offset c, double R, _Strand s, double energy,
      double speed) {
    const n = 120;
    final rot = t * speed * 0.5 + s.phase;
    final cosR = math.cos(rot), sinR = math.sin(rot);

    final pts = <Offset>[];
    for (var i = 0; i <= n; i++) {
      final u = (i / n) * 2 * math.pi;
      // Base ellipse + flowing warp (the "sweeping forms").
      final rx = R * s.amp * (1 + 0.28 * math.sin(u * 2 + t * 1.3 + s.phase));
      final ry = R * s.amp * 0.62 * (1 + 0.30 * math.sin(u * 3 - t * 1.1));
      var x = math.cos(u) * rx;
      var y = math.sin(u) * ry;
      // Rotate the whole strand.
      final xr = x * cosR - y * sinR;
      final yr = x * sinR + y * cosR;
      // A little wobble so strands don't look perfectly geometric.
      final wob = 1 + 0.05 * math.sin(u * 5 + t * 1.7 + s.phase);
      pts.add(Offset(c.dx + xr * wob, c.dy + yr * wob));
    }

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }

    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = s.color.withValues(alpha: (0.20 * energy).clamp(0.0, 1.0))
      ..strokeWidth = s.width * 3.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
    final coreP = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Color.lerp(s.color, Colors.white, 0.45)!
          .withValues(alpha: (0.55 * energy).clamp(0.0, 1.0))
      ..strokeWidth = s.width
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.6);

    canvas.drawPath(path, glow);
    canvas.drawPath(path, coreP);
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) =>
      old.t != t || old.amp != amp || old.state != state;
}

class _Strand {
  const _Strand({
    required this.color,
    required this.phase,
    required this.fx,
    required this.fy,
    required this.amp,
    required this.width,
  });
  final Color color;
  final double phase, fx, fy, amp, width;
}
