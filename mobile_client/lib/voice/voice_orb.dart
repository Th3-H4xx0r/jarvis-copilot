import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'voice_state.dart';

/// Voice orb — a dark translucent glass sphere with bright flowing light
/// ribbons swirling inside it (ref: the blue "Voice Assessment" orb). Instead
/// of an opaque blob, the body is mostly transparent/dark; the energy comes
/// from layered glowing arcs that orbit in 3D and brighten/quicken with
/// [amplitude]. Colours come from [state]'s palette.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.state,
    required this.amplitude,
    this.size = 250,
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
    duration: const Duration(seconds: 16),
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
            t: _ctrl.value * 16,
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
    final center = size.center(Offset.zero);
    final R = size.shortestSide / 2;
    final pal = state.palette; // [inner, mid, outer, rim]
    final bright = pal[0];     // brightest (ribbon highlight)
    final core = pal[1];       // main colour
    final accent = pal[3];     // secondary tint

    final speed = (state == VoiceState.listening ||
            state == VoiceState.speaking)
        ? 1.0 + 1.6 * amp
        : 0.8;
    final energy = (state == VoiceState.listening ||
            state == VoiceState.speaking)
        ? 0.55 + 0.45 * amp
        : 0.5 + 0.08 * math.sin(t * 2.2);

    // 1. Outer atmospheric glow halo.
    canvas.drawCircle(
      center,
      R * (0.98 + 0.04 * amp),
      Paint()
        ..shader = RadialGradient(
          colors: [
            core.withValues(alpha: 0.0),
            core.withValues(alpha: 0.18 + 0.18 * energy),
            core.withValues(alpha: 0.0),
          ],
          stops: const [0.55, 0.82, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: R)),
    );

    // 2. Dark glass sphere body — translucent, darker at centre so the ribbons
    //    read as light INSIDE a globe (not a solid disc).
    final sphereR = R * 0.84;
    canvas.drawCircle(
      center,
      sphereR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF05060E).withValues(alpha: 0.92),
            core.withValues(alpha: 0.10),
            core.withValues(alpha: 0.18),
          ],
          stops: const [0.30, 0.80, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: sphereR)),
    );

    // 3. Flowing light ribbons — several 3D-rotated rings drawn as additive
    //    glowing bands. Each ring tilts on a different axis so they interlace
    //    like the reference's swirling threads. Clipped to the sphere.
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: sphereR)));
    canvas.saveLayer(
      Rect.fromCircle(center: center, radius: sphereR),
      Paint()..blendMode = BlendMode.plus,
    );

    final rings = <_RingSpec>[
      _RingSpec(tiltX: 0.9, tiltZ: 0.2, phase: 0.0, color: bright, rr: 0.92),
      _RingSpec(tiltX: -0.5, tiltZ: 1.1, phase: 1.7, color: core, rr: 0.80),
      _RingSpec(tiltX: 0.3, tiltZ: -0.8, phase: 3.4, color: accent, rr: 0.86),
      _RingSpec(tiltX: 1.3, tiltZ: 0.6, phase: 5.0, color: bright, rr: 0.70),
    ];
    for (final ring in rings) {
      _drawRibbon(canvas, center, sphereR * ring.rr, ring, energy, speed);
    }
    canvas.restore();
    canvas.restore();

    // 4. Glassy rim + top sheen for the bubble look.
    canvas.drawCircle(
      center,
      sphereR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = R * 0.012
        ..shader = SweepGradient(
          startAngle: math.pi * 0.85,
          endAngle: math.pi * 2.1,
          colors: [
            const Color(0x00FFFFFF),
            Colors.white.withValues(alpha: 0.35),
            accent.withValues(alpha: 0.25),
            const Color(0x00FFFFFF),
          ],
          stops: const [0.0, 0.25, 0.6, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: sphereR)),
    );
    final spec = Offset(center.dx - sphereR * 0.30, center.dy - sphereR * 0.42);
    canvas.drawCircle(
      spec,
      sphereR * 0.22,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white.withValues(alpha: 0.22), const Color(0x00FFFFFF)],
        ).createShader(Rect.fromCircle(center: spec, radius: sphereR * 0.22)),
    );
  }

  /// Draws one tilted ring as a glowing ribbon: sample points around a circle,
  /// rotate into 3D (tilt + spin), project to 2D, stroke with depth-faded alpha
  /// and a soft blur so it reads as light, not a hard line.
  void _drawRibbon(Canvas canvas, Offset c, double r, _RingSpec ring,
      double energy, double speed) {
    const n = 96;
    final spin = t * 0.6 * speed + ring.phase;
    final cosT = math.cos(ring.tiltX), sinT = math.sin(ring.tiltX);
    final cosZ = math.cos(ring.tiltZ), sinZ = math.sin(ring.tiltZ);

    // Build the projected points with their depth (z), so we can fade the back.
    final pts = <Offset>[];
    final depths = <double>[];
    for (var i = 0; i <= n; i++) {
      final a = (i / n) * math.pi * 2 + spin;
      var x = math.cos(a) * r;
      var y = math.sin(a) * r;
      var z = 0.0;
      // tilt around X
      final y1 = y * cosT - z * sinT;
      final z1 = y * sinT + z * cosT;
      // tilt around Z
      final x2 = x * cosZ - y1 * sinZ;
      final y2 = x * sinZ + y1 * cosZ;
      pts.add(Offset(c.dx + x2, c.dy + y2));
      depths.add((z1 / r + 1) / 2); // 0 back .. 1 front
    }

    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    final crisp = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    for (var i = 0; i < n; i++) {
      final d = (depths[i] + depths[i + 1]) / 2;
      // Front of the ring is bright; back fades — gives the 3D weave.
      final aGlow = (0.05 + 0.45 * d) * energy;
      final aCrisp = (0.10 + 0.7 * d) * energy;
      final w = (1.5 + 3.5 * d);
      glow
        ..color = ring.color.withValues(alpha: aGlow.clamp(0.0, 1.0))
        ..strokeWidth = w * 2.2;
      crisp
        ..color = Color.lerp(ring.color, Colors.white, 0.35 * d)!
            .withValues(alpha: aCrisp.clamp(0.0, 1.0))
        ..strokeWidth = w;
      canvas.drawLine(pts[i], pts[i + 1], glow);
      canvas.drawLine(pts[i], pts[i + 1], crisp);
    }
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) =>
      old.t != t || old.amp != amp || old.state != state;
}

class _RingSpec {
  const _RingSpec({
    required this.tiltX,
    required this.tiltZ,
    required this.phase,
    required this.color,
    required this.rr,
  });
  final double tiltX, tiltZ, phase, rr;
  final Color color;
}
