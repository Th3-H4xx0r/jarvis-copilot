import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'voice_state.dart';

/// Flowing multi-line audio waveform (ref: the Siri-style ribbon). Several
/// overlaid sine bands of slightly different frequency/phase, their amplitude
/// driven by [amplitude] (mic RMS while listening, playback envelope while
/// speaking). Coloured from the active [state]'s palette so it matches the orb.
class VoiceWaveform extends StatefulWidget {
  const VoiceWaveform({
    super.key,
    required this.state,
    required this.amplitude,
    this.height = 120,
  });

  final VoiceState state;
  final ValueListenable<double> amplitude;
  final double height;

  @override
  State<VoiceWaveform> createState() => _VoiceWaveformState();
}

class _VoiceWaveformState extends State<VoiceWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 8),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      width: double.infinity,
      child: AnimatedBuilder(
        animation: Listenable.merge([_ctrl, widget.amplitude]),
        builder: (context, _) => CustomPaint(
          painter: _WavePainter(
            t: _ctrl.value * 8,
            amp: widget.amplitude.value.clamp(0.0, 1.0).toDouble(),
            state: widget.state,
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.t, required this.amp, required this.state});

  final double t;
  final double amp;
  final VoiceState state;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final pal = state.palette;
    // Three bands tinted across the iridescent range (inner, mid, rim).
    final bands = <(Color, double, double, double)>[
      (pal[1], 1.0, 1.0, 0.0),   // mid colour, base freq
      (pal[0], 0.7, 1.6, 1.3),   // inner colour, higher freq, phase shift
      (pal[3], 0.5, 0.7, 2.4),   // rim colour, lower freq
    ];

    // Idle/connecting/thinking: gentle self-motion. Listening/speaking: swell
    // with amplitude so it visibly reacts to the voice.
    final reactive = state == VoiceState.listening ||
        state == VoiceState.speaking;
    // Boost sensitivity: a gentle curve (sqrt) lifts quiet speech, and a higher
    // ceiling makes loud speech swing wide. Reactive states are far more lively.
    final env = reactive
        ? math.max(0.18, math.sqrt(amp) * 1.35).clamp(0.0, 1.4)
        : 0.16 + 0.05 * math.sin(t * 2.0);

    for (final (color, ampScale, freqScale, phase) in bands) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..color = color.withValues(alpha: 0.85);
      final path = Path();
      // Fewer steps = cheaper repaint (was 64) — smoother on device.
      const steps = 44;
      for (var i = 0; i <= steps; i++) {
        final x = size.width * i / steps;
        final nx = i / steps;
        // Taper amplitude toward the edges so the ribbon pinches at the ends.
        final taper = math.sin(nx * math.pi);
        final wave = math.sin(nx * math.pi * 2 * (2.2 * freqScale) +
            t * 3.0 * freqScale + phase);
        final y = mid +
            wave * taper * size.height * 0.38 * env * ampScale;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.t != t || old.amp != amp || old.state != state;
}
