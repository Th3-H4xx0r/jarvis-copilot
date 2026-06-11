import 'dart:async';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../services/app_lifecycle.dart';
import '../theme.dart';
import '../widgets/glass.dart';
import '../widgets/markdown_stream.dart';
import 'coding_attach.dart';
import 'coding_controller.dart';
import 'coding_models.dart';

/// Chat mode for the Coding session detail — renders the session's
/// conversation (a Claude Code transcript) like the Claude Code mobile app:
/// user bubbles right, assistant text left, tool uses as compact collapsible
/// cards, with a live state chip in the header and an interactive-prompt
/// bottom sheet when Claude is waiting for input.
///
/// IMPORTANT: this view does NOT own a transport of its own. The terminal PTY
/// (started by the page / [CodingSessionsController.startTerminal]) stays
/// alive underneath and IS the input channel: free text = bytes + `\r`,
/// option key = just the key, Esc = `\x1b`, Enter = `\r` — all through
/// [CodingSessionsController.sendTerminalInput]. The transcript itself is
/// polled from `/api/coding/session/$id/messages` (incremental via `after`)
/// every ~3s while this view is mounted.
class CodingChatView extends StatefulWidget {
  const CodingChatView({
    super.key,
    required this.controller,
    required this.sessionId,
  });

  final CodingSessionsController controller;
  final String sessionId;

  @override
  State<CodingChatView> createState() => _CodingChatViewState();
}

class _CodingChatViewState extends State<CodingChatView> {
  // Adaptive poll: snappy while a turn is live, relaxed when idle.
  static const Duration _pollActive = Duration(milliseconds: 1200);
  static const Duration _pollIdle = Duration(seconds: 4);
  int _fetchTick = 0; // every Nth incremental poll does a full reconcile

  final List<CodingChatMessage> _messages = [];
  String? _activityState; // working | waiting | idle | null
  String _status = '';
  bool _loading = true; // first fetch in flight
  bool _noTranscript = false; // server replied 409
  bool _fetching = false;
  Timer? _poll;

  // Auto-scroll: stick to the bottom unless the user scrolled up.
  final ScrollController _scroll = ScrollController();
  bool _stickToBottom = true;

  // Interactive-prompt (waiting) handling.
  CodingPromptState? _prompt;
  String? _dismissedPromptSig; // user closed the sheet for this prompt
  bool _promptOpen = false;
  bool _promptFetching = false;

  final TextEditingController _input = TextEditingController();

  bool get _isWaiting => _activityState == 'waiting';

  String? _statusLine; // live spinner line while working
  ChatContext? _context; // per-chat context-window gauge

  // Messages the user sent that haven't appeared in the transcript yet —
  // rendered as "queued" bubbles so steering/queueing while Claude works has
  // immediate visible feedback.
  final List<_PendingSend> _pendingSends = [];

  // Optimistic "Claude is working" right after WE send something: the pane
  // scan takes ~5s to flip the stored state, and without this the thinking
  // bubble shows nothing exactly when feedback matters most.
  DateTime? _localWorkingUntil;

  bool get _showThinking {
    if (_isWaiting || _messages.isEmpty) return false;
    if (_activityState == 'working') return true;
    final until = _localWorkingUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  bool _thinkingShown = false;

  /// Re-evaluate the bubble + auto-scroll when it APPEARS (a new list row at
  /// the bottom never triggers the message-driven scroll).
  void _syncThinking() {
    final now = _showThinking;
    if (now != _thinkingShown) {
      _thinkingShown = now;
      if (mounted) setState(() {});
      if (now) _autoScroll();
    }
  }

  void _kickLocalWorking() {
    _localWorkingUntil = DateTime.now().add(const Duration(seconds: 12));
    _syncThinking();
  }

  /// Live = input can be typed. Prefer the freshest signal (the /messages
  /// status), falling back to the controller's polled detail.
  bool get _isLive {
    if (_status.isNotEmpty) {
      return _status == 'running' || _status == 'starting' || _status == 'idle';
    }
    return widget.controller.selected?.isLive ?? false;
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // The terminal IS the input channel — make sure the server-side PTY is
    // attached (idempotent; the page keeps it alive across mode toggles).
    widget.controller.startTerminal();
    _fetch(full: true);
    _scheduleNextPoll();
  }

  /// Self-rescheduling poll so the interval can track the live state — 1.2s
  /// while Claude is working/waiting (realtime), 4s when idle (battery).
  Duration _pollIntervalFor() {
    final s = _activityState;
    if (s == 'working' || s == 'waiting' || _showThinking) return _pollActive;
    return _pollIdle;
  }

  void _scheduleNextPoll() {
    _poll?.cancel();
    _poll = Timer(_pollIntervalFor(), () async {
      if (AppLifecycle.isForeground) await _fetch();
      if (mounted) _scheduleNextPoll();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  bool _jumpingToBottom = false; // suppress stick-detection mid jump-loop

  void _onScroll() {
    if (!_scroll.hasClients || _jumpingToBottom) return;
    final atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 80;
    if (atBottom != _stickToBottom) {
      setState(() => _stickToBottom = atBottom);
    }
  }

  // ── Transcript polling ──────────────────────────────────────────
  Future<void> _fetch({bool full = false}) async {
    if (_fetching || !mounted) return;
    _fetching = true;
    // Periodic full reconcile heals divergence the incremental cursor can't
    // see — e.g. an EXISTING message whose content changed server-side (empty
    // tool turn → text) at an index below our `after` cursor.
    if (!full) {
      _fetchTick++;
      if (_fetchTick % 12 == 0) full = true;
    }
    try {
      final after = full ? 0 : _messages.length;
      final page = await widget.controller.api
          .chatMessages(widget.sessionId, after: after);
      if (!mounted) return;
      // History shrank/reset server-side (restart, re-parse) — reload fully.
      if (!full && page.total < _messages.length) {
        _fetching = false;
        return _fetch(full: true);
      }
      // The server jumped past our tail (we missed an index) — heal fully so a
      // message can never silently vanish into a gap.
      if (!full && page.messages.any((m) => m.i > _messages.length)) {
        _fetching = false;
        return _fetch(full: true);
      }
      final hadNew = full ? page.messages.isNotEmpty : page.messages
          .any((m) => m.i >= _messages.length);
      final hadNewAssistant = !full && page.messages
          .any((m) => m.i >= _messages.length && !m.isUser);
      setState(() {
        _noTranscript = false;
        _loading = false;
        if (full) {
          _messages
            ..clear()
            ..addAll(page.messages);
        } else {
          for (final m in page.messages) {
            if (m.i >= 0 && m.i < _messages.length) {
              _messages[m.i] = m; // updated in place (e.g. tool output landed)
            } else if (m.i == _messages.length) {
              _messages.add(m);
            }
          }
        }
        _activityState = page.activityState;
        _status = page.status;
        _statusLine = page.statusLine;
        if (page.context != null) _context = page.context;
        // A queued send is delivered once its text shows up in the transcript
        // as a user message (commands are swallowed by the parser — expire
        // them quickly); stale ones expire so they can't linger forever.
        final now = DateTime.now();
        _pendingSends.removeWhere((p) =>
            now.difference(p.ts).inSeconds >
                (p.text.startsWith('/') ? 25 : 90) ||
            page.messages.any(
                (m) => m.isUser && m.text.trim() == p.text.trim()) ||
            _messages.any(
                (m) => m.isUser && m.text.trim() == p.text.trim()));
        // The real state arrived — the optimistic flag has done its job. A
        // fresh ASSISTANT message also retires it: with a fast reply the
        // stored state can go straight back to idle without ever reading
        // "working", and the bubble would otherwise linger under the answer
        // for the rest of the 12s window.
        if (page.activityState == 'working' ||
            page.activityState == 'waiting' ||
            hadNewAssistant) {
          _localWorkingUntil = null;
        }
      });
      if (hadNew) _autoScroll(jump: full);
      _syncThinking();
      _onActivityChanged();
    } on DioException catch (e) {
      if (!mounted) return;
      if (e.response?.statusCode == 409) {
        setState(() {
          _noTranscript = true;
          _loading = false;
          _messages.clear();
        });
      } else {
        // Transient fetch failure — keep the old list, retry next tick.
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    } finally {
      _fetching = false;
    }
  }

  void _autoScroll({bool jump = false}) {
    if (!_stickToBottom) return;
    if (jump) {
      // Opening a chat must land at the BOTTOM. ListView.builder only
      // estimates its extent, so maxScrollExtent keeps growing for a few
      // frames as items lay out — one jump undershoots on long histories.
      // Re-jump each frame until the extent stabilizes (bounded).
      var tries = 0;
      _jumpingToBottom = true;
      void step() {
        if (!mounted || !_scroll.hasClients) {
          _jumpingToBottom = false;
          return;
        }
        final target = _scroll.position.maxScrollExtent;
        if (_scroll.position.pixels != target) _scroll.jumpTo(target);
        if (++tries < 12) {
          WidgetsBinding.instance.addPostFrameCallback((_) => step());
        } else {
          _jumpingToBottom = false;
        }
      }

      WidgetsBinding.instance.addPostFrameCallback((_) => step());
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    });
  }

  // ── Interactive prompt (waiting) ────────────────────────────────
  void _onActivityChanged() {
    if (_isWaiting) {
      _checkPrompt();
    } else if (_prompt != null || _dismissedPromptSig != null) {
      // The prompt resolved — forget it so the NEXT one pops fresh.
      setState(() {
        _prompt = null;
        _dismissedPromptSig = null;
      });
    }
  }

  Future<void> _checkPrompt() async {
    if (_promptFetching || _promptOpen || !mounted) return;
    _promptFetching = true;
    try {
      final p = await widget.controller.api.chatPrompt(widget.sessionId);
      if (!mounted || !p.waiting) return;
      setState(() => _prompt = p);
      // Don't re-pop the modal for the same prompt the user dismissed — the
      // header "Needs input" banner stays tappable instead.
      if (p.signature != _dismissedPromptSig) {
        _openPromptSheet(p);
      }
    } catch (_) {
      // best-effort; the banner/chip still lets the user open it manually
    } finally {
      _promptFetching = false;
    }
  }

  Future<void> _openPromptFromBanner() async {
    var p = _prompt;
    if (p == null || !p.waiting) {
      try {
        p = await widget.controller.api.chatPrompt(widget.sessionId);
      } catch (_) {
        return;
      }
      if (!mounted || !p.waiting) return;
      setState(() => _prompt = p);
    }
    _openPromptSheet(p);
  }

  Future<void> _openPromptSheet(CodingPromptState p) async {
    if (_promptOpen || !mounted) return;
    _promptOpen = true;
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PromptSheet(
        prompt: p,
        onSendKey: _sendRaw,
        onSendText: _sendText,
      ),
    );
    _promptOpen = false;
    if (!mounted) return;
    // Remember this prompt whether it was ANSWERED or dismissed: the activity
    // scan takes a few seconds to flip out of "waiting", and re-popping the
    // sheet the user just acted on is the glitch this guards against. The
    // banner stays tappable; a NEW prompt (different signature) still pops.
    setState(() => _dismissedPromptSig = p.signature);
    // Answering usually flips the state quickly — refresh soon either way.
    _fetch();
  }

  // ── Input (through the SAME path the terminal uses) ─────────────
  /// Raw byte sequence straight to the PTY (option keys, Esc, Enter).
  /// Returns whether it actually reached the server.
  Future<bool> _sendRaw(String seq) async {
    HapticFeedback.selectionClick();
    final ok = await widget.controller.sendTerminalInput(seq);
    if (!ok) {
      _sendFailedNote();
    } else {
      _kickLocalWorking(); // answering a prompt puts Claude back to work
    }
    return ok;
  }

  /// Free-text message: the text bytes, then Enter (`\r`) a beat later so the
  /// TUI registers it as typed input + submit.
  Future<bool> _sendText(String text) async {
    if (text.isEmpty) return false;
    final ok = await widget.controller.sendTerminalInput(text);
    if (!ok) {
      _sendFailedNote();
      return false;
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await widget.controller.sendTerminalInput('\r');
    if (mounted) {
      setState(() => _pendingSends.add(_PendingSend(text)));
      _autoScroll();
    }
    _kickLocalWorking();
    // Pick the echo up quickly instead of waiting for the next tick.
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted) _fetch();
    });
    return true;
  }

  void _sendFailedNote() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: JcTheme.surface,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: JcTheme.glassBorder),
      ),
      content: const Text(
        "Couldn't reach the session — check the Terminal view.",
        style: TextStyle(color: JcTheme.text, fontSize: 13),
      ),
    ));
  }

  void _openCommandSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _CommandSheet(onRun: (cmd) {
        Navigator.of(context).pop();
        _stickToBottom = true;
        _sendText(cmd);
        _autoScroll();
      }),
    );
  }

  Future<void> _sendComposer() async {
    final text = _input.text.trim();
    if (text.isEmpty && widget.controller.attachments.isEmpty) return;
    _input.clear();
    // Sending re-engages stick-to-bottom: with the keyboard up the viewport
    // shrank, so the user often isn't "at bottom" anymore and their own
    // message (and the thinking bubble) would land below the fold.
    _stickToBottom = true;
    // Upload any attachments and fold their `@path` refs into the message.
    final r = await widget.controller.consumeAttachmentsInto(text);
    if (!mounted) return;
    // Don't let a failed upload vanish silently — the message would otherwise
    // send WITHOUT the attachment and the user would never know.
    if (r.failed > 0) _attachmentFailedNote(r.failed);
    if (r.text.trim().isEmpty) return;
    await _sendText(r.text);
    _autoScroll();
  }

  void _attachmentFailedNote(int failed) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      backgroundColor: JcTheme.surface,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: JcTheme.glassBorder),
      ),
      content: Text(
        failed == 1
            ? "An attachment couldn't be uploaded — sent without it."
            : "$failed attachments couldn't be uploaded — sent without them.",
        style: const TextStyle(color: JcTheme.text, fontSize: 13),
      ),
    ));
  }

  // ── UI ──────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final showBanner = _isWaiting && !_promptOpen;
    return Column(
      children: [
        _header(),
        if (showBanner) _needsInputBanner(),
        Expanded(child: _body()),
        _ChatInputBar(
          controller: _input,
          coding: widget.controller,
          enabled: _isLive,
          onSend: _sendComposer,
          working: _showThinking,
          onCommands: _openCommandSheet,
        ),
      ],
    );
  }

  Widget _header() {
    final ctx = _context;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'Conversation',
                style: TextStyle(
                  color: JcTheme.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              _StateChip(
                state: _activityState,
                live: _isLive,
                onTap: _isWaiting ? _openPromptFromBanner : null,
              ),
            ],
          ),
          if (ctx != null) ...[
            const SizedBox(height: 7),
            _ContextGauge(ctx: ctx),
          ],
        ],
      ),
    );
  }

  Widget _needsInputBanner() {
    const purple = Color(0xFFC084FC);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _openPromptFromBanner,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: purple.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: purple.withValues(alpha: 0.35)),
            ),
            child: const Row(
              children: [
                Icon(Icons.help_outline_rounded, size: 16, color: purple),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Claude is asking for input — tap to answer',
                    style: TextStyle(
                      color: purple,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right_rounded, size: 18, color: purple),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_noTranscript) {
      return _emptyState(
        icon: Icons.chat_bubble_outline_rounded,
        text: 'No transcript yet — send a message or use the terminal.',
      );
    }
    if (_loading && _messages.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: JcTheme.muted),
      );
    }
    if (_messages.isEmpty) {
      return _emptyState(
        icon: Icons.forum_outlined,
        text: 'Nothing here yet — say something below.',
      );
    }
    final working = _showThinking;
    final pendingStart = _messages.length;
    final thinkingIdx = pendingStart + _pendingSends.length;
    return RefreshIndicator(
      color: JcTheme.primaryBlueHi,
      backgroundColor: JcTheme.surface,
      onRefresh: () => _fetch(full: true),
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        // After the transcript: any not-yet-acknowledged queued sends, then —
        // while Claude is working — a typing-style "thinking" indicator.
        itemCount: thinkingIdx + (working ? 1 : 0),
        itemBuilder: (context, idx) {
          if (idx >= thinkingIdx) {
            return _FadeIn(
              key: const ValueKey('thinking'),
              child: _ThinkingBubble(statusLine: _statusLine),
            );
          }
          if (idx >= pendingStart) {
            final p = _pendingSends[idx - pendingStart];
            return _FadeIn(
              key: ValueKey('pending-${p.ts.microsecondsSinceEpoch}'),
              child: _PendingBubble(send: p, working: working),
            );
          }
          final m = _messages[idx];
          // A tool on the LAST assistant message with no result yet is still
          // RUNNING while the session works — its card gets a live spinner.
          final live = working && idx == _messages.length - 1;
          return _FadeIn(
            key: ValueKey('msg-${m.i}'),
            child: _MessageTile(message: m, toolsRunning: live),
          );
        },
      ),
    );
  }

  Widget _emptyState({required IconData icon, required String text}) {
    // Inside a RefreshIndicator-less branch — still allow pull-to-refresh by
    // wrapping in a scrollable.
    return RefreshIndicator(
      color: JcTheme.primaryBlueHi,
      backgroundColor: JcTheme.surface,
      onRefresh: () => _fetch(full: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 90),
          Icon(icon, size: 42, color: JcTheme.muted.withValues(alpha: 0.6)),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: JcTheme.muted, fontSize: 14, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

// ── State chip (working spinner / waiting badge / idle) ───────────
class _StateChip extends StatelessWidget {
  const _StateChip({required this.state, required this.live, this.onTap});

  final String? state;
  final bool live;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final String label;
    final Color color;
    Widget? leading;
    switch (state) {
      case 'working':
        label = 'Working';
        color = const Color(0xFF34D399);
        leading = const SizedBox(
          width: 11,
          height: 11,
          child: CircularProgressIndicator(
              strokeWidth: 1.6, color: Color(0xFF34D399)),
        );
        break;
      case 'waiting':
        label = 'Needs input';
        color = const Color(0xFFC084FC);
        break;
      case 'idle':
        label = 'Idle';
        color = const Color(0xFF838B97);
        break;
      default:
        label = live ? 'Live' : 'Offline';
        color = live ? JcTheme.primaryBlueHi : JcTheme.muted;
    }
    leading ??= Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          leading,
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: chip,
      ),
    );
  }
}

/// Slim per-chat context-window gauge: a thin fill bar + "NN% · used/window".
/// The fill ramps blue → amber → red as it approaches auto-compact.
class _ContextGauge extends StatelessWidget {
  const _ContextGauge({required this.ctx});

  final ChatContext ctx;

  Color get _color {
    if (ctx.pct >= 92) return const Color(0xFFF87171); // red — near compact
    if (ctx.pct >= 80) return const Color(0xFFFBBF24); // amber — getting full
    return JcTheme.primaryBlueHi;
  }

  @override
  Widget build(BuildContext context) {
    final frac = (ctx.pct.clamp(0, 100)) / 100.0;
    final color = _color;
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Stack(
              children: [
                Container(height: 5, color: JcTheme.glassBorder),
                FractionallySizedBox(
                  widthFactor: frac == 0 ? 0.001 : frac,
                  child: Container(height: 5, color: color),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 9),
        Text(
          '${ctx.pct}% · ${ctx.usedLabel}/${ctx.windowLabel}',
          style: const TextStyle(
            color: JcTheme.muted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

// ── One-shot fade/slide-in for newly inserted messages ────────────
/// Animates once when the element is first built (keyed per message index),
/// giving smooth insertion without an AnimatedList's bookkeeping.
class _FadeIn extends StatefulWidget {
  const _FadeIn({super.key, required this.child});
  final Widget child;

  @override
  State<_FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<_FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  )..forward();

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: _ac, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.04),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _ac, curve: Curves.easeOutCubic)),
        child: widget.child,
      ),
    );
  }
}

// ── Message tile ──────────────────────────────────────────────────
class _MessageTile extends StatelessWidget {
  const _MessageTile({required this.message, this.toolsRunning = false});
  final CodingChatMessage message;

  /// True when this is the last message of a WORKING session — its tools that
  /// have no result yet are still executing and render a live spinner.
  final bool toolsRunning;

  @override
  Widget build(BuildContext context) {
    final m = message;
    if (m.isUser) return _userBubble(context);
    return _assistantBlock(context);
  }

  Widget _userBubble(BuildContext context) {
    final maxW = MediaQuery.of(context).size.width * 0.78;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: JcTheme.primaryBlue.withValues(alpha: 0.22),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(5),
                ),
                border: Border.all(
                    color: JcTheme.primaryBlue.withValues(alpha: 0.35)),
              ),
              child: _LightMarkdown(text: message.text),
            ),
          ),
          _Timestamp(ts: message.ts, alignEnd: true),
        ],
      ),
    );
  }

  Widget _assistantBlock(BuildContext context) {
    final m = message;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 24),
              child: _LightMarkdown(text: m.text),
            ),
          for (final t in m.tools)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 24),
              child: _ToolCard(
                tool: t,
                // Spin only while the tool/subagent is genuinely in flight
                // (ok == null). A COMPLETED tool with empty output must not
                // spin forever just because its turn is still working.
                running: toolsRunning && t.running,
              ),
            ),
          _Timestamp(ts: m.ts, alignEnd: false),
        ],
      ),
    );
  }
}

class _Timestamp extends StatelessWidget {
  const _Timestamp({required this.ts, required this.alignEnd});
  final double? ts;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final t = ts;
    if (t == null || t <= 0) return const SizedBox.shrink();
    final dt = DateTime.fromMillisecondsSinceEpoch((t * 1000).round());
    final now = DateTime.now();
    final sameDay = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    String two(int v) => v.toString().padLeft(2, '0');
    final label = sameDay
        ? '${two(dt.hour)}:${two(dt.minute)}'
        : '${two(dt.month)}/${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(
        label,
        textAlign: alignEnd ? TextAlign.end : TextAlign.start,
        style: TextStyle(
          color: JcTheme.muted.withValues(alpha: 0.65),
          fontSize: 10.5,
        ),
      ),
    );
  }
}

// ── Markdown (full renderer via the app's shared MarkdownStream, themed
// to the coding chat: dark code blocks, glass borders, Menlo mono) ─
class _LightMarkdown extends StatelessWidget {
  const _LightMarkdown({required this.text});
  final String text;

  static const _body =
      TextStyle(color: JcTheme.text, fontSize: 14.5, height: 1.45);

  @override
  Widget build(BuildContext context) {
    return MarkdownStream(
      text: text,
      style: MarkdownStyleSheet(
        p: _body,
        listBullet: _body,
        tableBody: _body.copyWith(fontSize: 13),
        strong: const TextStyle(
            color: JcTheme.text, fontWeight: FontWeight.w700),
        em: const TextStyle(
            color: JcTheme.text, fontStyle: FontStyle.italic),
        a: const TextStyle(color: JcTheme.primaryBlueHi),
        code: const TextStyle(
          fontFamily: 'Menlo',
          fontSize: 12.5,
          color: Color(0xFFD7DAE0),
          backgroundColor: Color(0x33000000),
        ),
        codeblockDecoration: BoxDecoration(
          color: const Color(0xFF0A0D13),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: JcTheme.glassBorder),
        ),
        codeblockPadding: const EdgeInsets.all(10),
        h1: _body.copyWith(fontSize: 19, fontWeight: FontWeight.w700),
        h2: _body.copyWith(fontSize: 17, fontWeight: FontWeight.w700),
        h3: _body.copyWith(fontSize: 15.5, fontWeight: FontWeight.w700),
        blockquoteDecoration: const BoxDecoration(
          border: Border(
            left: BorderSide(color: JcTheme.primaryBlue, width: 3),
          ),
          color: JcTheme.glassFill,
        ),
        horizontalRuleDecoration: const BoxDecoration(
          border: Border(top: BorderSide(color: JcTheme.glassBorder)),
        ),
      ),
    );
  }
}

// ── Tool-use card (compact, collapsible) ──────────────────────────
class _ToolCard extends StatefulWidget {
  const _ToolCard({required this.tool, this.running = false});
  final CodingChatTool tool;
  final bool running;

  @override
  State<_ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<_ToolCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.tool;
    final ok = t.ok;
    final isSub = t.isSubagent;
    final running = widget.running || t.running;
    final hasOutput = t.output.trim().isNotEmpty;
    const subColor = Color(0xFFC084FC); // subagent purple
    return Container(
      decoration: BoxDecoration(
        color: isSub ? subColor.withValues(alpha: 0.07) : JcTheme.glassFill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isSub ? subColor.withValues(alpha: 0.30) : JcTheme.glassBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: hasOutput ? () => setState(() => _expanded = !_expanded) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                child: Row(
                  children: [
                    if (running)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: isSub ? subColor : const Color(0xFF34D399),
                        ),
                      )
                    else
                      Icon(
                        isSub
                            ? (ok
                                ? Icons.account_tree_rounded
                                : Icons.error_outline_rounded)
                            : (ok
                                ? Icons.build_circle_outlined
                                : Icons.error_outline_rounded),
                        size: 16,
                        color: isSub
                            ? (ok ? subColor : JcTheme.danger)
                            : (ok ? JcTheme.cyan : JcTheme.danger),
                      ),
                    const SizedBox(width: 8),
                    Text(
                      isSub
                          ? (t.subagentType.isNotEmpty
                              ? t.subagentType
                              : 'subagent')
                          : t.name,
                      style: TextStyle(
                        color: isSub ? subColor : JcTheme.text,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'Menlo',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t.summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: JcTheme.muted,
                          fontSize: 12,
                          fontFamily: 'Menlo',
                        ),
                      ),
                    ),
                    if (hasOutput)
                      Icon(
                        _expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18,
                        color: JcTheme.muted,
                      ),
                  ],
                ),
              ),
            ),
          ),
          // File-edit tools render their DIFF inline (always visible) —
          // red/green lines like a real diff view, not just "edited a file".
          if (t.diff.isNotEmpty) _DiffBlock(lines: t.diff),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: !_expanded || !hasOutput
                ? const SizedBox(width: double.infinity)
                : Container(
                    width: double.infinity,
                    color: const Color(0xFF0A0D13),
                    padding: const EdgeInsets.all(10),
                    child: SelectableText(
                      t.output.trimRight(),
                      style: const TextStyle(
                        color: Color(0xFFB9BFC9),
                        fontSize: 11.5,
                        height: 1.45,
                        fontFamily: 'Menlo',
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ── Chat input bar ────────────────────────────────────────────────
class _ChatInputBar extends StatelessWidget {
  const _ChatInputBar({
    required this.controller,
    required this.coding,
    required this.enabled,
    required this.onSend,
    this.working = false,
    this.onCommands,
  });

  final TextEditingController controller;
  final CodingSessionsController coding;
  final bool enabled;
  final VoidCallback onSend;

  /// Claude is mid-turn: sends still work (the TUI queues/steers them) — the
  /// hint says so.
  final bool working;

  /// Opens the slash-command sheet.
  final VoidCallback? onCommands;

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 6, 12, 8 + bottomPad),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: JcTheme.glassFill,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: JcTheme.glassBorder),
            ),
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AttachmentChips(controller: coding),
                Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                AttachButton(controller: coding, enabled: enabled),
                IconButton(
                  onPressed: enabled ? onCommands : null,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Commands',
                  icon: Text(
                    '/',
                    style: TextStyle(
                      color: enabled
                          ? JcTheme.primaryBlueHi
                          : JcTheme.muted.withValues(alpha: 0.5),
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'Menlo',
                    ),
                  ),
                ),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 120),
                    child: TextField(
                      controller: controller,
                      enabled: enabled,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                      style: const TextStyle(color: JcTheme.text, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: !enabled
                            ? 'Session isn’t live'
                            : working
                                ? 'Steer Claude — queues mid-turn…'
                                : 'Message Claude…',
                        hintStyle: const TextStyle(color: JcTheme.muted),
                        filled: true,
                        fillColor: Colors.transparent,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 0, vertical: 10),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: enabled ? onSend : null,
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: enabled ? blueGradient() : null,
                      color: enabled ? null : JcTheme.glassFill,
                      shape: BoxShape.circle,
                      border: enabled
                          ? null
                          : Border.all(color: JcTheme.glassBorder),
                    ),
                    child: Icon(
                      Icons.arrow_upward,
                      color: enabled ? Colors.white : JcTheme.muted,
                      size: 20,
                    ),
                  ),
                ),
              ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Interactive-prompt bottom sheet ───────────────────────────────
/// Shown when Claude is waiting for input. Structured options become one
/// button each (sends just the option's KEY — no newline); otherwise the raw
/// pane tail is shown monospace with Esc / Enter controls. A free-text field
/// is always available (text + `\r`).
///
/// Every action AWAITS delivery: the tapped control shows a spinner, the
/// sheet only closes once the keys actually reached the server, and a failed
/// send keeps it open with an inline error (the old fire-and-forget version
/// closed instantly and the unanswered prompt re-popped — the glitch).
class _PromptSheet extends StatefulWidget {
  const _PromptSheet({
    required this.prompt,
    required this.onSendKey,
    required this.onSendText,
  });

  final CodingPromptState prompt;
  final Future<bool> Function(String seq) onSendKey;
  final Future<bool> Function(String text) onSendText;

  @override
  State<_PromptSheet> createState() => _PromptSheetState();
}

class _PromptSheetState extends State<_PromptSheet> {
  static const _purple = Color(0xFFC084FC);

  final _text = TextEditingController();
  String? _pending; // the action currently being delivered (option key/esc/…)
  bool _failed = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _deliver(String tag, Future<bool> Function() send) async {
    if (_pending != null) return;
    setState(() {
      _pending = tag;
      _failed = false;
    });
    final ok = await send();
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _pending = null;
        _failed = true;
      });
    }
  }

  void _answerKey(String key) =>
      _deliver(key, () => widget.onSendKey(key)); // just the key — NO newline

  void _esc() => _deliver('esc', () => widget.onSendKey('\x1b'));

  void _enter() => _deliver('enter', () => widget.onSendKey('\r'));

  void _sendFree() {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    _deliver('text', () => widget.onSendText(t));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.prompt;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final hasOptions = p.options.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: BoxDecoration(
          color: JcTheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: JcTheme.glassBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 30,
              offset: const Offset(0, -8),
            ),
          ],
        ),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: JcTheme.muted.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: _purple.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                      border:
                          Border.all(color: _purple.withValues(alpha: 0.35)),
                    ),
                    child: const Icon(Icons.touch_app_rounded,
                        size: 19, color: _purple),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'CLAUDE NEEDS YOUR INPUT',
                          style: TextStyle(
                            color: _purple.withValues(alpha: 0.9),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          (p.question ?? '').trim().isNotEmpty
                              ? p.question!.trim()
                              : 'Choose how to continue',
                          style: const TextStyle(
                            color: JcTheme.text,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(height: 1, color: JcTheme.glassBorder),
              const SizedBox(height: 14),
              if (hasOptions) ...[
                for (final o in p.options)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _OptionButton(
                      keyLabel: o.key,
                      label: o.label,
                      pending: _pending == o.key,
                      disabled: _pending != null && _pending != o.key,
                      onTap: () => _answerKey(o.key),
                    ),
                  ),
              ] else if ((p.raw ?? '').trim().isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0D13),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: JcTheme.glassBorder),
                  ),
                  child: Text(
                    p.raw!.trimRight(),
                    style: const TextStyle(
                      color: Color(0xFFD7DAE0),
                      fontSize: 11.5,
                      height: 1.45,
                      fontFamily: 'Menlo',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: _pending == 'esc' ? 'Sending…' : 'Esc',
                      icon: Icons.keyboard_return_rounded,
                      ghost: true,
                      full: true,
                      onPressed: _pending == null ? _esc : null,
                    ),
                  ),
                  if (!hasOptions) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: GlassButton(
                        label: _pending == 'enter' ? 'Sending…' : 'Enter',
                        icon: Icons.keyboard_double_arrow_right_rounded,
                        ghost: true,
                        full: true,
                        onPressed: _pending == null ? _enter : null,
                      ),
                    ),
                  ],
                ],
              ),
              if (_failed) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.error_outline_rounded,
                        size: 15, color: JcTheme.danger),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        "Couldn't reach the session — it may have detached. "
                        'Try again or use the Terminal view.',
                        style: TextStyle(
                          color: JcTheme.danger.withValues(alpha: 0.95),
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      minLines: 1,
                      maxLines: 4,
                      style: const TextStyle(color: JcTheme.text, fontSize: 14),
                      decoration: const InputDecoration(
                        hintText: 'Or type a reply…',
                        hintStyle: TextStyle(color: JcTheme.muted),
                      ),
                      onSubmitted: (_) => _sendFree(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _pending == null ? _sendFree : null,
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        gradient: blueGradient(),
                        shape: BoxShape.circle,
                      ),
                      child: _pending == 'text'
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.arrow_upward,
                              color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One structured prompt option: a numbered key chip + its label, with a
/// delivery spinner while its keypress is in flight.
class _OptionButton extends StatelessWidget {
  const _OptionButton({
    required this.keyLabel,
    required this.label,
    required this.onTap,
    this.pending = false,
    this.disabled = false,
  });

  final String keyLabel;
  final String label;
  final VoidCallback onTap;
  final bool pending;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final dim = disabled ? 0.45 : 1.0;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: dim,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: (pending || disabled) ? null : onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: JcTheme.primaryBlue
                  .withValues(alpha: pending ? 0.2 : 0.12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                  color: JcTheme.primaryBlue.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: JcTheme.primaryBlue.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    keyLabel,
                    style: const TextStyle(
                      color: JcTheme.primaryBlueHi,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'Menlo',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label.isEmpty ? 'Option $keyLabel' : label,
                    style: const TextStyle(
                      color: JcTheme.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (pending)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.8, color: JcTheme.primaryBlueHi),
                  )
                else
                  const Icon(Icons.chevron_right_rounded,
                      size: 18, color: JcTheme.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Diff block (red/green unified-diff lines for file-edit tools) ──
class _DiffBlock extends StatelessWidget {
  const _DiffBlock({required this.lines});
  final List<String> lines;

  static const _add = Color(0xFF34D399);
  static const _del = Color(0xFFF87171);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF0A0D13),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final ln in lines) _line(ln)],
          ),
        ),
      ),
    );
  }

  Widget _line(String ln) {
    Color? bg;
    Color fg = const Color(0xFFB9BFC9);
    if (ln.startsWith('+')) {
      bg = _add.withValues(alpha: 0.13);
      fg = _add;
    } else if (ln.startsWith('-')) {
      bg = _del.withValues(alpha: 0.13);
      fg = _del;
    } else if (ln.startsWith('@@')) {
      fg = JcTheme.muted;
    }
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Text(
        ln.isEmpty ? ' ' : ln,
        style: TextStyle(
          color: fg,
          fontSize: 11.5,
          height: 1.4,
          fontFamily: 'Menlo',
        ),
      ),
    );
  }
}

// ── Queued/steering sends (awaiting transcript acknowledgement) ────
class _PendingSend {
  _PendingSend(this.text) : ts = DateTime.now();
  final String text;
  final DateTime ts;
}

/// A user message delivered to the PTY but not yet visible in the transcript
/// — "Queued" while Claude is mid-turn (the TUI processes it after the turn).
class _PendingBubble extends StatelessWidget {
  const _PendingBubble({required this.send, required this.working});
  final _PendingSend send;
  final bool working;

  @override
  Widget build(BuildContext context) {
    final maxW = MediaQuery.of(context).size.width * 0.78;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxW),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: JcTheme.primaryBlue.withValues(alpha: 0.10),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(5),
                ),
                border: Border.all(
                    color: JcTheme.primaryBlue.withValues(alpha: 0.22)),
              ),
              child: Text(
                send.text,
                style: TextStyle(
                  color: JcTheme.text.withValues(alpha: 0.75),
                  fontSize: 14.5,
                  height: 1.45,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(working ? Icons.schedule_rounded : Icons.check_rounded,
                    size: 11, color: JcTheme.muted.withValues(alpha: 0.7)),
                const SizedBox(width: 3),
                Text(
                  working ? 'Queued' : 'Sent',
                  style: TextStyle(
                    color: JcTheme.muted.withValues(alpha: 0.7),
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Slash-command sheet ─────────────────────────────────────────────
class _CommandSheet extends StatelessWidget {
  const _CommandSheet({required this.onRun});
  final void Function(String cmd) onRun;

  static const _commands = [
    ('/compact', 'Summarize the conversation and shrink context'),
    ('/clear', 'Reset the conversation'),
    ('/context', 'Show what is using up the context window'),
    ('/cost', 'Show token usage and cost for this session'),
    ('/model', 'Show or change the model'),
    ('/todos', 'Show the current task list'),
  ];

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return Container(
      decoration: BoxDecoration(
        color: JcTheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: JcTheme.glassBorder),
      ),
      padding: EdgeInsets.fromLTRB(20, 10, 20, 16 + bottomPad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: JcTheme.muted.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const Text(
            'COMMANDS',
            style: TextStyle(
              color: JcTheme.muted,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          for (final (cmd, desc) in _commands)
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onRun(cmd),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
                  child: Row(
                    children: [
                      Text(
                        cmd,
                        style: const TextStyle(
                          color: JcTheme.primaryBlueHi,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'Menlo',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          desc,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: JcTheme.muted, fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── "Thinking" indicator (typing-style, shown while Claude works) ──
class _ThinkingBubble extends StatefulWidget {
  const _ThinkingBubble({this.statusLine});

  /// The live spinner line ("✳ Zesting… (50s · ↑ 2.0k tokens)") — shown
  /// instead of the generic "Working…" when available.
  final String? statusLine;

  @override
  State<_ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<_ThinkingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: JcTheme.glassFill,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(5),
                topRight: Radius.circular(16),
                bottomLeft: Radius.circular(16),
                bottomRight: Radius.circular(16),
              ),
              border: Border.all(color: JcTheme.glassBorder),
            ),
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < 3; i++) ...[
                      if (i > 0) const SizedBox(width: 5),
                      _dot(((_c.value + 1 - i * 0.18) % 1.0)),
                    ],
                    const SizedBox(width: 10),
                    _label(),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// "Working…" fallback, or the live status line parsed into styled parts:
  /// verb (salmon) · elapsed (muted) · tokens (blue) · effort (purple).
  Widget _label() {
    const green = Color(0xFF34D399);
    const salmon = Color(0xFFFB7185);
    const blue = JcTheme.primaryBlueHi;
    const purple = Color(0xFFC084FC);
    final st = LiveStatus.parse(widget.statusLine);
    if (st == null) {
      return Text(
        'Working…',
        style: TextStyle(
          color: green.withValues(alpha: 0.9),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    const sep = TextStyle(color: JcTheme.muted, fontSize: 11.5,
        fontFamily: 'Menlo');
    final spans = <TextSpan>[
      TextSpan(
        text: st.verb,
        style: const TextStyle(
          color: salmon,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          fontFamily: 'Menlo',
        ),
      ),
    ];
    void seg(String? text, Color color) {
      if (text == null || text.isEmpty) return;
      spans
        ..add(const TextSpan(text: '  ·  ', style: sep))
        ..add(TextSpan(
          text: text,
          style: TextStyle(
              color: color, fontSize: 11.5, fontFamily: 'Menlo'),
        ));
    }

    seg(st.elapsed, JcTheme.muted);
    seg(st.tokens, blue.withValues(alpha: 0.9));
    seg(st.effort, purple.withValues(alpha: 0.9));
    for (final e in st.extra) {
      seg(e, JcTheme.muted);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: Text.rich(
        TextSpan(children: spans),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// One pulsing dot: phase 0..1 → eased rise-and-fall of opacity + lift.
  Widget _dot(double phase) {
    final wave = (1 - (phase * 2 - 1).abs()).clamp(0.0, 1.0);
    final eased = Curves.easeInOut.transform(wave);
    return Transform.translate(
      offset: Offset(0, -2.5 * eased),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: const Color(0xFF34D399)
              .withValues(alpha: 0.35 + 0.65 * eased),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
