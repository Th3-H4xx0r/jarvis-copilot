import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'voice_state.dart';

/// Voice orb — a glassy globe with flowing translucent light *ribbons* sweeping
/// around a dark hollow interior, plus a bright fresnel rim. Modelled directly
/// on the design template: elegant silk-like bands of light (not a glowing ball,
/// not a tangle of thin threads) wrapping a transparent sphere.
///
/// How it's built (and why it reads as 3D silk on a 2D canvas):
///   • each ribbon is a wavy loop on a unit sphere (elevation oscillates as it
///     goes around), tilted in 3D and orthographically projected;
///   • it's drawn as a filled BAND — the centerline offset ± a half-width that
///     GROWS where the ribbon faces the viewer (depth) — so it reads as a flat
///     sheet folding through space;
///   • each ribbon = a soft wide glow + a brighter defined sheet + a bright edge
///     (the silk fold catching light), depth-shaded; ribbons are drawn back-to-
///     front so the additive light layers correctly.
///
/// Pure CustomPainter (this app disables Impeller on Android, so runtime shaders
/// aren't reliable). iOS runs Impeller — so soft edges use `MaskFilter.blur` on
/// SOLID-colour paints only (never combined with a shader), and everything
/// composites additively via `BlendMode.plus`. The dark interior is simply the
/// absence of light on the near-black canvas.
///
/// `state` drives the palette + motion (spin/undulation/brightness); `amplitude`
/// (smoothed here with a dt-based attack/release envelope) drives reactivity.
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
    duration: const Duration(seconds: 1),
  )..repeat();
  final Stopwatch _clock = Stopwatch()..start();

  double _amp = 0.0; // smoothed amplitude envelope (0..1)
  double _lastT = 0.0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // One-pole envelope: fast attack, slow release, frame-rate independent.
  double _smooth(double target, double dt) {
    const attack = 0.06, release = 0.28; // seconds
    final tau = target > _amp ? attack : release;
    final k = 1 - math.exp(-dt / math.max(tau, 1e-3));
    _amp += (target - _amp) * k.clamp(0.0, 1.0);
    return _amp;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_ctrl, widget.amplitude]),
          builder: (context, _) {
            final tSec = _clock.elapsedMicroseconds / 1e6;
            final dt = (tSec - _lastT).clamp(0.0, 0.1);
            _lastT = tSec;
            final raw = widget.state == VoiceState.listening
                ? widget.amplitude.value.clamp(0.0, 1.0).toDouble()
                : 0.0;
            final amp = _smooth(raw, dt);
            return CustomPaint(
              painter: _OrbPainter(t: tSec, amp: amp, state: widget.state),
            );
          },
        ),
      ),
    );
  }
}

/// A flowing ribbon as a wavy loop on a sphere, tilted in 3D. `amp` = elevation
/// wave depth, `k` = number of waves, `phase` = where the wave starts, and
/// (rx,ry,rz) tilt the whole loop so the set weaves together like silk.
class _Strand {
  const _Strand(this.amp, this.k, this.phase, this.rx, this.ry, this.rz);
  final double amp;
  final int k;
  final double phase;
  final double rx, ry, rz;
}

const _strands = <_Strand>[
  _Strand(0.20, 2, 0.0, 0.55, 0.30, 0.15),
  _Strand(0.26, 2, 2.1, 0.72, 0.58, 0.10),
  _Strand(0.18, 1, 4.2, 0.42, 0.85, 0.22),
];

class _Built {
  _Built(this.pts, this.depth, this.meanFront);
  final List<Offset> pts; // projected screen points (closed loop)
  final List<double> depth; // z in -1..1 per point
  final double meanFront; // 0 (back) .. 1 (front), mean over the loop
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.t, required this.amp, required this.state});

  final double t; // seconds (continuous)
  final double amp; // smoothed 0..1
  final VoiceState state;

  static const int _m = 120; // points per ribbon loop

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final R = size.shortestSide / 2;
    final pal = state.palette; // [highlight, core, dark, accent]
    final hi = pal[0], core = pal[1], accent = pal[3];

    final breath = 0.5 + 0.5 * math.sin(t * 0.9);
    final talk = 0.5 + 0.5 * math.sin(t * 3.4);

    double energy;
    switch (state) {
      case VoiceState.listening:
        energy = (0.42 + 0.58 * amp).clamp(0.0, 1.0).toDouble();
      case VoiceState.speaking:
        energy = (0.58 + 0.30 * talk).clamp(0.0, 1.0).toDouble();
      case VoiceState.thinking:
        energy = 0.55 + 0.12 * breath;
      case VoiceState.connecting:
        energy = 0.40 + 0.14 * breath;
      case VoiceState.error:
        energy = 0.34 + 0.08 * breath;
      case VoiceState.idle:
        energy = 0.34 + 0.14 * breath;
    }

    final scale = 1.0 + 0.02 * breath + 0.03 * energy + amp * 0.04;
    final rs = R * 0.60 * scale; // projected sphere radius
    final bright = (0.82 + 0.34 * energy).clamp(0.0, 1.3).toDouble();
    final gt = t * (0.12 + 0.45 * energy); // global spin
    final undu = t * 0.30; // ribbon undulation

    // Build + depth-sort (back → front) so additive light stacks correctly.
    final built = [for (final s in _strands) _build(s, c, rs, gt, undu)]
      ..sort((a, b) => a.meanFront.compareTo(b.meanFront));

    // ── Outer halo glow ───────────────────────────────────────────────
    final haloR = rs * 1.7;
    canvas.drawCircle(
      c,
      haloR,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          colors: [
            core.withValues(alpha: 0.20 * bright),
            accent.withValues(alpha: 0.08 * bright),
            const Color(0x00000000),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: haloR)),
    );

    // ── Ribbons ───────────────────────────────────────────────────────
    final sheetCol = Color.lerp(core, hi, 0.4)!;
    final edgeCol = Color.lerp(hi, Colors.white, 0.5)!;
    final halfBase = rs * 0.17 * (1.0 + 0.10 * amp);
    for (final b in built) {
      final band = _ribbonPath(b, halfBase);

      // soft wide glow (the ribbon's aura)
      canvas.drawPath(
        band,
        Paint()
          ..blendMode = BlendMode.plus
          ..color = core.withValues(
              alpha: ((0.10 + 0.10 * b.meanFront) * bright).clamp(0.0, 0.5))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, rs * 0.06),
      );
      // defined translucent sheet
      canvas.drawPath(
        band,
        Paint()
          ..blendMode = BlendMode.plus
          ..color = sheetCol.withValues(
              alpha: ((0.22 + 0.16 * b.meanFront) * bright).clamp(0.0, 0.7))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, rs * 0.022),
      );
      // bright edge (silk fold catching light), depth-split front/back
      final (frontEdge, backEdge) = _edgePaths(b);
      canvas.drawPath(
        backEdge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = rs * 0.012
          ..blendMode = BlendMode.plus
          ..color = edgeCol.withValues(alpha: (0.22 * bright).clamp(0.0, 0.5))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, rs * 0.010),
      );
      canvas.drawPath(
        frontEdge,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = rs * 0.016
          ..blendMode = BlendMode.plus
          ..color = edgeCol.withValues(alpha: (0.55 * bright).clamp(0.0, 0.85))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, rs * 0.008),
      );
    }

    // ── Fresnel rim — bright soft ring at the sphere edge, brighter up-top ──
    final rimCol = Color.lerp(core, Colors.white, 0.5)!;
    final rimRect = Rect.fromCircle(center: c, radius: rs);
    canvas.drawCircle(
      c,
      rs,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = rs * 0.03
        ..blendMode = BlendMode.plus
        ..color = rimCol.withValues(alpha: (0.40 * bright).clamp(0.0, 0.7))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, rs * 0.05),
    );
    // top emphasis arc (no gradient needed → Impeller-safe)
    canvas.drawArc(
      rimRect,
      -math.pi + 0.25,
      math.pi - 0.5,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = rs * 0.045
        ..strokeCap = StrokeCap.round
        ..blendMode = BlendMode.plus
        ..color = rimCol.withValues(alpha: (0.38 * bright).clamp(0.0, 0.7))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, rs * 0.05),
    );
  }

  /// Generate one ribbon: wavy loop on a unit sphere → 3D tilt → ortho project.
  _Built _build(_Strand s, Offset c, double rs, double gt, double undu) {
    final cx = math.cos(s.rx), sx = math.sin(s.rx);
    final cy = math.cos(s.ry), sy = math.sin(s.ry);
    final cz = math.cos(s.rz), sz = math.sin(s.rz);
    final pts = <Offset>[];
    final depth = <double>[];
    var sumFront = 0.0;
    for (var i = 0; i < _m; i++) {
      final u = (i / _m) * 2 * math.pi;
      final theta = math.pi / 2 + s.amp * math.sin(s.k * u + s.phase + undu);
      final phi = u + gt;
      var x = math.sin(theta) * math.cos(phi);
      var y = math.sin(theta) * math.sin(phi);
      var z = math.cos(theta);
      // Rx
      var y1 = y * cx - z * sx, z1 = y * sx + z * cx;
      y = y1;
      z = z1;
      // Ry
      var x1 = x * cy + z * sy, z2 = -x * sy + z * cy;
      x = x1;
      z = z2;
      // Rz
      var x2 = x * cz - y * sz, y2 = x * sz + y * cz;
      x = x2;
      y = y2;
      pts.add(Offset(c.dx + rs * x, c.dy - rs * y));
      depth.add(z);
      sumFront += (z + 1) / 2;
    }
    return _Built(pts, depth, sumFront / _m);
  }

  /// Build the filled band: offset the centerline ± a half-width along the 2D
  /// normal; half-width grows toward the front so the sheet "folds" in space.
  Path _ribbonPath(_Built b, double halfBase) {
    final n = b.pts.length;
    final left = <Offset>[];
    final right = <Offset>[];
    for (var i = 0; i < n; i++) {
      final p = b.pts[i];
      final pp = b.pts[(i - 1 + n) % n];
      final pn = b.pts[(i + 1) % n];
      var tx = pn.dx - pp.dx, ty = pn.dy - pp.dy;
      final len = math.sqrt(tx * tx + ty * ty);
      if (len > 1e-6) {
        tx /= len;
        ty /= len;
      }
      final nx = -ty, ny = tx;
      final df = (b.depth[i] + 1) / 2;
      final hw = halfBase * (0.35 + 0.75 * df);
      left.add(Offset(p.dx + nx * hw, p.dy + ny * hw));
      right.add(Offset(p.dx - nx * hw, p.dy - ny * hw));
    }
    final path = Path()..moveTo(left[0].dx, left[0].dy);
    for (var i = 1; i < n; i++) {
      path.lineTo(left[i].dx, left[i].dy);
    }
    for (var i = n - 1; i >= 0; i--) {
      path.lineTo(right[i].dx, right[i].dy);
    }
    return path..close();
  }

  /// Split the centerline into front (z≥0) and back (z<0) polylines so the front
  /// edge can be drawn brighter than the part seen through the glass.
  (Path, Path) _edgePaths(_Built b) {
    final n = b.pts.length;
    final front = Path();
    final back = Path();
    bool fOpen = false, bOpen = false;
    for (var i = 0; i <= n; i++) {
      final idx = i % n;
      final isFront = b.depth[idx] >= -0.05;
      final p = b.pts[idx];
      if (isFront) {
        if (!fOpen) {
          front.moveTo(p.dx, p.dy);
          fOpen = true;
        } else {
          front.lineTo(p.dx, p.dy);
        }
        bOpen = false;
      } else {
        if (!bOpen) {
          back.moveTo(p.dx, p.dy);
          bOpen = true;
        } else {
          back.lineTo(p.dx, p.dy);
        }
        fOpen = false;
      }
    }
    return (front, back);
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) =>
      old.t != t || old.amp != amp || old.state != state;
}
