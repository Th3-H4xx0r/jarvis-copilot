import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../main.dart' as app;
import '../theme.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_orb.dart';
import '../voice/voice_state.dart';
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
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _c,
          builder: (context, _) => _buildBody(),
        ),
      ),
    );
  }

  Widget _buildBody() {
    // Top line: what the USER said (once they've spoken), else the soft prompt.
    final topLine = _c.userTranscript.isNotEmpty
        ? _c.userTranscript
        : _captionFor(_c.state);
    // Big centred text below the orb = the AI's reply (clean, unboxed).
    final reply = _c.error != null
        ? _c.error!
        : _plainSpeech(_c.assistantText);

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(flex: 2),
                // User-spoken text / prompt — quiet, single line up top.
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    topLine,
                    key: ValueKey(topLine),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: JcTheme.muted,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                VoiceOrb(state: _c.state, amplitude: _c.amplitude, size: 248),
                const SizedBox(height: 32),
                // AI response — large, centred, unboxed (the focal text).
                if (reply.isNotEmpty)
                  Text(
                    reply,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: JcTheme.text,
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                      letterSpacing: -0.2,
                    ),
                  )
                else
                  // Before any reply, echo the state subtly where the reply goes.
                  Text(
                    _c.state.label,
                    style: TextStyle(
                      color: _stateColor(_c.state),
                      fontSize: 13,
                      letterSpacing: 1.6,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                const Spacer(flex: 3),
              ],
            ),
          ),
        ),
        _Controls(controller: _c, onPrimary: _onPrimary),
        SizedBox(height: 12 + MediaQuery.of(context).viewPadding.bottom),
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

/// Soft conversational prompt shown above the orb, per state.
String _captionFor(VoiceState s) {
  switch (s) {
    case VoiceState.idle:
      return 'Tap the mic to start talking';
    case VoiceState.connecting:
      return 'Connecting…';
    case VoiceState.listening:
      return "Go ahead, I'm listening…";
    case VoiceState.thinking:
      return 'Thinking it through…';
    case VoiceState.speaking:
      return 'Speaking…';
    case VoiceState.error:
      return 'Something went wrong — tap to retry';
  }
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
class _Controls extends StatelessWidget {
  const _Controls({required this.controller, required this.onPrimary});

  final VoiceController controller;
  final VoidCallback onPrimary;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final active = c.active;
    final speakingOrThinking = c.state == VoiceState.speaking ||
        c.state == VoiceState.thinking;

    // Left ghost button: Mute (only while a session is live).
    final left = active
        ? _GhostCircle(
            icon: c.muted ? Icons.mic_off : Icons.mic_none,
            highlighted: c.muted,
            onTap: c.toggleMute,
          )
        : const _GhostCircle(icon: Icons.mic_none, onTap: null);

    // Right ghost button: Done (while listening) / Interrupt (while speaking).
    Widget right;
    if (active && c.state == VoiceState.listening) {
      right = _GhostCircle(icon: Icons.check_rounded, onTap: c.finishSpeaking);
    } else if (active && speakingOrThinking) {
      right = _GhostCircle(icon: Icons.stop_rounded, onTap: c.interrupt);
    } else {
      right = const _GhostCircle(icon: Icons.bookmark_border_rounded, onTap: null);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 4, 36, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          left,
          _MicButton(active: active, onTap: onPrimary),
          right,
        ],
      ),
    );
  }
}

/// The big central mic button — gradient ring + filled mic. Turns to a stop
/// glyph (red ring) while a session is running.
class _MicButton extends StatelessWidget {
  const _MicButton({required this.active, required this.onTap});
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 78,
        height: 78,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: iridescentGradient(),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF3A86FF).withValues(alpha: 0.5),
              blurRadius: 28,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF0B0E1C),
            ),
            child: Icon(
              active ? Icons.stop_rounded : Icons.mic_rounded,
              color: Colors.white,
              size: 30,
            ),
          ),
        ),
      ),
    );
  }
}

/// A small frosted ghost circle for the side actions.
class _GhostCircle extends StatelessWidget {
  const _GhostCircle({required this.icon, this.onTap, this.highlighted = false});
  final IconData icon;
  final VoidCallback? onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: highlighted ? JcTheme.accent.withValues(alpha: 0.18) : JcTheme.glassFill,
            border: Border.all(color: JcTheme.glassBorder),
          ),
          child: Icon(icon,
              color: highlighted ? JcTheme.accent : JcTheme.text, size: 22),
        ),
      ),
    );
  }
}
