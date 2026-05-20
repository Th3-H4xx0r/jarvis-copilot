import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../theme.dart';

class ChatMessageBubble extends StatelessWidget {
  const ChatMessageBubble({
    super.key,
    required this.role, // "user" | "assistant" | "system"
    required this.text,
    this.streaming = false,
  });

  final String role;
  final String text;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final isUser = role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.84,
        ),
        decoration: BoxDecoration(
          color: isUser ? JcTheme.surfaceAlt : JcTheme.surface,
          border: Border.all(color: JcTheme.border),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isUser ? 14 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 14),
          ),
        ),
        child: MarkdownBody(
          data: streaming && text.isEmpty ? '…' : text,
          styleSheet: MarkdownStyleSheet(
            p: const TextStyle(color: JcTheme.text, fontSize: 14, height: 1.4),
            code: const TextStyle(
              fontFamily: 'monospace',
              color: JcTheme.accent,
              backgroundColor: Color(0x33000000),
            ),
            codeblockDecoration: BoxDecoration(
              color: const Color(0xFF0F1830),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: JcTheme.border),
            ),
          ),
          selectable: true,
          softLineBreak: true,
        ),
      ),
    );
  }
}
