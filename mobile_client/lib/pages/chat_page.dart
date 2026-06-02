import 'dart:ui';

import 'package:flutter/material.dart';

import '../chat/chat_controller.dart';
import '../chat/widgets/message_view.dart';
import '../chat/widgets/sessions_drawer.dart';
import '../main.dart' as app;
import '../theme.dart';
import '../widgets/glass.dart';

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

  @override
  void initState() {
    super.initState();
    _c.addListener(_autoScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _c.openInitial());
  }

  @override
  void dispose() {
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
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

  void _send() {
    final text = _composer.text;
    if (text.trim().isEmpty || _c.streaming) return;
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
          Padding(
            padding: const EdgeInsets.only(right: 16),
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
        child: Column(
          children: [
            Expanded(
              child: ListenableBuilder(
                listenable: _c,
                builder: (context, _) => _buildBody(),
              ),
            ),
            _Composer(
              controller: _composer,
              chat: _c,
              onSend: _send,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_c.historyLoading && _c.messages.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_c.messages.isEmpty) {
      return const _EmptyState();
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      itemCount: _c.messages.length,
      itemBuilder: (context, i) => MessageView(message: _c.messages[i]),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              gradient: blueGradient(),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Text(
              'J',
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'How can I help?',
            style: TextStyle(
              color: JcTheme.text,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Ask anything, or run a skill on your devices.',
            style: TextStyle(color: JcTheme.muted, fontSize: 13),
          ),
        ],
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
