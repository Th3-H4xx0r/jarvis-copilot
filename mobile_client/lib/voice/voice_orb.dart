import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'voice_state.dart';

/// Liquid iridescent voice orb — a soft, glowing gradient blob whose surface
/// gently morphs (wobbling blob outline + drifting internal colour swirls),
/// brightening and swelling with [amplitude]. Replaces the old particle-dot
/// sphere with the frosted "liquid" look from the design references.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.state,
    required this.amplitude,
    this.size = 240,
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
    duration: const Duration(seconds: 20),
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
        builder: (context, _) {
          return CustomPaint(
            painter: _LiquidOrbPainter(
              t: _ctrl.value * 20,
              amp: widget.amplitude.value.clamp(0.0, 1.0).toDouble(),
              state: widget.state,
            ),
          );
        },
      ),
    );
  }
}

class _LiquidOrbPainter extends CustomPainter {
  _LiquidOrbPainter({required this.t, required this.amp, required this.state});

  final double t;
  final double amp;
  final VoiceState state;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final scale = size.shortestSide / 2;
    final pal = state.palette; // [inner, mid, outer, rim]
    final inner = pal[0], mid = pal[1], rim = pal[3];

    final pulsing = state == VoiceState.thinking ||
        state == VoiceState.connecting ||
        state == VoiceState.idle;
    // Breathe when idle/thinking; swell with the voice when listening/speaking.
    final swell = pulsing
        ? 0.92 + 0.05 * math.sin(t * 2.4)
        : 1 + 0.18 * amp;
    final baseR = scale * 0.74 * swell;

    // 1. Outer atmospheric glow.
    final glowR = scale * (0.98 + 0.05 * amp);
    canvas.drawCircle(
      center,
      glowR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            mid.withValues(alpha: 0.30 + 0.25 * amp),
            mid.withValues(alpha: 0.10),
            const Color(0x00000000),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: glowR)),
    );

    // 2. The liquid blob — a wobbling closed path so the rim isn't a perfect
    //    circle (organic "blob" silhouette).
    final blob = _blobPath(center, baseR, t, amp);

    // Body fill: a soft radial iridescent gradient, off-centre so it reads as a
    // lit 3D sphere. The light point drifts slowly.
    final lightAngle = t * 0.4;
    final lightOffset = Offset(
      center.dx + math.cos(lightAngle) * baseR * 0.28,
      center.dy + math.sin(lightAngle * 0.7) * baseR * 0.28,
    );
    canvas.drawPath(
      blob,
      Paint()
        ..shader = RadialGradient(
          center: Alignment(
            (lightOffset.dx - center.dx) / baseR,
            (lightOffset.dy - center.dy) / baseR,
          ),
          radius: 1.1,
          colors: [
            Color.lerp(inner, Colors.white, 0.25)!,
            inner,
            mid,
            Color.lerp(pal[2], mid, 0.4)!,
          ],
          stops: const [0.0, 0.35, 0.7, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: baseR)),
    );

    // 3. Internal colour swirls — three drifting translucent blobs (additive)
    //    give the "liquid marble" movement. Clipped to the body.
    canvas.save();
    canvas.clipPath(blob);
    canvas.saveLayer(
      Rect.fromCircle(center: center, radius: baseR),
      Paint()..blendMode = BlendMode.plus,
    );
    final swirls = [
      (rim, 0.0, 0.42, 0.55),
      (inner, 2.1, 0.55, 0.40),
      (Color.lerp(mid, rim, 0.5)!, 4.2, 0.35, 0.6),
    ];
    for (final (c, ph, rr, sp) in swirls) {
      final a = t * sp + ph;
      final pos = Offset(
        center.dx + math.cos(a) * baseR * 0.4,
        center.dy + math.sin(a * 1.3) * baseR * 0.4,
      );
      final br = baseR * rr * (0.9 + 0.1 * math.sin(t * 1.7 + ph));
      canvas.drawCircle(
        pos,
        br,
        Paint()
          ..shader = RadialGradient(
            colors: [c.withValues(alpha: 0.55), const Color(0x00000000)],
          ).createShader(Rect.fromCircle(center: pos, radius: br)),
      );
    }
    canvas.restore();
    canvas.restore();

    // 4. Glassy rim highlight — a bright thin arc at the top-left for the
    //    frosted-glass sheen.
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = scale * 0.03
      ..shader = SweepGradient(
        startAngle: math.pi * 0.9,
        endAngle: math.pi * 1.9,
        colors: [
          const Color(0x00FFFFFF),
          Colors.white.withValues(alpha: 0.5),
          const Color(0x00FFFFFF),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: baseR));
    canvas.drawPath(blob, rimPaint);

    // 5. Bright specular dot for the glassy bubble look.
    final spec = Offset(
      center.dx - baseR * 0.34,
      center.dy - baseR * 0.40,
    );
    canvas.drawCircle(
      spec,
      baseR * 0.16,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white.withValues(alpha: 0.7), const Color(0x00FFFFFF)],
        ).createShader(Rect.fromCircle(center: spec, radius: baseR * 0.16)),
    );
  }

  /// A closed wobbling blob path (sum of two low-frequency sines around the
  /// circle) so the silhouette breathes organically instead of a fixed circle.
  Path _blobPath(Offset c, double r, double t, double amp) {
    const pts = 72;
    final path = Path();
    final wob = 0.04 + 0.05 * amp; // wobble depth grows with voice
    for (var i = 0; i <= pts; i++) {
      final a = (i / pts) * math.pi * 2;
      final rad = r *
          (1 +
              wob * math.sin(a * 3 + t * 1.6) +
              wob * 0.6 * math.sin(a * 5 - t * 1.1));
      final p = Offset(c.dx + math.cos(a) * rad, c.dy + math.sin(a) * rad);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _LiquidOrbPainter old) =>
      old.t != t || old.amp != amp || old.state != state;
}
