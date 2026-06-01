import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../main.dart' as app;
import '../theme.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_orb.dart';
import '../voice/voice_state.dart';
import '../voice/voice_waveform.dart';
import '../widgets/glass.dart';

/// Native voice screen — a recreation of the webui voice experience:
/// a state-coloured orb, live transcript, and two modes (push-to-talk
/// "Quality" and continuous "Realtime").
class VoicePage extends StatefulWidget {
  const VoicePage({super.key});

  @override
  State<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends State<VoicePage> with WidgetsBindingObserver {
  late final VoiceController _c = VoiceController(app.api);
  bool _waitingForSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    app.voiceLaunchRequested.addListener(_onVoiceLaunch);
    _c.addListener(_manageWake);
    // Cold launch via Siri may have latched the request before we mounted.
    if (app.voiceLaunchRequested.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _onVoiceLaunch());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    app.voiceLaunchRequested.removeListener(_onVoiceLaunch);
    _c.removeListener(_manageWake);
    _c.dispose();
    super.dispose();
  }

  // Keep the app-wide wake word in sync with turns: the mic can't be
  // shared, so release it while a turn runs and resume when idle.
  void _manageWake() {
    if (_c.active) {
      app.wake.suppress();
    } else {
      app.wake.resume();
    }
  }

  Future<void> _toggleWake() async {
    if (app.wake.enabled.value) {
      await app.wake.setEnabled(false);
      return;
    }
    final ok = await app.wake.setEnabled(true);
    if (!ok) await _showMicDialog();
  }

  // Siri intent / wake word latched a request: go realtime and start.
  void _onVoiceLaunch() {
    if (!mounted || !app.voiceLaunchRequested.value) return;
    app.voiceLaunchRequested.value = false; // consume
    app.wake.suppress(); // release the wake mic before recording
    if (_c.mode != VoiceMode.realtime) _c.setMode(VoiceMode.realtime);
    if (!_c.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_c.active) _onPrimary();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) async {
    if (s == AppLifecycleState.resumed && _waitingForSettings) {
      _waitingForSettings = false;
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      if (await Permission.microphone.isGranted) {
        _c.primaryAction();
      }
      return;
    }
    // Leave playback + the WS running in the background so the reply
    // keeps speaking; just pause mic capture (resumed on return).
    if (s == AppLifecycleState.paused) {
      _c.pauseForBackground();
    } else if (s == AppLifecycleState.resumed) {
      _c.resumeFromBackground();
    }
  }

  Future<void> _onPrimary() async {
    // Stopping never needs permission.
    final stopping = _c.active &&
        (_c.mode == VoiceMode.realtime || _c.state == VoiceState.listening);
    if (stopping) {
      _c.primaryAction();
      return;
    }
    if (await _c.ensureMic()) {
      _c.primaryAction();
    } else {
      await _showMicDialog();
    }
  }

  Future<void> _showMicDialog() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: JcTheme.surface,
        title: const Text('Enable Microphone',
            style: TextStyle(color: JcTheme.text)),
        content: const Text(
          "iOS has blocked microphone access for JarvisCopilot, so the "
          "system prompt won't appear again. Tap Open Settings, turn on "
          "Microphone, then come back — the mic will start automatically.",
          style: TextStyle(color: JcTheme.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _waitingForSettings = true;
              openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: JcTheme.bg,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Voice'),
        backgroundColor: Colors.transparent,
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: app.wake.enabled,
            builder: (_, on, __) => IconButton(
              tooltip: on
                  ? 'Wake word on ("Hey Jarvis") — foreground only'
                  : 'Enable "Hey Jarvis" wake word',
              icon: Icon(
                on ? Icons.hearing : Icons.hearing_disabled,
                color: on ? JcTheme.cyan : JcTheme.muted,
              ),
              onPressed: _toggleWake,
            ),
          ),
        ],
      ),
      body: AppBackground(
        child: SafeArea(
          child: ListenableBuilder(
            listenable: _c,
            builder: (context, _) => _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    return Column(
      children: [
        const SizedBox(height: 8),
        _ModeToggle(
          mode: _c.mode,
          enabled: !_c.active,
          onChanged: _c.setMode,
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              children: [
                const SizedBox(height: 10),
                VoiceOrb(
                  state: _c.state,
                  amplitude: _c.amplitude,
                  size: 240,
                ),
                const SizedBox(height: 4),
                // Reactive waveform ribbon under the orb (ref Siri-style).
                VoiceWaveform(
                  state: _c.state,
                  amplitude: _c.amplitude,
                  height: 84,
                ),
                const SizedBox(height: 8),
                // State label in a frosted-glass pill.
                GlassCard(
                  blur: false,
                  radius: 999,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                  child: Text(
                    (_c.toolStatus ?? _c.state.label).toUpperCase(),
                    style: TextStyle(
                      color: _stateColor(_c.state),
                      fontSize: 11,
                      letterSpacing: 1.8,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                if (_c.userTranscript.isNotEmpty)
                  _TranscriptRow(text: _c.userTranscript, role: 'user'),
                if (_c.assistantText.isNotEmpty)
                  _TranscriptRow(
                      text: _plainSpeech(_c.assistantText), role: 'assistant'),
                if (_c.error != null) _ErrorBanner(message: _c.error!),
              ],
            ),
          ),
        ),
        _Controls(controller: _c, onPrimary: _onPrimary),
        SizedBox(height: 8 + MediaQuery.of(context).viewPadding.bottom),
      ],
    );
  }
}

/// Strip markdown so the transcript bubble reads like clean speech —
/// matches what the server now synthesizes (see voice.py `_speakable`).
String _plainSpeech(String text) {
  var s = text.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
  s = s.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!);
  s = s.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m[1]!);
  s = s.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
  s = s.replaceAll(RegExp(r'^\s{0,3}>\s?', multiLine: true), '');
  s = s.replaceAll(RegExp(r'^\s{0,3}[-*+]\s+', multiLine: true), '');
  s = s.replaceAll(RegExp(r'\*\*|\*|__|_|~~|`'), '');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}

Color _stateColor(VoiceState s) {
  switch (s) {
    case VoiceState.listening:
      return JcTheme.cyan;
    case VoiceState.thinking:
    case VoiceState.connecting:
      return JcTheme.accent;
    case VoiceState.speaking:
      return JcTheme.accentAlt;
    case VoiceState.error:
      return JcTheme.danger;
    case VoiceState.idle:
      return JcTheme.muted;
  }
}

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  final VoiceMode mode;
  final bool enabled;
  final ValueChanged<VoiceMode> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget seg(VoiceMode m, String label) {
      final active = m == mode;
      return Expanded(
        child: GestureDetector(
          onTap: enabled && !active ? () => onChanged(m) : null,
          child: Container(
            margin: const EdgeInsets.all(2),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: active ? JcTheme.accent.withValues(alpha: 0.16) : null,
              borderRadius: BorderRadius.circular(7),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: active ? JcTheme.accent : JcTheme.muted,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }

    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        width: 240,
        decoration: BoxDecoration(
          color: JcTheme.surface,
          border: Border.all(color: JcTheme.border),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          children: [
            seg(VoiceMode.quality, 'Push-to-talk'),
            seg(VoiceMode.realtime, 'Realtime'),
          ],
        ),
      ),
    );
  }
}

class _TranscriptRow extends StatelessWidget {
  const _TranscriptRow({required this.text, required this.role});
  final String text;
  final String role;

  @override
  Widget build(BuildContext context) {
    final isUser = role == 'user';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isUser
            ? Colors.white.withValues(alpha: 0.05)
            : JcTheme.blue.withValues(alpha: 0.08),
        border: Border.all(
          color: isUser
              ? Colors.white.withValues(alpha: 0.08)
              : JcTheme.blue.withValues(alpha: 0.20),
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isUser ? 'You' : 'JarvisCopilot',
            style: TextStyle(
              color: isUser ? JcTheme.muted : JcTheme.blue,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            text,
            style: const TextStyle(
              color: JcTheme.text,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: JcTheme.danger.withValues(alpha: 0.08),
        border: Border.all(color: JcTheme.danger.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: const TextStyle(color: JcTheme.danger, fontSize: 13),
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.controller, required this.onPrimary});

  final VoiceController controller;
  final VoidCallback onPrimary;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final thinking = c.state == VoiceState.thinking ||
        c.state == VoiceState.connecting;

    // Primary button label.
    String label;
    IconData icon;
    if (c.mode == VoiceMode.quality) {
      if (c.state == VoiceState.listening) {
        label = 'Stop & send';
        icon = Icons.send;
      } else {
        label = 'Tap to talk';
        icon = Icons.mic;
      }
    } else {
      label = c.active ? 'Stop' : 'Start';
      icon = c.active ? Icons.stop : Icons.graphic_eq;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _PrimaryButton(
                label: label,
                icon: icon,
                busy: thinking && c.mode == VoiceMode.quality,
                danger: c.mode == VoiceMode.realtime && c.active,
                onTap: thinking && c.mode == VoiceMode.quality
                    ? null
                    : onPrimary,
              ),
              // Realtime secondary controls.
              if (c.mode == VoiceMode.realtime && c.active) ...[
                const SizedBox(width: 10),
                if (c.state == VoiceState.listening)
                  _SecondaryButton(
                    label: 'Done',
                    onTap: c.finishSpeaking,
                  )
                else if (c.state == VoiceState.speaking ||
                    c.state == VoiceState.thinking)
                  _SecondaryButton(
                    label: 'Interrupt',
                    onTap: c.interrupt,
                  ),
                const SizedBox(width: 10),
                _SecondaryButton(
                  label: c.muted ? 'Unmute' : 'Mute',
                  active: c.muted,
                  onTap: c.toggleMute,
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            c.mode == VoiceMode.quality
                ? 'Tap to record, tap again to send.'
                : 'Speak naturally — it listens and replies continuously.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: JcTheme.muted, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.busy = false,
    this.danger = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null && !busy ? 0.6 : 1,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: BoxDecoration(
            gradient: danger ? null : JcTheme.brandGradient,
            color: danger ? JcTheme.surfaceAlt : null,
            border: danger ? Border.all(color: JcTheme.danger) : null,
            borderRadius: BorderRadius.circular(999),
            boxShadow: danger
                ? null
                : const [
                    BoxShadow(
                      color: Color(0x55E0552B),
                      blurRadius: 18,
                      offset: Offset(0, 6),
                    ),
                  ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Colors.black),
                  ),
                )
              else
                Icon(icon, size: 20, color: danger ? JcTheme.danger : Colors.black),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: danger ? JcTheme.danger : Colors.black,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: active ? JcTheme.accent.withValues(alpha: 0.14) : JcTheme.surface,
          border: Border.all(
            color: active ? JcTheme.accent : JcTheme.border,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? JcTheme.accent : JcTheme.text,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
