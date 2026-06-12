import 'dart:ui';

import 'package:flutter/material.dart';

import '../chat/chat_controller.dart';
import '../chat/widgets/message_view.dart';
import '../chat/widgets/sessions_drawer.dart';
import '../main.dart' as app;
import '../services/on_device_ai_types.dart';
import '../theme.dart';
import '../voice/voice_orb.dart';
import '../voice/voice_state.dart';
import '../widgets/glass.dart';
import '../widgets/model_picker_sheet.dart';

/// Native chat screen — a from-scratch recreation of the webui chat
/// interface (sessions sidebar, streaming markdown replies, tool cards,
/// thinking traces) instead of the old embedded WebView.
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final ChatController _c = ChatController(app.api);
  final _composer = TextEditingController();
  final _scroll = ScrollController();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // Track the open session so we can jump to the newest message when a
  // chat is opened/switched (vs. the gentle follow used while streaming).
  String? _lastSessionId;
  bool _jumpPending = false;

  bool _wasVisible = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(_autoScroll);
    // Live chats: poll the list only while this tab is visible, and pull the
    // latest list + open thread each time the tab regains focus, so turns added
    // elsewhere (a voice conversation) show up without a manual reload.
    app.activeTabIndex.addListener(_onTabVisibility);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _c.openInitial();
      _onTabVisibility();
    });
  }

  void _onTabVisibility() {
    final visible = app.activeTabIndex.value == app.kChatTabIndex;
    _c.setListPolling(visible);
    if (visible && !_wasVisible) _c.refreshOnFocus(); // became visible → refresh
    _wasVisible = visible;
  }

  @override
  void dispose() {
    app.activeTabIndex.removeListener(_onTabVisibility);
    _c.removeListener(_autoScroll);
    _c.dispose();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _autoScroll() {
    // Opening or switching a session: jump to the latest message once its
    // history has loaded, regardless of current scroll position.
    if (_c.sessionId != _lastSessionId) {
      _lastSessionId = _c.sessionId;
      _jumpPending = true;
    }
    if (_jumpPending && !_c.historyLoading && _c.messages.isNotEmpty) {
      _jumpPending = false;
      _pinToBottom();
      return;
    }

    // Otherwise keep pinned to the newest content while streaming, but
    // only if the user is already near the bottom (don't yank them up).
    if (!_scroll.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (max - _scroll.offset < 240) {
        _scroll.jumpTo(max);
      }
    });
  }

  /// Jump to the very bottom when a chat is opened. A single jump lands short
  /// because the thread keeps growing taller across frames (markdown, tool
  /// cards, images render after the first layout), so re-pin a few times over a
  /// short window until the height settles.
  void _pinToBottom([int tries = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      if (tries < 6) {
        Future.delayed(const Duration(milliseconds: 50),
            () => _pinToBottom(tries + 1));
      }
    });
  }

  void _send() {
    final text = _composer.text;
    if (text.trim().isEmpty || _c.streaming) return;
    _composer.clear();
    _c.send(text);
    FocusScope.of(context).unfocus();
  }

  // A starter chip on the empty state: send it straight away.
  void _onSuggestion(String text) {
    if (_c.streaming) return;
    _composer.clear();
    _c.send(text);
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      drawer: SessionsDrawer(controller: _c),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leadingWidth: 60,
        leading: Padding(
          padding: const EdgeInsets.only(left: 16),
          child: GlassIconButton(
            icon: Icons.menu_rounded,
            onTap: () => _scaffoldKey.currentState?.openDrawer(),
          ),
        ),
        title: ListenableBuilder(
          listenable: _c,
          builder: (_, __) => Text(
            _c.sessionTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: JcTheme.text,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        actions: [
          GlassIconButton(
            icon: Icons.auto_awesome_rounded,
            onTap: () => showModelPickerSheet(context, VoiceSurface.chat),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 16),
            child: GlassIconButton(
              icon: Icons.edit_square,
              onTap: () {
                _composer.clear();
                _c.startNewSession();
              },
            ),
          ),
        ],
      ),
      body: AppBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: ListenableBuilder(
                  listenable: _c,
                  builder: (context, _) => _buildBody(),
                ),
              ),
              ListenableBuilder(
                listenable: _c,
                builder: (_, __) {
                  final clarify = _c.pendingClarify;
                  if (clarify == null) return const SizedBox.shrink();
                  return _ClarifyPrompt(
                    question: (clarify['question'] ?? '').toString(),
                    choices: ((clarify['choices'] as List?) ?? const [])
                        .map((c) => c.toString())
                        .toList(),
                    onAnswer: _c.respondClarify,
                  );
                },
              ),
              _Composer(
                controller: _composer,
                chat: _c,
                onSend: _send,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_c.historyLoading && _c.messages.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_c.messages.isEmpty) {
      return _EmptyState(onSuggestion: _onSuggestion);
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      itemCount: _c.messages.length,
      itemBuilder: (context, i) => MessageView(message: _c.messages[i]),
    );
  }
}

/// New-chat welcome screen: the brand orb hero, a gradient greeting, a frosted
/// blurb, and a few tappable starter chips that kick off a conversation.
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onSuggestion});

  final ValueChanged<String> onSuggestion;

  static const _suggestions = [
    "What can you do?",
    "Summarize my day",
    "Check my devices",
    "Run a skill",
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.of(context).size.height * 0.62,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const VoiceOrb(
              state: VoiceState.idle,
              amplitude: AlwaysStoppedAnimation(0.0),
              size: 156,
            ),
            const SizedBox(height: 24),
            const GradientText(
              'Hello, I’m JARVIS',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
                height: 1.15,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Your intelligent copilot — ask anything, or run a skill on your devices.',
              textAlign: TextAlign.center,
              style: TextStyle(color: JcTheme.muted, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 26),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final s in _suggestions)
                  _SuggestionChip(label: s, onTap: () => onSuggestion(s)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A frosted starter-prompt pill.
class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(
            color: JcTheme.glassFill,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: JcTheme.glassBorder),
          ),
          child: Text(
            label,
            style: const TextStyle(
                color: JcTheme.text, fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.chat,
    required this.onSend,
  });

  final TextEditingController controller;
  final ChatController chat;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 8, 12, 8 + bottomPad),
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
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 140),
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      keyboardType: TextInputType.multiline,
                      style: const TextStyle(color: JcTheme.text, fontSize: 15),
                      decoration: const InputDecoration(
                        hintText: 'Message JarvisCopilot…',
                        hintStyle: TextStyle(color: JcTheme.muted),
                        filled: true,
                        fillColor: Colors.transparent,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 0,
                          vertical: 10,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Only the send/stop button reacts to streaming state — keep
                // the TextField out of the rebuild path so streamed tokens
                // don't churn the keyboard/cursor.
                ListenableBuilder(
                  listenable: chat,
                  builder: (context, _) => _SendButton(
                    streaming: chat.streaming,
                    onSend: onSend,
                    onStop: chat.cancel,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.streaming,
    required this.onSend,
    required this.onStop,
  });

  final bool streaming;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: streaming ? onStop : onSend,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          gradient: streaming ? null : blueGradient(),
          color: streaming ? JcTheme.glassFill : null,
          shape: BoxShape.circle,
          border: streaming
              ? Border.all(color: JcTheme.glassBorder)
              : null,
          boxShadow: streaming
              ? null
              : [
                  BoxShadow(
                    color: JcTheme.primaryBlue.withValues(alpha: 0.4),
                    blurRadius: 24,
                    offset: const Offset(0, 4),
                  ),
                ],
        ),
        child: Icon(
          streaming ? Icons.stop : Icons.arrow_upward,
          color: streaming ? JcTheme.muted : Colors.white,
          size: 22,
        ),
      ),
    );
  }
}

/// Inline prompt shown when the agent asks a clarify question — the question +
/// tappable choice chips (and the composer can also be typed into). Answering
/// resumes the blocked turn instead of leaving it stuck on "thinking".
class _ClarifyPrompt extends StatelessWidget {
  const _ClarifyPrompt({
    required this.question,
    required this.choices,
    required this.onAnswer,
  });

  final String question;
  final List<String> choices;
  final void Function(String) onAnswer;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: JcTheme.cyan.withValues(alpha: 0.10),
        border: Border.all(color: JcTheme.cyan.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.help_outline_rounded, size: 15, color: JcTheme.cyan),
            SizedBox(width: 6),
            Text('Quick question',
                style: TextStyle(
                    color: JcTheme.cyan,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 6),
          Text(question,
              style: const TextStyle(
                  color: JcTheme.text, fontSize: 14, height: 1.35)),
          if (choices.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in choices)
                  GestureDetector(
                    onTap: () => onAnswer(c),
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: JcTheme.cyan.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                            color: JcTheme.cyan.withValues(alpha: 0.40)),
                      ),
                      child: Text(c,
                          style: const TextStyle(
                              color: JcTheme.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
