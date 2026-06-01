import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'voice_state.dart';

/// Voice orb — a clean, premium "living light" sphere modelled on modern
/// assistant orbs (ChatGPT Advanced Voice / Siri / Gemini): a soft-edged glowing
/// ball whose life comes from churning interior light, NOT from deforming the
/// silhouette. The result reads as a luminous sphere on near-black, never a
/// lopsided blob.
///
/// Design rules distilled from those references (all unanimous):
///   • Soft edges come from radial gradients fading alpha→0 — NEVER a stroke /
///     outline. A visible rim is the #1 "amateur" tell.
///   • A wide additive bloom halo behind the body is the biggest "premium" cue.
///   • The silhouette stays a clean circle; "alive" = drifting internal blobs +
///     gentle breathing, not a wobbling membrane.
///   • Off-center *soft* core (not a blown-out white dot) + one specular
///     highlight make it read as a lit 3D sphere.
///
/// Built on CustomPainter (not GLSL) on purpose: this app disables Impeller on
/// Android, so runtime fragment shaders aren't reliable cross-platform. Every
/// effect is plain Canvas. To stay correct on iOS (Impeller, can't disable):
/// soft edges use alpha→0 gradients (no blur), additive uses BlendMode.plus +
/// shader (fine on Impeller), and we never combine a maskFilter with a shader.
///
/// `state` drives the palette + motion character; `amplitude` drives reactivity.
/// Reactivity is shaped to how the controller feeds amplitude: a bursty ~15 Hz
/// mic *peak* while listening (smoothed here with a dt-based attack/release
/// envelope), and a constant 0.6 "talk-flag" while speaking (so speaking
/// liveliness comes from the animation clock, not the amplitude value).
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
  // The controller is just the vsync repaint pump; real time comes from the
  // stopwatch so phase + dt are continuous and frame-rate independent.
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
            // Listening uses the real (bursty) peak; speaking's 0.6 is a flag, so
            // don't let it drive the envelope — feed 0 and animate from time.
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

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.t, required this.amp, required this.state});

  final double t; // seconds (continuous)
  final double amp; // smoothed 0..1
  final VoiceState state;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final R = size.shortestSide / 2;
    final pal = state.palette; // [highlight, core, dark, accent]
    final hi = pal[0], core = pal[1], dark = pal[2], accent = pal[3];

    final breath = 0.5 + 0.5 * math.sin(t * 0.9);
    // "talk" pulse for speaking (amplitude is a flag there, so animate by time).
    final talk = 0.5 + 0.5 * math.sin(t * 3.4);

    // Per-state liveliness 0..1 + how fast the interior light churns.
    final double energy, churn;
    switch (state) {
      case VoiceState.listening:
        energy = (0.40 + 0.60 * amp).clamp(0.0, 1.0).toDouble();
        churn = 0.7 + 0.9 * amp;
      case VoiceState.speaking:
        energy = (0.58 + 0.30 * talk).clamp(0.0, 1.0).toDouble();
        churn = 1.2;
      case VoiceState.thinking:
        energy = 0.50 + 0.12 * breath;
        churn = 1.35; // introspective inner churn, decoupled from mic
      case VoiceState.connecting:
        energy = 0.38 + 0.14 * breath;
        churn = 0.9;
      case VoiceState.error:
        energy = 0.32 + 0.08 * breath;
        churn = 0.5;
      case VoiceState.idle:
        energy = 0.30 + 0.14 * breath;
        churn = 0.5;
    }

    // Restrained breathing — peak scale ~1.12 (premium references stay ≤1.35).
    final scale = 1.0 + 0.025 * breath + 0.04 * energy + amp * 0.06;
    final bodyR = R * 0.62 * scale;

    // ── 1) Bloom halo (additive, alpha→0). The biggest "premium" tell. Two
    //    passes for depth: a wide soft atmosphere + a tighter inner glow hugging
    //    the body, so the orb reads as *emitting* light rather than sitting there.
    final haloR = bodyR * (1.75 + 0.30 * energy);
    canvas.drawCircle(
      c,
      haloR,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          colors: [
            core.withValues(alpha: 0.13 + 0.22 * energy),
            accent.withValues(alpha: 0.06 + 0.12 * energy),
            const Color(0x00000000),
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: haloR)),
    );
    final innerR = bodyR * 1.22;
    canvas.drawCircle(
      c,
      innerR,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          colors: [
            Color.lerp(core, Colors.white, 0.2)!
                .withValues(alpha: 0.10 + 0.20 * energy),
            core.withValues(alpha: 0.06 + 0.10 * energy),
            const Color(0x00000000),
          ],
          stops: const [0.0, 0.6, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: innerR)),
    );

    // ── 2) Sphere body — a mid-toned, shaded ball (srcOver for solidity; soft
    //    edge = outer stop alpha 0). Deliberately NOT white in the centre: the
    //    luminous core is built by the additive plasma + core layers on top, so
    //    the interior never washes out into a blown-out blob. Lit from upper-left
    //    so it reads as a 3D sphere, shading to a dark — but transparent — edge.
    final bodyR2 = bodyR * 1.06;
    canvas.drawCircle(
      c,
      bodyR2,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.30, -0.34),
          radius: 1.0,
          colors: [
            Color.lerp(hi, core, 0.40)!.withValues(alpha: 0.96), // lit area
            core.withValues(alpha: 0.94),
            Color.lerp(core, dark, 0.62)!.withValues(alpha: 0.86), // shading
            dark.withValues(alpha: 0.0), // soft edge — no stroke, no hard rim
          ],
          stops: const [0.0, 0.40, 0.76, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: bodyR2)),
    );

    // ── 3) Internal plasma — a few drifting blurred-by-gradient colour blobs,
    //    additive so overlaps bloom into iridescent living light. Clipped to the
    //    body circle; blobs stay well inside so the clip edge is never visible
    //    (their alpha is ~0 long before the boundary → no hard seam).
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: bodyR)));
    final lobes = <_Lobe>[
      _Lobe(color: hi, orbit: 0.20, speed: 0.45, phase: 0.0, radius: 0.52),
      _Lobe(color: core, orbit: 0.22, speed: -0.34, phase: 2.1, radius: 0.48),
      _Lobe(color: accent, orbit: 0.18, speed: 0.60, phase: 4.2, radius: 0.44),
    ];
    for (final l in lobes) {
      final ang = t * l.speed * churn + l.phase;
      final drift =
          l.orbit * bodyR * (0.70 + 0.30 * math.sin(t * 0.6 * churn + l.phase));
      final lc = Offset(
        c.dx + math.cos(ang) * drift,
        c.dy + math.sin(ang) * drift * 0.9,
      );
      final lr = bodyR * l.radius * (0.80 + 0.30 * energy);
      final a = (0.20 + 0.34 * energy).clamp(0.0, 0.68).toDouble();
      canvas.drawCircle(
        lc,
        lr,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(
            colors: [
              Color.lerp(l.color, Colors.white, 0.25)!.withValues(alpha: a),
              l.color.withValues(alpha: a * 0.5),
              l.color.withValues(alpha: 0.0),
            ],
            stops: const [0.0, 0.5, 1.0],
          ).createShader(Rect.fromCircle(center: lc, radius: lr)),
      );
    }
    canvas.restore();

    // ── 4) Single soft lit core — ONE coherent bright region biased up-left
    //    toward the light, diffuse (not a hard dot, not blown-out white). This
    //    is the only highlight; a second offset hotspot reads as "eyes".
    final coreC = Offset(c.dx - bodyR * 0.12, c.dy - bodyR * 0.14);
    final coreA = (0.14 + 0.14 * energy).clamp(0.0, 0.26).toDouble();
    canvas.drawCircle(
      coreC,
      bodyR * 0.62,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          colors: [
            Color.lerp(core, Colors.white, 0.65)!.withValues(alpha: coreA),
            Color.lerp(core, Colors.white, 0.35)!
                .withValues(alpha: coreA * 0.55),
            const Color(0x00000000),
          ],
          stops: const [0.0, 0.35, 1.0],
        ).createShader(Rect.fromCircle(center: coreC, radius: bodyR * 0.62)),
    );

    // ── 5) Faint glass sheen — a wide, very-low-alpha brightening up-left (a
    //    sheen, not a glint). Sells "glass" without becoming a second dot.
    final spec = Offset(c.dx - bodyR * 0.30, c.dy - bodyR * 0.36);
    canvas.drawCircle(
      spec,
      bodyR * 0.42,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: 0.10),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: spec, radius: bodyR * 0.42)),
    );
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) =>
      old.t != t || old.amp != amp || old.state != state;
}

class _Lobe {
  const _Lobe({
    required this.color,
    required this.orbit,
    required this.speed,
    required this.phase,
    required this.radius,
  });

  /// Orbit radius (fraction of sphere radius).
  final double orbit;

  /// Angular speed (× churn); sign sets direction.
  final double speed;

  /// Lobe radius (fraction of sphere radius).
  final double radius;
  final double phase;
  final Color color;
}
