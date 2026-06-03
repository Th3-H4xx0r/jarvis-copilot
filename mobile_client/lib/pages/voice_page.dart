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
  // The single app-wide voice session (see main.voiceController). Referencing
  // the singleton — never constructing one here — guarantees there's only ever
  // one live session, so a rebuilt VoicePage can't spawn a second one.
  VoiceController get _c => app.voiceController;
  final _replyScroll = ScrollController(); // auto-scrolls the reply as it speaks
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
    // Do NOT dispose _c — it's the app-wide singleton, not owned by this page.
    _replyScroll.dispose();
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
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Voice'),
        backgroundColor: Colors.transparent,
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: ValueListenableBuilder<bool>(
              valueListenable: app.wake.enabled,
              builder: (_, on, __) => GlassIconButton(
                icon: on ? Icons.hearing : Icons.hearing_disabled,
                color: on ? JcTheme.cyan : JcTheme.muted,
                onTap: _toggleWake,
              ),
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
    // Top line: what the USER said (once they've spoken), else the soft prompt.
    final topLine = _c.userTranscript.isNotEmpty
        ? _c.userTranscript
        : _captionFor(_c.state);
    // Big centred text below the orb = the AI's reply (clean, unboxed). While
    // speaking, words light up (white) as they're voiced; the rest stay grey.
    final isError = _c.error != null;
    final reply = isError ? _c.error! : _c.assistantText;
    final spokenWords = isError ? 1 << 30 : _c.spokenWords;

    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(flex: 3),
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
                      color: Color(0xFFB8C0CE),
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 30),
                VoiceOrb(state: _c.state, amplitude: _c.amplitude, size: 248),
                const SizedBox(height: 30),
                // AI response — centred, unboxed, SCROLLABLE (long replies
                // aren't truncated) with word-by-word karaoke highlighting and
                // auto-scroll synced to the spoken audio.
                Expanded(
                  flex: 6,
                  child: reply.isNotEmpty
                      ? _KaraokeReply(
                          text: reply,
                          spokenWords: spokenWords,
                          controller: _replyScroll,
                        )
                      // Before any reply, echo the state subtly where the
                      // reply goes.
                      : Align(
                          alignment: Alignment.topCenter,
                          child: Text(
                            _c.state.label,
                            style: TextStyle(
                              color: _stateColor(_c.state),
                              fontSize: 13,
                              letterSpacing: 1.6,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                ),
                const Spacer(flex: 1),
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
      // Idle placeholder: a disabled "Done" check — the same glyph this slot
      // turns into once the mic is on and listening — so the icon doesn't jump
      // from an unrelated bookmark to a check when a turn starts.
      right = const _GhostCircle(icon: Icons.check_rounded, onTap: null);
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

/// The big central mic button — a glossy solid-blue circle inside a faint ring,
/// matching the reference. Shows a stop glyph while a session is running.
class _MicButton extends StatelessWidget {
  const _MicButton({required this.active, required this.onTap});
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 88,
        height: 88,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0x2EFFFFFF), width: 1.2),
        ),
        child: Center(
          child: Container(
            width: 66,
            height: 66,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: Alignment(-0.3, -0.4),
                radius: 1.05,
                colors: [Color(0xFF6FB0FF), Color(0xFF2E6BFF), Color(0xFF1E57DC)],
                stops: [0.0, 0.55, 1.0],
              ),
              boxShadow: [
                BoxShadow(
                  color: Color(0x662E6BFF),
                  blurRadius: 28,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(
              active ? Icons.stop_rounded : Icons.mic_rounded,
              color: Colors.white,
              size: 28,
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

/// The assistant's reply, rendered word-by-word: words already spoken are
/// white, the rest grey. Scrolls itself so the current word stays in view as
/// the audio plays. [spokenWords] is how many leading words to light up.
class _KaraokeReply extends StatefulWidget {
  const _KaraokeReply({
    required this.text,
    required this.spokenWords,
    required this.controller,
  });

  final String text;
  final int spokenWords;
  final ScrollController controller;

  @override
  State<_KaraokeReply> createState() => _KaraokeReplyState();
}

class _KaraokeReplyState extends State<_KaraokeReply> {
  static final RegExp _word = RegExp(r'\S+');
  static const _style = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w500,
    height: 1.4,
    letterSpacing: -0.2,
  );

  // A zero-size marker placed at the current spoken position INSIDE the real
  // paragraph. We scroll using its actual laid-out position (via its
  // RenderBox), not a re-measuring TextPainter — a separate painter never
  // matches the rendered paragraph's geometry exactly, so its estimate drifts
  // further off with each line and walks the active word off-screen.
  final GlobalKey _cursorKey = GlobalKey();

  int _lastScrolled = -1;
  String? _cText;
  List<List<int>> _ranges = const []; // [start, end] char range per word

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
    return SingleChildScrollView(
      controller: widget.controller,
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text.rich(
          TextSpan(children: _spans()),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  // Tokenize once per text change → list of [start, end] word ranges.
  void _ensureRanges() {
    if (_cText == widget.text) return;
    _cText = widget.text;
    _ranges = [
      for (final m in _word.allMatches(widget.text)) [m.start, m.end]
    ];
  }

  // One span per word (coloured by spoken/unspoken); whitespace passes through.
  // A zero-size keyed marker is injected at the spoken/unspoken boundary so we
  // can scroll to the word being voiced right now.
  List<InlineSpan> _spans() {
    _ensureRanges();
    final spoken = _style.copyWith(color: JcTheme.text);
    final unspoken = _style.copyWith(color: JcTheme.muted);
    final cursor = widget.spokenWords.clamp(0, _ranges.length);
    final marker = WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: SizedBox.shrink(key: _cursorKey),
    );
    final out = <InlineSpan>[];
    var last = 0;
    for (var i = 0; i < _ranges.length; i++) {
      final s = _ranges[i][0], e = _ranges[i][1];
      if (s > last) out.add(TextSpan(text: widget.text.substring(last, s)));
      if (i == cursor) out.add(marker);
      out.add(TextSpan(
        text: widget.text.substring(s, e),
        style: i < widget.spokenWords ? spoken : unspoken,
      ));
      last = e;
    }
    if (last < widget.text.length) {
      out.add(TextSpan(text: widget.text.substring(last), style: unspoken));
    }
    if (cursor >= _ranges.length) out.add(marker); // whole reply spoken
    return out;
  }

  // Keep the current word comfortably in view. Uses the marker's REAL position
  // in the viewport, and only scrolls when it drifts out of a band — so it
  // never re-centres on every word (jittery) and never lets the active word
  // leave the screen.
  void _follow() {
    final n = widget.spokenWords;
    if (n == _lastScrolled || !widget.controller.hasClients) return;
    final reset = n <= 0 || n < _lastScrolled; // new reply / rewound → top
    _lastScrolled = n;

    final ctx = _cursorKey.currentContext;
    final markerBox = ctx?.findRenderObject();
    final viewBox = Scrollable.maybeOf(ctx ?? context)?.context.findRenderObject();
    if (markerBox is! RenderBox || viewBox is! RenderBox) return;

    final pos = widget.controller.position;
    final h = viewBox.size.height;
    // Marker's y within the visible viewport (0 = top, h = bottom).
    final y = markerBox.localToGlobal(Offset.zero, ancestor: viewBox).dy;

    final double target;
    if (reset) {
      target = (pos.pixels + y).clamp(0.0, pos.maxScrollExtent);
    } else if (y >= h * 0.25 && y <= h * 0.7) {
      return; // still comfortably visible — don't scroll
    } else {
      target = (pos.pixels + (y - h * 0.4)).clamp(0.0, pos.maxScrollExtent);
    }
    if ((target - pos.pixels).abs() < 4) return;
    widget.controller.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }
}
