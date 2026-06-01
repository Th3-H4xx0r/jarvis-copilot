import 'package:flutter/material.dart';

import '../chat/chat_controller.dart';
import '../chat/widgets/message_view.dart';
import '../chat/widgets/sessions_drawer.dart';
import '../main.dart' as app;
import '../theme.dart';

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
      backgroundColor: JcTheme.bg,
      drawer: SessionsDrawer(controller: _c),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.menu_rounded),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: ListenableBuilder(
          listenable: _c,
          builder: (_, __) => Text(
            _c.sessionTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'New chat',
            icon: const Icon(Icons.edit_square),
            onPressed: () {
              _composer.clear();
              _c.startNewSession();
            },
          ),
        ],
      ),
      body: Column(
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
            decoration: const BoxDecoration(
              gradient: JcTheme.brandGradient,
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
    return Container(
      decoration: const BoxDecoration(
        color: JcTheme.bg,
        border: Border(top: BorderSide(color: JcTheme.border)),
      ),
      padding: EdgeInsets.fromLTRB(
        10,
        8,
        10,
        8 + MediaQuery.of(context).viewPadding.bottom,
      ),
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
                decoration: InputDecoration(
                  hintText: 'Message JarvisCopilot…',
                  hintStyle: const TextStyle(color: JcTheme.muted),
                  filled: true,
                  fillColor: JcTheme.surfaceAlt,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: const BorderSide(color: JcTheme.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: const BorderSide(color: JcTheme.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide:
                        const BorderSide(color: JcTheme.accent, width: 1.3),
                  ),
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
          gradient: streaming ? null : JcTheme.brandGradient,
          color: streaming ? JcTheme.surfaceAlt : null,
          shape: BoxShape.circle,
          border: streaming ? Border.all(color: JcTheme.border) : null,
        ),
        child: Icon(
          streaming ? Icons.stop : Icons.arrow_upward,
          color: streaming ? JcTheme.danger : Colors.white,
          size: 22,
        ),
      ),
    );
  }
}
